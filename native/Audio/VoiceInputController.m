#import "VoiceInputController.h"
#import "AudioHub.h"

#import <AVFoundation/AVFoundation.h>
#import <Speech/Speech.h>

/// 噪声门的下限。房间再安静也不把门压到 0，否则风扇声都算说话。
static const float kMinGate = 0.006f;
/// 噪声底噪的跟踪系数：跌得快、涨得慢。涨得慢是关键——
/// Voice Processing 的 AGC 会在人一开口就把增益拉起来，底噪跟着涨的话门就废了。
static const float kFloorFallRate = 0.35f;
static const float kFloorRiseRate = 0.0015f;
/// 开麦头 0.35 秒只用来采底噪，不做判决。
static const NSTimeInterval kFloorWarmup = 0.35;
/// 噪声环境下的兜底：识别器这么久没吐出新字，就当说完了，
/// 不再要求音频也安静——开着电视时音频永远不会安静。
static const double kNoisyEndpointFactor = 2.2;
/// 一次最多喂给识别器多少条专有名词。给太多反而稀释效果。
static const NSUInteger kMaxContextualStrings = 100;
/// 识别器"假死"的判据：人确实说了这么久的话，却连一版 partial 都没吐出来。
/// 正常听写第一版 partial 在半秒内就到，累计 2.5 秒人声还是空的只有一种解释——
/// 任务是死的。取 2.5 秒是为了不被空调/电视这类持续噪声误判成"在说话"。
static const NSTimeInterval kNoResponseVoicedSeconds = 2.5;

typedef NS_ENUM(NSInteger, JarvisVoicePhase) {
    JarvisVoicePhaseIdle = 0,
    JarvisVoicePhaseListening,   ///< 正在收音
    JarvisVoicePhaseFinalizing,  ///< 麦克风已关，在等识别器的终版结果
};

@interface VoiceInputController () <SFSpeechRecognizerDelegate>
@property (nonatomic, copy)   NSString *localeIdentifier;
@property (nonatomic, assign) JarvisVoiceOptions options;

@property (nonatomic, strong) SFSpeechRecognizer *recognizer;
@property (nonatomic, strong) SFSpeechAudioBufferRecognitionRequest *request;
@property (nonatomic, strong) SFSpeechRecognitionTask *task;
@property (nonatomic, copy)   NSString *tapToken;
@property (nonatomic, strong) NSTimer *watchdog;

@property (nonatomic, assign) JarvisVoicePhase phase;
@property (nonatomic, copy)   NSString *transcript;
@property (nonatomic, assign) NSTimeInterval startedAt;
@property (nonatomic, assign) NSTimeInterval lastVoiceAt;
@property (nonatomic, assign) NSTimeInterval lastTextAt;
@property (nonatomic, assign) NSTimeInterval finalizingAt;
@property (nonatomic, assign) float smoothedLevel;
@property (nonatomic, assign) float noiseFloor;

/// 这一次收音的统计。只为了收尾时打一行日志——没有它就分不清
/// "根本没声音进来"和"有声音但识别器不吐字"，而这两条的修法完全不同。
@property (nonatomic, assign) NSTimeInterval voicedSeconds;
@property (nonatomic, assign) float peakLevel;
@property (nonatomic, assign) NSUInteger resultCount;
@end

@implementation VoiceInputController

- (instancetype)initWithLocale:(NSString *)localeIdentifier
                       options:(JarvisVoiceOptions)options {
    if ((self = [super init])) {
        _localeIdentifier = [localeIdentifier copy] ?: @"zh-CN";
        _options = options;
        if (_options.silenceTimeout <= 0) _options.silenceTimeout = 0.9;
        if (_options.finalWait     <  0) _options.finalWait     = 0.6;
        if (_options.idleTimeout   <= 0) _options.idleTimeout   = 30.0;
        if (_options.maxSeconds    <= 0) _options.maxSeconds    = 60.0;
        _contextualStrings = @[];
    }
    return self;
}

- (void)dealloc { [self teardown]; }

- (BOOL)isListening { return self.phase != JarvisVoicePhaseIdle; }

#pragma mark - 权限

