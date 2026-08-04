#import "NativeToolExecutor.h"

#import "MediaController.h"
#import "WeChatController.h"

#import <AppKit/AppKit.h>
#import <UserNotifications/UserNotifications.h>
#import <EventKit/EventKit.h>
#import <IOKit/ps/IOPowerSources.h>
#import <IOKit/ps/IOPSKeys.h>
#include <mach/mach.h>
#include <unistd.h>

static NSArray<NSString *> *ApplicationSearchPaths(void) {
    return @[@"/Applications",
             @"/Applications/Utilities",
             @"/System/Applications",
             @"/System/Applications/Utilities",
             [@"~/Applications" stringByExpandingTildeInPath]];
}

@interface NativeToolExecutor ()
@property (nonatomic, strong) MediaController *media;
@property (nonatomic, strong) WeChatController *wechat;
@property (nonatomic, strong) EKEventStore *eventStore;
@property (nonatomic) dispatch_queue_t mailQueue;
@end

@implementation NativeToolExecutor

+ (BOOL)handlesToolNamed:(NSString *)name {
    static NSSet *names = nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        names = [NSSet setWithArray:@[@"app_open", @"app_quit", @"app_list_running",
                                      @"url_open", @"finder_reveal",
                                      @"clipboard_read", @"clipboard_write",
                                      @"system_notify", @"system_info",
                                      @"calendar_events",
                                      @"mail_unread",
                                      @"wechat_read",
                                      @"media_control"]];
    });
    return [names containsObject:name];
}

- (MediaController *)media {
    if (!_media) _media = [[MediaController alloc] init];
    return _media;
}

- (WeChatController *)wechat {
    if (!_wechat) _wechat = [[WeChatController alloc] init];
    return _wechat;
}

- (void)execute:(NSString *)name
      arguments:(NSDictionary *)arguments
     completion:(JarvisToolCompletion)completion {

    if ([name isEqualToString:@"app_open"])          { [self openApp:arguments completion:completion]; }
    else if ([name isEqualToString:@"app_quit"])     { [self quitApp:arguments completion:completion]; }
    else if ([name isEqualToString:@"app_list_running"]) { completion([self listRunning], nil); }
    else if ([name isEqualToString:@"url_open"])     { [self openURL:arguments completion:completion]; }
    else if ([name isEqualToString:@"finder_reveal"]){ [self reveal:arguments completion:completion]; }
    else if ([name isEqualToString:@"clipboard_read"])  { completion([self readClipboard], nil); }
    else if ([name isEqualToString:@"clipboard_write"]) { [self writeClipboard:arguments completion:completion]; }
    else if ([name isEqualToString:@"system_notify"])   { [self notify:arguments completion:completion]; }
    else if ([name isEqualToString:@"system_info"])     { completion([self systemInfo], nil); }
    else if ([name isEqualToString:@"calendar_events"]) { [self calendarEvents:arguments completion:completion]; }
    else if ([name isEqualToString:@"mail_unread"])      { [self unreadMail:arguments completion:completion]; }
    else if ([name isEqualToString:@"wechat_read"])      { [self.wechat read:arguments completion:completion]; }
    else if ([name isEqualToString:@"media_control"])   { [self controlMedia:arguments completion:completion]; }
    else { completion(nil, [NSString stringWithFormat:@"宿主不认识工具 %@", name]); }
}

#pragma mark - 邮件（只读元数据）

- (dispatch_queue_t)mailQueue {
    if (!_mailQueue) _mailQueue = dispatch_queue_create("com.jarvis.mail-read", DISPATCH_QUEUE_SERIAL);
    return _mailQueue;
}

