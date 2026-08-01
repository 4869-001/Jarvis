//
//  OrbWindowController —— 壁纸层的球体窗口（每块屏幕一个）。
//
//  这部分原样保留自最初的 main.m：层级、透明底、限帧策略都是实测出来的，
//  没有理由动它。只是从 AppDelegate 里拆出来，并把状态入口从"轮询文件"
//  改成方法调用——现在写状态的一方就在同一个进程里。
//

#import <Cocoa/Cocoa.h>

NS_ASSUME_NONNULL_BEGIN

@interface OrbWindowController : NSObject

- (void)start;
- (void)stop;

/// idle / listening / thinking / speaking / error
- (void)applyState:(NSString *)state;
@property (nonatomic, readonly, copy) NSString *orbState;

/// 0–1 实时音量。播报时是播放振幅，收音时是麦克风 RMS。
/// 变化不大时会自行丢弃，不必调用方节流。
- (void)applyLevel:(float)level;

@end

NS_ASSUME_NONNULL_END
