#import "MediaController.h"

#import <AppKit/AppKit.h>
#import <IOKit/hidsystem/ev_keymap.h>
#include <dlfcn.h>

#pragma mark - MediaRemote（私有框架，全部走 dlsym，拿不到就整条通道降级）

// 命令码。只用这几个，其余的没实测过就不写进来。
enum {
    MRCommandPlay     = 0,
    MRCommandPause    = 1,
    MRCommandToggle   = 2,
    MRCommandNext     = 4,
    MRCommandPrevious = 5,
};

typedef Boolean (*MRSendCommandFn)(int command, CFDictionaryRef _Nullable options);
typedef void (*MRGetInfoFn)(dispatch_queue_t queue, void (^handler)(CFDictionaryRef info));
typedef void (*MRGetIsPlayingFn)(dispatch_queue_t queue, void (^handler)(Boolean playing));
typedef void (*MRGetPIDFn)(dispatch_queue_t queue, void (^handler)(int pid));

static MRSendCommandFn   MRSendCommand   = NULL;
static MRGetInfoFn       MRGetInfo       = NULL;
static MRGetIsPlayingFn  MRGetIsPlaying  = NULL;
static MRGetPIDFn        MRGetPID        = NULL;

static void LoadMediaRemote(void) {
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        void *handle = dlopen("/System/Library/PrivateFrameworks/MediaRemote.framework/MediaRemote",
                              RTLD_LAZY);
        if (!handle) return;
        MRSendCommand  = (MRSendCommandFn)dlsym(handle, "MRMediaRemoteSendCommand");
        MRGetInfo      = (MRGetInfoFn)dlsym(handle, "MRMediaRemoteGetNowPlayingInfo");
        MRGetIsPlaying = (MRGetIsPlayingFn)dlsym(handle, "MRMediaRemoteGetNowPlayingApplicationIsPlaying");
        MRGetPID       = (MRGetPIDFn)dlsym(handle, "MRMediaRemoteGetNowPlayingApplicationPID");
    });
}

#pragma mark - 播放器名录

static NSString *const kNetEaseBundleID = @"com.netease.163music";

/// 口语名 → bundle id。auto 不在表里，单独处理。
static NSDictionary<NSString *, NSString *> *PlayerAliases(void) {
    static NSDictionary *table = nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        table = @{@"netease": kNetEaseBundleID,
                  @"neteasemusic": kNetEaseBundleID,
                  @"网易云": kNetEaseBundleID,
                  @"网易云音乐": kNetEaseBundleID,
                  @"网易": kNetEaseBundleID,
                  @"163": kNetEaseBundleID,
                  @"music": @"com.apple.Music",
                  @"apple music": @"com.apple.Music",
                  @"音乐": @"com.apple.Music",
                  @"spotify": @"com.spotify.client",
                  @"qq": @"com.tencent.QQMusicMac",
                  @"qqmusic": @"com.tencent.QQMusicMac",
                  @"qq音乐": @"com.tencent.QQMusicMac"};
    });
    return table;
}

static NSRunningApplication *RunningAppWithBundleID(NSString *bundleID) {
    NSArray *apps = [NSRunningApplication runningApplicationsWithBundleIdentifier:bundleID];
    return apps.firstObject;
}

#pragma mark -

@implementation MediaController

