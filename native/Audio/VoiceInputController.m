#import "VoiceInputController.h"
#import "AudioHub.h"

#import <AVFoundation/AVFoundation.h>
#import <Speech/Speech.h>

/// 开麦后一直没识别出任何文字，多久放弃。给足开口时间，但不能无限等。
static const NSTimeInterval kOpeningGrace = 6.0;

@interface VoiceInputController ()
@property (nonatomic, copy)   NSString *localeIdentifier;
@property (nonatomic, assign) NSTimeInterval silenceTimeout;
@property (nonatomic, assign) NSTimeInterval maxSeconds;
@property (nonatomic, assign) BOOL preferOnDevice;

@property (nonatomic, strong) SFSpeechRecognizer *recognizer;
@property (nonatomic, strong) SFSpeechAudioBufferRecognitionRequest *request;
@property (nonatomic, strong) SFSpeechRecognitionTask *task;
@property (nonatomic, copy)   NSString *tapToken;
@property (nonatomic, strong) NSTimer *watchdog;

@property (nonatomic, assign) BOOL listening;
@property (nonatomic, copy)   NSString *transcript;
@property (nonatomic, assign) NSTimeInterval startedAt;
@property (nonatomic, assign) NSTimeInterval lastVoiceAt;
@property (nonatomic, assign) float smoothedLevel;
@end

@implementation VoiceInputController

- (instancetype)initWithLocale:(NSString *)localeIdentifier
                silenceTimeout:(NSTimeInterval)silenceTimeout
                    maxSeconds:(NSTimeInterval)maxSeconds
                preferOnDevice:(BOOL)preferOnDevice {
    if ((self = [super init])) {
        _localeIdentifier = [localeIdentifier copy] ?: @"zh-CN";
        _silenceTimeout = silenceTimeout > 0 ? silenceTimeout : 1.6;
        _maxSeconds = maxSeconds > 0 ? maxSeconds : 30.0;
        _preferOnDevice = preferOnDevice;
    }
    return self;
}

- (void)dealloc { [self teardown]; }

#pragma mark - 权限

/// 麦克风和语音识别是两套独立授权，缺一不可，所以串起来问。
- (void)ensureAuthorized:(void (^)(BOOL granted, NSString *reason))completion {
    [SFSpeechRecognizer requestAuthorization:^(SFSpeechRecognizerAuthorizationStatus status) {
        if (status != SFSpeechRecognizerAuthorizationStatusAuthorized) {
            dispatch_async(dispatch_get_main_queue(), ^{
                completion(NO, @"语音识别未授权。系统设置 → 隐私与安全性 → 语音识别，勾上 Jarvis。");
            });
            return;
        }
        [[AudioHub shared] requestPermission:completion];
    }];
}

#pragma mark - 开始 / 结束

- (void)start {
    if (self.listening) return;
    [self ensureAuthorized:^(BOOL granted, NSString *reason) {
        if (!granted) { [self.delegate voiceInput:self failed:reason]; return; }
        [self reallyStart];
    }];
}

- (void)reallyStart {
    if (self.listening) return;

    self.recognizer = [[SFSpeechRecognizer alloc]
                       initWithLocale:[NSLocale localeWithLocaleIdentifier:self.localeIdentifier]];
    if (!self.recognizer.isAvailable) {
        [self.delegate voiceInput:self failed:
         [NSString stringWithFormat:@"%@ 的识别器当前不可用", self.localeIdentifier]];
        return;
    }

    self.request = [[SFSpeechAudioBufferRecognitionRequest alloc] init];
    self.request.shouldReportPartialResults = YES;
    if (self.preferOnDevice && self.recognizer.supportsOnDeviceRecognition) {
        self.request.requiresOnDeviceRecognition = YES;
    }

    // 麦克风由 AudioHub 独占——唤醒词可能正常听着，不能在这儿再开一个引擎
    NSError *startError = nil;
    __weak typeof(self) weakSelf = self;
    self.tapToken = [[AudioHub shared] addTap:^(AVAudioPCMBuffer *buffer) {
        [weakSelf.request appendAudioPCMBuffer:buffer];
        [weakSelf noteLevelFromBuffer:buffer];
    } error:&startError];

    if (!self.tapToken) {
        [self.delegate voiceInput:self failed:
         [NSString stringWithFormat:@"麦克风启动失败：%@", startError.localizedDescription]];
        [self teardown];
        return;
    }

    self.transcript = @"";
    self.listening = YES;
    self.startedAt = [NSDate timeIntervalSinceReferenceDate];
    self.lastVoiceAt = self.startedAt;
    self.smoothedLevel = 0;

    self.task = [self.recognizer recognitionTaskWithRequest:self.request
                                              resultHandler:^(SFSpeechRecognitionResult *result,
                                                              NSError *error) {
        dispatch_async(dispatch_get_main_queue(), ^{
            [weakSelf handleResult:result error:error];
        });
    }];

    self.watchdog = [NSTimer scheduledTimerWithTimeInterval:0.2 repeats:YES
                                                      block:^(NSTimer *timer) { [weakSelf checkTimeouts]; }];

    [self.delegate voiceInputDidStart:self];
}

