//
//  AudioHub —— 全进程唯一的麦克风入口。
//
//  唤醒词要常听、语音识别要收句，两者不能各开一个 AVAudioEngine：
//  同一个输入设备被开两次，轻则格式打架，重则第二个直接起不来。
//  所以这里独占引擎和 tap，再把缓冲广播给各个消费者。
//
//  Voice Processing（AEC + 降噪 + AGC）在这一层统一启用，
//  下游拿到的就已经是消过回声的流。
//

#import <Foundation/Foundation.h>
#import <AVFoundation/AVFoundation.h>

NS_ASSUME_NONNULL_BEGIN

typedef void (^JarvisAudioTap)(AVAudioPCMBuffer *buffer);

@interface AudioHub : NSObject

+ (instancetype)shared;

/// 采集格式。加第一个 tap 之前为 nil。
@property (nonatomic, readonly, nullable) AVAudioFormat *format;
@property (nonatomic, readonly, getter=isRunning) BOOL running;

/// 麦克风授权。未授权时 reason 是给用户看的中文说明。
- (void)requestPermission:(void (^)(BOOL granted, NSString *_Nullable reason))completion;

/// 返回 token 用于注销。第一个 tap 会拉起引擎，最后一个注销后引擎关闭。
/// 失败返回 nil 并填 error。
- (nullable NSString *)addTap:(JarvisAudioTap)tap error:(NSError **)error;
- (void)removeTap:(nullable NSString *)token;

@end

NS_ASSUME_NONNULL_END