- (void)perform:(NSString *)action
         player:(NSString *)player
     completion:(JarvisMediaCompletion)completion {

    LoadMediaRemote();
    action = [(action ?: @"") lowercaseString];

    if ([action isEqualToString:@"status"]) {
        [self fetchStatus:^(NSDictionary *status) { completion(status, nil); }];
        return;
    }

    BOOL explicitTarget = NO;
    NSString *targetBundleID = [self resolveTarget:player explicit:&explicitTarget];

    // 点名了某个播放器却没开：不能默默去控别人，说清楚是哪个没开
    if (explicitTarget && !RunningAppWithBundleID(targetBundleID)) {
        BOOL wantsToStart = ([action isEqualToString:@"play"] || [action isEqualToString:@"toggle"]);
        if ([targetBundleID isEqualToString:kNetEaseBundleID] && wantsToStart) {
            [self launchNetEaseThen:action completion:completion];
        } else {
            completion(nil, [NSString stringWithFormat:@"「%@」没有在运行",
                             [self displayNameForBundleID:targetBundleID]]);
        }
        return;
    }

    if (!targetBundleID) {
        // 没指定、也没有已知播放器在跑：看系统总线在谁手上（浏览器里的视频也算）
        targetBundleID = [self nowPlayingOwnerBundleIDWaitingUpTo:1.5];
    }
    if (!targetBundleID) {
        // 真的什么都没在放。要"开始播放"就替用户把播放器拉起来，其余动作直说没得控。
        if ([action isEqualToString:@"play"] || [action isEqualToString:@"toggle"]) {
            [self launchNetEaseThen:action completion:completion];
        } else if ([action isEqualToString:@"volume_up"] || [action isEqualToString:@"volume_down"]) {
            [self changeSystemVolumeBy:[action isEqualToString:@"volume_up"] ? 8 : -8
                            completion:completion];
        } else {
            completion(nil, @"现在没有播放器在放东西");
        }
        return;
    }

    if ([targetBundleID isEqualToString:kNetEaseBundleID]) {
        [self controlNetEase:action completion:completion];
        return;
    }
    [self controlViaSystemBus:action player:targetBundleID completion:completion];
}

/// 返回目标 bundle id；nil 表示"谁占着系统播放总线就控制谁"。
/// outExplicit 为 YES 表示这是用户点名的播放器，此时它没开就该报错而不是改控别人。
- (NSString *)resolveTarget:(NSString *)player explicit:(BOOL *)outExplicit {
    *outExplicit = NO;

    NSString *key = [[(player ?: @"") lowercaseString]
                     stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]];
    if (key.length == 0 || [key isEqualToString:@"auto"] || [key isEqualToString:@"system"]) {
        // auto：优先本机开着的已知播放器，都没开就走总线（浏览器里的视频也能接住）
        if ([key isEqualToString:@"system"]) return nil;
        for (NSString *bundleID in @[kNetEaseBundleID, @"com.tencent.QQMusicMac",
                                     @"com.spotify.client", @"com.apple.Music"]) {
            if (RunningAppWithBundleID(bundleID)) return bundleID;
        }
        return nil;
    }

    NSString *mapped = PlayerAliases()[key];
    if (!mapped) {
        // 没匹配上时按包含关系再试一轮，"网易云音乐 app" 这种说法也能落地
        for (NSString *alias in PlayerAliases()) {
            if ([key containsString:alias]) { mapped = PlayerAliases()[alias]; break; }
        }
    }
    if (mapped) *outExplicit = YES;
    return mapped;
}

#pragma mark - 网易云音乐

/// 「控制」菜单里的项。网易云是中文界面，但英文版和将来改名都兜一手。
static NSInteger MenuIndexForAction(NSArray<NSString *> *names, NSString *action) {
    NSDictionary *keywords = @{@"toggle":       @[@"播放", @"暂停", @"Play", @"Pause"],
                               @"play":         @[@"播放", @"暂停", @"Play", @"Pause"],
                               @"pause":        @[@"播放", @"暂停", @"Play", @"Pause"],
                               @"next":         @[@"下一", @"Next"],
                               @"previous":     @[@"上一", @"Previous"],
                               @"volume_up":    @[@"升高", @"调高", @"Increase", @"Up"],
                               @"volume_down":  @[@"降低", @"调低", @"Decrease", @"Down"],
                               @"like":         @[@"喜欢", @"Like", @"Love"]};
    NSDictionary *fallback = @{@"toggle": @1, @"play": @1, @"pause": @1, @"next": @2,
                               @"previous": @3, @"volume_up": @4, @"volume_down": @5, @"like": @6};

    NSArray *wanted = keywords[action];
    if (!wanted) return 0;
    for (NSUInteger i = 0; i < names.count; i++) {
        for (NSString *keyword in wanted) {
            if ([names[i] containsString:keyword]) return (NSInteger)i + 1;   // AppleScript 从 1 数
        }
    }
    NSNumber *index = fallback[action];
    return (index && index.integerValue <= (NSInteger)names.count) ? index.integerValue : 0;
}

