//
//  AppDelegate —— 把各部分接起来的地方，本身不实现任何业务。
//
//  事件流：
//      面板输入 ──► BrainIPCClient ──► Python Brain
//      Brain 事件 ──┬─► 球体状态（OrbWindowController）
//                   ├─► 对话面板（流式文本、工具卡片、确认框）
//                   ├─► 菜单栏图标
//                   └─► 原生工具执行（NativeToolExecutor）→ 结果回传 Brain
//

#import <Cocoa/Cocoa.h>

@interface AppDelegate : NSObject <NSApplicationDelegate>
@end