/// 麦克风和语音识别是两套独立授权，缺一不可。
///
/// 两边都先看同步的 status，只有"尚未询问"时才走异步请求。以前每次开麦都发
/// 一次 requestAuthorization，那是两趟 XPC——用户按下 ⌥V 到麦克风真的开，
/// 白白多出百来毫秒，而这段延迟恰好落在最容易被感知的开头。
- (void)ensureAuthorized:(void (^)(BOOL granted, NSString *reason))completion {
    SFSpeechRecognizerAuthorizationStatus speech = [SFSpeechRecognizer authorizationStatus];
    if (speech == SFSpeechRecognizerAuthorizationStatusAuthorized) {
        [[AudioHub shared] requestPermission:completion];
        return;
    }
    if (speech != SFSpeechRecognizerAuthorizationStatusNotDetermined) {
        completion(NO, @"语音识别未授权。系统设置 → 隐私与安全性 → 语音识别，勾上 Jarvis。");
        return;
    }
    [SFSpeechRecognizer requestAuthorization:^(SFSpeechRecognizerAuthorizationStatus status) {
        dispatch_async(dispatch_get_main_queue(), ^{
            if (status != SFSpeechRecognizerAuthorizationStatusAuthorized) {
                completion(NO, @"语音识别未授权。系统设置 → 隐私与安全性 → 语音识别，勾上 Jarvis。");
                return;
            }
            [[AudioHub shared] requestPermission:completion];
        });
    }];
}

#pragma mark - 识别器

/// 识别器复用。每次开麦都 new 一个的话，系统要重新解析语言资源；
/// 复用之后开麦几乎是瞬时的。locale 不变就一直用同一个。
///
/// ⚠️ 但复用的前提是它还活着。Jarvis 是常驻进程，一个识别器一建就是好几天，
/// 中间要经历系统休眠唤醒、语音资源更新、speechrecognitiond 重启——这些都会让
/// 旧对象变成 `isAvailable == NO`，而**它派出的任务既不吐结果也不报错**，
/// 收音全程静悄悄地什么都不发生。症状就是「麦克风开了，但一个字都不出」。
/// 所以每次开麦都要重新验一遍，死了就丢掉重建。
- (SFSpeechRecognizer *)ensureRecognizer {
    if (self.recognizer && self.recognizer.isAvailable) return self.recognizer;
    if (self.recognizer) {
        NSLog(@"[jarvis] 缓存的识别器（%@）已不可用，重建",
              self.recognizer.locale.localeIdentifier);
        self.recognizer = nil;
    }

    NSArray<NSString *> *candidates = @[self.localeIdentifier,
                                        [NSLocale currentLocale].localeIdentifier,
                                        @"en-US"];
    SFSpeechRecognizer *first = nil;
    for (NSString *identifier in candidates) {
        SFSpeechRecognizer *recognizer = [[SFSpeechRecognizer alloc]
            initWithLocale:[NSLocale localeWithLocaleIdentifier:identifier]];
        if (!recognizer) continue;
        recognizer.delegate = self;
        if (!first) first = recognizer;
        if (!recognizer.isAvailable) continue;
        if (![identifier isEqualToString:self.localeIdentifier]) {
            NSLog(@"[jarvis] %@ 的识别器不可用，退到 %@", self.localeIdentifier, identifier);
        }
        self.recognizer = recognizer;
        return recognizer;
    }

    // 一个都不报可用。刚 new 出来的识别器是异步确定可用性的，头几十毫秒
    // 报 NO 属于正常，这时候直接判死刑会把"其实能用"的场景也挡掉。
    // 先用着，真死了由 checkTimeouts 里的假死判据兜住。
    if (first) {
        NSLog(@"[jarvis] 识别器暂时报不可用（%@），先用着", first.locale.localeIdentifier);
        self.recognizer = first;
    }
    return first;
}

/// 可用性变化是异步推过来的。这行日志本身就是排障线索：
/// 「开麦前变 NO」能一眼说明识别器是什么时候、因为什么死的。
- (void)speechRecognizer:(SFSpeechRecognizer *)recognizer
  availabilityDidChange:(BOOL)available {
    NSLog(@"[jarvis] 识别器可用性变化：%@ → %@",
          recognizer.locale.localeIdentifier, available ? @"可用" : @"不可用");
}

- (void)prewarm {
    if ([SFSpeechRecognizer authorizationStatus] != SFSpeechRecognizerAuthorizationStatusAuthorized) {
        return;                                  // 没授权就别去碰，会白弹一次框
    }
    [self ensureRecognizer];
}

#pragma mark - 开始 / 结束