- (void)unreadMail:(NSDictionary *)arguments completion:(JarvisToolCompletion)completion {
    NSInteger limit = [arguments[@"limit"] respondsToSelector:@selector(integerValue)]
        ? [arguments[@"limit"] integerValue] : 10;
    limit = MAX(1, MIN(limit, 20));

    // Mail 的 Apple Event 有时要等应用/账户响应，不能堵住 AppKit 主线程。
    // 只取 id、发件人、主题和收件时间；正文、附件与收件人都不读取。
    NSString *source = [NSString stringWithFormat:
        @"tell application \"Mail\"\n"
         "set unreadMessages to (messages of inbox whose read status is false)\n"
         "set resultRows to {}\n"
         "set rowCount to count of unreadMessages\n"
         "if rowCount > %ld then set rowCount to %ld\n"
         "repeat with i from 1 to rowCount\n"
         "set m to item i of unreadMessages\n"
         "set end of resultRows to {(id of m as text), (sender of m as text), "
         "(subject of m as text), (date received of m as text)}\n"
         "end repeat\n"
         "return resultRows\n"
         "end tell", (long)limit, (long)limit];

    dispatch_async(self.mailQueue, ^{
        NSAppleScript *script = [[NSAppleScript alloc] initWithSource:source];
        NSDictionary *errorInfo = nil;
        NSAppleEventDescriptor *answer = [script executeAndReturnError:&errorInfo];
        NSMutableArray *messages = [NSMutableArray array];
        if (!errorInfo && answer.numberOfItems) {
            for (NSInteger i = 1; i <= answer.numberOfItems; i++) {
                NSAppleEventDescriptor *row = [answer descriptorAtIndex:i];
                if (row.numberOfItems < 4) continue;
                NSString *(^clean)(NSString *) = ^NSString *(NSString *value) {
                    value = value ?: @"";
                    NSString *oneLine = [[value stringByReplacingOccurrencesOfString:@"\r" withString:@" "]
                                         stringByReplacingOccurrencesOfString:@"\n" withString:@" "];
                    return oneLine.length > 300 ? [oneLine substringToIndex:300] : oneLine;
                };
                [messages addObject:@{
                    @"id": clean([row descriptorAtIndex:1].stringValue),
                    @"sender": clean([row descriptorAtIndex:2].stringValue),
                    @"subject": clean([row descriptorAtIndex:3].stringValue),
                    @"received": clean([row descriptorAtIndex:4].stringValue)
                }];
            }
        }
        dispatch_async(dispatch_get_main_queue(), ^{
            if (errorInfo) {
                NSString *message = errorInfo[NSAppleScriptErrorMessage] ?: @"Apple Mail 没有响应";
                completion(nil, [NSString stringWithFormat:@"读取未读邮件失败：%@", message]);
            } else {
                completion(@{@"count": @(messages.count), @"messages": messages,
                             @"content_included": @NO}, nil);
            }
        });
    });
}

#pragma mark - 日历

- (EKEventStore *)eventStore {
    if (!_eventStore) _eventStore = [[EKEventStore alloc] init];
    return _eventStore;
}

