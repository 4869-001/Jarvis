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
@property (nonatomic, strong) NSTimer *silenceWatchdog;
@end

/// 当前默认输入设备的名字和硬件采样率。
///
/// 值得单独跑一趟 CoreAudio HAL：日志里只写 AVAudioEngine 报的格式是不够的——
/// 2026-08-06 实测 AirPods Pro 的硬件是 24000 Hz，而引擎一直报 48000 Hz，
/// 正是这个不一致让收音全程静音。不把设备名和真实采样率打出来，
/// 下次还是会在"engine 说 48k"这条假线索上绕。
static NSString *CurrentInputDeviceDescription(void) {
    AudioObjectPropertyAddress addr = {
        kAudioHardwarePropertyDefaultInputDevice,
        kAudioObjectPropertyScopeGlobal,
        kAudioObjectPropertyElementMain
    };
    AudioDeviceID device = kAudioObjectUnknown;
    UInt32 size = sizeof(device);
    if (AudioObjectGetPropertyData(kAudioObjectSystemObject, &addr, 0, NULL, &size, &device) != noErr
        || device == kAudioObjectUnknown) {
        return @"（拿不到默认输入设备）";
    }

    CFStringRef name = NULL;
    size = sizeof(name);
    addr.mSelector = kAudioObjectPropertyName;
    AudioObjectGetPropertyData(device, &addr, 0, NULL, &size, &name);

    Float64 rate = 0;
    size = sizeof(rate);
    addr.mSelector = kAudioDevicePropertyNominalSampleRate;
    addr.mScope = kAudioObjectPropertyScopeInput;
    AudioObjectGetPropertyData(device, &addr, 0, NULL, &size, &rate);

    NSString *deviceName = name ? (__bridge_transfer NSString *)name : @"?";
    return [NSString stringWithFormat:@"%@ @ %.0f Hz", deviceName, rate];
}

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

    NSString *device = CurrentInputDeviceDescription();
    NSLog(@"[jarvis] 输入设备：%@ ｜ 引擎格式：%.0f Hz/%u ch commonFormat=%ld interleaved=%@",
          device, format.sampleRate, (unsigned)format.channelCount,
          (long)format.commonFormat, format.isInterleaved ? @"是" : @"否");

    __weak typeof(self) weakSelf = self;
    [input installTapOnBus:0 bufferSize:2048 format:format
                     block:^(AVAudioPCMBuffer *buffer, AVAudioTime *when) {
        __strong typeof(weakSelf) strongSelf = weakSelf;
        [strongSelf inspectInput:buffer];          // 先检测，且不受降混那几处 return 影响
        [strongSelf broadcast:[strongSelf monoFromBuffer:buffer]];
    }];

    [engine prepare];
    if (![engine startAndReturnError:error]) {
        [input removeTapOnBus:0];
        return NO;
    }

    self.engine = engine;
    self.deviceFormat = format;
    self.format = self.monoFormat;      // 对外只承认单声道

    // ⚠️ 输入设备一变（插拔耳机、AirPods 连上、A2DP↔HFP 切换），引擎缓存的格式
    // 就作废了，但它**不会自己重建**，只会继续按旧格式收——表现是一路全零、
    // 不报任何错。2026-08-06 实测：AirPods Pro 硬件 24000 Hz，引擎却一直报
    // 48000 Hz，收音 30 秒一个非零采样都没有。这个通知就是系统给的正解。
    [[NSNotificationCenter defaultCenter] removeObserver:self
                                                    name:AVAudioEngineConfigurationChangeNotification
                                                  object:nil];
    [[NSNotificationCenter defaultCenter] addObserver:self
                                             selector:@selector(audioConfigurationChanged:)
                                                 name:AVAudioEngineConfigurationChangeNotification
                                               object:engine];

    // 看门狗必须按**时间**走，不能按 buffer 走。设备哑掉的时候 tap 根本不回调，
    // 一个 buffer 都没有——挂在 buffer 上的检查一次也跑不到。这是 2026-08-06
    // 第一版自救没生效的真正原因。
    [self.silenceWatchdog invalidate];
    self.silenceWatchdog = [NSTimer scheduledTimerWithTimeInterval:kSilentInputTimeout
                                                          repeats:NO
                                                            block:^(NSTimer *timer) {
        [self checkForSilentInput];
    }];
    NSLog(@"[jarvis] 麦克风已开：设备 %.0f Hz/%u ch → 下游 %.0f Hz/1 ch（Voice Processing %@）",
          format.sampleRate, (unsigned)format.channelCount, self.monoFormat.sampleRate,
          voiceProcessing ? @"开" : @"关");
    return YES;
}