- (void)controlNetEase:(NSString *)action completion:(JarvisMediaCompletion)completion {
    [self controlNetEase:action forceMenu:NO completion:completion];
}

- (void)controlNetEase:(NSString *)action
             forceMenu:(BOOL)forceMenu
            completion:(JarvisMediaCompletion)completion {
    NSArray<NSString *> *items = nil;
    NSString *error = [self netEaseControlMenuItems:&items];
    if (error) { completion(nil, error); return; }

    NSInteger index = MenuIndexForAction(items, action);
    if (index == 0) {
        completion(nil, [NSString stringWithFormat:@"网易云音乐不支持「%@」这个操作", action]);
        return;
    }

    // 菜单第一项的名字就是状态：写着"播放"说明当前停着，写着"暂停"说明正在放。
    BOOL playing = ([items.firstObject containsString:@"暂停"] ||
                    [items.firstObject containsString:@"Pause"]);
    if (([action isEqualToString:@"play"] && playing) ||
        ([action isEqualToString:@"pause"] && !playing)) {
        completion(@{@"player": @"网易云音乐", @"action": action,
                     @"playing": @(playing), @"changed": @NO}, nil);
        return;
    }

    BOOL flipsPlayback = ([action isEqualToString:@"toggle"] ||
                          [action isEqualToString:@"play"] ||
                          [action isEqualToString:@"pause"]);

    // 总线在网易云手上时优先走 MediaRemote：不碰菜单就不会有菜单闪动。
    // 抢不到总线（浏览器在放视频）时才点菜单——那条路一定打得中。
    BOOL viaBus = NO;
    if (!forceMenu && (flipsPlayback || [action isEqualToString:@"next"] ||
                       [action isEqualToString:@"previous"])) {
        viaBus = [self sendBusCommandForAction:action ifOwnedBy:kNetEaseBundleID];
    }

    // MRMediaRemoteSendCommand 返回的是"命令送出去了"，不是"播放器照做了"。
    // 冷启动后的头几秒它就会返回真但什么也没发生，所以播放状态必须回读校验。
    if (viaBus && flipsPlayback && ![self netEaseBecomesPlaying:!playing within:1.5]) {
        viaBus = NO;
    }

    if (!viaBus) {
        NSString *clickError = [self clickNetEaseControlItemAtIndex:index];
        if (clickError) { completion(nil, clickError); return; }
    }

    NSMutableDictionary *result = [@{@"player": @"网易云音乐",
                                     @"action": action,
                                     @"via": viaBus ? @"MediaRemote" : @"菜单",
                                     @"changed": @YES} mutableCopy];
    if (flipsPlayback) {
        result[@"playing"] = @(viaBus ? !playing : [self netEaseBecomesPlaying:!playing within:1.5]);
    }
    completion(result, nil);
}

/// 轮询「控制」菜单等状态翻过去。用 runloop 空转而不是 sleep——
/// 这里跑在主线程上，睡死会把球体和面板一起冻住。
- (BOOL)netEaseBecomesPlaying:(BOOL)wanted within:(NSTimeInterval)timeout {
    NSDate *deadline = [NSDate dateWithTimeIntervalSinceNow:timeout];
    while (YES) {
        NSArray *items = nil;
        if ([self netEaseControlMenuItems:&items] == nil && items.count > 0) {
            NSString *first = items.firstObject;
            BOOL playing = ([first containsString:@"暂停"] || [first containsString:@"Pause"]);
            if (playing == wanted) return YES;
        }
        if ([deadline timeIntervalSinceNow] <= 0) return NO;
        CFRunLoopRunInMode(kCFRunLoopDefaultMode, 0.25, false);
    }
}