- (void)start {
    if (self.isListening) return;
    [self ensureAuthorized:^(BOOL granted, NSString *reason) {
        if (!granted) { [self.delegate voiceInput:self failed:reason]; return; }
        [self reallyStart];
    }];
}

- (void)reallyStart {
    if (self.isListening) return;

    SFSpeechRecognizer *recognizer = [self ensureRecognizer];
    if (!recognizer) {
        [self.delegate voiceInput:self failed:
         [NSString stringWithFormat:@"%@ 的识别器当前不可用", self.localeIdentifier]];
        return;
    }

    self.request = [[SFSpeechAudioBufferRecognitionRequest alloc] init];
    self.request.shouldReportPartialResults = YES;
    // 连续语音而非搜索词。选错 hint 会让识别器用错语言模型，短句尤其明显。
    self.request.taskHint = SFSpeechRecognitionTaskHintDictation;
    if (self.options.preferOnDevice && recognizer.supportsOnDeviceRecognition) {
        self.request.requiresOnDeviceRecognition = YES;
    }
    if (self.options.addsPunctuation) {
        self.request.addsPunctuation = YES;      // 字幕好读，也让 TTS 的断句更自然
    }
    // 专有名词提示：应用名、项目名、人名这类词识别器本来最容易听错，
    // 喂进去之后基本能一次听对。
    if (self.contextualStrings.count) {
        NSUInteger count = MIN(self.contextualStrings.count, kMaxContextualStrings);
        self.request.contextualStrings = [self.contextualStrings subarrayWithRange:NSMakeRange(0, count)];
    }

    // 麦克风由 AudioHub 独占——唤醒词可能正常听着，不能在这儿再开一个引擎
    NSError *startError = nil;
    __weak typeof(self) weakSelf = self;
    self.tapToken = [[AudioHub shared] addTap:^(AVAudioPCMBuffer *buffer) {
        __strong typeof(weakSelf) strongSelf = weakSelf;
        if (strongSelf.phase != JarvisVoicePhaseListening) return;
        [strongSelf.request appendAudioPCMBuffer:buffer];
        [strongSelf noteLevelFromBuffer:buffer];
    } error:&startError];

    if (!self.tapToken) {
        [self.delegate voiceInput:self failed:
         [NSString stringWithFormat:@"麦克风启动失败：%@", startError.localizedDescription]];
        [self teardown];
        return;
    }

    NSTimeInterval now = [NSDate timeIntervalSinceReferenceDate];
    self.transcript = @"";
    self.phase = JarvisVoicePhaseListening;
    self.startedAt = now;
    self.lastVoiceAt = now;
    self.lastTextAt = now;
    self.smoothedLevel = 0;
    self.noiseFloor = 0;
    self.voicedSeconds = 0;
    self.peakLevel = 0;
    self.resultCount = 0;

    NSLog(@"[jarvis] 开始收音：%@ 离线=%@ 提示词 %lu 条",
          recognizer.locale.localeIdentifier,
          self.request.requiresOnDeviceRecognition ? @"是" : @"否",
          (unsigned long)self.request.contextualStrings.count);

    self.task = [recognizer recognitionTaskWithRequest:self.request
                                         resultHandler:^(SFSpeechRecognitionResult *result,
                                                         NSError *error) {
        dispatch_async(dispatch_get_main_queue(), ^{
            [weakSelf handleResult:result error:error];
        });
    }];

    self.watchdog = [NSTimer scheduledTimerWithTimeInterval:0.1 repeats:YES
                                                      block:^(NSTimer *timer) { [weakSelf checkTimeouts]; }];

    [self.delegate voiceInputDidStart:self];
}

/// 收句。不直接交文本，而是先关麦克风、再给识别器一小段时间出终版结果。
- (void)stop {
    if (self.phase != JarvisVoicePhaseListening) return;

    self.phase = JarvisVoicePhaseFinalizing;
    self.finalizingAt = [NSDate timeIntervalSinceReferenceDate];

    // 麦克风立刻还回去。等识别器收尾的这段时间里没有理由还占着输入设备——
    // 没别的 tap 时 AudioHub 会顺手把引擎停掉，指示灯也就灭了。
    [[AudioHub shared] removeTap:self.tapToken];
    self.tapToken = nil;
    [self.delegate voiceInput:self level:0];

    [self.request endAudio];
    [self.delegate voiceInputDidFinishCapturing:self];

    // finalWait 为 0 表示不等，直接用现有的 partial
    if (self.options.finalWait <= 0) [self deliverFinal];
}

