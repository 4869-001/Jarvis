//
//  NativeToolExecutor —— 由宿主进程执行的那部分工具。
//
//  为什么不放 Python：TCC 权限按 app bundle 授予。Python 子进程去调 NSWorkspace、
//  发 Apple Events 或读剪贴板，授权归属会漂到解释器上，弹窗写的是 "Python" 而不是
//  "J.A.R.V.I.S."，且随 macOS 版本和进程签名变化。留在宿主里，系统只认一个 bundle。
//
//  纯文件读写留在 Python 侧——那部分不涉及 Apple Events，且用 Schema 更好约束。
//

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// 结果通过 completion 异步回传。error 非空表示失败，此时 result 忽略。
typedef void (^JarvisToolCompletion)(NSDictionary *_Nullable result, NSString *_Nullable error);

@interface NativeToolExecutor : NSObject

+ (BOOL)handlesToolNamed:(NSString *)name;

- (void)execute:(NSString *)name
      arguments:(NSDictionary *)arguments
     completion:(JarvisToolCompletion)completion;

@end

NS_ASSUME_NONNULL_END