/// 读「控制」菜单的所有项名。顺带承担"网易云在不在、辅助功能权限有没有"的探测。
- (NSString *)netEaseControlMenuItems:(NSArray<NSString *> **)outItems {
    NSString *source =
        @"tell application \"System Events\"\n"
        @"  if not (exists process \"NeteaseMusic\") then return \"ERR:网易云音乐没有在运行\"\n"
        @"  tell process \"NeteaseMusic\"\n"
        @"    repeat with mb in menu bar items of menu bar 1\n"
        @"      if name of mb is in {\"控制\", \"Controls\", \"Control\"} then\n"
        @"        return name of every menu item of menu 1 of mb\n"
        @"      end if\n"
        @"    end repeat\n"
        @"  end tell\n"
        @"end tell\n"
        @"return \"ERR:网易云音乐里找不到「控制」菜单\"";

    NSString *error = nil;
    NSAppleEventDescriptor *result = [self runAppleScript:source error:&error];
    if (error) return error;

    // 单个字符串 = 我们自己 return 的错误；列表 = 菜单项
    if (result.descriptorType != typeAEList) {
        NSString *text = result.stringValue ?: @"";
        if ([text hasPrefix:@"ERR:"]) return [text substringFromIndex:4];
        return @"读取网易云音乐菜单失败";
    }

    NSMutableArray *items = [NSMutableArray array];
    for (NSInteger i = 1; i <= result.numberOfItems; i++) {
        NSString *name = [result descriptorAtIndex:i].stringValue;
        [items addObject:name ?: @""];
    }
    if (items.count == 0) return @"网易云音乐的「控制」菜单是空的";
    *outItems = items;
    return nil;
}

- (NSString *)clickNetEaseControlItemAtIndex:(NSInteger)index {
    NSString *source = [NSString stringWithFormat:
        @"tell application \"System Events\"\n"
        @"  tell process \"NeteaseMusic\"\n"
        @"    repeat with mb in menu bar items of menu bar 1\n"
        @"      if name of mb is in {\"控制\", \"Controls\", \"Control\"} then\n"
        @"        click menu item %ld of menu 1 of mb\n"
        @"        return \"OK\"\n"
        @"      end if\n"
        @"    end repeat\n"
        @"  end tell\n"
        @"end tell\n"
        @"return \"ERR:找不到「控制」菜单\"", (long)index];

    NSString *error = nil;
    NSAppleEventDescriptor *result = [self runAppleScript:source error:&error];
    if (error) return error;
    NSString *text = result.stringValue ?: @"";
    return [text hasPrefix:@"ERR:"] ? [text substringFromIndex:4] : nil;
}

/// 冷启动后播放器要几秒才接上系统总线，太早发命令会石沉大海。
- (void)launchNetEaseThen:(NSString *)action completion:(JarvisMediaCompletion)completion {
    NSURL *url = [[NSWorkspace sharedWorkspace] URLForApplicationWithBundleIdentifier:kNetEaseBundleID];
    if (!url) { completion(nil, @"本机没装网易云音乐"); return; }

    NSWorkspaceOpenConfiguration *config = [NSWorkspaceOpenConfiguration configuration];
    config.activates = NO;
    [[NSWorkspace sharedWorkspace] openApplicationAtURL:url configuration:config
                                      completionHandler:^(NSRunningApplication *app, NSError *error) {
        if (error) {
            dispatch_async(dispatch_get_main_queue(), ^{
                completion(nil, [NSString stringWithFormat:@"启动网易云音乐失败：%@",
                                 error.localizedDescription]);
            });
            return;
        }
        dispatch_async(dispatch_get_main_queue(), ^{ [self playNetEaseAfterLaunch:completion]; });
    }];
}

