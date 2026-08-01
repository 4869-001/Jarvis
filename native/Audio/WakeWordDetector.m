#import "WakeWordDetector.h"
#import "AudioHub.h"

#import <AVFoundation/AVFoundation.h>
#import "sherpa-onnx/c-api/c-api.h"

// KWS 模型固定要求 16k / 80 维 fbank
static const double kModelSampleRate = 16000.0;
static const int32_t kFeatureDim = 80;

// 同一个词连续触发的最小间隔。说一次"贾维斯"模型可能连报两帧。
static const NSTimeInterval kRetriggerGuard = 1.5;

@interface WakeWordDetector ()
@property (nonatomic, copy) NSString *modelDirectory;
@property (nonatomic, copy) NSString *keywordsFile;
@property (nonatomic, assign) float score;
@property (nonatomic, assign) float threshold;

@property (nonatomic, assign) const SherpaOnnxKeywordSpotter *spotter;
@property (nonatomic, assign) const SherpaOnnxOnlineStream *stream;
@property (nonatomic, strong) AVAudioConverter *converter;
@property (nonatomic, strong) AVAudioFormat *modelFormat;
@property (nonatomic, copy)   NSString *tapToken;
@property (nonatomic, strong) dispatch_queue_t decodeQueue;
@property (nonatomic, assign) BOOL running;
@property (nonatomic, assign) NSTimeInterval lastTrigger;
@property (nonatomic, assign) NSTimeInterval startedAt;
@property (nonatomic, assign) NSTimeInterval lastLevelLog;
@property (nonatomic, assign) float peakSinceStart;
@end

@implementation WakeWordDetector

- (instancetype)initWithModelDirectory:(NSString *)modelDirectory
                          keywordsFile:(NSString *)keywordsFile
                                 score:(float)score
                             threshold:(float)threshold {
    if ((self = [super init])) {
        _modelDirectory = [modelDirectory copy];
        _keywordsFile = [keywordsFile copy];
        _score = score > 0 ? score : 1.5f;
        _threshold = threshold > 0 ? threshold : 0.25f;
        // 解码放独立串行队列：绝不能在 CoreAudio 的实时线程上跑神经网络
        _decodeQueue = dispatch_queue_create("com.jarvis.kws", DISPATCH_QUEUE_SERIAL);
    }
    return self;
}

- (void)dealloc { [self stop]; }

#pragma mark - 启停

- (BOOL)start {
    if (self.running) return YES;

    NSFileManager *fm = [NSFileManager defaultManager];
    NSString *encoder = [self.modelDirectory stringByAppendingPathComponent:
                         @"encoder-epoch-13-avg-2-chunk-16-left-64.int8.onnx"];
    NSString *decoder = [self.modelDirectory stringByAppendingPathComponent:
                         @"decoder-epoch-13-avg-2-chunk-16-left-64.onnx"];
    NSString *joiner  = [self.modelDirectory stringByAppendingPathComponent:
                         @"joiner-epoch-13-avg-2-chunk-16-left-64.int8.onnx"];
    NSString *tokens  = [self.modelDirectory stringByAppendingPathComponent:@"tokens.txt"];

    for (NSString *path in @[encoder, decoder, joiner, tokens, self.keywordsFile]) {
        if (![fm fileExistsAtPath:path]) {
            [self.delegate wakeWordDetector:self failed:
             [NSString stringWithFormat:@"唤醒模型缺文件：%@", path.lastPathComponent]];
            return NO;
        }
    }

    SherpaOnnxKeywordSpotterConfig config;
    memset(&config, 0, sizeof(config));
    config.feat_config.sample_rate = (int32_t)kModelSampleRate;
    config.feat_config.feature_dim = kFeatureDim;
    config.model_config.transducer.encoder = encoder.fileSystemRepresentation;
    config.model_config.transducer.decoder = decoder.fileSystemRepresentation;
    config.model_config.transducer.joiner  = joiner.fileSystemRepresentation;
    config.model_config.tokens = tokens.fileSystemRepresentation;
    config.model_config.num_threads = 1;        // 8GB 的 Air，常驻的东西省着点
    config.model_config.provider = "cpu";
    config.model_config.debug = 0;
    config.max_active_paths = 4;
    config.num_trailing_blanks = 1;
    config.keywords_score = self.score;
    config.keywords_threshold = self.threshold;
    config.keywords_file = self.keywordsFile.fileSystemRepresentation;

    self.spotter = SherpaOnnxCreateKeywordSpotter(&config);
    if (!self.spotter) {
        [self.delegate wakeWordDetector:self failed:@"唤醒词模型加载失败"];
        return NO;
    }
    self.stream = SherpaOnnxCreateKeywordStream(self.spotter);

    AudioHub *hub = [AudioHub shared];
    NSError *error = nil;
    __weak typeof(self) weakSelf = self;
    NSString *token = [hub addTap:^(AVAudioPCMBuffer *buffer) {
        [weakSelf consume:buffer];
    } error:&error];

    if (!token) {
        [self teardownSherpa];
        [self.delegate wakeWordDetector:self failed:
         [NSString stringWithFormat:@"唤醒词无法开麦：%@", error.localizedDescription]];
        return NO;
    }

    self.tapToken = token;
    self.modelFormat = [[AVAudioFormat alloc] initWithCommonFormat:AVAudioPCMFormatFloat32
                                                        sampleRate:kModelSampleRate
                                                          channels:1
                                                       interleaved:NO];
    self.converter = [[AVAudioConverter alloc] initFromFormat:hub.format toFormat:self.modelFormat];
    self.running = YES;
    self.startedAt = [NSDate timeIntervalSinceReferenceDate];
    self.lastLevelLog = 0;
    self.peakSinceStart = 0;
    NSLog(@"[jarvis] 唤醒词已启动（score=%.2f threshold=%.2f，采集 %.0fHz/%uch → 16kHz/1ch）",
          self.score, self.threshold,
          hub.format.sampleRate, (unsigned)hub.format.channelCount);
    return YES;
}

