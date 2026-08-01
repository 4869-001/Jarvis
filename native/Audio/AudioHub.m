#import "AudioHub.h"

@interface AudioHub ()
@property (nonatomic, strong) AVAudioEngine *engine;
@property (nonatomic, strong) NSMutableDictionary<NSString *, JarvisAudioTap> *taps;
@property (nonatomic, strong) AVAudioFormat *format;
@property (nonatomic, strong) AVAudioFormat *monoFormat;
@property (nonatomic, strong) AVAudioFormat *deviceFormat;
@property (nonatomic, strong) dispatch_queue_t lockQueue;
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
        if (![self startEngine:error]) return nil;
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

- (BOOL)startEngine:(NSError **)error {
    AVAudioEngine *engine = [[AVAudioEngine alloc] init];
    AVAudioInputNode *input = engine.inputNode;

    // 系统级 AEC + 降噪 + AGC，必须在启动前设置。
    // 失败不致命——回落到"没有回声消除"，半双工门仍然挡得住自激。
    NSError *vpError = nil;
    if (![input setVoiceProcessingEnabled:YES error:&vpError]) {
        NSLog(@"[jarvis] Voice Processing 启用失败：%@", vpError.localizedDescription);
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
    // 症状是"唤醒词怎么都不触发"，且没有任何报错。所以自己取通道 0
    // （Voice Processing 的处理结果就在通道 0），下游只需做采样率转换。
    self.monoFormat = [[AVAudioFormat alloc] initWithCommonFormat:AVAudioPCMFormatFloat32
                                                       sampleRate:format.sampleRate
                                                         channels:1
                                                      interleaved:NO];

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
    NSLog(@"[jarvis] 麦克风已开：设备 %.0f Hz/%u ch → 下游 %.0f Hz/1 ch",
          format.sampleRate, (unsigned)format.channelCount, self.monoFormat.sampleRate);
    return YES;
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
    NSLog(@"[jarvis] 麦克风已关");
}

/// 取通道 0 拷成单声道。只是一次 memcpy，放在实时线程上没问题。
- (AVAudioPCMBuffer *)monoFromBuffer:(AVAudioPCMBuffer *)buffer {
    if (!self.monoFormat || buffer.frameLength == 0) return nil;
    if (buffer.format.channelCount == 1) return buffer;

    float *const *channels = buffer.floatChannelData;
    if (!channels) return nil;

    AVAudioPCMBuffer *mono = [[AVAudioPCMBuffer alloc] initWithPCMFormat:self.monoFormat
                                                           frameCapacity:buffer.frameLength];
    if (!mono) return nil;
    mono.frameLength = buffer.frameLength;
    memcpy(mono.floatChannelData[0], channels[0], buffer.frameLength * sizeof(float));
    return mono;
}

/// tap block 在 CoreAudio 的实时线程上跑，不要在里面做重活。
- (void)broadcast:(AVAudioPCMBuffer *)buffer {
    if (!buffer) return;
    __block NSArray *snapshot = nil;
    dispatch_sync(self.lockQueue, ^{ snapshot = self.taps.allValues; });
    for (JarvisAudioTap tap in snapshot) tap(buffer);
}

@end