/// 冷启动后点"播放"会空点：菜单早就在了、菜单项也报 enabled，但播放内核还没接上，
/// 点了没反应也没有任何错误。唯一可靠的做法是点完回读，没生效就再点一次。
/// MediaRemote 在这个阶段更不能用——它连命令送达都会报成功。
- (void)playNetEaseAfterLaunch:(JarvisMediaCompletion)completion {
    NSString *lastError = nil;
    for (int attempt = 0; attempt < 5; attempt++) {
        NSArray<NSString *> *items = nil;
        lastError = [self netEaseControlMenuItems:&items];
        if (lastError == nil && items.count > 0) {
            NSString *first = items.firstObject;
            BOOL playing = ([first containsString:@"暂停"] || [first containsString:@"Pause"]);
            if (!playing) {
                NSInteger index = MenuIndexForAction(items, @"play");
                if (index > 0) [self clickNetEaseControlItemAtIndex:index];
                playing = [self netEaseBecomesPlaying:YES within:2.0];
            }
            if (playing) {
                completion(@{@"player": @"网易云音乐", @"action": @"play", @"via": @"菜单",
                             @"launched": @YES, @"playing": @YES, @"changed": @YES}, nil);
                return;
            }
        }
        CFRunLoopRunInMode(kCFRunLoopDefaultMode, 1.0, false);
    }
    // 一直读不到菜单多半是权限问题，把最后那条错误如实带出去，别报成"播放列表空的"
    if (lastError) { completion(nil, lastError); return; }
    completion(@{@"player": @"网易云音乐", @"launched": @YES, @"playing": @NO, @"changed": @NO,
                 @"note": @"网易云音乐已经打开了，但它没有开始播放——"
                          @"多半是播放列表是空的，需要先在界面里选一首歌"}, nil);
}

#pragma mark - 系统播放总线（Apple Music / Spotify / QQ 音乐 / 浏览器都走这条）

- (void)controlViaSystemBus:(NSString *)action
                     player:(NSString *)bundleID
                 completion:(JarvisMediaCompletion)completion {

    if ([action isEqualToString:@"volume_up"] || [action isEqualToString:@"volume_down"]) {
        [self changeSystemVolumeBy:[action isEqualToString:@"volume_up"] ? 8 : -8
                        completion:completion];
        return;
    }
    if ([action isEqualToString:@"like"]) {
        completion(nil, @"只有网易云音乐支持「喜欢」这个操作");
        return;
    }

    if ([self sendBusCommandForAction:action ifOwnedBy:bundleID]) {
        completion(@{@"action": action, @"via": @"MediaRemote",
                     @"player": [self displayNameForBundleID:bundleID] ?: @"当前播放器"}, nil);
        return;
    }

    // 总线拒了（没人在播、或者目标不是总线持有者）：退媒体键，谁接住算谁的
    if ([self postMediaKeyForAction:action]) {
        completion(@{@"action": action, @"via": @"媒体键"}, nil);
        return;
    }
    completion(nil, [NSString stringWithFormat:@"没有播放器响应「%@」", action]);
}

/// bundleID 为 nil 表示不挑；非 nil 时只有它正持有总线才发命令，避免打错人。
- (BOOL)sendBusCommandForAction:(NSString *)action ifOwnedBy:(NSString *)bundleID {
    LoadMediaRemote();
    if (!MRSendCommand) return NO;

    if (bundleID) {
        NSString *owner = [self nowPlayingOwnerBundleIDWaitingUpTo:1.0];
        if (![owner isEqualToString:bundleID]) return NO;
    }

    NSDictionary *commands = @{@"play": @(MRCommandPlay), @"pause": @(MRCommandPause),
                               @"toggle": @(MRCommandToggle), @"next": @(MRCommandNext),
                               @"previous": @(MRCommandPrevious)};
    NSNumber *command = commands[action];
    if (!command) return NO;
    return MRSendCommand(command.intValue, NULL) ? YES : NO;
}

- (BOOL)postMediaKeyForAction:(NSString *)action {
    NSDictionary *keys = @{@"play": @(NX_KEYTYPE_PLAY), @"pause": @(NX_KEYTYPE_PLAY),
                           @"toggle": @(NX_KEYTYPE_PLAY), @"next": @(NX_KEYTYPE_FAST),
                           @"previous": @(NX_KEYTYPE_REWIND)};
    NSNumber *key = keys[action];
    if (!key) return NO;
    if (!AXIsProcessTrusted()) return NO;      // 没辅助功能权限，发了也是空放

    for (int down = 1; down >= 0; down--) {
        NSEvent *event = [NSEvent otherEventWithType:NSEventTypeSystemDefined
                                            location:NSZeroPoint
                                       modifierFlags:(down ? 0xa00 : 0xb00)
                                           timestamp:0
                                        windowNumber:0
                                             context:nil
                                             subtype:8      // NX_SUBTYPE_AUX_CONTROL_BUTTONS
                                               data1:((key.intValue << 16) | ((down ? 0xa : 0xb) << 8))
                                               data2:-1];
        CGEventRef cgEvent = [event CGEvent];
        if (cgEvent) CGEventPost(kCGHIDEventTap, cgEvent);
    }
    return YES;
}