- (void)calendarEvents:(NSDictionary *)arguments completion:(JarvisToolCompletion)completion {
    NSInteger hours = [arguments[@"hours"] respondsToSelector:@selector(integerValue)]
        ? [arguments[@"hours"] integerValue] : 24;
    NSInteger limit = [arguments[@"limit"] respondsToSelector:@selector(integerValue)]
        ? [arguments[@"limit"] integerValue] : 20;
    hours = MAX(1, MIN(hours, 24 * 14));
    limit = MAX(1, MIN(limit, 50));

    void (^load)(BOOL, NSError *) = ^(BOOL granted, NSError *error) {
        dispatch_async(dispatch_get_main_queue(), ^{
            if (!granted) {
                NSString *reason = error.localizedDescription ?: @"请在系统设置 → 隐私与安全性 → 日历中允许 J.A.R.V.I.S.";
                completion(nil, [NSString stringWithFormat:@"没有日历读取权限：%@", reason]);
                return;
            }
            NSDate *start = [NSDate date];
            NSDate *end = [start dateByAddingTimeInterval:hours * 3600.0];
            NSPredicate *predicate = [self.eventStore predicateForEventsWithStartDate:start
                                                                               endDate:end
                                                                             calendars:nil];
            NSArray<EKEvent *> *found = [self.eventStore eventsMatchingPredicate:predicate];
            NSMutableArray *events = [NSMutableArray array];
            NSISO8601DateFormatter *iso = [[NSISO8601DateFormatter alloc] init];
            for (EKEvent *event in found) {
                if (events.count >= (NSUInteger)limit) break;
                NSMutableDictionary *item = [@{
                    @"title": event.title ?: @"（无标题）",
                    @"start": [iso stringFromDate:event.startDate] ?: @"",
                    @"end": [iso stringFromDate:event.endDate] ?: @"",
                    @"all_day": @(event.isAllDay),
                    @"calendar": event.calendar.title ?: @""
                } mutableCopy];
                if (event.location.length) item[@"location"] = event.location;
                [events addObject:item];
            }
            completion(@{@"from": [iso stringFromDate:start] ?: @"",
                         @"to": [iso stringFromDate:end] ?: @"",
                         @"count": @(events.count), @"events": events}, nil);
        });
    };

    if (@available(macOS 14.0, *)) {
        [self.eventStore requestFullAccessToEventsWithCompletion:load];
    } else {
        [self.eventStore requestAccessToEntityType:EKEntityTypeEvent completion:load];
    }
}

#pragma mark - 播放器

- (void)controlMedia:(NSDictionary *)arguments completion:(JarvisToolCompletion)completion {
    NSString *action = arguments[@"action"];
    if (![action isKindOfClass:[NSString class]] || action.length == 0) {
        completion(nil, @"缺少 action"); return;
    }
    NSString *player = [arguments[@"player"] isKindOfClass:[NSString class]] ? arguments[@"player"] : nil;
    NSString *query = [arguments[@"query"] isKindOfClass:[NSString class]] ? arguments[@"query"] : nil;
    [self.media perform:action player:player query:query completion:completion];
}

#pragma mark - 应用

/// 名字 → .app 的 URL。依次试：bundle id、搜索目录里的精确/前缀匹配、已运行应用的显示名。
- (NSURL *)urlForApplicationNamed:(NSString *)name {
    NSWorkspace *workspace = [NSWorkspace sharedWorkspace];
    NSFileManager *fm = [NSFileManager defaultManager];

    if ([name containsString:@"."] && ![name hasSuffix:@".app"]) {
        NSURL *byID = [workspace URLForApplicationWithBundleIdentifier:name];
        if (byID) return byID;
    }

    NSString *bare = [name hasSuffix:@".app"] ? [name stringByDeletingPathExtension] : name;
    NSString *filename = [bare stringByAppendingPathExtension:@"app"];

    for (NSString *dir in ApplicationSearchPaths()) {
        NSString *exact = [dir stringByAppendingPathComponent:filename];
        if ([fm fileExistsAtPath:exact]) return [NSURL fileURLWithPath:exact];
    }
    // 大小写不敏感 + 前缀匹配，"vs code" 这种口语名交给下面的 open -a 兜底
    for (NSString *dir in ApplicationSearchPaths()) {
        for (NSString *entry in [fm contentsOfDirectoryAtPath:dir error:nil]) {
            if (![entry hasSuffix:@".app"]) continue;
            NSString *entryBare = [entry stringByDeletingPathExtension];
            if ([entryBare caseInsensitiveCompare:bare] == NSOrderedSame) {
                return [NSURL fileURLWithPath:[dir stringByAppendingPathComponent:entry]];
            }
        }
    }
    for (NSRunningApplication *app in [workspace runningApplications]) {
        if ([app.localizedName caseInsensitiveCompare:bare] == NSOrderedSame) return app.bundleURL;
    }
    return nil;
}

