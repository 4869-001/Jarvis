//
//  BrainProcessManager —— 托管 Python Brain 子进程。
//
//  子进程崩了要能自己爬起来，但不能无限快速重启（会把 CPU 烧光还刷爆日志），
//  所以退避重启并在连续失败若干次后停手，把失败状态报给 UI。
//

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

@class BrainProcessManager;

@protocol BrainProcessManagerDelegate <NSObject>
/// 进程状态变化。running=NO 且 detail 非空时表示异常退出。
- (void)brainProcess:(BrainProcessManager *)manager isRunning:(BOOL)running detail:(nullable NSString *)detail;
@end

@interface BrainProcessManager : NSObject

@property (nonatomic, weak) id<BrainProcessManagerDelegate> delegate;
@property (nonatomic, readonly, getter=isRunning) BOOL running;
@property (nonatomic, readonly, copy, nullable) NSString *lastError;

- (void)start;
/// 手动重启：清零退避计数，立即拉起
- (void)restart;
- (void)stop;

@end

NS_ASSUME_NONNULL_END