- (void)changeSystemVolumeBy:(int)delta completion:(JarvisMediaCompletion)completion {
    NSString *source = [NSString stringWithFormat:
        @"set current to output volume of (get volume settings)\n"
        @"set target to current + (%d)\n"
        @"if target > 100 then set target to 100\n"
        @"if target < 0 then set target to 0\n"
        @"set volume output volume target\n"
        @"return target", delta];
    NSString *error = nil;
    NSAppleEventDescriptor *result = [self runAppleScript:source error:&error];
    if (error) { completion(nil, error); return; }
    completion(@{@"system_volume": @(result.int32Value), @"changed": @YES}, nil);
}

#pragma mark - 状态

- (void)fetchStatus:(void (^)(NSDictionary *status))done {
    LoadMediaRemote();

    NSMutableDictionary *status = [NSMutableDictionary dictionary];
    NSString *owner = [self nowPlayingOwnerBundleIDWaitingUpTo:1.5];
    if (owner) {
        status[@"bundle_id"] = owner;
        status[@"player"] = [self displayNameForBundleID:owner] ?: owner;
    }

    // 网易云的菜单比总线的 playbackRate 准：实测暂停后 rate 仍报 1
    NSArray *items = nil;
    if ([owner isEqualToString:kNetEaseBundleID] || RunningAppWithBundleID(kNetEaseBundleID)) {
        if ([self netEaseControlMenuItems:&items] == nil && items.count > 0) {
            NSString *first = items.firstObject;
            status[@"playing"] = @([first containsString:@"暂停"] || [first containsString:@"Pause"]);
            status[@"liked"] = @([items containsObject:@"取消喜欢"]);
            if (!status[@"player"]) status[@"player"] = @"网易云音乐";
        }
    }

    if (!MRGetInfo) {
        // playing=false 单独一条不算信息量：没有曲目也没有播放器时要明说
        if (!status[@"title"] && !status[@"bundle_id"]) {
            status[@"note"] = @"当前没有播放器在放东西";
        }
        done(status);
        return;
    }

    __block BOOL finished = NO;
    void (^finish)(void) = ^{
        if (finished) return;
        finished = YES;
        // playing=false 单独一条不算信息量：没有曲目也没有播放器时要明说
        if (!status[@"title"] && !status[@"bundle_id"]) {
            status[@"note"] = @"当前没有播放器在放东西";
        }
        done(status);
    };

    MRGetInfo(dispatch_get_main_queue(), ^(CFDictionaryRef raw) {
        NSDictionary *info = (__bridge NSDictionary *)raw;
        NSString *title = info[@"kMRMediaRemoteNowPlayingInfoTitle"];
        NSString *artist = info[@"kMRMediaRemoteNowPlayingInfoArtist"];
        NSString *album = info[@"kMRMediaRemoteNowPlayingInfoAlbum"];
        NSNumber *elapsed = info[@"kMRMediaRemoteNowPlayingInfoElapsedTime"];
        NSNumber *duration = info[@"kMRMediaRemoteNowPlayingInfoDuration"];
        if (title) status[@"title"] = title;
        if (artist) status[@"artist"] = artist;
        if (album) status[@"album"] = album;
        if (elapsed) status[@"elapsed_seconds"] = @(llround(elapsed.doubleValue));
        if (duration) status[@"duration_seconds"] = @(llround(duration.doubleValue));

        if (status[@"playing"] || !MRGetIsPlaying) { finish(); return; }
        MRGetIsPlaying(dispatch_get_main_queue(), ^(Boolean playing) {
            status[@"playing"] = @(playing ? YES : NO);
            finish();
        });
    });

    // 私有框架不回调就是不回调，不能让工具卡到 Brain 超时
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(2.5 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{ finish(); });
}

