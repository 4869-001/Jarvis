//
//  BrainIPCClient —— 与 Python Brain 的 Unix Domain Socket 通道。
//
//  协议：JSON Lines，一行一个对象，双向。
//  Brain 是服务端，本类是客户端：Brain 崩溃重启后 socket 会被重建，
//  客户端只要退避重连即可，不需要两边同步生命周期。
//
//  读在后台串行队列上阻塞循环，解析后统一回主线程回调。
//

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

@class BrainIPCClient;

@protocol BrainIPCClientDelegate <NSObject>
- (void)brainClient:(BrainIPCClient *)client didReceiveEvent:(NSDictionary *)event;
- (void)brainClientDidConnect:(BrainIPCClient *)client;
- (void)brainClient:(BrainIPCClient *)client didDisconnectWithReason:(NSString *)reason;
@end

@interface BrainIPCClient : NSObject

@property (nonatomic, weak) id<BrainIPCClientDelegate> delegate;
@property (nonatomic, readonly, getter=isConnected) BOOL connected;

- (instancetype)initWithSocketPath:(NSString *)socketPath;

/// 开始连接并在断开后自动退避重连（0.5s 起，封顶 5s）
- (void)start;
- (void)stop;

/// 线程安全。未连接时静默丢弃——调用方不该为此写重试逻辑。
- (void)send:(NSDictionary *)message;

@end

NS_ASSUME_NONNULL_END
