#import "AudioHub.h"

/// 通道里出现这么大的 RMS 就认定"信号在这条通道上"，锁定它。
/// 0.01 大约是正常说话的下沿，底噪够不着。
static const float kChannelPickLevel = 0.01f;
/// 全零多久算采集链路死了。真麦克风的 ADC 底噪不可能是逐位的零，
/// 所以这个判据不会把"安静的房间"误判成故障。
static const NSTimeInterval kSilentInputTimeout = 2.0;

@interface AudioHub ()
@property (nonatomic, strong) AVAudioEngine *engine;
@property (nonatomic, strong) NSMutableDictionary<NSString *, JarvisAudioTap> *taps;
@property (nonatomic, strong) AVAudioFormat *format;
@property (nonatomic, strong) AVAudioFormat *monoFormat;
@property (nonatomic, strong) AVAudioFormat *deviceFormat;
@property (nonatomic, strong) dispatch_queue_t lockQueue;

@property (nonatomic, assign) BOOL voiceProcessing;      ///< 当前这台引擎开没开 VP
@property (nonatomic, assign) NSUInteger sourceChannel;  ///< 取哪条通道当单声道源
@property (nonatomic, assign) BOOL channelLocked;        ///< 已经找到有信号的通道
@property (nonatomic, assign) BOOL sawAnyNonZero;        ///< 见过任何一个非零采样
@property (nonatomic, assign) BOOL recoveryScheduled;
@property (nonatomic, assign) BOOL silenceRecoveryDone;
@property (nonatomic, assign) NSTimeInterval engineStartedAt;
@end

@implementation AudioHub

+ (instancetype)shared {
    static AudioHub *instance = nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ instance = [[AudioHub alloc] init]; });
    return instance;
}

- (instancetype)init {
    if ((self = [super init])) {
        _taps = [NSMutableDictionary dictionary];
        _lockQueue = dispatch_queue_create("com.jarvis.audiohub", DISPATCH_QUEUE_SERIAL);
    }
    return self;
}

- (BOOL)isRunning { return self.engine.isRunning; }

#pragma mark - 权限

- (void)requestPermission:(void (^)(BOOL, NSString *))completion {
    // 已经问过就同步答复。requestAccess 即使在已授权时也要走一趟 XPC，
    // 而这段延迟正好卡在用户按下开麦键到麦克风真的打开之间。
    AVAuthorizationStatus status = [AVCaptureDevice authorizationStatusForMediaType:AVMediaTypeAudio];
    if (status != AVAuthorizationStatusNotDetermined) {
        BOOL granted = (status == AVAuthorizationStatusAuthorized);
        dispatch_async(dispatch_get_main_queue(), ^{
            completion(granted, granted ? nil :
                       @"麦克风未授权。系统设置 → 隐私与安全性 → 麦克风，勾上 Jarvis。");
        });
        return;
    }
    [AVCaptureDevice requestAccessForMediaType:AVMediaTypeAudio completionHandler:^(BOOL granted) {
        dispatch_async(dispatch_get_main_queue(), ^{
            completion(granted, granted ? nil :
                       @"麦克风未授权。系统设置 → 隐私与安全性 → 麦克风，勾上 Jarvis。");
        });
    }];
}

#pragma mark - tap 管理

- (NSString *)addTap:(JarvisAudioTap)tap error:(NSError **)error {
    if (!tap) return nil;

    if (!self.engine.isRunning) {
        if (![self startEngine:error withVoiceProcessing:YES]) return nil;
    }

    NSString *token = [[NSUUID UUID] UUIDString];
    dispatch_sync(self.lockQueue, ^{ self.taps[token] = [tap copy]; });
    return token;
}

- (void)removeTap:(NSString *)token {
    if (token.length == 0) return;
    __block NSUInteger remaining = 0;
    dispatch_sync(self.lockQueue, ^{
        [self.taps removeObjectForKey:token];
        remaining = self.taps.count;
    });
    if (remaining == 0) [self stopEngine];
}

#pragma mark - 引擎

