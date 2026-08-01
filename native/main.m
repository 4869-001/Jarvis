//
//  J.A.R.V.I.S.
//
//  一个进程里三件事：
//    1. 壁纸层的球体（桌面图标之下、系统壁纸之上，鼠标穿透，跟随所有 Space）
//    2. 对话面板 + 菜单栏入口
//    3. 托管 Python Brain 子进程，并代它执行需要 TCC 权限的原生操作
//
//  球体的状态由真实会话驱动，不再是一个空转的呼吸动画。
//
//  说明：本机 CommandLineTools 的 Swift SDK 与编译器版本不匹配，
//  任何 import 系统框架的 Swift 都编不过。Objective-C 不受影响，故以此为准。
//

#import <Cocoa/Cocoa.h>
#import "AppDelegate.h"

int main(int argc, const char *argv[]) {
    @autoreleasepool {
        NSApplication *app = [NSApplication sharedApplication];
        AppDelegate *delegate = [[AppDelegate alloc] init];
        app.delegate = delegate;
        [app run];
    }
    return 0;
}