/// 同步等一个异步回调。只在这两处用，等的都是 ≤1.5s 的本机 IPC。
- (NSString *)nowPlayingOwnerBundleIDWaitingUpTo:(NSTimeInterval)timeout {
    LoadMediaRemote();
    if (!MRGetPID) return nil;

    __block int pid = -1;
    dispatch_semaphore_t done = dispatch_semaphore_create(0);
    // 回调队列不能用 main：调用方常常就在 main 上，等自己等成死锁
    MRGetPID(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^(int found) {
        pid = found;
        dispatch_semaphore_signal(done);
    });
    dispatch_semaphore_wait(done, dispatch_time(DISPATCH_TIME_NOW, (int64_t)(timeout * NSEC_PER_SEC)));
    if (pid <= 0) return nil;
    return [NSRunningApplication runningApplicationWithProcessIdentifier:pid].bundleIdentifier;
}

- (NSString *)displayNameForBundleID:(NSString *)bundleID {
    if (!bundleID) return nil;
    NSRunningApplication *app = RunningAppWithBundleID(bundleID);
    if (app.localizedName) return app.localizedName;
    // 没在运行就拿不到 localizedName，可报错时恰恰都是没在运行的情况
    NSDictionary *names = @{kNetEaseBundleID: @"网易云音乐",
                            @"com.apple.Music": @"Apple Music",
                            @"com.spotify.client": @"Spotify",
                            @"com.tencent.QQMusicMac": @"QQ 音乐"};
    return names[bundleID] ?: bundleID;
}

#pragma mark - AppleScript

/// 本地是 ad-hoc 签名，重新构建 cdhash 就变，TCC 里存的授权随之作废——
/// 系统设置里开关看着还是开的，实际不作数。这是最容易误判成"代码写错了"的一种失败。
- (NSString *)permissionHint {
    return AXIsProcessTrusted() ? @"缺少权限" : @"权限失效了（重新构建过就要关掉再打开一次）";
}

/// NSAppleScript 必须在主线程跑。返回 nil 且 outError 非空表示失败。
- (NSAppleEventDescriptor *)runAppleScript:(NSString *)source error:(NSString **)outError {
    __block NSAppleEventDescriptor *result = nil;
    __block NSString *failure = nil;

    void (^work)(void) = ^{
        NSAppleScript *script = [[NSAppleScript alloc] initWithSource:source];
        NSDictionary *scriptError = nil;
        result = [script executeAndReturnError:&scriptError];
        if (scriptError) {
            NSNumber *code = scriptError[NSAppleScriptErrorNumber];
            NSString *message = scriptError[NSAppleScriptErrorMessage] ?: @"未知错误";
            // 权限类和"界面还没就绪"类必须分开报，否则排查会一路跑偏：
            //   -1743  errAEEventNotPermitted   自动化权限（目标是"系统事件"）
            //   -25211 kAXErrorAPIDisabled      辅助功能权限
            //   -1719  errAEIllegalIndex        菜单/菜单栏还不存在，是时序不是权限
            //   -1728  errAENoSuchObject        同上
            if (code.integerValue == -1743) {
                failure = [NSString stringWithFormat:@"%@（自动化）：系统设置 → 隐私与安全性 → "
                           @"自动化，把 J.A.R.V.I.S. 下的「系统事件」打开", [self permissionHint]];
            } else if (code.integerValue == -25211) {
                failure = [NSString stringWithFormat:@"%@（辅助功能）：系统设置 → 隐私与安全性 → "
                           @"辅助功能，把 J.A.R.V.I.S. 打开", [self permissionHint]];
            } else if (code.integerValue == -1719 || code.integerValue == -1728) {
                failure = @"网易云音乐的窗口/菜单还没就绪，稍后再试";
            } else {
                failure = [NSString stringWithFormat:@"控制失败：%@（%@）", message, code ?: @"?"];
            }
        }
    };

    if ([NSThread isMainThread]) work();
    else dispatch_sync(dispatch_get_main_queue(), work);

    if (failure) { if (outError) *outError = failure; return nil; }
    return result;
}

@end
