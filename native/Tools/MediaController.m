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
static NSString *const kJarvisBundleID = @"com.jarvis.desktop";

/// 搜索结果页上的点击目标，**相对窗口原点的点偏移**。
///
/// 走的是「单曲」标签页而不是「综合」页。综合页那颗「▶ 播放」按钮的 y
/// 取决于页面上方有没有「歌手 / MV」卡片区——出现与否由搜的内容决定，
/// 出现时按钮在 326、不出现时在 204，差 122 点，**没有任何常数能同时对**。
/// 单曲页没有卡片区，布局与查询内容无关；那里的「播放全部」还高 34 点，
/// 比综合页那颗 26 点的小按钮宽容得多。
///
/// 更要紧的是**点空了不会闯祸**：标签行和右上角在综合页上都是空白，
/// 点不中最多是没播成；而综合页上按老坐标点歪会落进歌手卡片，
/// 一跳转就把后续点击带进了另一套布局，最后播的是不相干的歌。
///
/// 2026-08-06 实测（窗口 1470×820 与 1100×741 两种尺寸，取值完全一致）：
///   「单曲」标签   x=316（固定左偏移）
///   「播放全部」   距窗口**右缘** 213 点（右对齐，所以按右缘算）
/// y 有两种页头：搜索框下方是「猜你想搜」一行时整行在 140，是查询大标题时在 152。
/// 标签只有 16 点高，两个 y 都点一下（都落在标签行内，无副作用）；
/// 「播放全部」34 点高，取中点 146 对两种页头都落在按钮内。
///
/// 单位是**点**不是像素。AX 的 position/size 和 CGEvent 鼠标坐标说的都是点，
/// 所以这些常数跨显示器通用——内置 Retina、1× 外接屏、多屏负坐标都不用特判。
/// ⚠️ 但凡以后再从截图上量这些值，记得**除以那块屏的 backing scale**
/// （内置屏截图是 2×，一般外接 1080p 是 1×）——同一个目标在两块屏上量出的
/// 像素数差一倍，点数才是相同的那个。
static const CGFloat kNetEaseSongsTabX = 316.0;
static const CGFloat kNetEaseSongsTabYA = 140.0;
static const CGFloat kNetEaseSongsTabYB = 152.0;
static const CGFloat kNetEasePlayAllRightInset = 213.0;
static const CGFloat kNetEasePlayAllY = 146.0;

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

static BOOL MainWindowBoundsForPID(pid_t pid, CGRect *outBounds) {
    NSArray *windows = CFBridgingRelease(CGWindowListCopyWindowInfo(
        kCGWindowListOptionOnScreenOnly | kCGWindowListExcludeDesktopElements, kCGNullWindowID));
    for (NSDictionary *window in windows) {
        if ([window[(id)kCGWindowOwnerPID] intValue] != pid) continue;
        if ([window[(id)kCGWindowLayer] integerValue] != 0) continue;
        CGRect bounds = CGRectZero;
        if (CGRectMakeWithDictionaryRepresentation((__bridge CFDictionaryRef)window[(id)kCGWindowBounds],
                                                   &bounds)) {
            if (outBounds) *outBounds = bounds;
            return YES;
        }
    }
    return NO;
}

static void MoveMouse(CGPoint point) {
    CGEventRef move = CGEventCreateMouseEvent(NULL, kCGEventMouseMoved, point, kCGMouseButtonLeft);
    CGEventPost(kCGHIDEventTap, move);
    CFRelease(move);
}

static void PostClick(CGPoint point) {
    CGEventRef move = CGEventCreateMouseEvent(NULL, kCGEventMouseMoved, point, kCGMouseButtonLeft);
    CGEventRef down = CGEventCreateMouseEvent(NULL, kCGEventLeftMouseDown, point, kCGMouseButtonLeft);
    CGEventRef up = CGEventCreateMouseEvent(NULL, kCGEventLeftMouseUp, point, kCGMouseButtonLeft);
    CGEventPost(kCGHIDEventTap, move);
    CGEventPost(kCGHIDEventTap, down);
    CGEventPost(kCGHIDEventTap, up);
    CFRelease(move);
    CFRelease(down);
    CFRelease(up);
}

#pragma mark -

@implementation MediaController