- (void)stop {
    if (!self.running) return;
    self.running = NO;
    [[AudioHub shared] removeTap:self.tapToken];
    self.tapToken = nil;
    self.converter = nil;
    // 队列里可能还有未解码的缓冲，等它排空再释放 sherpa 对象
    dispatch_sync(self.decodeQueue, ^{});
    [self teardownSherpa];
    NSLog(@"[jarvis] 唤醒词已停止");
}

- (void)teardownSherpa {
    if (self.stream) { SherpaOnnxDestroyOnlineStream(self.stream); self.stream = NULL; }
    if (self.spotter) { SherpaOnnxDestroyKeywordSpotter(self.spotter); self.spotter = NULL; }
}

#pragma mark - 送样

- (void)consume:(AVAudioPCMBuffer *)buffer {
    if (!self.running || self.muted) return;

    AVAudioPCMBuffer *mono16k = [self convert:buffer];
    if (!mono16k || mono16k.frameLength == 0) return;

    // 拷一份出来：原缓冲归 CoreAudio 所有，出了这个回调就不保证还在
    NSUInteger count = mono16k.frameLength;
    NSMutableData *samples = [NSMutableData dataWithBytes:mono16k.floatChannelData[0]
                                                   length:count * sizeof(float)];

    dispatch_async(self.decodeQueue, ^{ [self decode:samples frames:(int32_t)count]; });
}

- (AVAudioPCMBuffer *)convert:(AVAudioPCMBuffer *)input {
    if (!self.converter) return nil;

    AVAudioFrameCount capacity = (AVAudioFrameCount)ceil(
        input.frameLength * kModelSampleRate / input.format.sampleRate) + 64;
    AVAudioPCMBuffer *output = [[AVAudioPCMBuffer alloc] initWithPCMFormat:self.modelFormat
                                                            frameCapacity:capacity];
    if (!output) return nil;

    __block BOOL delivered = NO;
    NSError *error = nil;
    AVAudioConverterOutputStatus status = [self.converter
        convertToBuffer:output error:&error
        withInputFromBlock:^AVAudioBuffer *(AVAudioPacketCount need, AVAudioConverterInputStatus *outStatus) {
            if (delivered) { *outStatus = AVAudioConverterInputStatus_NoDataNow; return nil; }
            delivered = YES;
            *outStatus = AVAudioConverterInputStatus_HaveData;
            return input;
        }];

    if (status == AVAudioConverterOutputStatus_Error) {
        NSLog(@"[jarvis] 重采样失败：%@", error.localizedDescription);
        return nil;
    }
    return output;
}

/// 启动后 10 秒内每 2 秒报一次重采样后的峰值，之后不再打扰日志。
- (void)logStartupLevel:(NSData *)samples frames:(int32_t)frames {
    NSTimeInterval now = [NSDate timeIntervalSinceReferenceDate];
    if (now - self.startedAt > 10.0) return;

    const float *values = samples.bytes;
    for (int32_t i = 0; i < frames; i++) {
        float magnitude = fabsf(values[i]);
        if (magnitude > self.peakSinceStart) self.peakSinceStart = magnitude;
    }

    if (now - self.lastLevelLog < 2.0) return;
    self.lastLevelLog = now;
    NSLog(@"[jarvis] 唤醒词输入峰值 %.4f%@", self.peakSinceStart,
          self.peakSinceStart < 0.0005f ? @"（几乎静音，检查麦克风与重采样）" : @"");
    self.peakSinceStart = 0;
}

- (void)decode:(NSData *)samples frames:(int32_t)frames {
    if (!self.running || !self.stream) return;

    // 启动后头几秒报一次音量。唤醒词不灵时第一个要排除的就是
    // "重采样后压根没声音"——48kHz/多声道转 16k 单声道这一步最容易出问题，
    // 而它失败时是完全静默的，没有这条日志只能靠猜。
    [self logStartupLevel:samples frames:frames];

    SherpaOnnxOnlineStreamAcceptWaveform(self.stream, (int32_t)kModelSampleRate,
                                         (const float *)samples.bytes, frames);

    while (SherpaOnnxIsKeywordStreamReady(self.spotter, self.stream)) {
        SherpaOnnxDecodeKeywordStream(self.spotter, self.stream);
    }

    const SherpaOnnxKeywordResult *result = SherpaOnnxGetKeywordResult(self.spotter, self.stream);
    if (!result) return;

    NSString *keyword = (result->keyword && result->keyword[0])
        ? [NSString stringWithUTF8String:result->keyword] : nil;
    SherpaOnnxDestroyKeywordResult(result);
    if (keyword.length == 0) return;

    // 命中后必须 reset，否则同一次发声会在后续帧里反复命中
    SherpaOnnxResetKeywordStream(self.spotter, self.stream);

    NSTimeInterval now = [NSDate timeIntervalSinceReferenceDate];
    if (now - self.lastTrigger < kRetriggerGuard) return;
    self.lastTrigger = now;

    dispatch_async(dispatch_get_main_queue(), ^{
        if (self.running) [self.delegate wakeWordDetector:self didDetect:keyword];
    });
}

@end