- (void)openApp:(NSDictionary *)arguments completion:(JarvisToolCompletion)completion {
    NSString *name = [arguments[@"name"] isKindOfClass:[NSString class]] ? arguments[@"name"] : nil;
    if (name.length == 0) { completion(nil, @"缺少 name"); return; }

    NSURL *url = [self urlForApplicationNamed:name];
    if (!url) {
        // 中文名、本地化名、"VS Code" 这类别名，LaunchServices 认得比我们全
        [self runOpenWithArguments:@[@"-a", name] completion:^(int status, NSString *stderrText) {
            if (status == 0) completion(@{@"opened": name, @"via": @"open -a"}, nil);
            else completion(nil, [NSString stringWithFormat:@"找不到应用「%@」", name]);
        }];
        return;
    }

    NSWorkspaceOpenConfiguration *config = [NSWorkspaceOpenConfiguration configuration];
    config.activates = YES;
    [[NSWorkspace sharedWorkspace] openApplicationAtURL:url configuration:config
                                      completionHandler:^(NSRunningApplication *app, NSError *error) {
        dispatch_async(dispatch_get_main_queue(), ^{
            if (error) { completion(nil, [NSString stringWithFormat:@"打开失败：%@", error.localizedDescription]); }
            else { completion(@{@"opened": app.localizedName ?: name,
                                @"bundle_id": app.bundleIdentifier ?: @"",
                                @"path": url.path}, nil); }
        });
    }];
}

- (void)quitApp:(NSDictionary *)arguments completion:(JarvisToolCompletion)completion {
    NSString *name = arguments[@"name"];
    if (![name isKindOfClass:[NSString class]] || name.length == 0) {
        completion(nil, @"缺少 name"); return;
    }
    NSString *bare = [name hasSuffix:@".app"] ? [name stringByDeletingPathExtension] : name;

    for (NSRunningApplication *app in [[NSWorkspace sharedWorkspace] runningApplications]) {
        if (app.activationPolicy != NSApplicationActivationPolicyRegular) continue;
        if ([app.localizedName caseInsensitiveCompare:bare] != NSOrderedSame &&
            ![app.bundleIdentifier isEqualToString:name]) continue;
        if ([app.bundleIdentifier isEqualToString:[[NSBundle mainBundle] bundleIdentifier]]) {
            completion(nil, @"不能让我退出我自己"); return;
        }
        // terminate 而非 forceTerminate：有未保存内容时让应用自己弹保存对话框
        BOOL ok = [app terminate];
        completion(@{@"quit": app.localizedName ?: bare, @"accepted": @(ok)}, nil);
        return;
    }
    completion(nil, [NSString stringWithFormat:@"「%@」没有在运行", bare]);
}

- (NSDictionary *)listRunning {
    NSMutableArray *apps = [NSMutableArray array];
    NSRunningApplication *front = [[NSWorkspace sharedWorkspace] frontmostApplication];
    for (NSRunningApplication *app in [[NSWorkspace sharedWorkspace] runningApplications]) {
        if (app.activationPolicy != NSApplicationActivationPolicyRegular) continue;
        [apps addObject:@{@"name": app.localizedName ?: @"",
                          @"bundle_id": app.bundleIdentifier ?: @"",
                          @"frontmost": @([app isEqual:front])}];
    }
    [apps sortUsingDescriptors:@[[NSSortDescriptor sortDescriptorWithKey:@"name" ascending:YES]]];
    return @{@"count": @(apps.count), @"apps": apps};
}