- (void)perform:(NSString *)action
         player:(NSString *)player
          query:(NSString *)query
     completion:(JarvisMediaCompletion)completion {

    LoadMediaRemote();
    action = [(action ?: @"") lowercaseString];

    if ([action isEqualToString:@"search_play"]) {
        [self searchAndPlayNetEase:query completion:completion];
        return;
    }

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

/// 网易云 3.x 的主内容区是自绘 WebView，不暴露可点的 AX 元素，也没有 AppleScript
/// 字典。可靠入口是它自己的搜索框：聚焦窗口左上角搜索框、提交，再点“单曲”的播放。
/// 所有坐标都相对 window 1，不依赖窗口放在屏幕什么位置。
- (void)searchAndPlayNetEase:(NSString *)query completion:(JarvisMediaCompletion)completion {
    query = [query stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    if (query.length == 0) { completion(nil, @"搜索歌曲时缺少 query"); return; }
    if (!AXIsProcessTrusted()) {
        completion(nil, [NSString stringWithFormat:@"%@（辅助功能）：系统设置 → 隐私与安全性 → "
                         @"辅助功能，把 JARVIS 打开", [self permissionHint]]);
        return;
    }

    BOOL wasAlreadyRunning = RunningAppWithBundleID(kNetEaseBundleID) != nil;
    BOOL wasHidden = RunningAppWithBundleID(kNetEaseBundleID).hidden;
    NSString *previousFrontmostBundleID = NSWorkspace.sharedWorkspace.frontmostApplication.bundleIdentifier;
    NSRunningApplication *jarvisApp = RunningAppWithBundleID(kJarvisBundleID);
    BOOL shouldTemporarilyHideJarvis = jarvisApp && !jarvisApp.hidden;

    void (^restorePreviousApp)(void) = ^{
        // 搜索必须短暂让网易云接收键盘输入；若它原本已经运行，完成后立即把用户之前
        // 使用的应用切回来。这样网易云只在后台播放，不会一直盖在 Jarvis 或其他窗口上。
        if (shouldTemporarilyHideJarvis) [RunningAppWithBundleID(kJarvisBundleID) unhide];
        if (wasAlreadyRunning && previousFrontmostBundleID.length > 0 &&
            ![previousFrontmostBundleID isEqualToString:kNetEaseBundleID]) {
            NSRunningApplication *previous = RunningAppWithBundleID(previousFrontmostBundleID);
            [previous activateWithOptions:NSApplicationActivateAllWindows];
        }
        if (wasHidden) [RunningAppWithBundleID(kNetEaseBundleID) hide];
    };

    void (^runSearch)(void) = ^{
        // 后台隐藏或最小化时，网易云的 WebView 不会接收搜索键盘事件，也没有可取的
        // on-screen 窗口坐标。临时恢复窗口，播放完成后再还原原来的前台/隐藏状态。
        // Jarvis 对话面板是浮动层级，会遮住网易云左侧的“单曲”标签；来自面板的命令
        // 必须在点击期间临时隐藏 Jarvis，结束后再完整恢复面板。
        if (shouldTemporarilyHideJarvis) [RunningAppWithBundleID(kJarvisBundleID) hide];
        NSRunningApplication *runningNetEase = RunningAppWithBundleID(kNetEaseBundleID);
        [runningNetEase activateWithOptions:NSApplicationActivateAllWindows];
        // 回车之前必须把鼠标挪出搜索框下方——**这是搜错歌的真正原因**。
        //
        // 网易云的搜索联想下拉**按鼠标悬停高亮**，回车提交的是被悬停的那一条，
        // 而不是你输入的文字。上一次点击（比如点"单曲"标签）会把指针留在
        // (316, 189) 附近，正好压在下拉列表第三行上，于是
        // 「海阔天空 Beyond」被提交成了联想词「海阔天空 beyond伴奏」——
        // 2026-08-06 截图实测：粘贴进去的原文一字不差，是回车挑走了别的词。
        // 搜错了词，页面内容跟着变，后面点得再准也是在播别的歌。
        //
        // 停在窗口左下角：那里是侧边栏/播放条，悬停无副作用，也够远。
        CGRect parkBounds = CGRectZero;
        if (MainWindowBoundsForPID(runningNetEase.processIdentifier, &parkBounds)) {
            MoveMouse(CGPointMake(CGRectGetMinX(parkBounds) + 40,
                                  CGRectGetMaxY(parkBounds) - 40));
        }

        // 搜索词走剪贴板 + ⌘V，**不要**用 keystroke 逐字符打。
        // 实测（2026-08-06）：keystroke 打进网易云的搜索框会丢字符——
        // 「Back in Black」进去成了「Back inBlack」，「Hells Bells」更是只剩
        // 「Bells」并接在上一次的残留后面。搜错了词，页面布局跟着变，
        // 后面点得再准也是在播别的歌。粘贴是一次性事务，没有这个问题。
        NSPasteboard *board = [NSPasteboard generalPasteboard];
        NSString *savedClipboard = [board stringForType:NSPasteboardTypeString];
        [board clearContents];
        [board setString:query forType:NSPasteboardTypeString];

        NSString *source =
            @"tell application \"System Events\"\n"
             "tell process \"NeteaseMusic\"\n"
             "set frontmost to true\n"
             "if (count of windows) is 0 then error \"网易云音乐没有可用窗口\"\n"
             "if value of attribute \"AXMinimized\" of window 1 is true then "
             "set value of attribute \"AXMinimized\" of window 1 to false\n"
             "keystroke \"f\" using command down\n"
             "delay 0.6\n"
             "keystroke \"a\" using command down\n"
             "delay 0.2\n"
             "key code 51\n"
             "delay 0.2\n"
             "keystroke \"v\" using command down\n"
             "delay 0.4\n"
             "key code 36\n"
             "delay 3\n"
             "end tell\n"
             "end tell";
        NSString *error = nil;
        [self runAppleScript:source error:&error];

        // 借完就还。用户的剪贴板不是我们的暂存区。
        if (savedClipboard) {
            [board clearContents];
            [board setString:savedClipboard forType:NSPasteboardTypeString];
        }
        if (error) { restorePreviousApp(); completion(nil, error); return; }

        NSRunningApplication *netEase = RunningAppWithBundleID(kNetEaseBundleID);
        CGRect bounds = CGRectZero;
        if (!netEase || !MainWindowBoundsForPID(netEase.processIdentifier, &bounds)) {
            restorePreviousApp();
            completion(nil, @"找不到网易云音乐主窗口");
            return;
        }
        // 已经在放要的那首就别再点了——点下去是从头重放，而且万一状态回读
        // 慢半拍还会误判成没命中、再点一次点到别的歌上去。
        [self fetchStatus:^(NSDictionary *status) {
            if ([status[@"playing"] boolValue] && NetEaseTrackMatches(status, query)) {
                NSMutableDictionary *r = [status mutableCopy];
                r[@"action"] = @"search_play";
                r[@"query"] = query;
                r[@"verified"] = @YES;
                restorePreviousApp();
                completion(r, nil);
                return;
            }
            [self clickNetEasePlayAllInWindow:bounds];
            CGPoint playAll = CGPointMake(CGRectGetMaxX(bounds) - kNetEasePlayAllRightInset,
                                          CGRectGetMinY(bounds) + kNetEasePlayAllY);
            [self pollNetEasePlayback:4 query:query clicked:playAll
                              restore:restorePreviousApp completion:completion];
        }];
    };

    if (RunningAppWithBundleID(kNetEaseBundleID)) { runSearch(); return; }
    NSURL *url = [[NSWorkspace sharedWorkspace] URLForApplicationWithBundleIdentifier:kNetEaseBundleID];
    if (!url) { completion(nil, @"本机没装网易云音乐"); return; }
    [[NSWorkspace sharedWorkspace] openApplicationAtURL:url
                                          configuration:[NSWorkspaceOpenConfiguration configuration]
                                      completionHandler:^(NSRunningApplication *app, NSError *error) {
        if (error) {
            completion(nil, [NSString stringWithFormat:@"启动网易云音乐失败：%@",
                              error.localizedDescription]);
            return;
        }
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(2.5 * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), runSearch);
    }];
}

/// 切到「单曲」标签页，再点右上角的「播放全部」。
///
/// 两次标签点击对应两种页头布局，都落在标签行内；点空了是无害的空白区。
/// 中间要留时间给标签页切换渲染——网易云是 Electron，切页不是同步的，
/// 不等就会点在还没出现的按钮位置上。
- (void)clickNetEasePlayAllInWindow:(CGRect)bounds {
    CGFloat x = CGRectGetMinX(bounds) + kNetEaseSongsTabX;
    PostClick(CGPointMake(x, CGRectGetMinY(bounds) + kNetEaseSongsTabYA));
    usleep(150000);
    PostClick(CGPointMake(x, CGRectGetMinY(bounds) + kNetEaseSongsTabYB));
    usleep(900000);
    PostClick(CGPointMake(CGRectGetMaxX(bounds) - kNetEasePlayAllRightInset,
                          CGRectGetMinY(bounds) + kNetEasePlayAllY));
}

/// 播放到的是不是用户要的那首。
///
/// 词元一半以上出现在「标题 + 歌手」里就算命中——搜索词很少和曲目全称逐字一致。
/// 但**必须至少有一个词元落在曲名上**：2026-08-06 实测，只按合并串算的话，
/// 查询「Hells Bells AC/DC」对上正在放的「Highway To Hell (Live) · AC/DC」
/// 光靠 ac + dc 两个词元就凑够了一半，于是判定"已经在放你要的歌"——
/// 播的是完全另一首，却报 verified: true。歌手对上不等于歌对上。
static BOOL NetEaseTrackMatches(NSDictionary *status, NSString *query) {
    NSString *(^fold)(NSString *) = ^NSString *(NSString *text) {
        return [[text lowercaseString] stringByFoldingWithOptions:
            NSDiacriticInsensitiveSearch locale:[NSLocale currentLocale]];
    };
    NSString *title = fold(status[@"title"] ?: @"");
    NSString *actual = fold([NSString stringWithFormat:@"%@ %@",
                             status[@"title"] ?: @"", status[@"artist"] ?: @""]);
    NSCharacterSet *separators = [[NSCharacterSet alphanumericCharacterSet] invertedSet];
    NSArray *tokens = [fold(query) componentsSeparatedByCharactersInSet:separators];

    NSInteger useful = 0, matched = 0, titleHits = 0;
    for (NSString *token in tokens) {
        if (token.length < 2) continue;
        useful++;
        if ([actual containsString:token]) matched++;
        if (title.length && [title containsString:token]) titleHits++;
    }
    if (useful == 0 || titleHits == 0) return NO;
    return matched >= MAX(1, (useful + 1) / 2);
}

/// 点完之后每秒回读一次播放状态，最多 attemptsLeft 次。
///
/// 为什么要轮询而不是等一次：网易云冷启动后头几秒，点击会安静地什么都不发生
/// （见 media_control 的老账）；歌曲起播也有网络延迟。等一次就判死刑会把
/// 「其实播上了」误报成失败。
///
/// 为什么**不再**点第二个位置：点错地方的代价比失败大得多——落在歌手卡片上会
/// 跳转到歌手页，后续点击就落进了另一套布局，最后可能播的是完全不相干的歌。
/// 坐标是实测常量（见 kNetEasePlayButtonX/Y），真失手了就老实报失败，
/// 把点击坐标写进 note 里，下次一眼能看出是布局变了还是没点上。
///
/// 用方法递归而不是块递归，避免 ARC retain cycle。
- (void)pollNetEasePlayback:(int)attemptsLeft
                      query:(NSString *)query
                    clicked:(CGPoint)point
                    restore:(void (^)(void))restorePreviousApp
                 completion:(JarvisMediaCompletion)completion {
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.0 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        [self fetchStatus:^(NSDictionary *status) {
            if ([status[@"playing"] boolValue] && NetEaseTrackMatches(status, query)) {
                NSMutableDictionary *r = [status mutableCopy];
                r[@"action"] = @"search_play";
                r[@"query"] = query;
                r[@"verified"] = @YES;
                restorePreviousApp();
                completion(r, nil);
                return;
            }
            if (attemptsLeft > 1) {
                [self pollNetEasePlayback:attemptsLeft - 1 query:query clicked:point
                                  restore:restorePreviousApp completion:completion];
                return;
            }
            restorePreviousApp();
            // 点击坐标只进日志。它是给排障看的，不该出现在面板和播报里——
            // 用户要听的是"没播成"，不是我点了哪个像素。
            NSLog(@"[jarvis] search_play 未命中：点击 %.0f,%.0f，当前曲目 %@",
                  point.x, point.y, status[@"title"] ?: @"（读不到）");
            NSMutableDictionary *r = [NSMutableDictionary dictionary];
            r[@"action"] = @"search_play";
            r[@"query"] = query;
            r[@"verified"] = @NO;
            r[@"note"] = status[@"title"]
                ? [NSString stringWithFormat:@"搜索结果已打开，但实际仍是 %@", status[@"title"]]
                : @"已打开搜索结果，但没有确认歌曲开始播放";
            completion(r, nil);
        }];
    });
}

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
    BOOL skipsTrack = ([action isEqualToString:@"next"] ||
                       [action isEqualToString:@"previous"]);

    // 切歌前先记下曲名，切完拿它对比——这是唯一能证明"真的换歌了"的凭据。
    NSString *titleBefore = skipsTrack ? [self nowPlayingTitleWaitingUpTo:1.0] : nil;

    // 总线在网易云手上时优先走 MediaRemote：不碰菜单就不会有菜单闪动。
    // 抢不到总线（浏览器在放视频）时才点菜单——那条路一定打得中。
    BOOL viaBus = NO;
    if (!forceMenu && (flipsPlayback || skipsTrack)) {
        viaBus = [self sendBusCommandForAction:action ifOwnedBy:kNetEaseBundleID];
    }

    // MRMediaRemoteSendCommand 返回的是"命令送出去了"，不是"播放器照做了"。
    // 冷启动后的头几秒它就会返回真但什么也没发生，所以播放状态必须回读校验。
    if (viaBus && flipsPlayback && ![self netEaseBecomesPlaying:!playing within:1.5]) {
        viaBus = NO;
    }

    // 切歌同样要回读。以前这里只校验 toggle/play/pause，切歌发完就报成功——
    // 暂停态下对总线发 next 常常安静地什么都不发生，用户听到"已跳到下一首"
    // 而歌根本没变（2026-08-06 实测复现）。
    //
    // ⚠️ 只有读得到切歌前的曲名才敢回退点菜单：读不到就无从判断，
    // 这时候再点一次菜单，万一总线其实成功了就一次命令跳两首。
    BOOL skipConfirmed = NO;
    if (viaBus && skipsTrack && titleBefore.length) {
        skipConfirmed = [self netEaseTrackChangesFrom:titleBefore within:2.5];
        if (!skipConfirmed) viaBus = NO;
    }

    if (!viaBus) {
        NSString *clickError = [self clickNetEaseControlItemAtIndex:index];
        if (clickError) { completion(nil, clickError); return; }
        if (skipsTrack && titleBefore.length) {
            skipConfirmed = [self netEaseTrackChangesFrom:titleBefore within:2.5];
        }
    }

    NSMutableDictionary *result = [@{@"player": @"网易云音乐",
                                     @"action": action,
                                     @"via": viaBus ? @"MediaRemote" : @"菜单"} mutableCopy];
    result[@"changed"] = @(skipsTrack ? skipConfirmed : YES);
    if (flipsPlayback) {
        result[@"playing"] = @(viaBus ? !playing : [self netEaseBecomesPlaying:!playing within:1.5]);
    }
    if (skipsTrack) {
        NSString *titleAfter = [self nowPlayingTitleWaitingUpTo:1.0];
        if (titleAfter.length) result[@"title"] = titleAfter;
        if (!skipConfirmed) {
            // 报不出实话就别报喜。模型照着 changed:true 会说"已经跳到下一首"，
            // 而用户听着的还是原来那首——这种谎比失败本身更糟。
            result[@"note"] = titleBefore.length
                ? @"命令已送出，但曲目没有变化，可能没切成"
                : @"命令已送出，但读不到曲目信息，无法确认是否切歌";
        }
    }
    completion(result, nil);
}