- (BOOL)startEngine:(NSError **)error withVoiceProcessing:(BOOL)useVoiceProcessing {
    AVAudioEngine *engine = [[AVAudioEngine alloc] init];
    AVAudioInputNode *input = engine.inputNode;

    // 系统级 AEC + 降噪 + AGC，必须在启动前设置。
    // 失败不致命——回落到"没有回声消除"，半双工门仍然挡得住自激。
    BOOL voiceProcessing = NO;
    if (useVoiceProcessing) {
        NSError *vpError = nil;
        voiceProcessing = [input setVoiceProcessingEnabled:YES error:&vpError];
        if (!voiceProcessing) {
            NSLog(@"[jarvis] Voice Processing 启用失败：%@", vpError.localizedDescription);
        }
    }

    AVAudioFormat *format = [input outputFormatForBus:0];
    if (format.sampleRate <= 0 || format.channelCount == 0) {
        if (error) *error = [NSError errorWithDomain:@"com.jarvis.audio" code:1
                                            userInfo:@{NSLocalizedDescriptionKey: @"拿不到麦克风输入格式"}];
        return NO;
    }

    // 广播出去的一律是单声道。原因是实测出来的：
    // 这台 M2 Air 的输入是 3 声道麦阵列，启用 Voice Processing 后变成 7 声道，
    // 而 7 声道没有标准声道布局，AVAudioConverter 对它做降混会**静默产出全零**，
    // 症状是"唤醒词怎么都不触发"，且没有任何报错。所以自己挑一条通道拷出来，
    // 下游只需做采样率转换。
    //
    // 通道号不再写死 0。VP 的处理结果**并不保证**落在通道 0——2026-08-05 实测到
    // 通道 0 送的是逐位精确的零，识别器全程报 "No speech detected"。
    // 现在改成先听哪条通道真有信号再锁定它，见 monoFromBuffer。
    self.monoFormat = [[AVAudioFormat alloc] initWithCommonFormat:AVAudioPCMFormatFloat32
                                                       sampleRate:format.sampleRate
                                                         channels:1
                                                      interleaved:NO];

    self.voiceProcessing = voiceProcessing;
    self.sourceChannel = 0;
    self.channelLocked = (format.channelCount == 1);
    self.sawAnyNonZero = NO;
    self.recoveryScheduled = NO;
    self.silenceRecoveryDone = NO;
    self.engineStartedAt = CACurrentMediaTime();

    __weak typeof(self) weakSelf = self;
    [input installTapOnBus:0 bufferSize:2048 format:format
                     block:^(AVAudioPCMBuffer *buffer, AVAudioTime *when) {
        [weakSelf broadcast:[weakSelf monoFromBuffer:buffer]];
    }];

    [engine prepare];
    if (![engine startAndReturnError:error]) {
        [input removeTapOnBus:0];
        return NO;
    }

    self.engine = engine;
    self.deviceFormat = format;
    self.format = self.monoFormat;      // 对外只承认单声道
    NSLog(@"[jarvis] 麦克风已开：设备 %.0f Hz/%u ch → 下游 %.0f Hz/1 ch（Voice Processing %@）",
          format.sampleRate, (unsigned)format.channelCount, self.monoFormat.sampleRate,
          voiceProcessing ? @"开" : @"关");
    return YES;
}

/// 换一台引擎，但**不动 taps**——对上层完全透明，收音不中断，
/// 正在跑的识别任务只是中间少了一小段音频。
- (void)restartEngineWithVoiceProcessing:(BOOL)useVoiceProcessing {
    AVAudioEngine *old = self.engine;
    if (old.isRunning) {
        [old.inputNode removeTapOnBus:0];
        [old stop];
    }
    self.engine = nil;

    NSError *error = nil;
    if (![self startEngine:&error withVoiceProcessing:useVoiceProcessing]) {
        NSLog(@"[jarvis] 重开麦克风失败：%@", error.localizedDescription);
    }
}

/// 输入连续送了两秒逐位精确的零。真麦克风的 ADC 底噪不可能是零，
/// 所以这不是"房间安静"，是采集链路死了。
- (void)recoverFromSilentInput {
    if (self.silenceRecoveryDone || !self.engine.isRunning) return;

    if (!self.voiceProcessing) {
        // VP 都关了还是全零：问题在设备或授权那一层，代码这边没得救了，
        // 留一行能直接指路的日志。
        self.silenceRecoveryDone = YES;
        NSLog(@"[jarvis] ⚠️ 关掉 Voice Processing 后输入仍然全零。"
              @"查：系统设置→隐私与安全性→麦克风是否给了 Jarvis、"
              @"输入设备是不是被别的应用独占、输入音量是不是 0。");
        return;
    }

    NSLog(@"[jarvis] ⚠️ 输入连续 %.0f 秒是逐位的零（不是安静，是链路死了）。"
          @"关掉 Voice Processing 重开——代价是没有回声消除。",
          kSilentInputTimeout);
    [self restartEngineWithVoiceProcessing:NO];
}