- (void)abort {
    if (!self.isListening) return;
    [self teardown];
    [self.delegate voiceInput:self finalText:@""];
}

/// 把当前最好的文本交出去，然后彻底收摊。只会走一次。
- (void)deliverFinal {
    if (self.phase == JarvisVoicePhaseIdle) return;
    NSString *text = [(self.transcript ?: @"") stringByTrimmingCharactersInSet:
                      [NSCharacterSet whitespaceAndNewlineCharacterSet]];
    // 这一行是排障的主入口：有声时长和峰值说明"音频有没有进来"，
    // 结果条数说明"识别器有没有在干活"，两者一比就知道该查哪一头。
    NSLog(@"[jarvis] 收音结束 %.1fs：有声 %.1fs 峰值 %.3f 底噪 %.4f 结果 %lu 条 → 「%@」",
          [NSDate timeIntervalSinceReferenceDate] - self.startedAt,
          self.voicedSeconds, self.peakLevel, self.noiseFloor,
          (unsigned long)self.resultCount, text);
    [self teardown];
    [self.delegate voiceInput:self finalText:text];
}

/// 注意：不清 self.recognizer——它是可复用的，留着下次开麦快。
- (void)teardown {
    [self.watchdog invalidate];
    self.watchdog = nil;

    if (self.tapToken) {
        [[AudioHub shared] removeTap:self.tapToken];
        self.tapToken = nil;
    }
    [self.request endAudio];
    [self.task cancel];

    self.request = nil;
    self.task = nil;
    self.phase = JarvisVoicePhaseIdle;
    [self.delegate voiceInput:self level:0];
}

#pragma mark - 识别回调

- (void)handleResult:(SFSpeechRecognitionResult *)result error:(NSError *)error {
    if (self.phase == JarvisVoicePhaseIdle) return;

    if (result) {
        self.resultCount++;
        NSString *text = result.bestTranscription.formattedString ?: @"";
        if (![text isEqualToString:self.transcript]) {
            self.transcript = text;
            self.lastTextAt = [NSDate timeIntervalSinceReferenceDate];
            if (self.phase == JarvisVoicePhaseListening) {
                [self.delegate voiceInput:self partialText:text];
            }
        }
        // 终版到了就直接交，不走 stop 的等待路径——finalWait 等的就是这一刻，
        // 已经等到了还再等 0.6 秒，就是白白往每一句上加延迟。
        if (result.isFinal) { [self deliverFinal]; return; }
    }

    if (error) {
        // 用户没说话时识别器会以 "No speech detected" 收场，这不是故障。
        // 已经进入收尾阶段的错误一律当"没有更好的结果了"处理，用手里的 partial。
        // 两种情况都不该再等——不会有更好的结果了。
        BOOL noSpeech = (error.code == 1110 || error.code == 203);
        NSLog(@"[jarvis] 识别回调报错 %@/%ld：%@%@", error.domain, (long)error.code,
              error.localizedDescription, noSpeech ? @"（没听到人声，不算故障）" : @"");
        if (noSpeech || self.phase == JarvisVoicePhaseFinalizing) {
            [self deliverFinal];
            return;
        }
        // 识别器出过错就别再留着复用了，下次开麦重建一个干净的。
        self.recognizer = nil;
        NSString *message = [NSString stringWithFormat:@"识别失败：%@", error.localizedDescription];
        [self teardown];
        [self.delegate voiceInput:self failed:message];
    }
}

#pragma mark - 电平与自适应噪声门

