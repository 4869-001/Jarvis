#import "SpeechPlayer.h"

#import <AVFoundation/AVFoundation.h>

static const NSTimeInterval kMeterInterval = 0.05;   // 20Hz，够球体跟得上又不费电

@interface SpeechPlayer () <AVAudioPlayerDelegate>
@property (nonatomic, strong) NSMutableArray<NSString *> *queue;
@property (nonatomic, strong) AVAudioPlayer *player;
@property (nonatomic, strong) NSTimer *meterTimer;
@property (nonatomic, assign) float smoothedLevel;
@property (nonatomic, assign) BOOL announcedStart;
@end

@implementation SpeechPlayer

- (instancetype)init {
    if ((self = [super init])) {
        _queue = [NSMutableArray array];
    }
    return self;
}

- (BOOL)isPlaying { return self.player.isPlaying || self.queue.count > 0; }

#pragma mark - 队列

- (void)enqueue:(NSString *)wavPath {
    if (wavPath.length == 0) return;
    [self.queue addObject:wavPath];
    if (!self.player.isPlaying) [self playNext];
}

- (void)stopAll {
    [self.queue removeAllObjects];
    [self.player stop];
    self.player = nil;
    [self finishIfIdle];
}

- (void)playNext {
    if (self.queue.count == 0) { [self finishIfIdle]; return; }

    NSString *path = self.queue.firstObject;
    [self.queue removeObjectAtIndex:0];

    NSError *error = nil;
    AVAudioPlayer *player = [[AVAudioPlayer alloc]
                             initWithContentsOfURL:[NSURL fileURLWithPath:path] error:&error];
    if (!player) {
        NSLog(@"[jarvis] 播放失败 %@：%@", path.lastPathComponent, error.localizedDescription);
        [self playNext];        // 一句播不了不该卡住后面所有句子
        return;
    }

    player.delegate = self;
    player.meteringEnabled = YES;
    [player prepareToPlay];
    self.player = player;
    [player play];

    if (!self.announcedStart) {
        self.announcedStart = YES;
        [self.delegate speechPlayerDidStart:self];
    }
    [self startMetering];
}

- (void)finishIfIdle {
    [self stopMetering];
    if (!self.announcedStart) return;
    self.announcedStart = NO;
    self.smoothedLevel = 0;
    [self.delegate speechPlayer:self level:0];
    [self.delegate speechPlayerDidFinish:self];
}

#pragma mark - 振幅

- (void)startMetering {
    if (self.meterTimer) return;
    self.meterTimer = [NSTimer scheduledTimerWithTimeInterval:kMeterInterval repeats:YES
                                                        block:^(NSTimer *timer) { [self tick]; }];
}

- (void)stopMetering {
    [self.meterTimer invalidate];
    self.meterTimer = nil;
}

- (void)tick {
    AVAudioPlayer *player = self.player;
    if (!player.isPlaying) return;
    [player updateMeters];

    // dB → 0..1。-45dB 以下当静音，人声动态大致就落在这个区间
    float db = [player averagePowerForChannel:0];
    float linear = db < -45.0f ? 0.0f : (db + 45.0f) / 45.0f;
    linear = MIN(1.0f, MAX(0.0f, linear));

    // 起快落慢：球体跟着音节亮起来，尾音收得柔和一点
    float rate = linear > self.smoothedLevel ? 0.55f : 0.18f;
    self.smoothedLevel += (linear - self.smoothedLevel) * rate;
    [self.delegate speechPlayer:self level:self.smoothedLevel];
}

#pragma mark - AVAudioPlayerDelegate

- (void)audioPlayerDidFinishPlaying:(AVAudioPlayer *)player successfully:(BOOL)flag {
    if (player != self.player) return;      // stopAll 之后来的迟到回调
    self.player = nil;
    [self playNext];
}

- (void)audioPlayerDecodeErrorDidOccur:(AVAudioPlayer *)player error:(NSError *)error {
    NSLog(@"[jarvis] 解码失败：%@", error.localizedDescription);
    if (player != self.player) return;
    self.player = nil;
    [self playNext];
}

@end
