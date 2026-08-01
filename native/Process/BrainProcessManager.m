#import "BrainProcessManager.h"
#import "JarvisPaths.h"

#include <fcntl.h>

static const NSUInteger kMaxConsecutiveFailures = 5;
static const NSTimeInterval kRestartDelayBase = 1.0;

@interface BrainProcessManager ()
@property (nonatomic, strong, nullable) NSTask *task;
@property (nonatomic, strong, nullable) NSFileHandle *logHandle;
@property (nonatomic, assign) NSUInteger failures;
@property (nonatomic, assign) BOOL wantRunning;
/// 我们自己 terminate 的，不算故障，不该计入退避
@property (nonatomic, assign) BOOL terminatingOnPurpose;
@property (nonatomic, copy, nullable) NSString *lastError;
@end

@implementation BrainProcessManager

- (BOOL)isRunning { return self.task.isRunning; }

#pragma mark - 生命周期

- (void)start {
    self.wantRunning = YES;
    [self launch];
}

- (void)restart {
    self.failures = 0;
    self.wantRunning = YES;
    if (self.task.isRunning) {
        self.terminatingOnPurpose = YES;
        [self.task terminate];     // terminationHandler 会负责重新拉起
    } else {
        [self launch];
    }
}

- (void)stop {
    self.wantRunning = NO;
    NSTask *task = self.task;
    self.task = nil;
    if (task.isRunning) [task terminate];
    [self closeLog];
}

#pragma mark - 拉起

- (void)launch {
    if (!self.wantRunning || self.task.isRunning) return;

    NSString *brainDir = [JarvisPaths brainDirectory];
    if (!brainDir) {
        [self failWith:@"找不到 Brain 目录（Resources/brain 与 ~/Projects/Jarvis/brain 都不存在）"];
        return;
    }

    NSTask *task = [[NSTask alloc] init];
    task.executableURL = [NSURL fileURLWithPath:[JarvisPaths pythonExecutable]];
    task.arguments = @[@"-m", @"jarvis_brain", @"serve"];
    task.currentDirectoryURL = [NSURL fileURLWithPath:brainDir];

    NSMutableDictionary *env = [[[NSProcessInfo processInfo] environment] mutableCopy];
    env[@"PYTHONPATH"] = brainDir;
    env[@"PYTHONUNBUFFERED"] = @"1";
    // 未安装 CA 时 urllib 会走系统钥匙串，这里不额外指定 SSL_CERT_FILE
    task.environment = env;

    NSFileHandle *log = [self openLog];
    if (log) { task.standardOutput = log; task.standardError = log; }

    __weak typeof(self) weakSelf = self;
    task.terminationHandler = ^(NSTask *finished) {
        dispatch_async(dispatch_get_main_queue(), ^{
            [weakSelf handleTermination:finished];
        });
    };

    NSError *error = nil;
    if (![task launchAndReturnError:&error]) {
        [self failWith:[NSString stringWithFormat:@"启动 Brain 失败：%@", error.localizedDescription]];
        return;
    }

    self.task = task;
    self.lastError = nil;
    NSLog(@"[jarvis] Brain 已启动 pid=%d（%@）", task.processIdentifier, [JarvisPaths pythonExecutable]);
    [self.delegate brainProcess:self isRunning:YES detail:nil];
}

- (void)handleTermination:(NSTask *)finished {
    if (self.task != finished) return;      // 已经被新的取代
    self.task = nil;

    int status = finished.terminationStatus;

    if (!self.wantRunning) {
        [self.delegate brainProcess:self isRunning:NO detail:nil];
        return;
    }

    if (self.terminatingOnPurpose) {
        self.terminatingOnPurpose = NO;
        [self launch];
        return;
    }

    self.failures = (status == 0) ? 0 : self.failures + 1;
    if (self.failures >= kMaxConsecutiveFailures) {
        [self failWith:[NSString stringWithFormat:
                        @"Brain 连续 %lu 次异常退出（最后退出码 %d），已停止重启。看 %@",
                        (unsigned long)self.failures, status, [JarvisPaths brainLogPath]]];
        return;
    }

    NSTimeInterval delay = kRestartDelayBase * (NSTimeInterval)(1 << MIN(self.failures, 4u));
    NSLog(@"[jarvis] Brain 退出（码 %d），%.0fs 后重启", status, delay);
    [self.delegate brainProcess:self isRunning:NO
                         detail:[NSString stringWithFormat:@"Brain 已退出，%.0f 秒后重启", delay]];

    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(delay * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{ [self launch]; });
}

- (void)failWith:(NSString *)message {
    NSLog(@"[jarvis] %@", message);
    self.lastError = message;
    self.wantRunning = NO;
    [self.delegate brainProcess:self isRunning:NO detail:message];
}

#pragma mark - 日志

- (NSFileHandle *)openLog {
    if (self.logHandle) return self.logHandle;
    NSString *path = [JarvisPaths brainLogPath];
    NSFileManager *fm = [NSFileManager defaultManager];

    // 超过 2MB 就截断重来，别让它无限长
    NSNumber *size = [[fm attributesOfItemAtPath:path error:nil] objectForKey:NSFileSize];
    if (size.longLongValue > 2 * 1024 * 1024) [fm removeItemAtPath:path error:nil];

    // 必须 O_APPEND：Brain 重启后新进程复用同一个句柄，靠固定偏移量写会互相覆盖。
    int fd = open(path.fileSystemRepresentation, O_WRONLY | O_APPEND | O_CREAT, 0644);
    if (fd < 0) return nil;
    self.logHandle = [[NSFileHandle alloc] initWithFileDescriptor:fd closeOnDealloc:YES];
    return self.logHandle;
}

- (void)closeLog {
    [self.logHandle closeFile];
    self.logHandle = nil;
}

@end