/// LaunchServices 的名字解析比我们自己扫目录全，找不到时用它兜底。
- (void)runOpenWithArguments:(NSArray<NSString *> *)arguments
                  completion:(void (^)(int status, NSString *stderrText))completion {
    NSTask *task = [[NSTask alloc] init];
    task.executableURL = [NSURL fileURLWithPath:@"/usr/bin/open"];
    task.arguments = arguments;
    NSPipe *pipe = [NSPipe pipe];
    task.standardError = pipe;
    task.standardOutput = [NSPipe pipe];

    task.terminationHandler = ^(NSTask *finished) {
        NSData *data = [pipe.fileHandleForReading readDataToEndOfFile];
        NSString *text = [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding];
        dispatch_async(dispatch_get_main_queue(), ^{
            completion(finished.terminationStatus, text ?: @"");
        });
    };

    NSError *error = nil;
    if (![task launchAndReturnError:&error]) {
        completion(-1, error.localizedDescription);
    }
}

#pragma mark - URL / 访达

- (void)openURL:(NSDictionary *)arguments completion:(JarvisToolCompletion)completion {
    NSString *raw = arguments[@"url"];
    if (![raw isKindOfClass:[NSString class]] || raw.length == 0) { completion(nil, @"缺少 url"); return; }
    if (![raw containsString:@"://"]) raw = [@"https://" stringByAppendingString:raw];

    NSURL *url = [NSURL URLWithString:raw];
    if (!url) {   // 中文或空格没编码
        url = [NSURL URLWithString:[raw stringByAddingPercentEncodingWithAllowedCharacters:
                                    [NSCharacterSet URLQueryAllowedCharacterSet]]];
    }
    if (!url.scheme) { completion(nil, [NSString stringWithFormat:@"无法解析的地址：%@", raw]); return; }
    if (!([url.scheme isEqualToString:@"http"] || [url.scheme isEqualToString:@"https"])) {
        completion(nil, [NSString stringWithFormat:@"只允许 http/https，收到 %@", url.scheme]); return;
    }

    BOOL ok = [[NSWorkspace sharedWorkspace] openURL:url];
    if (ok) completion(@{@"opened": url.absoluteString}, nil);
    else completion(nil, [NSString stringWithFormat:@"打开失败：%@", url.absoluteString]);
}

- (void)reveal:(NSDictionary *)arguments completion:(JarvisToolCompletion)completion {
    NSString *raw = arguments[@"path"];
    if (![raw isKindOfClass:[NSString class]] || raw.length == 0) { completion(nil, @"缺少 path"); return; }

    NSString *path = [[raw stringByExpandingTildeInPath] stringByStandardizingPath];
    if (![[NSFileManager defaultManager] fileExistsAtPath:path]) {
        completion(nil, [NSString stringWithFormat:@"路径不存在：%@", raw]); return;
    }
    [[NSWorkspace sharedWorkspace] selectFile:path inFileViewerRootedAtPath:@""];
    completion(@{@"revealed": path}, nil);
}

#pragma mark - 剪贴板

- (NSDictionary *)readClipboard {
    NSString *text = [[NSPasteboard generalPasteboard] stringForType:NSPasteboardTypeString];
    if (text.length == 0) return @{@"empty": @YES, @"text": @""};
    NSString *clipped = text.length > 8000 ? [text substringToIndex:8000] : text;
    return @{@"text": clipped, @"length": @(text.length), @"truncated": @(text.length > 8000)};
}

- (void)writeClipboard:(NSDictionary *)arguments completion:(JarvisToolCompletion)completion {
    NSString *text = arguments[@"text"];
    if (![text isKindOfClass:[NSString class]]) { completion(nil, @"缺少 text"); return; }
    NSPasteboard *board = [NSPasteboard generalPasteboard];
    [board clearContents];
    [board setString:text forType:NSPasteboardTypeString];
    completion(@{@"written": @(text.length)}, nil);
}

#pragma mark - 通知

