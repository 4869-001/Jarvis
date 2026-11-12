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

/// 按歌名点歌。
///
/// 以前的做法是模拟用户：把网易云拉到前台、⌘F、粘贴、回车、再按写死的坐标点
/// 「单曲」和「播放全部」。它在每一环上都会失手——窗口尺寸和页头布局一变坐标就偏，
/// 联想下拉会被鼠标悬停换掉搜索词，焦点被别的窗口抢走时粘贴落空，冷启动时
/// 点击安静地什么都不发生；而且 macOS 15.4 起第三方进程读不到 MediaRemote 的曲名，
/// 回读校验永远失败，即使播对了也只会报"无法确认播放"。
///
/// 现在不碰界面：
///   1. 用网易云 PC 客户端自己的搜索接口拿到歌曲 id（云搜索，对口误和大小写很宽容，
///      语音识别成 "back in back" 也能搜到 Back In Black）；
///   2. 交给客户端注册的 orpheus:// 协议：base64({"type":"song","id":…,"cmd":"play"})，
///      这是网页版「在客户端打开」用的同一条通道，客户端收到后直接插进队列并播放；
///   3. 先暂停、再发命令、再等「控制」菜单翻成"暂停"——看到在播放，才说明是新歌
///      起播了，而不是原来那首还在放。曲名和歌手来自搜索结果，id 是确定的。
/// 整个过程网易云留在后台，不抢焦点、不动鼠标、不借剪贴板。
- (void)searchAndPlayNetEase:(NSString *)query completion:(JarvisMediaCompletion)completion {
    query = [query stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    if (query.length == 0) { completion(nil, @"搜索歌曲时缺少 query"); return; }
    if (![[NSWorkspace sharedWorkspace] URLForApplicationWithBundleIdentifier:kNetEaseBundleID]) {
        completion(nil, @"本机没装网易云音乐");
        return;
    }

    [self searchNetEaseSongs:query completion:^(NSArray<NSDictionary *> *songs, NSString *error) {
        if (error) { completion(nil, error); return; }
        NSDictionary *song = BestNetEaseSong(songs, query);
        if (!song) {
            completion(nil, [NSString stringWithFormat:@"网易云音乐里没有搜到「%@」", query]);
            return;
        }
        [self playNetEaseSong:song query:query completion:completion];
    }];
}

/// 网易云 PC 端的云搜索。回调总在主线程。
- (void)searchNetEaseSongs:(NSString *)query
                completion:(void (^)(NSArray<NSDictionary *> *songs, NSString *error))completion {
    NSMutableCharacterSet *allowed = [[NSCharacterSet URLQueryAllowedCharacterSet] mutableCopy];
    [allowed removeCharactersInString:@"&=+?/"];
    NSString *body = [NSString stringWithFormat:@"s=%@&type=1&limit=10&offset=0",
                      [query stringByAddingPercentEncodingWithAllowedCharacters:allowed]];

    NSMutableURLRequest *request = [NSMutableURLRequest requestWithURL:
        [NSURL URLWithString:@"https://music.163.com/api/cloudsearch/pc"]];
    request.HTTPMethod = @"POST";
    request.HTTPBody = [body dataUsingEncoding:NSUTF8StringEncoding];
    request.timeoutInterval = 8;
    [request setValue:@"application/x-www-form-urlencoded" forHTTPHeaderField:@"Content-Type"];
    [request setValue:@"https://music.163.com/" forHTTPHeaderField:@"Referer"];
    [request setValue:@"Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 "
                      @"(KHTML, like Gecko) Version/17.0 Safari/605.1.15"
   forHTTPHeaderField:@"User-Agent"];

    [[[NSURLSession sharedSession] dataTaskWithRequest:request
                                     completionHandler:^(NSData *data, NSURLResponse *response, NSError *error) {
        NSArray *songs = nil;
        NSString *failure = nil;
        if (error) {
            failure = [NSString stringWithFormat:@"搜索歌曲失败：%@", error.localizedDescription];
        } else {
            id json = data ? [NSJSONSerialization JSONObjectWithData:data options:0 error:nil] : nil;
            id result = [json isKindOfClass:[NSDictionary class]] ? json[@"result"] : nil;
            id list = [result isKindOfClass:[NSDictionary class]] ? result[@"songs"] : nil;
            if ([list isKindOfClass:[NSArray class]]) {
                songs = list;
            } else if (![json isKindOfClass:[NSDictionary class]]) {
                failure = @"网易云的搜索接口返回了看不懂的内容";
            } else if ([json[@"code"] integerValue] != 200) {
                failure = [NSString stringWithFormat:@"网易云的搜索接口拒绝了请求（code %@）",
                           json[@"code"] ?: @"?"];
            } else {
                songs = @[];
            }
        }
        dispatch_async(dispatch_get_main_queue(), ^{ completion(songs, failure); });
    }] resume];
}

/// 小写、去重音、只留字母数字（含中日韩文字），用来做"包含"判断。
static NSString *FoldForMatch(NSString *text) {
    if (![text isKindOfClass:[NSString class]]) return @"";
    NSString *folded = [[text lowercaseString] stringByFoldingWithOptions:NSDiacriticInsensitiveSearch
                                                                   locale:nil];
    NSCharacterSet *drop = [[NSCharacterSet alphanumericCharacterSet] invertedSet];
    return [[folded componentsSeparatedByCharactersInSet:drop] componentsJoinedByString:@""];
}

static NSString *NetEaseArtists(NSDictionary *song) {
    NSMutableArray *names = [NSMutableArray array];
    id artists = song[@"ar"] ?: song[@"artists"];
    if ([artists isKindOfClass:[NSArray class]]) {
        for (id artist in artists) {
            id name = [artist isKindOfClass:[NSDictionary class]] ? artist[@"name"] : nil;
            if ([name isKindOfClass:[NSString class]] && [name length]) [names addObject:name];
        }
    }
    return [names componentsJoinedByString:@" / "];
}

/// 从搜索结果里挑最像用户要的那首。
///
/// 搜索接口按热度排，热门的翻唱、伴奏、DJ 版常常排在原曲前面。所以：
///   · 曲名（去掉括号里的版本说明）出现在查询里 +4
///   · 某位歌手的名字出现在查询里 +3（"海阔天空 Beyond" 就该选 Beyond 的）
///   · 曲名里带伴奏 / Live / DJ / 翻唱 / 女声版之类、而用户没提 −3
///   · 原始排序做轻微的平手裁决
static NSDictionary *BestNetEaseSong(NSArray<NSDictionary *> *songs, NSString *query) {
    NSString *q = FoldForMatch(query);
    NSString *qLower = [query lowercaseString];
    NSArray *variants = @[@"伴奏", @"纯音乐", @"instrumental", @"karaoke", @"live", @"dj",
                          @"remix", @"翻自", @"翻唱", @"cover", @"女声", @"男声", @"钢琴", @"片段",
                          @"铃声", @"加速", @"降调", @"慢速", @"0.8x", @"1.2x", @"童声", @"抖音"];

    NSDictionary *best = nil;
    double bestScore = -1e9;
    NSUInteger index = 0;
    for (NSDictionary *song in songs) {
        if (![song isKindOfClass:[NSDictionary class]] || !song[@"id"]) { index++; continue; }
        NSString *name = [song[@"name"] isKindOfClass:[NSString class]] ? song[@"name"] : @"";
        NSString *base = name;
        for (NSString *open in @[@"(", @"（", @"[", @"【", @" - "]) {
            NSRange cut = [base rangeOfString:open];
            if (cut.location != NSNotFound && cut.location > 0) base = [base substringToIndex:cut.location];
        }

        double score = -0.1 * (double)index;
        NSString *baseFolded = FoldForMatch(base);
        if (baseFolded.length && [q containsString:baseFolded]) score += 4;

        id artists = song[@"ar"] ?: song[@"artists"];
        if ([artists isKindOfClass:[NSArray class]]) {
            for (id artist in artists) {
                NSString *artistFolded = FoldForMatch([artist isKindOfClass:[NSDictionary class]] ? artist[@"name"] : nil);
                if (artistFolded.length >= 2 && [q containsString:artistFolded]) { score += 3; break; }
            }
        }

        NSString *nameLower = [name lowercaseString];
        for (NSString *word in variants) {
            if ([nameLower containsString:word] && ![qLower containsString:word]) { score -= 3; break; }
        }

        if (score > bestScore) { bestScore = score; best = song; }
        index++;
    }
    return best;
}

static BOOL NetEaseMenuSaysPlaying(NSArray<NSString *> *items) {
    NSString *first = items.firstObject ?: @"";
    return [first containsString:@"暂停"] || [first containsString:@"Pause"];
}

- (void)playNetEaseSong:(NSDictionary *)song
                  query:(NSString *)query
             completion:(JarvisMediaCompletion)completion {
    NSURL *appURL = [[NSWorkspace sharedWorkspace] URLForApplicationWithBundleIdentifier:kNetEaseBundleID];
    NSString *songID = [NSString stringWithFormat:@"%@", song[@"id"]];
    NSData *payload = [NSJSONSerialization dataWithJSONObject:@{@"type": @"song", @"id": songID, @"cmd": @"play"}
                                                      options:0 error:nil];
    NSURL *orpheus = [NSURL URLWithString:[@"orpheus://" stringByAppendingString:
                                           [payload base64EncodedStringWithOptions:0]]];

    NSMutableDictionary *result = [@{@"action": @"search_play", @"query": query,
                                     @"player": @"网易云音乐", @"song_id": songID} mutableCopy];
    if ([song[@"name"] isKindOfClass:[NSString class]]) result[@"title"] = song[@"name"];
    NSString *artists = NetEaseArtists(song);
    if (artists.length) result[@"artist"] = artists;
    id album = [song[@"al"] isKindOfClass:[NSDictionary class]] ? song[@"al"][@"name"] : nil;
    if ([album isKindOfClass:[NSString class]]) result[@"album"] = album;

    void (^send)(void) = ^{
        NSWorkspaceOpenConfiguration *config = [NSWorkspaceOpenConfiguration configuration];
        config.activates = NO;     // 留在后台：不抢用户正在用的窗口
        [[NSWorkspace sharedWorkspace] openURLs:@[orpheus] withApplicationAtURL:appURL
                                  configuration:config completionHandler:nil];
    };

    void (^start)(void) = ^{
        // 先停下当前在放的，之后"变成在播放"才能证明新歌起播了。
        NSArray<NSString *> *items = nil;
        if ([self netEaseControlMenuItems:&items] == nil && NetEaseMenuSaysPlaying(items)) {
            NSInteger index = MenuIndexForAction(items, @"pause");
            if (index > 0) [self clickNetEaseControlItemAtIndex:index];
            [self netEaseBecomesPlaying:NO within:1.5];
        }
        send();
        // 后台收到协议到真正出声，实测 3～8 秒；一直没动静就补发一次（同一首，重复无害）。
        [self waitForNetEaseSong:result attempts:28 resendAt:12 send:send completion:completion];
    };

    if (RunningAppWithBundleID(kNetEaseBundleID)) { start(); return; }

    // 冷启动：先在后台拉起来，等菜单能读了、播放内核接上了再发，否则协议消息会被吞掉。
    NSWorkspaceOpenConfiguration *config = [NSWorkspaceOpenConfiguration configuration];
    config.activates = NO;
    [[NSWorkspace sharedWorkspace] openApplicationAtURL:appURL configuration:config
                                      completionHandler:^(NSRunningApplication *app, NSError *error) {
        dispatch_async(dispatch_get_main_queue(), ^{
            if (error) {
                completion(nil, [NSString stringWithFormat:@"启动网易云音乐失败：%@", error.localizedDescription]);
                return;
            }
            [self whenNetEaseReady:20 then:^{
                dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(2.0 * NSEC_PER_SEC)),
                               dispatch_get_main_queue(), start);
            }];
        });
    }];
}