- (void)stop {
    if (!self.listening) return;
    NSString *text = [self.transcript stringByTrimmingCharactersInSet:
                      [NSCharacterSet whitespaceAndNewlineCharacterSet]];
    [self teardown];
    [self.delegate voiceInput:self finalText:text ?: @""];
}

- (void)abort {
    if (!self.listening) return;
    [self teardown];
    [self.delegate voiceInput:self finalText:@""];
}

- (void)teardown {
    [self.watchdog invalidate];
    self.watchdog = nil;

    [[AudioHub shared] removeTap:self.tapToken];
    self.tapToken = nil;
    [self.request endAudio];
    [self.task cancel];

    self.request = nil;
    self.task = nil;
    self.recognizer = nil;
    self.listening = NO;
    [self.delegate voiceInput:self level:0];
}

#pragma mark - 识别回调

- (void)handleResult:(SFSpeechRecognitionResult *)result error:(NSError *)error {
    if (!self.listening) return;

    if (result) {
        NSString *text = result.bestTranscription.formattedString ?: @"";
        if (![text isEqualToString:self.transcript]) {
            self.transcript = text;
            self.lastVoiceAt = [NSDate timeIntervalSinceReferenceDate];
            [self.delegate voiceInput:self partialText:text];
        }
        if (result.isFinal) { [self stop]; return; }
    }

    if (error) {
        // 用户没说话时识别器会以 "No speech detected" 收场，这不是故障
        BOOL noSpeech = (error.code == 1110 || error.code == 203);
        if (noSpeech) { [self stop]; return; }
        NSString *message = [NSString stringWithFormat:@"识别失败：%@", error.localizedDescription];
        [self teardown];
        [self.delegate voiceInput:self failed:message];
    }
}

#pragma mark - 静音与超时

- (void)noteLevelFromBuffer:(AVAudioPCMBuffer *)buffer {
    float const *samples = buffer.floatChannelData ? buffer.floatChannelData[0] : NULL;
    if (!samples) return;

    // RMS，比峰值稳，不会被一次咔哒声顶满
    double sum = 0;
    AVAudioFrameCount count = buffer.frameLength;
    for (AVAudioFrameCount i = 0; i < count; i++) sum += (double)samples[i] * samples[i];
    float rms = count ? (float)sqrt(sum / count) : 0.0f;
    float level = MIN(1.0f, rms * 12.0f);       // 说话大致落在 0.02–0.15

    float rate = level > self.smoothedLevel ? 0.5f : 0.15f;
    self.smoothedLevel += (level - self.smoothedLevel) * rate;

    if (level > 0.045f) self.lastVoiceAt = [NSDate timeIntervalSinceReferenceDate];

    __weak typeof(self) weakSelf = self;
    dispatch_async(dispatch_get_main_queue(), ^{
        if (weakSelf.listening) [weakSelf.delegate voiceInput:weakSelf level:weakSelf.smoothedLevel];
    });
}

- (void)checkTimeouts {
    if (!self.listening) return;
    NSTimeInterval now = [NSDate timeIntervalSinceReferenceDate];

    if (now - self.startedAt > self.maxSeconds) { [self stop]; return; }

    if (self.transcript.length > 0) {
        // 说过话了：按"距上次有声"收句
        if (now - self.lastVoiceAt > self.silenceTimeout) [self stop];
        return;
    }

    // 一句都没识别出来：必须按开麦后的绝对时长判，不能按"距上次有声"。
    // Voice Processing 的 AGC 会把安静房间的底噪也拉到阈值以上，
    // lastVoiceAt 于是被无限刷新，麦克风就再也关不掉了。
    if (now - self.startedAt > kOpeningGrace) [self stop];
}

@end
