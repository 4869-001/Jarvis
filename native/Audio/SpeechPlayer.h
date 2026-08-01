//
//  SpeechPlayer —— 按顺序播放 Brain 合成好的 wav。
//
//  Brain 是逐句合成的，所以这里必须是队列：第二句到达时第一句多半还在播。
//  播放期间按 ~20Hz 上报振幅，用来驱动球体的 speaking 态；
//  同时它也是半双工的"占用方"——正在播就不该让麦克风提交识别结果。
//

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

@class SpeechPlayer;

@protocol SpeechPlayerDelegate <NSObject>
- (void)speechPlayerDidStart:(SpeechPlayer *)player;
- (void)speechPlayerDidFinish:(SpeechPlayer *)player;
/// 0.0–1.0，已做过平滑
- (void)speechPlayer:(SpeechPlayer *)player level:(float)level;
@end

@interface SpeechPlayer : NSObject

@property (nonatomic, weak) id<SpeechPlayerDelegate> delegate;
@property (nonatomic, readonly, getter=isPlaying) BOOL playing;

- (void)enqueue:(NSString *)wavPath;
/// 清空队列并立刻停止（打断播报时用）
- (void)stopAll;

@end

NS_ASSUME_NONNULL_END
