//
//  JarvisPaths —— 统一解析运行期路径。
//
//  同一份代码要能在两种形态下跑：
//    · 打包后：资源在 Jarvis.app/Contents/Resources/
//    · 开发时：直接跑源码目录 ~/Projects/Jarvis/
//  所有"找文件"的逻辑集中在这里，别散到各处再各写一遍 fallback。
//

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

@interface JarvisPaths : NSObject

/// ~/.jarvis，不存在则创建
+ (NSString *)supportDirectory;
+ (NSString *)socketPath;       // ~/.jarvis/brain.sock
+ (NSString *)statePath;        // ~/.jarvis/state
+ (NSString *)configPath;       // ~/.jarvis/config.json
+ (NSString *)brainLogPath;     // ~/.jarvis/brain.log

/// 网页资源（Resources/web 优先，回落到源码 ui/）
+ (NSURL *)webPage:(NSString *)filename;

/// Brain 的 Python 包所在目录（含 jarvis_brain/）
+ (nullable NSString *)brainDirectory;

/// 跑 Brain 用的解释器：优先 brain/.venv，其次系统 python3
+ (NSString *)pythonExecutable;

/// 唤醒词模型目录与音素词表（Resources/models 优先，回落到源码 models/）
+ (nullable NSString *)kwsModelDirectory;
+ (nullable NSString *)wakeKeywordsFile;

/// 源码根目录，仅用于菜单里的"打开项目目录"
+ (nullable NSString *)projectDirectory;

@end

NS_ASSUME_NONNULL_END
