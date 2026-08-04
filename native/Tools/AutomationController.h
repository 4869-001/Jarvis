//
//  AutomationController —— 「指挥任意本机软件」那一层。
//
//  设计前提：**不为每个 App 写一个工具**。写死的工具只能覆盖当初想到的那几个
//  App，而 macOS 上真正的通用控制面只有三个，这里把三个都开出来，按可靠性排序：
//
//    1. AppleScript / JXA —— 有脚本字典的 App（Mail、备忘录、Finder、Keynote、
//       OmniFocus、Chrome…）的正规接口。能力最强、语义最稳。
//    2. 菜单点击 —— 没有字典但有标准菜单栏的 App。菜单项名字就是能力清单。
//    3. 辅助功能（AX）—— 前两条都没有时的兜底，直接点界面元素。
//
//  再往下（自绘界面、Electron 里的 canvas）就没有可靠通道了，这种情况要如实
//  告诉用户，不要用键鼠模拟假装做到了——详见 refs 里微信那份技术方案。
//
//  为什么留在 ObjC：TCC 按 app bundle 授权。Python 子进程去发 Apple Events 会让
//  授权归属漂到解释器上，弹窗写的是 "Python" 而不是 "J.A.R.V.I.S."。
//

#import <Foundation/Foundation.h>

#import "NativeToolExecutor.h"

NS_ASSUME_NONNULL_BEGIN

@interface AutomationController : NSObject

+ (BOOL)handlesToolNamed:(NSString *)name;

/// 中文应用名 → 磁盘上的 bundle 名（备忘录→Notes）。NativeToolExecutor 的
/// app_open 也用它，两处必须是同一份表。
+ (NSDictionary<NSString *, NSString *> *)nameAliases;

- (void)execute:(NSString *)name
      arguments:(NSDictionary *)arguments
     completion:(JarvisToolCompletion)completion;

@end

NS_ASSUME_NONNULL_END