- (void)notify:(NSDictionary *)arguments completion:(JarvisToolCompletion)completion {
    NSString *title = arguments[@"title"];
    NSString *body = arguments[@"body"] ?: @"";
    if (![title isKindOfClass:[NSString class]] || title.length == 0) { completion(nil, @"缺少 title"); return; }
    if (![body isKindOfClass:[NSString class]]) body = @"";

    UNUserNotificationCenter *center = [UNUserNotificationCenter currentNotificationCenter];
    [center requestAuthorizationWithOptions:UNAuthorizationOptionAlert | UNAuthorizationOptionSound
                          completionHandler:^(BOOL granted, NSError *error) {
        dispatch_async(dispatch_get_main_queue(), ^{
            if (!granted) {
                // ad-hoc 签名的 App 有时拿不到通知权限，退回 osascript
                [self notifyViaAppleScriptTitle:title body:body completion:completion];
                return;
            }
            UNMutableNotificationContent *content = [[UNMutableNotificationContent alloc] init];
            content.title = title;
            content.body = body;
            content.sound = [UNNotificationSound defaultSound];
            UNNotificationRequest *request =
                [UNNotificationRequest requestWithIdentifier:[[NSUUID UUID] UUIDString]
                                                     content:content trigger:nil];
            [center addNotificationRequest:request withCompletionHandler:^(NSError *addError) {
                dispatch_async(dispatch_get_main_queue(), ^{
                    if (addError) [self notifyViaAppleScriptTitle:title body:body completion:completion];
                    else completion(@{@"notified": title}, nil);
                });
            }];
        });
    }];
}

- (void)notifyViaAppleScriptTitle:(NSString *)title body:(NSString *)body
                       completion:(JarvisToolCompletion)completion {
    NSString *script = [NSString stringWithFormat:
        @"display notification %@ with title %@", [self asQuote:body], [self asQuote:title]];
    NSAppleScript *apple = [[NSAppleScript alloc] initWithSource:script];
    NSDictionary *error = nil;
    [apple executeAndReturnError:&error];
    if (error) completion(nil, [NSString stringWithFormat:@"通知发送失败：%@", error[NSAppleScriptErrorMessage]]);
    else completion(@{@"notified": title, @"via": @"applescript"}, nil);
}

- (NSString *)asQuote:(NSString *)text {
    NSString *escaped = [[text stringByReplacingOccurrencesOfString:@"\\" withString:@"\\\\"]
                         stringByReplacingOccurrencesOfString:@"\"" withString:@"\\\""];
    return [NSString stringWithFormat:@"\"%@\"", escaped];
}

#pragma mark - 系统状态

- (NSDictionary *)systemInfo {
    NSMutableDictionary *info = [NSMutableDictionary dictionary];

    NSDateFormatter *formatter = [[NSDateFormatter alloc] init];
    formatter.dateFormat = @"yyyy-MM-dd HH:mm:ss EEEE";
    info[@"time"] = [formatter stringFromDate:[NSDate date]];
    info[@"macos"] = [[NSProcessInfo processInfo] operatingSystemVersionString];
    info[@"hostname"] = [[NSProcessInfo processInfo] hostName];

    NSRunningApplication *front = [[NSWorkspace sharedWorkspace] frontmostApplication];
    if (front) {
        info[@"frontmost_app"] = front.localizedName ?: @"";
        info[@"frontmost_bundle_id"] = front.bundleIdentifier ?: @"";
    }

    // 面板一获得键盘焦点，frontmostApplication 就会变成 Jarvis 自己。再看一眼
    // 窗口层级中 Jarvis 后面的第一个普通应用，才能知道用户唤出面板前在做什么。
    CFArrayRef windowBlob = CGWindowListCopyWindowInfo(
        kCGWindowListOptionOnScreenOnly | kCGWindowListExcludeDesktopElements,
        kCGNullWindowID);
    for (NSDictionary *window in (__bridge NSArray *)windowBlob) {
        pid_t pid = [window[(id)kCGWindowOwnerPID] intValue];
        NSInteger layer = [window[(id)kCGWindowLayer] integerValue];
        if (pid == getpid() || layer != 0) continue;
        NSRunningApplication *behind = [NSRunningApplication runningApplicationWithProcessIdentifier:pid];
        if (!behind || behind.activationPolicy != NSApplicationActivationPolicyRegular) continue;
        info[@"previous_app"] = behind.localizedName ?: @"";
        info[@"previous_bundle_id"] = behind.bundleIdentifier ?: @"";
        break;
    }
    if (windowBlob) CFRelease(windowBlob);

    NSMutableArray *displays = [NSMutableArray array];
    for (NSScreen *screen in [NSScreen screens]) {
        NSRect frame = screen.frame;
        [displays addObject:@{@"width": @((NSInteger)frame.size.width),
                              @"height": @((NSInteger)frame.size.height),
                              @"scale": @(screen.backingScaleFactor),
                              @"main": @(screen == [NSScreen mainScreen])}];
    }
    info[@"displays"] = displays;

    info[@"battery"] = [self batteryInfo];
    info[@"memory"] = [self memoryInfo];

    NSDictionary *fsAttrs = [[NSFileManager defaultManager]
                             attributesOfFileSystemForPath:NSHomeDirectory() error:nil];
    if (fsAttrs) {
        double freeGB = [fsAttrs[NSFileSystemFreeSize] doubleValue] / 1e9;
        double totalGB = [fsAttrs[NSFileSystemSize] doubleValue] / 1e9;
        info[@"disk"] = [NSString stringWithFormat:@"剩余 %.0f GB / 共 %.0f GB", freeGB, totalGB];
    }
    return info;
}