/// 同步取当前曲名。回调队列**不能用 main**——调用方常常就在 main 上，等自己等成死锁。
- (NSString *)nowPlayingTitleWaitingUpTo:(NSTimeInterval)timeout {
    LoadMediaRemote();
    if (!MRGetInfo) return nil;

    __block NSString *title = nil;
    dispatch_semaphore_t done = dispatch_semaphore_create(0);
    MRGetInfo(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^(CFDictionaryRef raw) {
        NSDictionary *info = (__bridge NSDictionary *)raw;
        title = info[@"kMRMediaRemoteNowPlayingInfoTitle"];
        dispatch_semaphore_signal(done);
    });
    dispatch_semaphore_wait(done, dispatch_time(DISPATCH_TIME_NOW, (int64_t)(timeout * NSEC_PER_SEC)));
    return title;
}

/// 等曲目真的换掉。总线上报的 now-playing 有滞后（起播头几秒常常整个是空的），
/// 所以要轮询而不是等一次。用 runloop 空转而不是 sleep——这里跑在主线程上。
- (BOOL)netEaseTrackChangesFrom:(NSString *)before within:(NSTimeInterval)timeout {
    if (before.length == 0) return NO;
    NSDate *deadline = [NSDate dateWithTimeIntervalSinceNow:timeout];
    while (YES) {
        NSString *now = [self nowPlayingTitleWaitingUpTo:0.5];
        if (now.length && ![now isEqualToString:before]) return YES;
        if ([deadline timeIntervalSinceNow] <= 0) return NO;
        CFRunLoopRunInMode(kCFRunLoopDefaultMode, 0.25, false);
    }
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
                           @"自动化，把 JARVIS 下的「系统事件」打开", [self permissionHint]];
            } else if (code.integerValue == -25211) {
                failure = [NSString stringWithFormat:@"%@（辅助功能）：系统设置 → 隐私与安全性 → "
                           @"辅助功能，把 JARVIS 打开", [self permissionHint]];
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