/// 每 0.5 秒看一次菜单是否已经能读，最多 attempts 次。用 dispatch_after 而不是
/// 原地空转 runloop，主线程在等的这几秒里球体和面板照常响应。
- (void)whenNetEaseReady:(int)attempts then:(void (^)(void))next {
    NSArray *items = nil;
    if ([self netEaseControlMenuItems:&items] == nil || attempts <= 0) { next(); return; }
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.5 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{ [self whenNetEaseReady:attempts - 1 then:next]; });
}

- (void)waitForNetEaseSong:(NSMutableDictionary *)result
                  attempts:(int)attemptsLeft
                  resendAt:(int)resendAt
                      send:(void (^)(void))send
                completion:(JarvisMediaCompletion)completion {
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.5 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        NSArray<NSString *> *items = nil;
        NSString *error = [self netEaseControlMenuItems:&items];
        if (!error && NetEaseMenuSaysPlaying(items)) {
            result[@"verified"] = @YES;
            result[@"playing"] = @YES;
            completion(result, nil);
            return;
        }
        if (attemptsLeft == resendAt) send();
        if (attemptsLeft > 1) {
            [self waitForNetEaseSong:result attempts:attemptsLeft - 1 resendAt:resendAt
                                send:send completion:completion];
            return;
        }
        NSLog(@"[jarvis] search_play：已把歌曲 %@ 交给网易云，但它没有开始播放（%@）",
              result[@"song_id"], error ?: items.firstObject ?: @"?");
        if (error) { completion(nil, error); return; }
        result[@"verified"] = @NO;
        result[@"playing"] = @NO;
        result[@"note"] = @"已经把这首歌交给网易云，但它没有开始播放——可能需要会员、没有版权，"
                          @"或者网易云弹出了需要处理的提示";
        completion(result, nil);
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
            status[@"liked"] = @([items containsObject:@"取消喜欢"] || [items containsObject:@"Unlike"] ||
                                 [items containsObject:@"Dislike"]);
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