- (NSString *)batteryInfo {
    CFTypeRef blob = IOPSCopyPowerSourcesInfo();
    if (!blob) return @"未知";
    CFArrayRef sources = IOPSCopyPowerSourcesList(blob);
    if (!sources) { CFRelease(blob); return @"未知"; }

    NSString *result = @"外接电源";
    for (CFIndex i = 0; i < CFArrayGetCount(sources); i++) {
        CFDictionaryRef description = IOPSGetPowerSourceDescription(blob, CFArrayGetValueAtIndex(sources, i));
        if (!description) continue;
        NSDictionary *source = (__bridge NSDictionary *)description;
        NSNumber *current = source[@kIOPSCurrentCapacityKey];
        NSNumber *max = source[@kIOPSMaxCapacityKey];
        NSString *state = source[@kIOPSPowerSourceStateKey];
        if (current && max.intValue > 0) {
            int percent = (int)lround(current.doubleValue / max.doubleValue * 100.0);
            BOOL onBattery = [state isEqualToString:@kIOPSBatteryPowerValue];
            result = [NSString stringWithFormat:@"%d%%（%@）", percent, onBattery ? @"电池供电" : @"充电中"];
        }
        break;
    }
    CFRelease(sources);
    CFRelease(blob);
    return result;
}

- (NSString *)memoryInfo {
    vm_size_t pageSize = 0;
    host_page_size(mach_host_self(), &pageSize);

    vm_statistics64_data_t stats;
    mach_msg_type_number_t count = HOST_VM_INFO64_COUNT;
    if (host_statistics64(mach_host_self(), HOST_VM_INFO64, (host_info64_t)&stats, &count) != KERN_SUCCESS) {
        return @"未知";
    }

    double totalGB = (double)[[NSProcessInfo processInfo] physicalMemory] / 1e9;
    // "已用"取 App 内存 + 联动内存 + 压缩后占用，跟活动监视器口径接近
    double usedGB = (double)((uint64_t)(stats.internal_page_count - stats.purgeable_count
                                        + stats.wire_count + stats.compressor_page_count)
                             * pageSize) / 1e9;
    double swapGB = (double)stats.swapouts * pageSize / 1e9;
    return [NSString stringWithFormat:@"已用 %.1f / %.0f GB，压缩 %.1f GB，累计换出 %.1f GB",
            usedGB, totalGB,
            (double)((uint64_t)stats.compressor_page_count * pageSize) / 1e9, swapGB];
}

@end
