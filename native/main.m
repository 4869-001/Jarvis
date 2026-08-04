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
#import "Tools/NativeToolExecutor.h"

/// 直接跑一个原生工具然后退出，不起球体、不起 Brain。
///
///   Jarvis.app/Contents/MacOS/Jarvis --tool media_control action=toggle
///
/// 存在的理由是 TCC：辅助功能、自动化这些权限按 bundle 授予，用一个临时编的小程序
/// 去测等于换了个身份，测不出真实结果。同一个可执行文件跑起来才是同一个被授权的主体。
static int RunToolFromCommandLine(int argc, const char *argv[]) {
    NSString *name = nil;
    NSMutableDictionary *arguments = [NSMutableDictionary dictionary];
    for (int i = 2; i < argc; i++) {
        NSString *item = [NSString stringWithUTF8String:argv[i]];
        NSRange split = [item rangeOfString:@"="];
        if (split.location == NSNotFound) { name = item; continue; }
        NSString *key = [item substringToIndex:split.location];
        NSString *value = [item substringFromIndex:split.location + 1];
        // 数组/对象参数（menu_invoke 的 path）在命令行上只能写成 JSON。
        // 以 [ 或 { 开头就按 JSON 解析，解析不了就当普通字符串——
        // 这样 `text=[草稿]` 这种真的以方括号开头的文本不会被吃掉。
        id parsed = nil;
        if ([value hasPrefix:@"["] || [value hasPrefix:@"{"]) {
            parsed = [NSJSONSerialization JSONObjectWithData:[value dataUsingEncoding:NSUTF8StringEncoding]
                                                     options:0 error:nil];
        }
        arguments[key] = parsed ?: value;
    }
    if (name.length == 0) {
        fprintf(stderr, "用法：Jarvis --tool <工具名> [键=值 ...]\n");
        return 2;
    }

    // NSAppleScript、NSWorkspace 都要一个跑着的 runloop 和 NSApplication
    [NSApplication sharedApplication];
    __block int status = 0;
    __block BOOL done = NO;

    NativeToolExecutor *executor = [[NativeToolExecutor alloc] init];
    [executor execute:name arguments:arguments completion:^(NSDictionary *result, NSString *error) {
        if (error) {
            fprintf(stderr, "✗ %s\n", error.UTF8String);
            status = 1;
        } else {
            NSData *json = [NSJSONSerialization dataWithJSONObject:(result ?: @{})
                                                           options:NSJSONWritingPrettyPrinted error:nil];
            fprintf(stdout, "%s\n", [[NSString alloc] initWithData:json encoding:NSUTF8StringEncoding].UTF8String);
        }
        done = YES;
        CFRunLoopStop(CFRunLoopGetMain());
    }];

    // 同步完成的工具在 runloop 起来之前就回调了，这时 CFRunLoopStop 是空放，
    // 不先判一下就会白等满超时。30 秒是 Brain 那边等原生工具的量级。
    if (!done) CFRunLoopRunInMode(kCFRunLoopDefaultMode, 30, false);
    if (!done) { fprintf(stderr, "✗ 超时\n"); return 1; }
    return status;
}

int main(int argc, const char *argv[]) {
    @autoreleasepool {
        if (argc >= 2 && strcmp(argv[1], "--tool") == 0) {
            return RunToolFromCommandLine(argc, argv);
        }
        NSApplication *app = [NSApplication sharedApplication];
        AppDelegate *delegate = [[AppDelegate alloc] init];
        app.delegate = delegate;
        [app run];
    }
    return 0;
}