/// 这一包音频里有没有任何一个非零采样；从头到尾全零就触发自救。
///
/// ⚠️ 这件事**必须独立于降混**。2026-08-06 栽了第二次：检测原本挂在
/// monoFromBuffer 的后半段，而它前面有三处 return 会把检测整个跳过——
/// 拿不到 monoFormat、单声道直通、floatChannelData 为空。那天设备变成
/// 3 声道，日志如实报了"整段没有一个非零采样，采集链路是死的"，
/// 而"关掉 Voice Processing 重开"的自救一次都没触发。
///
/// 所以这里不碰声道选择、不假设平面浮点，能认的格式全认，认不出来也要喊一声：
/// 悄悄返回是这一晚上所有难查 bug 的共同形状。
- (void)inspectInput:(AVAudioPCMBuffer *)buffer {
    if (self.sawAnyNonZero) return;                 // 见过信号就不必再查
    AVAudioFrameCount frames = buffer.frameLength;
    if (frames == 0) return;

    AVAudioChannelCount channels = buffer.format.channelCount;
    BOOL interleaved = buffer.format.isInterleaved;
    // 交错时全部采样挤在第 0 个平面里；非交错时每个声道一个平面。
    NSUInteger planes = interleaved ? 1 : channels;
    NSUInteger perPlane = interleaved ? (NSUInteger)frames * channels : frames;

    BOOL nonZero = NO;
    if (buffer.floatChannelData) {
        float *const *data = buffer.floatChannelData;
        for (NSUInteger p = 0; p < planes && !nonZero; p++)
            for (NSUInteger i = 0; i < perPlane; i++)
                if (data[p][i] != 0.0f) { nonZero = YES; break; }
    } else if (buffer.int16ChannelData) {
        int16_t *const *data = buffer.int16ChannelData;
        for (NSUInteger p = 0; p < planes && !nonZero; p++)
            for (NSUInteger i = 0; i < perPlane; i++)
                if (data[p][i] != 0) { nonZero = YES; break; }
    } else if (buffer.int32ChannelData) {
        int32_t *const *data = buffer.int32ChannelData;
        for (NSUInteger p = 0; p < planes && !nonZero; p++)
            for (NSUInteger i = 0; i < perPlane; i++)
                if (data[p][i] != 0) { nonZero = YES; break; }
    } else {
        static dispatch_once_t once;
        dispatch_once(&once, ^{
            NSLog(@"[jarvis] ⚠️ 认不出输入格式（commonFormat=%ld interleaved=%@），"
                  @"静音检测和降混都会失效",
                  (long)buffer.format.commonFormat, interleaved ? @"是" : @"否");
        });
        return;
    }

    // 只负责记录"见过信号"这一个事实。判死刑与自救交给 checkForSilentInput
    // 那个定时器——放在这里就只能等 buffer 来，而设备哑掉时 buffer 永远不来。
    if (nonZero) self.sawAnyNonZero = YES;
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

/// 引擎的 I/O 配置变了（换设备、采样率变、蓝牙 A2DP↔HFP 切换）。
/// 系统只负责通知，重建是我们的事——不重建就会继续按作废的格式收，一路全零。
- (void)audioConfigurationChanged:(NSNotification *)note {
    if (!self.engine) return;
    dispatch_async(dispatch_get_main_queue(), ^{
        if (!self.engine) return;
        NSLog(@"[jarvis] 音频配置已变化（%@），按新格式重建引擎", CurrentInputDeviceDescription());
        [self restartEngineWithVoiceProcessing:self.voiceProcessing];
    });
}

/// 开麦这么久了还一个非零采样都没见过 → 采集链路是死的，去救。
/// 由定时器驱动，所以"设备一个 buffer 都不给"这种情况同样能抓到。
- (void)checkForSilentInput {
    self.silenceWatchdog = nil;
    if (self.sawAnyNonZero || !self.engine.isRunning) return;
    [self recoverFromSilentInput];
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
    [self.silenceWatchdog invalidate];
    self.silenceWatchdog = nil;
    [[NSNotificationCenter defaultCenter] removeObserver:self
                                                    name:AVAudioEngineConfigurationChangeNotification
                                                  object:nil];
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
    if (!channels) {
        // 悄悄 return nil 会让下游一个采样都收不到、却什么错都不报——
        // 正是这一晚上所有难查 bug 的形状。喊一声（只喊一次，这是实时线程）。
        static dispatch_once_t once;
        dispatch_once(&once, ^{
            NSLog(@"[jarvis] ⚠️ 输入不是平面浮点，降混无法进行：commonFormat=%ld interleaved=%@",
                  (long)buffer.format.commonFormat, buffer.format.isInterleaved ? @"是" : @"否");
        });
        return nil;
    }
    // 交错格式下 channels[c] 那套索引不成立，别乱猜，直接放弃降混并报出来。
    if (buffer.format.isInterleaved) {
        static dispatch_once_t onceInterleaved;
        dispatch_once(&onceInterleaved, ^{
            NSLog(@"[jarvis] ⚠️ 输入是交错格式，当前降混只支持平面格式");
        });
        return nil;
    }

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
    // 全零判定与自救不在这儿——它们在 inspectInput，那里对每个 buffer 无条件执行。
}

/// tap block 在 CoreAudio 的实时线程上跑，不要在里面做重活。
- (void)broadcast:(AVAudioPCMBuffer *)buffer {
    if (!buffer) return;
    __block NSArray *snapshot = nil;
    dispatch_sync(self.lockQueue, ^{ snapshot = self.taps.allValues; });
    for (JarvisAudioTap tap in snapshot) tap(buffer);
}

@end