- (void)noteLevelFromBuffer:(AVAudioPCMBuffer *)buffer {
    float const *samples = buffer.floatChannelData ? buffer.floatChannelData[0] : NULL;
    if (!samples) return;

    // RMS，比峰值稳，不会被一次咔哒声顶满
    double sum = 0;
    AVAudioFrameCount count = buffer.frameLength;
    for (AVAudioFrameCount i = 0; i < count; i++) sum += (double)samples[i] * samples[i];
    float rms = count ? (float)sqrt(sum / count) : 0.0f;

    // 自适应底噪。固定阈值在这台机器上是行不通的：Voice Processing 的 AGC
    // 会把安静房间的底噪也拉到任何固定阈值之上，于是"距上次有声"永远在刷新，
    // 静音判定形同虚设。跟着环境走的门才分得清"安静"和"有人在说话"。
    if (self.noiseFloor <= 0) {
        self.noiseFloor = rms;
    } else {
        float rate = (rms < self.noiseFloor) ? kFloorFallRate : kFloorRiseRate;
        self.noiseFloor += (rms - self.noiseFloor) * rate;
    }

    float level = MIN(1.0f, rms * 12.0f);        // 说话大致落在 0.02–0.15
    float rate = level > self.smoothedLevel ? 0.5f : 0.15f;
    self.smoothedLevel += (level - self.smoothedLevel) * rate;

    NSTimeInterval now = [NSDate timeIntervalSinceReferenceDate];
    float gate = MAX(kMinGate, self.noiseFloor * 3.0f + 0.004f);
    if (now - self.startedAt < kFloorWarmup) {
        self.lastVoiceAt = now;                  // 采底噪期间不做判决
    } else if (rms > gate) {
        self.lastVoiceAt = now;
        // 累计"确实有人在说话"的时长。假死判据用它而不是用挂钟时间，
        // 免得安静地举着麦克风发呆也被当成识别器坏了。
        if (buffer.format.sampleRate > 0) {
            self.voicedSeconds += (double)count / buffer.format.sampleRate;
        }
    }
    if (rms > self.peakLevel) self.peakLevel = rms;

    __weak typeof(self) weakSelf = self;
    dispatch_async(dispatch_get_main_queue(), ^{
        if (weakSelf.phase == JarvisVoicePhaseListening) {
            [weakSelf.delegate voiceInput:weakSelf level:weakSelf.smoothedLevel];
        }
    });
}

#pragma mark - 收句判定

- (void)checkTimeouts {
    NSTimeInterval now = [NSDate timeIntervalSinceReferenceDate];

    if (self.phase == JarvisVoicePhaseFinalizing) {
        if (now - self.finalizingAt > self.options.finalWait) [self deliverFinal];
        return;
    }
    if (self.phase != JarvisVoicePhaseListening) return;

    if (now - self.startedAt > self.options.maxSeconds) { [self stop]; return; }

    if (self.transcript.length == 0) {
        // 说了半天却一版 partial 都没有 = 识别任务是死的。它不会报错，
        // 干等只会等到 idleTimeout 然后交出一句空话，用户看到的就是
        // 「麦克风开了，但一个字都不出」。识破它，重建识别器，让下一次能用。
        if (self.voicedSeconds >= kNoResponseVoicedSeconds && self.resultCount == 0) {
            [self handleDeadRecognizer];
            return;
        }
        // 一个字都没识别出来：必须按开麦后的绝对时长判，不能按"距上次有声"。
        // AGC 会不断刷新 lastVoiceAt，按它算的话麦克风永远关不掉。
        // 到点自动关麦是用户明确要的——开着不用的麦克风既费电也占着音频引擎。
        if (now - self.startedAt > self.options.idleTimeout) [self stop];
        return;
    }

    // 说过话了。两条收句路径：
    //   安静环境——文本停了、音频也静了，两个条件都满足才收，最稳；
    //   吵闹环境——音频永远不会静（电视、空调、旁人说话），所以文本停够久就收。
    double textQuiet = now - self.lastTextAt;
    double audioQuiet = now - self.lastVoiceAt;
    if (textQuiet >= self.options.silenceTimeout && audioQuiet >= self.options.silenceTimeout) {
        [self stop];
    } else if (textQuiet >= self.options.silenceTimeout * kNoisyEndpointFactor) {
        [self stop];
    }
}

/// 识别任务假死：音频确实进来了，识别器却一声不吭。
/// 丢掉这个识别器（下次开麦 ensureRecognizer 会重建），并明确告诉用户再说一次——
/// 悄悄收场的话，用户只会觉得"Jarvis 又聋了"，不知道再按一次就好了。
- (void)handleDeadRecognizer {
    NSLog(@"[jarvis] 识别器假死：有声 %.1fs 峰值 %.3f，但一条结果都没有。丢弃重建。",
          self.voicedSeconds, self.peakLevel);
    self.recognizer = nil;
    [self teardown];
    [self.delegate voiceInput:self failed:@"识别器没有响应，已重建。请再说一次。"];
}

@end
