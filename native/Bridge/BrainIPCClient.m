#import "BrainIPCClient.h"

#include <sys/socket.h>
#include <sys/un.h>
#include <unistd.h>
#include <errno.h>
#include <string.h>

static const NSTimeInterval kRetryMin = 0.5;
static const NSTimeInterval kRetryMax = 5.0;

@interface BrainIPCClient ()
@property (nonatomic, copy)   NSString *socketPath;
@property (nonatomic, assign) int fd;
@property (nonatomic, assign) BOOL running;
@property (nonatomic, assign) BOOL connected;
@property (nonatomic, assign) NSTimeInterval retryDelay;
@property (nonatomic, strong) dispatch_queue_t readQueue;
@property (nonatomic, strong) dispatch_queue_t writeQueue;
@end

@implementation BrainIPCClient

- (instancetype)initWithSocketPath:(NSString *)socketPath {
    if ((self = [super init])) {
        _socketPath = [socketPath copy];
        _fd = -1;
        _retryDelay = kRetryMin;
        _readQueue  = dispatch_queue_create("com.jarvis.ipc.read",  DISPATCH_QUEUE_SERIAL);
        _writeQueue = dispatch_queue_create("com.jarvis.ipc.write", DISPATCH_QUEUE_SERIAL);
    }
    return self;
}

- (void)dealloc { [self stop]; }

#pragma mark - 生命周期

- (void)start {
    if (self.running) return;
    self.running = YES;
    [self scheduleConnect:0];
}

- (void)stop {
    self.running = NO;
    [self closeSocket];
}

- (void)scheduleConnect:(NSTimeInterval)delay {
    if (!self.running) return;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(delay * NSEC_PER_SEC)),
                   self.readQueue, ^{ [self connectAndPump]; });
}

#pragma mark - 连接 + 读循环（后台队列）

- (void)connectAndPump {
    if (!self.running) return;

    struct sockaddr_un addr;
    memset(&addr, 0, sizeof(addr));
    addr.sun_family = AF_UNIX;
    const char *path = self.socketPath.fileSystemRepresentation;
    if (strlen(path) >= sizeof(addr.sun_path)) {
        NSLog(@"[jarvis] socket 路径过长：%@", self.socketPath);
        return;
    }
    strlcpy(addr.sun_path, path, sizeof(addr.sun_path));

    int sock = socket(AF_UNIX, SOCK_STREAM, 0);
    if (sock < 0) { [self retryAfterFailure:@"socket() 失败"]; return; }

    if (connect(sock, (struct sockaddr *)&addr, sizeof(addr)) != 0) {
        close(sock);
        // Brain 还没起来时这是常态，不打日志刷屏
        [self retryAfterFailure:nil];
        return;
    }

    self.fd = sock;
    self.connected = YES;
    self.retryDelay = kRetryMin;
    dispatch_async(dispatch_get_main_queue(), ^{
        [self.delegate brainClientDidConnect:self];
    });

    NSMutableData *buffer = [NSMutableData data];
    char chunk[16384];
    NSString *reason = @"Brain 关闭了连接";

    while (self.running) {
        ssize_t got = recv(sock, chunk, sizeof(chunk), 0);
        if (got > 0) {
            [buffer appendBytes:chunk length:(NSUInteger)got];
            [self drainLinesFrom:buffer];
            continue;
        }
        if (got == 0) break;
        if (errno == EINTR) continue;
        reason = [NSString stringWithFormat:@"读取失败：%s", strerror(errno)];
        break;
    }

    [self closeSocket];
    dispatch_async(dispatch_get_main_queue(), ^{
        [self.delegate brainClient:self didDisconnectWithReason:reason];
    });
    [self retryAfterFailure:nil];
}

/// 按 \n 切出完整的行，半行留在 buffer 里等下次 recv。
- (void)drainLinesFrom:(NSMutableData *)buffer {
    while (YES) {
        const char *bytes = buffer.bytes;
        NSUInteger length = buffer.length;
        NSUInteger newline = NSNotFound;
        for (NSUInteger i = 0; i < length; i++) {
            if (bytes[i] == '\n') { newline = i; break; }
        }
        if (newline == NSNotFound) return;

        NSData *line = [buffer subdataWithRange:NSMakeRange(0, newline)];
        [buffer replaceBytesInRange:NSMakeRange(0, newline + 1) withBytes:NULL length:0];
        if (line.length == 0) continue;

        NSError *error = nil;
        id parsed = [NSJSONSerialization JSONObjectWithData:line options:0 error:&error];
        if (![parsed isKindOfClass:[NSDictionary class]]) {
            NSLog(@"[jarvis] 无法解析的 Brain 消息：%@", error.localizedDescription);
            continue;
        }
        dispatch_async(dispatch_get_main_queue(), ^{
            [self.delegate brainClient:self didReceiveEvent:parsed];
        });
    }
}

- (void)retryAfterFailure:(NSString *)reason {
    if (reason) NSLog(@"[jarvis] IPC %@", reason);
    if (!self.running) return;
    NSTimeInterval delay = self.retryDelay;
    self.retryDelay = MIN(self.retryDelay * 1.6, kRetryMax);
    [self scheduleConnect:delay];
}

- (void)closeSocket {
    int sock = self.fd;
    self.fd = -1;
    self.connected = NO;
    if (sock >= 0) {
        shutdown(sock, SHUT_RDWR);
        close(sock);
    }
}

#pragma mark - 写

- (void)send:(NSDictionary *)message {
    NSError *error = nil;
    NSData *json = [NSJSONSerialization dataWithJSONObject:message options:0 error:&error];
    if (!json) {
        NSLog(@"[jarvis] 消息无法序列化：%@", error.localizedDescription);
        return;
    }
    NSMutableData *payload = [json mutableCopy];
    [payload appendBytes:"\n" length:1];

    dispatch_async(self.writeQueue, ^{
        int sock = self.fd;
        if (sock < 0) return;
        const uint8_t *bytes = payload.bytes;
        size_t remaining = payload.length;
        while (remaining > 0) {
            ssize_t wrote = send(sock, bytes, remaining, 0);
            if (wrote > 0) { bytes += wrote; remaining -= (size_t)wrote; continue; }
            if (wrote < 0 && errno == EINTR) continue;
            NSLog(@"[jarvis] 发送失败：%s", strerror(errno));
            return;
        }
    });
}

@end
