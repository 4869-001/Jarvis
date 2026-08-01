//
//  MediaController —— 播放器控制。
//
//  网易云音乐没有 AppleScript 字典（Contents/Resources 下没有 .sdef），所以
//  "tell application 网易云音乐 to playpause" 这条路根本不存在——这就是原来只能
//  启动、不能播放/暂停的原因。能用的只有三条通道，按可靠性排序：
//
//    1. MediaRemote（私有框架，dlopen 拿符号）——系统级"正在播放"总线。
//       实测网易云音乐完整接入：播放/暂停/上下一首都生效，还能读到曲目信息。
//       缺点是它只认当前占用总线的那一个 App，浏览器放视频会把总线抢走。
//    2. System Events 点"控制"菜单——定点打击，不管谁占着总线都能打到网易云。
//       喜欢/取消喜欢、App 内音量也只有这条路有。
//    3. 媒体键 HID 事件——最后兜底，谁在前台谁接。
//
//  1 和 3 要辅助功能权限，2 还要额外的 Apple Events 权限（目标是 System Events）。
//

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

typedef void (^JarvisMediaCompletion)(NSDictionary *_Nullable result, NSString *_Nullable error);

@interface MediaController : NSObject

/// action: toggle / play / pause / next / previous / volume_up / volume_down / like / status
/// player: 可空，auto（默认）/ netease / music / spotify / system
- (void)perform:(NSString *)action
         player:(nullable NSString *)player
     completion:(JarvisMediaCompletion)completion;

@end

NS_ASSUME_NONNULL_END