- (void)stopEngine {
    if (!self.engine) return;
    if (self.engine.isRunning) {
        [self.engine.inputNode removeTapOnBus:0];
        [self.engine stop];
    }
    self.engine = nil;
    self.format = nil;
    self.monoFormat = nil;
    self.deviceFormat = nil;
    if (!self.sawAnyNonZero) {
        NSLog(@"[jarvis] 麦克风已关（整段没有一个非零采样——采集链路是死的）");
    } else {
        NSLog(@"[jarvis] 麦克风已关（用的通道 %lu）", (unsigned long)self.sourceChannel);
    }
}

/// 取一条通道拷成单声道。只是一次 memcpy，放在实时线程上没问题。
- (AVAudioPCMBuffer *)monoFromBuffer:(AVAudioPCMBuffer *)buffer {
    if (!self.monoFormat || buffer.frameLength == 0) return nil;
    if (buffer.format.channelCount == 1) return buffer;

    float *const *channels = buffer.floatChannelData;
    if (!channels) return nil;

    if (!self.channelLocked) [self pickChannelFromBuffer:buffer];

    NSUInteger source = MIN(self.sourceChannel, (NSUInteger)buffer.format.channelCount - 1);
    AVAudioPCMBuffer *mono = [[AVAudioPCMBuffer alloc] initWithPCMFormat:self.monoFormat
                                                           frameCapacity:buffer.frameLength];
    if (!mono) return nil;
    mono.frameLength = buffer.frameLength;
    memcpy(mono.floatChannelData[0], channels[source], buffer.frameLength * sizeof(float));
    return mono;
}

/// 找出真正有信号的那条通道。
///
/// 起因（2026-08-05）：VP 打开后输入是 7 声道，一直无条件取通道 0，而通道 0
/// 那天送的是逐位精确的零——识别器全程 "No speech detected"，麦克风灯亮着、
/// 电平条不动、一个字都不出，且没有任何报错。声道布局是系统给的，不该由我们假设。
///
/// 跑在实时线程上：只有没锁定时才逐通道算 RMS，锁定之后每个 buffer 就只剩一次
/// memcpy。日志一律甩给主队列，不在实时线程里 NSLog。
- (void)pickChannelFromBuffer:(AVAudioPCMBuffer *)buffer {
    AVAudioChannelCount count = buffer.format.channelCount;
    AVAudioFrameCount frames = buffer.frameLength;
    float *const *channels = buffer.floatChannelData;

    float levels[16] = {0};
    AVAudioChannelCount measured = MIN(count, (AVAudioChannelCount)16);
    float best = 0;
    NSUInteger bestIndex = 0;

    for (AVAudioChannelCount c = 0; c < measured; c++) {
        double sum = 0;
        const float *samples = channels[c];
        for (AVAudioFrameCount i = 0; i < frames; i++) sum += (double)samples[i] * samples[i];
        levels[c] = frames ? (float)sqrt(sum / frames) : 0.0f;
        if (levels[c] > 0) self.sawAnyNonZero = YES;
        if (levels[c] > best) { best = levels[c]; bestIndex = c; }
    }

    if (best >= kChannelPickLevel) {
        self.sourceChannel = bestIndex;
        self.channelLocked = YES;
        NSMutableString *profile = [NSMutableString string];
        for (AVAudioChannelCount c = 0; c < measured; c++) {
            [profile appendFormat:@"%@ch%u=%.4f", c ? @" " : @"", (unsigned)c, levels[c]];
        }
        dispatch_async(dispatch_get_main_queue(), ^{
            NSLog(@"[jarvis] 选定输入通道 %lu（%@）", (unsigned long)bestIndex, profile);
        });
        return;
    }

    // 一个非零采样都没见过，且已经过了判定窗口 → 采集链路死了，去救。
    if (!self.sawAnyNonZero && !self.recoveryScheduled && !self.silenceRecoveryDone
        && CACurrentMediaTime() - self.engineStartedAt > kSilentInputTimeout) {
        self.recoveryScheduled = YES;
        dispatch_async(dispatch_get_main_queue(), ^{ [self recoverFromSilentInput]; });
    }
}

/// tap block 在 CoreAudio 的实时线程上跑，不要在里面做重活。
- (void)broadcast:(AVAudioPCMBuffer *)buffer {
    if (!buffer) return;
    __block NSArray *snapshot = nil;
    dispatch_sync(self.lockQueue, ^{ snapshot = self.taps.allValues; });
    for (JarvisAudioTap tap in snapshot) tap(buffer);
}

@end
