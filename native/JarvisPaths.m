#import "JarvisPaths.h"

static NSString *const kDevRoot = @"~/Projects/Jarvis";

@implementation JarvisPaths

+ (NSString *)supportDirectory {
    static NSString *dir = nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        dir = [@"~/.jarvis" stringByExpandingTildeInPath];
        [[NSFileManager defaultManager] createDirectoryAtPath:dir
                                 withIntermediateDirectories:YES
                                                  attributes:nil
                                                       error:nil];
    });
    return dir;
}

+ (NSString *)socketPath   { return [[self supportDirectory] stringByAppendingPathComponent:@"brain.sock"]; }
+ (NSString *)statePath    { return [[self supportDirectory] stringByAppendingPathComponent:@"state"]; }
+ (NSString *)configPath   { return [[self supportDirectory] stringByAppendingPathComponent:@"config.json"]; }
+ (NSString *)brainLogPath { return [[self supportDirectory] stringByAppendingPathComponent:@"brain.log"]; }

+ (NSURL *)webPage:(NSString *)filename {
    NSURL *bundled = [[[NSBundle mainBundle] resourceURL]
                      URLByAppendingPathComponent:[@"web" stringByAppendingPathComponent:filename]];
    if (bundled && [[NSFileManager defaultManager] fileExistsAtPath:bundled.path]) return bundled;

    NSString *dev = [[kDevRoot stringByExpandingTildeInPath]
                     stringByAppendingPathComponent:[@"ui" stringByAppendingPathComponent:filename]];
    return [NSURL fileURLWithPath:dev];
}

+ (NSString *)brainDirectory {
    NSFileManager *fm = [NSFileManager defaultManager];
    NSString *bundled = [[[NSBundle mainBundle] resourcePath] stringByAppendingPathComponent:@"brain"];
    if (bundled && [fm fileExistsAtPath:[bundled stringByAppendingPathComponent:@"jarvis_brain"]]) {
        return bundled;
    }
    NSString *dev = [[kDevRoot stringByExpandingTildeInPath] stringByAppendingPathComponent:@"brain"];
    if ([fm fileExistsAtPath:[dev stringByAppendingPathComponent:@"jarvis_brain"]]) return dev;
    return nil;
}

+ (NSString *)pythonExecutable {
    NSFileManager *fm = [NSFileManager defaultManager];
    NSString *brain = [self brainDirectory];
    if (brain) {
        NSString *venv = [brain stringByAppendingPathComponent:@".venv/bin/python3"];
        if ([fm isExecutableFileAtPath:venv]) return venv;
    }
    // Brain 只用标准库，系统自带的就够。装了 venv 会自动优先用 venv。
    for (NSString *candidate in @[@"/usr/bin/python3",
                                  @"/opt/homebrew/bin/python3",
                                  @"/usr/local/bin/python3"]) {
        if ([fm isExecutableFileAtPath:candidate]) return candidate;
    }
    return @"/usr/bin/python3";
}

/// models/ 下的东西：打包后在 Resources/models，开发时在项目里
+ (NSString *)modelsDirectory {
    NSFileManager *fm = [NSFileManager defaultManager];
    NSString *bundled = [[[NSBundle mainBundle] resourcePath] stringByAppendingPathComponent:@"models"];
    if (bundled && [fm fileExistsAtPath:bundled]) return bundled;
    NSString *dev = [[kDevRoot stringByExpandingTildeInPath] stringByAppendingPathComponent:@"models"];
    return [fm fileExistsAtPath:dev] ? dev : nil;
}

+ (NSString *)kwsModelDirectory {
    NSString *models = [self modelsDirectory];
    if (!models) return nil;
    NSString *path = [models stringByAppendingPathComponent:@"kws-zh-en"];
    return [[NSFileManager defaultManager] fileExistsAtPath:path] ? path : nil;
}

+ (NSString *)wakeKeywordsFile {
    NSString *models = [self modelsDirectory];
    if (!models) return nil;
    NSString *path = [models stringByAppendingPathComponent:@"kws-jarvis.txt"];
    return [[NSFileManager defaultManager] fileExistsAtPath:path] ? path : nil;
}

+ (NSString *)projectDirectory {
    NSString *dev = [kDevRoot stringByExpandingTildeInPath];
    return [[NSFileManager defaultManager] fileExistsAtPath:dev] ? dev : nil;
}

@end
