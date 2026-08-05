#import "AutomationController.h"

#import <AppKit/AppKit.h>
#import <ApplicationServices/ApplicationServices.h>
#import <Carbon/Carbon.h>
#import <OSAKit/OSAKit.h>

/// 一次脚本最多跑多久。Brain 侧 native 工具的等待上限是 60s，这里必须更小，
/// 否则超时的是 Brain、宿主这边还在跑，用户会看到"报了超时但事情又做了"。
static const NSTimeInterval kScriptCeiling = 45.0;
static const NSInteger kMaxDictionaryChars = 9000;
// 220 太小：钉钉侧边栏扫到一半就被截断，恰好把「日志」那一行的按钮吃掉了，
// 表现是"这一项根本没有可点的东西"——而它其实存在。宁可多返回一些让模型自己筛。
static const NSInteger kMaxUINodes = 600;

@interface AutomationController ()
/// AppleScript 不是线程安全的，且绝不能放主线程——被脚本化的 App 卡住时会把
/// 整个 Jarvis 界面一起冻住（球体停转、面板点不动）。串行队列 + 看门狗。
@property (nonatomic) dispatch_queue_t scriptQueue;
@property (nonatomic) BOOL scriptRunning;
@end

@implementation AutomationController

+ (BOOL)handlesToolNamed:(NSString *)name {
    static NSSet *names = nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        names = [NSSet setWithArray:@[@"app_script", @"app_dictionary", @"app_scriptable",
                                      @"menu_list", @"menu_invoke",
                                      @"ui_inspect", @"ui_action",
                                      @"browser_tabs", @"browser_read", @"browser_act",
                                      @"browser_eval", @"browser_open", @"ui_type",
                                      @"form_read", @"form_write"]];
    });
    return [names containsObject:name];
}

- (dispatch_queue_t)scriptQueue {
    if (!_scriptQueue) _scriptQueue = dispatch_queue_create("com.jarvis.automation", DISPATCH_QUEUE_SERIAL);
    return _scriptQueue;
}

- (void)execute:(NSString *)name
      arguments:(NSDictionary *)arguments
     completion:(JarvisToolCompletion)completion {

    if ([name isEqualToString:@"app_script"])          { [self runScript:arguments completion:completion]; }
    else if ([name isEqualToString:@"app_dictionary"]) { [self dictionary:arguments completion:completion]; }
    else if ([name isEqualToString:@"app_scriptable"]) { completion([self scriptableApps:arguments], nil); }
    else if ([name isEqualToString:@"menu_list"])      { [self listMenus:arguments completion:completion]; }
    else if ([name isEqualToString:@"menu_invoke"])    { [self invokeMenu:arguments completion:completion]; }
    else if ([name isEqualToString:@"ui_inspect"])     { [self inspectUI:arguments completion:completion]; }
    else if ([name isEqualToString:@"ui_action"])      { [self actUI:arguments completion:completion]; }
    else if ([name isEqualToString:@"browser_tabs"])   { [self browserTabs:arguments completion:completion]; }
    else if ([name isEqualToString:@"browser_read"])   { [self browserRead:arguments completion:completion]; }
    else if ([name isEqualToString:@"browser_act"])    { [self browserAct:arguments completion:completion]; }
    else if ([name isEqualToString:@"browser_eval"])   { [self browserEval:arguments completion:completion]; }
    else if ([name isEqualToString:@"browser_open"])   { [self browserOpen:arguments completion:completion]; }
    else if ([name isEqualToString:@"ui_type"])        { [self typeText:arguments completion:completion]; }
    else if ([name isEqualToString:@"form_read"])      { [self formRead:arguments completion:completion]; }
    else if ([name isEqualToString:@"form_write"])     { [self formWrite:arguments completion:completion]; }
    else { completion(nil, [NSString stringWithFormat:@"自动化层不认识工具 %@", name]); }
}

#pragma mark - 应用定位

/// 按名字找 App。先问 LaunchServices（认得 bundle id 和显示名），再扫标准目录，
/// 最后按已运行的进程名匹配——用户嘴里的名字可能是本地化的（"备忘录"），
/// 也可能是英文的（"Notes"），两种都得认。
/// 中文名 → 磁盘上的英文 bundle 名。
///
/// 系统语言是中文，但苹果自带应用的中文名并不在 bundle 里能便宜读到的地方
/// （`displayNameAtPath:` 和 `localizedInfoDictionary` 在这台机器上都只给英文，
/// 中文名来自 bundle 之外的系统目录）。用户和模型嘴里说的却是「备忘录」「日历」，
/// 所以这张表是必要的——比每次去扫所有 .lproj 便宜得多，也不会漏。
+ (NSDictionary<NSString *, NSString *> *)nameAliases {
    static NSDictionary *aliases = nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        aliases = @{@"备忘录": @"Notes", @"邮件": @"Mail", @"日历": @"Calendar",
                    @"提醒事项": @"Reminders", @"通讯录": @"Contacts", @"联系人": @"Contacts",
                    @"信息": @"Messages", @"音乐": @"Music", @"照片": @"Photos",
                    @"预览": @"Preview", @"访达": @"Finder", @"终端": @"Terminal",
                    @"系统设置": @"System Settings", @"系统偏好设置": @"System Settings",
                    @"快捷指令": @"Shortcuts", @"自动操作": @"Automator",
                    @"文本编辑": @"TextEdit", @"计算器": @"Calculator", @"地图": @"Maps",
                    @"浏览器": @"Safari", @"苹果浏览器": @"Safari", @"谷歌浏览器": @"Google Chrome",
                    @"数字": @"Numbers", @"演讲稿": @"Keynote", @"页面": @"Pages",
                    @"活动监视器": @"Activity Monitor", @"磁盘工具": @"Disk Utility",
                    @"屏幕快照": @"Screenshot", @"字典": @"Dictionary", @"书籍": @"Books",
                    @"播客": @"Podcasts", @"电视": @"TV", @"网易云": @"NeteaseMusic",
                    @"网易云音乐": @"NeteaseMusic", @"微信": @"WeChat", @"企业微信": @"企业微信",
                    @"钉钉": @"DingTalk", @"腾讯会议": @"TencentMeeting"};
    });
    return aliases;
}

- (NSURL *)urlForAppNamed:(NSString *)name {
    if (!name.length) return nil;
    NSString *alias = [AutomationController nameAliases][name];
    if (alias && ![alias isEqualToString:name]) {
        NSURL *resolved = [self urlForAppNamed:alias];
        if (resolved) return resolved;
    }

    NSWorkspace *workspace = [NSWorkspace sharedWorkspace];
    // 只在名字真的长得像 bundle id 时才问 LaunchServices。拿普通名字去问会得到
    // 匪夷所思的结果——实测 `URLForApplicationWithBundleIdentifier:@"Safari"`
    // 返回的是 /usr/sbin/universalaccessd，于是后面一路读不出字典，
    // 报出来却是"这个应用不支持脚本"，排查方向直接跑偏。
    if ([name containsString:@"."] && ![name containsString:@" "] && ![name hasSuffix:@".app"]) {
        NSURL *byBundle = [workspace URLForApplicationWithBundleIdentifier:name];
        if ([byBundle.pathExtension isEqualToString:@"app"]) return byBundle;
    }

    for (NSRunningApplication *app in [workspace runningApplications]) {
        if ([self name:app.localizedName matches:name] || [self name:app.bundleIdentifier matches:name]) {
            if ([app.bundleURL.pathExtension isEqualToString:@"app"]) return app.bundleURL;
        }
    }

    NSArray<NSString *> *roots = @[@"/Applications", @"/Applications/Utilities",
                                   @"/System/Applications", @"/System/Applications/Utilities",
                                   [@"~/Applications" stringByExpandingTildeInPath]];
    NSFileManager *fm = [NSFileManager defaultManager];
    NSString *withSuffix = [name hasSuffix:@".app"] ? name : [name stringByAppendingString:@".app"];
    for (NSString *root in roots) {
        NSString *direct = [root stringByAppendingPathComponent:withSuffix];
        if ([fm fileExistsAtPath:direct]) return [NSURL fileURLWithPath:direct];
    }
    // 再宽松一轮：显示名匹配（"Google Chrome" vs "Chrome"）
    for (NSString *root in roots) {
        for (NSString *entry in [fm contentsOfDirectoryAtPath:root error:nil]) {
            if (![entry hasSuffix:@".app"]) continue;
            NSString *base = entry.stringByDeletingPathExtension;
            if ([base caseInsensitiveCompare:name] == NSOrderedSame ||
                [base rangeOfString:name options:NSCaseInsensitiveSearch].location != NSNotFound) {
                return [NSURL fileURLWithPath:[root stringByAppendingPathComponent:entry]];
            }
        }
    }
    return nil;
}

/// 名字比对。**必须先判空**：ObjC 里给 nil 发消息返回 0，而 0 就是
/// NSOrderedSame——`[app.bundleIdentifier caseInsensitiveCompare:@"Safari"]`
/// 在 bundleIdentifier 为 nil 的后台守护进程上会"匹配成功"。实测就是这样把
/// Safari 解析成了 /usr/sbin/universalaccessd，然后一路报"这个应用不支持脚本"。
- (BOOL)name:(NSString *)candidate matches:(NSString *)wanted {
    if (!candidate.length || !wanted.length) return NO;
    return [candidate caseInsensitiveCompare:wanted] == NSOrderedSame;
}

- (NSRunningApplication *)runningAppNamed:(NSString *)name {
    NSURL *url = [self urlForAppNamed:name];
    NSString *alias = [AutomationController nameAliases][name] ?: name;
    for (NSRunningApplication *app in [[NSWorkspace sharedWorkspace] runningApplications]) {
        // 只认有界面的应用：后台守护进程既没有菜单栏也没有窗口，
        // 匹配上了也只会让后续的菜单/AX 操作报一个莫名其妙的错。
        if (app.activationPolicy != NSApplicationActivationPolicyRegular) continue;
        if (url && [app.bundleURL.path isEqualToString:url.path]) return app;
        if ([self name:app.localizedName matches:name] ||
            [self name:app.localizedName matches:alias]) return app;
    }
    return nil;
}

#pragma mark - 自动化权限预检

/// 目标应用的自动化授权状态。**不预检的话，缺授权的表现是「卡满整个超时」**——
/// Apple Event 会一直等 TCC 的裁决结果，而不是立刻报错。用户看到的是"没反应"，
/// 排查时最容易误判成脚本写错了。
///
/// askUserIfNeeded 传 YES：这个动作是用户刚刚要求的，该弹就弹一次，
/// 授权完这个应用以后都不用再问。返回 nil 表示可以往下走。
- (NSString *)automationBlockedFor:(NSString *)appName {
    if (!appName.length) return nil;
    NSURL *url = [self urlForAppNamed:appName];
    NSBundle *bundle = url ? [NSBundle bundleWithURL:url] : nil;
    NSString *bundleID = bundle.bundleIdentifier;
    if (!bundleID.length) return nil;          // 认不出来就别拦，让脚本自己去报错

    NSAppleEventDescriptor *target =
        [NSAppleEventDescriptor descriptorWithBundleIdentifier:bundleID];
    OSStatus status = AEDeterminePermissionToAutomateTarget(
        target.aeDesc, typeWildCard, typeWildCard, YES);

    switch (status) {
        case noErr:
            return nil;
        case errAEEventNotPermitted:
            return [NSString stringWithFormat:
                    @"没有控制「%@」的权限：系统设置 → 隐私与安全性 → 自动化，"
                    @"把 JARVIS 下面的「%@」打开。%@", appName, appName,
                    AXIsProcessTrusted() ? @"" : @"（重新构建过的话，开关要关掉再打开一次）"];
        case procNotFound: {
            // AppleScript 的 `tell application "X"` 本来就会自己把 X 拉起来，
            // 所以"没在运行"不该是错误——真当错误报，模型就会先去 app_open
            // 再回来重试，白花两步。这里替它把应用拉起来再复检一次权限。
            NSURL *url = [self urlForAppNamed:appName];
            if (!url) return nil;                       // 认不出来就交给脚本自己去报
            NSWorkspaceOpenConfiguration *config = [NSWorkspaceOpenConfiguration configuration];
            config.activates = NO;                      // 别抢用户正在用的窗口
            dispatch_semaphore_t launched = dispatch_semaphore_create(0);
            [[NSWorkspace sharedWorkspace] openApplicationAtURL:url configuration:config
                                              completionHandler:^(NSRunningApplication *app, NSError *error) {
                dispatch_semaphore_signal(launched);
            }];
            dispatch_semaphore_wait(launched,
                                    dispatch_time(DISPATCH_TIME_NOW, (int64_t)(10 * NSEC_PER_SEC)));
            // 进程起来了不等于它已经能收 Apple Event，给它一点时间注册。
            for (int i = 0; i < 20 && ![self runningAppNamed:appName]; i++) {
                [NSThread sleepForTimeInterval:0.25];
            }
            OSStatus again = AEDeterminePermissionToAutomateTarget(
                target.aeDesc, typeWildCard, typeWildCard, YES);
            if (again == errAEEventNotPermitted) {
                return [NSString stringWithFormat:
                        @"没有控制「%@」的权限：系统设置 → 隐私与安全性 → 自动化，"
                        @"把 JARVIS 下面的「%@」打开。", appName, appName];
            }
            return nil;
        }
        default:
            return nil;                        // 其它情况交给脚本本身去报，信息更具体
    }
}

#pragma mark - 脚本执行

- (void)runScript:(NSDictionary *)arguments completion:(JarvisToolCompletion)completion {
    NSString *source = arguments[@"script"];
    if (![source isKindOfClass:[NSString class]] || !source.length) {
        completion(nil, @"缺少 script");
        return;
    }
    NSString *language = arguments[@"language"];
    BOOL isJXA = [language isKindOfClass:[NSString class]] &&
                 ([language caseInsensitiveCompare:@"javascript"] == NSOrderedSame ||
                  [language caseInsensitiveCompare:@"jxa"] == NSOrderedSame);

    if (self.scriptRunning) {
        completion(nil, @"上一段脚本还没结束（可能正卡在某个没响应的应用上），"
                        @"等它超时或换个方式");
        return;
    }

    NSTimeInterval timeout = kScriptCeiling;
    if ([arguments[@"timeout"] respondsToSelector:@selector(doubleValue)]) {
        timeout = MIN(MAX([arguments[@"timeout"] doubleValue], 1.0), kScriptCeiling);
    }

    // 完成回调只能走一次：脚本正常结束和看门狗超时会赛跑。
    __block BOOL settled = NO;
    NSObject *lock = [NSObject new];
    void (^finish)(NSDictionary *, NSString *) = ^(NSDictionary *result, NSString *error) {
        @synchronized (lock) {
            if (settled) return;
            settled = YES;
        }
        completion(result, error);
    };

    self.scriptRunning = YES;
    NSString *targetApp = [arguments[@"app"] isKindOfClass:[NSString class]] ? arguments[@"app"] : nil;
    dispatch_async(self.scriptQueue, ^{
        NSDate *started = [NSDate date];
        NSString *blocked = [self automationBlockedFor:targetApp];
        if (blocked) {
            self.scriptRunning = NO;
            finish(nil, blocked);
            return;
        }
        OSALanguage *osaLanguage = isJXA ? [OSALanguage languageForName:@"JavaScript"]
                                         : [OSALanguage languageForName:@"AppleScript"];
        NSDictionary *scriptError = nil;
        NSAppleEventDescriptor *answer = nil;
        if (!osaLanguage) {
            scriptError = @{OSAScriptErrorMessageKey: isJXA ? @"本机没有 JavaScript for Automation"
                                                            : @"本机没有 AppleScript 组件"};
        } else {
            OSAScript *script = [[OSAScript alloc] initWithSource:source language:osaLanguage];
            answer = [script executeAndReturnError:&scriptError];
        }
        self.scriptRunning = NO;

        if (scriptError) {
            finish(nil, [self describeScriptError:scriptError]);
            return;
        }
        finish(@{@"ok": @YES,
                 @"language": isJXA ? @"javascript" : @"applescript",
                 @"ms": @((NSInteger)([[NSDate date] timeIntervalSinceDate:started] * 1000)),
                 @"result": [self stringFromDescriptor:answer depth:0] ?: @""}, nil);
    });

    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(timeout * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        finish(nil, [NSString stringWithFormat:
                     @"脚本超过 %.0fs 没有返回。它可能还在后台跑，也可能是目标应用弹了"
                     @"对话框在等人点。别重试同一段脚本，先确认那个应用的状态。", timeout]);
    });
}

/// 权限类和"界面还没就绪"类必须分开报，否则排查会一路跑偏。
/// 这几个错误码的含义见 MediaController 里同样的处理。
- (NSString *)describeScriptError:(NSDictionary *)scriptError {
    NSNumber *code = scriptError[OSAScriptErrorNumberKey] ?: scriptError[NSAppleScriptErrorNumber];
    NSString *message = scriptError[OSAScriptErrorMessageKey]
                     ?: scriptError[NSAppleScriptErrorMessage] ?: @"未知错误";
    NSString *hint = AXIsProcessTrusted() ? @"缺少权限"
                                          : @"权限失效了（重新构建过就要在系统设置里关掉再打开一次）";
    switch (code.integerValue) {
        case -1743:
            return [NSString stringWithFormat:@"%@（自动化）：系统设置 → 隐私与安全性 → 自动化，"
                    @"把 JARVIS 下对应的应用打开。%@", hint, message];
        case -25211:
            return [NSString stringWithFormat:@"%@（辅助功能）：系统设置 → 隐私与安全性 → 辅助功能，"
                    @"把 JARVIS 打开", hint];
        case -1719:
        case -1728:
            return [NSString stringWithFormat:@"目标对象还不存在（窗口/菜单没就绪，或名字写错了），"
                    @"这是时序或拼写问题，不是权限：%@", message];
        case -600:
            return @"目标应用没在运行。先用 app_open 打开它。";
        case -1708:
            return [NSString stringWithFormat:@"这个应用不认识这条命令——它可能根本没有脚本字典。"
                    @"先用 app_dictionary 看它支持什么，或改用 menu_invoke / ui_action。%@", message];
        default:
            return [NSString stringWithFormat:@"脚本失败：%@（%@）", message, code ?: @"?"];
    }
}

/// 把 Apple Event 描述符转成人能读、模型也能读的文本。列表和记录递归展开——
/// 直接 `description` 出来的是 <NSAppleEventDescriptor: 'utxt'("…")> 这种噪音。
- (NSString *)stringFromDescriptor:(NSAppleEventDescriptor *)descriptor depth:(NSInteger)depth {
    if (!descriptor || depth > 4) return @"";
    DescType type = descriptor.descriptorType;

    if (type == typeAEList) {
        NSMutableArray *items = [NSMutableArray array];
        for (NSInteger i = 1; i <= descriptor.numberOfItems && i <= 200; i++) {
            NSString *piece = [self stringFromDescriptor:[descriptor descriptorAtIndex:i] depth:depth + 1];
            [items addObject:piece ?: @""];
        }
        return [NSString stringWithFormat:@"[%@]", [items componentsJoinedByString:@", "]];
    }
    if (type == typeAERecord) {
        NSMutableArray *pairs = [NSMutableArray array];
        for (NSInteger i = 1; i <= descriptor.numberOfItems && i <= 100; i++) {
            AEKeyword key = [descriptor keywordForDescriptorAtIndex:i];
            char raw[5] = {0};
            OSType swapped = CFSwapInt32HostToBig(key);
            memcpy(raw, &swapped, 4);
            NSString *value = [self stringFromDescriptor:[descriptor descriptorAtIndex:i] depth:depth + 1];
            [pairs addObject:[NSString stringWithFormat:@"%s: %@", raw, value ?: @""]];
        }
        return [NSString stringWithFormat:@"{%@}", [pairs componentsJoinedByString:@", "]];
    }
    if (type == typeNull) return @"";
    // AppleScript 的 missing value：描述符类型是 'type'（typeType），装着的
    // 四字符码才是 'msng'。菜单分隔线、没填的属性都长这样，不特判的话会显示成
    // 裸的类型码 "(1954115685)"（就是 'type' 的十进制），看着像出错了。
    if (type == typeType) {
        OSType code = descriptor.typeCodeValue;
        if (code == cMissingValue) return @"—";
        char raw[5] = {0};
        OSType swapped = CFSwapInt32HostToBig(code);
        memcpy(raw, &swapped, 4);
        return [NSString stringWithUTF8String:raw] ?: @"—";
    }
    if (type == typeBoolean || type == typeTrue || type == typeFalse) {
        return descriptor.booleanValue ? @"true" : @"false";
    }
    NSString *text = descriptor.stringValue;
    if (text) return text;
    return [NSString stringWithFormat:@"(类型 %@)", @(descriptor.descriptorType)];
}

#pragma mark - 脚本字典

/// sdef(1) 要 Xcode，本机只有 CommandLineTools（且已损坏），所以走 Carbon 的
/// OSACopyScriptingDefinitionFromURL——它正是 sdef 内部用的那个 API，
/// 既能读现代 .sdef，也能把老应用的 'aete' 资源合成出来。
- (void)dictionary:(NSDictionary *)arguments completion:(JarvisToolCompletion)completion {
    NSString *name = arguments[@"app"];
    NSURL *url = [self urlForAppNamed:name];
    if (!url) {
        completion(nil, [NSString stringWithFormat:@"找不到应用「%@」", name ?: @""]);
        return;
    }

    CFDataRef raw = NULL;
    OSAError status = OSACopyScriptingDefinitionFromURL((__bridge CFURLRef)url, 0, &raw);
    if (status != noErr || !raw) {
        if (raw) CFRelease(raw);
        // 状态码必须如实带出来。把"读取失败"一律说成"这个应用不支持脚本"，
        // 会让模型放弃正规接口转去点界面，而真正的原因可能只是路径解析错了。
        completion(@{@"app": name ?: @"",
                     @"path": url.path,
                     @"scriptable": @NO,
                     @"osa_status": @(status),
                     @"note": [NSString stringWithFormat:
                               @"没能读出脚本字典（OSA 状态 %d）。多半是这个应用没有脚本接口，"
                               @"改用 menu_invoke 点菜单，或 ui_inspect + ui_action 操作界面。",
                               (int)status]},
                   nil);
        return;
    }

    NSData *data = (__bridge_transfer NSData *)raw;
    NSError *xmlError = nil;
    NSXMLDocument *document = [[NSXMLDocument alloc] initWithData:data options:0 error:&xmlError];
    if (!document) {
        completion(nil, [NSString stringWithFormat:@"字典解析失败：%@", xmlError.localizedDescription]);
        return;
    }

    NSString *search = [arguments[@"search"] isKindOfClass:[NSString class]] ? arguments[@"search"] : nil;
    NSMutableString *out = [NSMutableString string];
    NSInteger commandCount = 0, classCount = 0;
    BOOL truncated = NO;

    for (NSXMLElement *suite in [document.rootElement elementsForName:@"suite"]) {
        NSMutableString *section = [NSMutableString string];
        for (NSXMLElement *command in [suite elementsForName:@"command"]) {
            NSString *line = [self lineForCommand:command detailed:(search != nil)];
            if (search && ![line localizedCaseInsensitiveContainsString:search]) continue;
            [section appendFormat:@"  %@\n", line];
            commandCount++;
        }
        for (NSXMLElement *klass in [suite elementsForName:@"class"]) {
            NSString *line = [self lineForClass:klass detailed:(search != nil)];
            if (search && ![line localizedCaseInsensitiveContainsString:search]) continue;
            [section appendFormat:@"  %@\n", line];
            classCount++;
        }
        if (!section.length) continue;
        NSString *suiteName = [[suite attributeForName:@"name"] stringValue] ?: @"suite";
        [out appendFormat:@"[%@]\n%@", suiteName, section];
        if (out.length > kMaxDictionaryChars) { truncated = YES; break; }
    }

    if (!out.length) {
        [out appendString:search.length ? @"（没有匹配的命令或类，去掉 search 看全部）"
                                        : @"（字典是空的）"];
    }
    NSString *body = out.length > kMaxDictionaryChars
        ? [[out substringToIndex:kMaxDictionaryChars] stringByAppendingString:@"\n…（已截断，用 search 缩小范围）"]
        : out;

    completion(@{@"app": name ?: @"",
                 @"path": url.path,
                 @"scriptable": @YES,
                 @"commands": @(commandCount),
                 @"classes": @(classCount),
                 @"truncated": @(truncated),
                 @"dictionary": body}, nil);
}

- (NSString *)lineForCommand:(NSXMLElement *)command detailed:(BOOL)detailed {
    NSString *name = [[command attributeForName:@"name"] stringValue] ?: @"?";
    NSString *description = [[command attributeForName:@"description"] stringValue] ?: @"";
    NSMutableString *line = [NSMutableString stringWithFormat:@"命令 %@", name];

    NSXMLElement *direct = [command elementsForName:@"direct-parameter"].firstObject;
    if (direct) {
        NSString *type = [[direct attributeForName:@"type"] stringValue] ?: @"any";
        [line appendFormat:@" <%@>", type];
    }
    NSArray<NSXMLElement *> *parameters = [command elementsForName:@"parameter"];
    if (parameters.count) {
        NSMutableArray *names = [NSMutableArray array];
        for (NSXMLElement *parameter in parameters) {
            NSString *pname = [[parameter attributeForName:@"name"] stringValue] ?: @"?";
            if (detailed) {
                NSString *type = [[parameter attributeForName:@"type"] stringValue] ?: @"any";
                BOOL optional = [[[parameter attributeForName:@"optional"] stringValue] isEqualToString:@"yes"];
                [names addObject:[NSString stringWithFormat:@"%@:%@%@", pname, type, optional ? @"?" : @""]];
            } else {
                [names addObject:pname];
            }
        }
        [line appendFormat:@" (%@)", [names componentsJoinedByString:@", "]];
    }
    if (description.length) [line appendFormat:@" — %@", description];
    return line;
}

- (NSString *)lineForClass:(NSXMLElement *)klass detailed:(BOOL)detailed {
    NSString *name = [[klass attributeForName:@"name"] stringValue] ?: @"?";
    NSMutableString *line = [NSMutableString stringWithFormat:@"类 %@", name];
    NSArray<NSXMLElement *> *properties = [klass elementsForName:@"property"];
    if (properties.count) {
        NSMutableArray *names = [NSMutableArray array];
        NSInteger cap = detailed ? 40 : 12;
        for (NSXMLElement *property in properties) {
            if (names.count >= cap) { [names addObject:@"…"]; break; }
            NSString *pname = [[property attributeForName:@"name"] stringValue] ?: @"?";
            if (detailed) {
                NSString *access = [[property attributeForName:@"access"] stringValue];
                [names addObject:access.length ? [NSString stringWithFormat:@"%@(%@)", pname, access] : pname];
            } else {
                [names addObject:pname];
            }
        }
        [line appendFormat:@"：%@", [names componentsJoinedByString:@", "]];
    }
    return line;
}

/// 本机哪些应用能用 AppleScript 驱动。判据用 Info.plist 里的两个声明位，
/// 比逐个去拷字典快得多（拷字典要解压 bundle 资源，几十个 App 会明显卡顿）。
- (NSDictionary *)scriptableApps:(NSDictionary *)arguments {
    NSArray<NSString *> *roots = @[@"/Applications", @"/Applications/Utilities",
                                   @"/System/Applications", @"/System/Applications/Utilities",
                                   [@"~/Applications" stringByExpandingTildeInPath]];
    NSString *filter = [arguments[@"filter"] isKindOfClass:[NSString class]] ? arguments[@"filter"] : nil;
    NSFileManager *fm = [NSFileManager defaultManager];
    NSMutableArray *found = [NSMutableArray array];

    NSMutableSet *runningNames = [NSMutableSet set];
    for (NSRunningApplication *app in [[NSWorkspace sharedWorkspace] runningApplications]) {
        if (app.localizedName) [runningNames addObject:app.localizedName];
    }

    for (NSString *root in roots) {
        for (NSString *entry in [[fm contentsOfDirectoryAtPath:root error:nil]
                                 sortedArrayUsingSelector:@selector(compare:)]) {
            if (![entry hasSuffix:@".app"]) continue;
            NSString *full = [root stringByAppendingPathComponent:entry];
            NSDictionary *info = [NSDictionary dictionaryWithContentsOfFile:
                                  [full stringByAppendingPathComponent:@"Contents/Info.plist"]];
            if (!info) continue;
            BOOL enabled = [info[@"NSAppleScriptEnabled"] boolValue] ||
                           [info[@"NSAppleScriptEnabled"] isEqual:@"YES"] ||
                           info[@"OSAScriptingDefinition"] != nil;
            if (!enabled) continue;
            NSString *base = entry.stringByDeletingPathExtension;
            if (filter.length && [base rangeOfString:filter options:NSCaseInsensitiveSearch].location == NSNotFound) {
                continue;
            }
            [found addObject:@{@"name": base,
                               @"path": full,
                               @"running": @([runningNames containsObject:base])}];
        }
    }
    return @{@"count": @(found.count),
             @"apps": found,
             @"note": @"只列出声明了脚本接口的应用。没列出来的用 menu_invoke 或 ui_action。"};
}

#pragma mark - 菜单

/// 菜单是"没有脚本字典的 App"最可靠的控制面：菜单项的名字就是它的能力清单，
/// 而且这条路走的是 System Events 的辅助功能接口，不需要目标应用配合。
- (NSString *)menuTargetExpression:(NSArray<NSString *> *)path {
    NSString *expression = [NSString stringWithFormat:@"menu bar item \"%@\" of menu bar 1",
                            [self escape:path.firstObject]];
    for (NSInteger i = 1; i < (NSInteger)path.count; i++) {
        expression = [NSString stringWithFormat:@"menu item \"%@\" of menu 1 of %@",
                      [self escape:path[i]], expression];
    }
    return expression;
}

- (NSString *)escape:(NSString *)value {
    return [[value ?: @"" stringByReplacingOccurrencesOfString:@"\\" withString:@"\\\\"]
            stringByReplacingOccurrencesOfString:@"\"" withString:@"\\\""];
}

- (void)listMenus:(NSDictionary *)arguments completion:(JarvisToolCompletion)completion {
    NSString *name = arguments[@"app"];
    NSRunningApplication *app = [self runningAppNamed:name];
    if (!app) {
        completion(nil, [NSString stringWithFormat:@"「%@」没在运行。先用 app_open 打开它。", name ?: @""]);
        return;
    }
    NSString *process = app.localizedName ?: name;
    NSString *menu = [arguments[@"menu"] isKindOfClass:[NSString class]] ? arguments[@"menu"] : nil;

    NSString *source;
    if (menu.length) {
        source = [NSString stringWithFormat:
            @"tell application \"System Events\" to tell process \"%@\"\n"
             "return name of every menu item of menu 1 of menu bar item \"%@\" of menu bar 1\n"
             "end tell", [self escape:process], [self escape:menu]];
    } else {
        source = [NSString stringWithFormat:
            @"tell application \"System Events\" to tell process \"%@\"\n"
             "return name of every menu bar item of menu bar 1\n"
             "end tell", [self escape:process]];
    }

    [self runScript:@{@"script": source, @"timeout": @15, @"app": @"System Events"}
         completion:^(NSDictionary *result, NSString *error) {
        if (error) { completion(nil, error); return; }
        completion(@{@"app": process,
                     @"menu": menu ?: @"（顶层）",
                     @"items": result[@"result"] ?: @"",
                     @"note": menu.length ? @"用 menu_invoke 传 path 点其中一项"
                                          : @"再调一次并传 menu 参数可以看某个菜单里的项"}, nil);
    }];
}

- (void)invokeMenu:(NSDictionary *)arguments completion:(JarvisToolCompletion)completion {
    NSString *name = arguments[@"app"];
    NSArray *path = arguments[@"path"];
    if (![path isKindOfClass:[NSArray class]] || path.count == 0) {
        completion(nil, @"缺少 path（菜单路径，如 [\"文件\", \"新建标签页\"]）");
        return;
    }
    for (id item in path) {
        if (![item isKindOfClass:[NSString class]]) {
            completion(nil, @"path 里必须都是字符串");
            return;
        }
    }
    NSRunningApplication *app = [self runningAppNamed:name];
    if (!app) {
        completion(nil, [NSString stringWithFormat:@"「%@」没在运行。先用 app_open 打开它。", name ?: @""]);
        return;
    }

    // 后台应用的菜单常常点不动（菜单栏根本没构建）。默认先激活；
    // 明确传 activate=false 才跳过——这会抢焦点，是有代价的，所以说清楚。
    BOOL activate = arguments[@"activate"] ? [arguments[@"activate"] boolValue] : YES;
    if (activate) {
        [app activateWithOptions:NSApplicationActivateIgnoringOtherApps];
        [NSThread sleepForTimeInterval:0.35];
    }

    NSString *process = app.localizedName ?: name;
    NSString *source = [NSString stringWithFormat:
        @"tell application \"System Events\" to tell process \"%@\"\n"
         "click %@\n"
         "end tell", [self escape:process], [self menuTargetExpression:path]];

    [self runScript:@{@"script": source, @"timeout": @20, @"app": @"System Events"}
         completion:^(NSDictionary *result, NSString *error) {
        if (error) { completion(nil, error); return; }
        completion(@{@"app": process,
                     @"path": [path componentsJoinedByString:@" → "],
                     @"clicked": @YES,
                     @"note": @"已点击。菜单项点了不等于事情做成了——需要确认结果就再读一次状态。"}, nil);
    }];
}

#pragma mark - 辅助功能

- (AXUIElementRef)rootElementForApp:(NSRunningApplication *)app CF_RETURNS_RETAINED {
    AXUIElementRef application = AXUIElementCreateApplication(app.processIdentifier);
    if (!application) return NULL;
    // 优先聚焦窗口，其次第一个窗口，都没有就返回应用本身（菜单栏还是能看到的）
    CFTypeRef window = NULL;
    if (AXUIElementCopyAttributeValue(application, kAXFocusedWindowAttribute, &window) == kAXErrorSuccess
        && window) {
        CFRelease(application);
        return (AXUIElementRef)window;
    }
    CFTypeRef windows = NULL;
    if (AXUIElementCopyAttributeValue(application, kAXWindowsAttribute, &windows) == kAXErrorSuccess
        && windows) {
        NSArray *list = (__bridge_transfer NSArray *)windows;
        if (list.count) {
            AXUIElementRef first = (__bridge AXUIElementRef)list.firstObject;
            CFRetain(first);
            CFRelease(application);
            return first;
        }
    }
    return application;
}

- (NSString *)stringAttribute:(CFStringRef)attribute of:(AXUIElementRef)element {
    CFTypeRef value = NULL;
    if (AXUIElementCopyAttributeValue(element, attribute, &value) != kAXErrorSuccess || !value) return nil;
    NSString *text = nil;
    if (CFGetTypeID(value) == CFStringGetTypeID()) {
        text = (__bridge NSString *)value;
    } else if (CFGetTypeID(value) == CFNumberGetTypeID() || CFGetTypeID(value) == CFBooleanGetTypeID()) {
        text = [(__bridge id)value description];
    }
    NSString *copy = text.length ? [text copy] : nil;
    CFRelease(value);
    if (copy.length > 160) copy = [[copy substringToIndex:160] stringByAppendingString:@"…"];
    return copy;
}

- (void)walkElement:(AXUIElementRef)element
               path:(NSString *)path
              depth:(NSInteger)depth
           maxDepth:(NSInteger)maxDepth
               into:(NSMutableArray *)nodes {
    if (nodes.count >= kMaxUINodes || depth > maxDepth) return;

    NSString *role = [self stringAttribute:kAXRoleAttribute of:element] ?: @"?";
    NSString *title = [self stringAttribute:kAXTitleAttribute of:element];
    NSString *value = [self stringAttribute:kAXValueAttribute of:element];
    NSString *label = [self stringAttribute:kAXDescriptionAttribute of:element];

    // 纯容器（没有标题、值、说明的 group/scroll area）本身不可操作，
    // 列出来只会把节点预算吃光——跳过它自己，但仍然往下走。
    BOOL informative = title.length || value.length || label.length ||
                       [role isEqualToString:@"AXButton"] || [role isEqualToString:@"AXTextField"] ||
                       [role isEqualToString:@"AXTextArea"] || [role isEqualToString:@"AXCheckBox"];
    if (informative && path.length) {
        NSMutableDictionary *node = [NSMutableDictionary dictionaryWithObject:role forKey:@"role"];
        node[@"path"] = path;
        if (title.length) node[@"title"] = title;
        if (label.length) node[@"label"] = label;
        if (value.length) node[@"value"] = value;

        CFArrayRef actions = NULL;
        if (AXUIElementCopyActionNames(element, &actions) == kAXErrorSuccess && actions) {
            NSArray *names = (__bridge_transfer NSArray *)actions;
            if ([names containsObject:(__bridge NSString *)kAXPressAction]) node[@"pressable"] = @YES;
        }

        // 屏幕坐标。Qt 之类的应用 AXPress 是空操作，只能靠真实鼠标事件点，
        // 而那需要知道元素在屏幕上的位置——所以坐标是必须采的，不是锦上添花。
        CGPoint origin = CGPointZero;
        CGSize size = CGSizeZero;
        CFTypeRef posValue = NULL, sizeValue = NULL;
        BOOL hasFrame = NO;
        if (AXUIElementCopyAttributeValue(element, kAXPositionAttribute, &posValue) == kAXErrorSuccess
            && posValue) {
            hasFrame = AXValueGetValue((AXValueRef)posValue, kAXValueCGPointType, &origin);
            CFRelease(posValue);
        }
        if (hasFrame &&
            AXUIElementCopyAttributeValue(element, kAXSizeAttribute, &sizeValue) == kAXErrorSuccess
            && sizeValue) {
            AXValueGetValue((AXValueRef)sizeValue, kAXValueCGSizeType, &size);
            CFRelease(sizeValue);
        }
        if (hasFrame && size.width > 0 && size.height > 0) {
            node[@"frame"] = @{@"x": @((NSInteger)origin.x), @"y": @((NSInteger)origin.y),
                               @"w": @((NSInteger)size.width), @"h": @((NSInteger)size.height)};
        }
        [nodes addObject:node];
    }

    CFTypeRef children = NULL;
    if (AXUIElementCopyAttributeValue(element, kAXChildrenAttribute, &children) != kAXErrorSuccess
        || !children) return;
    NSArray *list = (__bridge_transfer NSArray *)children;
    for (NSInteger i = 0; i < (NSInteger)list.count; i++) {
        if (nodes.count >= kMaxUINodes) return;
        NSString *childPath = path.length ? [NSString stringWithFormat:@"%@/%ld", path, (long)i]
                                          : [NSString stringWithFormat:@"%ld", (long)i];
        [self walkElement:(__bridge AXUIElementRef)list[i]
                     path:childPath depth:depth + 1 maxDepth:maxDepth into:nodes];
    }
}


/// 图标字体按钮的标题是私用区码位（钉钉侧边栏的按钮标题就是 U+F281 这种），
/// 对模型完全没有意义——它只能看见一个方框，于是转头去点旁边那行看得懂的文字，
/// 而那行文字是 AXStaticText，点了没反应。日志里模型反复"点日志点不动"就是这么来的。
///
/// 真实结构是**图标按钮和文字标签是兄弟**：
///     11/5/0/7/0/0  AXButton      title=U+F281
///     11/5/0/7/0/1  AXStaticText  value=待办
/// 所以给没有可读标题的按钮补一个 inferred_label：在同一个父节点下找最近的静态文字。

/// 往当前焦点敲一段文字。
///
/// ⚠️ 为什么不用 set_value：和 AXPress 是同一类问题。Qt 应用对 AX 的写入支持同样
/// 残缺——钉钉日志页那几个输入框连 **读** 都读不回来（AXValue 是空的，内容却明明
/// 显示在界面上），写进去更没有保证。键盘事件是所有应用都必须处理的东西。
///
/// 用 CGEventKeyboardSetUnicodeString 直接送 Unicode，**不做键位映射**：
/// 键位映射要依赖当前输入法和键盘布局，中文根本没法映射，而这个接口是绕过
/// 键盘布局直接投递字符的。
///
/// 分块送：一次投递的字符数太多会被丢，实测按 20 个字符一批稳定。

/// 键盘事件专用的事件源。
///
/// ⚠️ **不能用 NULL 源 + kCGHIDEventTap 投递键盘事件**——那是唯一失效的组合。
/// keycode 传 0 时，HID 层会拿当前键盘布局把这个键位重新翻译一遍，
/// **把 CGEventKeyboardSetUnicodeString 设的字符串覆盖掉**，结果是什么都不出现、
/// 也不报错。鼠标事件不走布局翻译，所以 click 一直是好的，只有打字受影响。
///
/// 五种组合实测（/tmp/keytest.m，往 TextEdit 敲）：
///     source=NULL    tap=HID      ✗
///     source=HID     tap=HID      ✗
///     source=Private tap=HID      ✓
///     source=NULL    tap=Session  ✓
///     source=Private tap=Session  ✓
/// 选 Private + Session：两个维度都避开了重翻译。
static CGEventSourceRef JarvisKeyboardSource(void) {
    static CGEventSourceRef source = NULL;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        source = CGEventSourceCreate(kCGEventSourceStatePrivate);
    });
    return source;
}

/// 发一次带修饰键的按键。用于把光标移到文末（⌘↓）或全选（⌘A）。
- (void)postKey:(CGKeyCode)code flags:(CGEventFlags)flags {
    CGEventSourceRef source = JarvisKeyboardSource();
    CGEventRef down = CGEventCreateKeyboardEvent(source, code, true);
    CGEventRef up = CGEventCreateKeyboardEvent(source, code, false);
    if (down) { CGEventSetFlags(down, flags); CGEventPost(kCGSessionEventTap, down); CFRelease(down); }
    [NSThread sleepForTimeInterval:0.02];
    if (up) { CGEventSetFlags(up, flags); CGEventPost(kCGSessionEventTap, up); CFRelease(up); }
}

- (void)typeText:(NSDictionary *)arguments completion:(JarvisToolCompletion)completion {
    if (!AXIsProcessTrusted()) {
        completion(nil, @"没有辅助功能权限：系统设置 → 隐私与安全性 → 辅助功能，把 JARVIS 打开");
        return;
    }
    NSString *text = arguments[@"text"];
    if (![text isKindOfClass:[NSString class]] || !text.length) {
        completion(nil, @"缺少 text");
        return;
    }
    NSString *appName = arguments[@"app"];
    if ([appName isKindOfClass:[NSString class]] && appName.length) {
        NSRunningApplication *app = [self runningAppNamed:appName];
        if (!app) {
            completion(nil, [NSString stringWithFormat:@"「%@」没在运行。", appName]);
            return;
        }
        // 键盘事件发给**当前前台应用**，目标不在前台就是往别人窗口里乱敲字。
        if (![self bringToFront:app]) {
            completion(nil, [NSString stringWithFormat:@"没能把「%@」切到前台，"
                             @"这时候敲字会敲进别的应用里，已放弃", appName]);
            return;
        }
    }

    // ⚠️ 追加 vs 覆盖。用户反馈过一次真实的数据丢失：让 Jarvis「往日志里加一条新内容」，
    // 它把已有内容全删了只留新的。原因是敲字前光标位置不确定，而模型为了"确保写对"
    // 会先全选——全选之后敲字就是覆盖。
    // 所以把意图变成显式参数，默认 append（在末尾接着写），**不是** replace。
    // 默认值选 append 而不是 insert：insert 依赖光标恰好在对的位置，
    // 那是不可控的；而"在末尾追加"对"补充内容"这个最常见的诉求永远是对的。
    NSString *mode = [arguments[@"mode"] isKindOfClass:[NSString class]] ? arguments[@"mode"] : @"append";
    if ([mode isEqualToString:@"replace"]) {
        [self postKey:0 flags:kCGEventFlagMaskCommand];          // ⌘A 全选，下一次输入即覆盖
        [NSThread sleepForTimeInterval:0.08];
    } else if ([mode isEqualToString:@"append"]) {
        [self postKey:125 flags:kCGEventFlagMaskCommand];        // ⌘↓ 移到**整个文档**末尾
        [NSThread sleepForTimeInterval:0.08];
    } else if ([mode isEqualToString:@"line_end"]) {
        // ⚠️ 分栏表单（钉钉日报这种一页里有好几个栏目的）**必须用这个，不能用 append**。
        // append 是 ⌘↓ = 跳到整个文档末尾，在分栏表单里意味着字落到最后一栏去了，
        // 而用户要写的是中间某一栏。用户实测就撞了这个：报告"字输进去了但不确定
        // 进了哪个板块"——它确实进去了，只是进错了栏。
        // 正确做法是先点中目标栏的现有文字（光标就落在那一栏），再 ⌘→ 到本行末尾。
        [self postKey:124 flags:kCGEventFlagMaskCommand];        // ⌘→ 本行末尾
        [NSThread sleepForTimeInterval:0.08];
    } else if ([mode isEqualToString:@"line_replace"]) {
        // 改写某一栏原有的一行（比如把「无」换成真实内容）：
        // ⌘← 回行首 → ⇧⌘→ 选中整行 → 输入即替换。只动这一行，别的栏目不受影响。
        [self postKey:123 flags:kCGEventFlagMaskCommand];
        [NSThread sleepForTimeInterval:0.05];
        [self postKey:124 flags:kCGEventFlagMaskCommand | kCGEventFlagMaskShift];
        [NSThread sleepForTimeInterval:0.08];
    }
    // insert：什么都不做，在当前光标处插入

    // ⚠️ 换行必须作为独立的回车键发，不能夹在 Unicode 字符串里。
    // 实测：一个字符串里带 \n 时，换行会送达，**后面的字符全部丢掉**——
    // 症状是"多行文本只出现了空行"。所以按行拆开，行与行之间补一次 keycode 36。
    NSArray<NSString *> *lines = [text componentsSeparatedByString:@"\n"];
    NSUInteger chunk = 20;
    for (NSUInteger lineIndex = 0; lineIndex < lines.count; lineIndex++) {
        if (lineIndex > 0) {
            [self postKey:36 flags:0];               // Return
            [NSThread sleepForTimeInterval:0.04];
        }
        NSString *line = lines[lineIndex];
        for (NSUInteger offset = 0; offset < line.length; ) {
            NSRange range = NSMakeRange(offset, MIN(chunk, line.length - offset));
            // 别在代理对（emoji）中间切开，否则送出去的是半个字符。
            range = [line rangeOfComposedCharacterSequencesForRange:range];
            NSString *piece = [line substringWithRange:range];

            NSUInteger length = piece.length;
            unichar *buffer = malloc(sizeof(unichar) * length);
            if (!buffer) { completion(nil, @"内存不足"); return; }
            [piece getCharacters:buffer range:NSMakeRange(0, length)];

            CGEventSourceRef source = JarvisKeyboardSource();
            CGEventRef down = CGEventCreateKeyboardEvent(source, 0, true);
            CGEventRef up = CGEventCreateKeyboardEvent(source, 0, false);
            // ⚠️ 必须显式清空修饰键。私有事件源会保留自己的修饰键状态，
            // append/replace 先发过 ⌘↓ / ⌘A，紧接着的字符事件会**继承那个 Command**，
            // 于是每个字都变成 ⌘+字母 快捷键——不出字，还可能触发菜单命令。
            // 症状是"insert 模式好使、append 模式什么都不出现"。
            if (down) {
                CGEventSetFlags(down, 0);
                CGEventKeyboardSetUnicodeString(down, length, buffer);
                CGEventPost(kCGSessionEventTap, down);
                CFRelease(down);
            }
            if (up) {
                CGEventSetFlags(up, 0);
                CGEventKeyboardSetUnicodeString(up, length, buffer);
                CGEventPost(kCGSessionEventTap, up);
                CFRelease(up);
            }
            free(buffer);
            [NSThread sleepForTimeInterval:0.03];
            offset = NSMaxRange(range);
        }
    }

    // ⚠️ 收尾必须等一下。CGEventPost 是异步投递的，敲完立刻返回的话，
    // `--tool` 这种一次性进程会在事件送达目标应用之前就退出，字就丢了——
    // 症状是"报告 typed=N 但界面上什么都没有"。独立测试程序里因为末尾有 sleep
    // 才看不出来，接进 Jarvis 才暴露。
    [NSThread sleepForTimeInterval:0.25];

    completion(@{@"ok": @YES, @"typed": @(text.length), @"mode": mode,
                 @"note": [NSString stringWithFormat:
                     @"以 %@ 方式敲了 %lu 个字。**一定要再 ui_inspect 确认原有内容还在、"
                     @"新内容也进去了**——焦点不对时这些字会落到别处，而 replace 会把原内容清掉。",
                     mode, (unsigned long)text.length]}, nil);
}

- (void)inferLabelsFor:(NSMutableArray *)nodes {
    NSMutableDictionary<NSString *, NSMutableArray *> *byParent = [NSMutableDictionary dictionary];
    for (NSDictionary *node in nodes) {
        NSString *path = node[@"path"];
        NSRange slash = [path rangeOfString:@"/" options:NSBackwardsSearch];
        NSString *parent = slash.location == NSNotFound ? @"" : [path substringToIndex:slash.location];
        NSMutableArray *bucket = byParent[parent];
        if (!bucket) { bucket = [NSMutableArray array]; byParent[parent] = bucket; }
        [bucket addObject:node];
    }

    for (NSMutableDictionary *node in nodes) {
        if (![node isKindOfClass:[NSMutableDictionary class]]) continue;
        NSString *role = node[@"role"];
        BOOL actionable = [node[@"pressable"] boolValue] || [role isEqualToString:@"AXButton"];
        if (!actionable) continue;
        NSString *readable = [self readableText:node[@"title"]] ?: [self readableText:node[@"label"]]
                          ?: [self readableText:node[@"value"]];
        if (readable.length) continue;              // 本来就有人话标题

        NSString *path = node[@"path"];
        NSRange slash = [path rangeOfString:@"/" options:NSBackwardsSearch];
        NSString *parent = slash.location == NSNotFound ? @"" : [path substringToIndex:slash.location];
        for (NSDictionary *sibling in byParent[parent]) {
            if (sibling == node) continue;
            if (![sibling[@"role"] isEqualToString:@"AXStaticText"]) continue;
            NSString *text = [self readableText:sibling[@"value"]] ?: [self readableText:sibling[@"title"]];
            // 按钮的标签一定是短的。不卡长度的话，标题栏那几个无标题按钮会把窗口
            // 里那一大段静态文字认成自己的名字（实测钉钉窗口右上角三个按钮都被标成了
            // 用户的个性签名），比没有标签更容易误导——模型会拿它当按钮的功能。
            if (text.length && text.length <= 20) { node[@"inferred_label"] = text; break; }
        }
    }
}

/// 去掉私用区码位（U+E000–U+F8FF，图标字体都落在这里）后还剩下东西吗。
- (NSString *)readableText:(NSString *)text {
    if (![text isKindOfClass:[NSString class]] || !text.length) return nil;
    NSMutableString *out = [NSMutableString string];
    [text enumerateSubstringsInRange:NSMakeRange(0, text.length)
                             options:NSStringEnumerationByComposedCharacterSequences
                          usingBlock:^(NSString *piece, NSRange r, NSRange e, BOOL *stop) {
        unichar c = [piece characterAtIndex:0];
        if (c >= 0xE000 && c <= 0xF8FF) return;     // 私用区：图标，不是文字
        [out appendString:piece];
    }];
    NSString *trimmed = [out stringByTrimmingCharactersInSet:
                         [NSCharacterSet whitespaceAndNewlineCharacterSet]];
    return trimmed.length ? trimmed : nil;
}

- (void)inspectUI:(NSDictionary *)arguments completion:(JarvisToolCompletion)completion {
    if (!AXIsProcessTrusted()) {
        completion(nil, @"没有辅助功能权限：系统设置 → 隐私与安全性 → 辅助功能，把 JARVIS 打开");
        return;
    }
    NSString *name = arguments[@"app"];
    NSRunningApplication *app = [self runningAppNamed:name];
    if (!app) {
        completion(nil, [NSString stringWithFormat:@"「%@」没在运行。先用 app_open 打开它。", name ?: @""]);
        return;
    }
    NSInteger depth = [arguments[@"depth"] respondsToSelector:@selector(integerValue)]
        ? [arguments[@"depth"] integerValue] : 6;
    depth = MAX(2, MIN(depth, 12));

    AXUIElementRef root = [self rootElementForApp:app];
    if (!root) {
        completion(nil, @"拿不到这个应用的界面元素（可能没有窗口）");
        return;
    }
    NSMutableArray *nodes = [NSMutableArray array];
    [self walkElement:root path:@"" depth:0 maxDepth:depth into:nodes];
    NSString *windowTitle = [self stringAttribute:kAXTitleAttribute of:root];
    CFRelease(root);
    [self inferLabelsFor:nodes];

    NSInteger total = nodes.count;
    BOOL truncated = nodes.count >= kMaxUINodes;

    // ⚠️ 全量返回是这条通道最大的成本。实测钉钉一次 33KB（约一万 token）——
    // 一个多步任务扫十几次就把上下文撑爆了：历史被压缩顶掉（用户看到的现象是
    // 「他把之前的内容删了重写」）、步数预算烧光、然后撞上限判失败。
    // 三个过滤器都是为了让常见情况只返回几百字节。
    NSString *wanted = [arguments[@"find"] isKindOfClass:[NSString class]] ? arguments[@"find"] : nil;
    if (wanted.length) {
        NSMutableArray *matched = [NSMutableArray array];
        for (NSDictionary *node in nodes) {
            for (NSString *key in @[@"inferred_label", @"title", @"label", @"value"]) {
                NSString *text = node[key];
                if ([text isKindOfClass:[NSString class]] &&
                    [text rangeOfString:wanted options:NSCaseInsensitiveSearch].location != NSNotFound) {
                    [matched addObject:node];
                    break;
                }
            }
        }
        nodes = matched;
    }

    if ([arguments[@"interactive"] boolValue]) {
        NSMutableArray *kept = [NSMutableArray array];
        for (NSDictionary *node in nodes) {
            NSString *role = node[@"role"];
            // 静态文字也留着：Qt 应用里侧边栏入口就是不可 press 的静态文字，
            // 但它有坐标、能用 click 点。把它们滤掉等于把最需要的东西滤掉。
            if ([node[@"pressable"] boolValue] || [role isEqualToString:@"AXButton"] ||
                [role isEqualToString:@"AXTextField"] || [role isEqualToString:@"AXTextArea"] ||
                [role isEqualToString:@"AXCheckBox"] || [role isEqualToString:@"AXStaticText"]) {
                [kept addObject:node];
            }
        }
        nodes = kept;
    }

    NSInteger limit = [arguments[@"limit"] respondsToSelector:@selector(integerValue)]
        ? MAX(1, [arguments[@"limit"] integerValue]) : 60;
    BOOL clipped = NO;
    if ((NSInteger)nodes.count > limit) {
        nodes = [[nodes subarrayWithRange:NSMakeRange(0, limit)] mutableCopy];
        clipped = YES;
    }

    NSMutableDictionary *result = [@{@"app": app.localizedName ?: (name ?: @""),
                                     @"window": windowTitle ?: @"",
                                     @"count": @(nodes.count),
                                     @"total_on_screen": @(total),
                                     @"truncated": @(truncated),
                                     @"elements": nodes} mutableCopy];
    if (clipped) {
        result[@"clipped"] = @YES;
        result[@"note_clipped"] = [NSString stringWithFormat:
            @"只返回了前 %ld 个（屏幕上共 %ld 个）。用 find 按文字缩小范围，别调大 limit——"
            @"整屏元素表很大，塞进上下文会挤掉别的东西。", (long)limit, (long)total];
    }
    result[@"note"] = wanted.length
        ? @"要操作某一项，直接把同样的文字传给 ui_action 的 find，不用再传 path。"
        : @"**下次带 find 参数**（按文字过滤）或 interactive=true，只取需要的那几个——"
          @"整屏返回很大，多扫几次就会把上下文挤爆。要操作某一项，"
          @"直接把它的文字传给 ui_action 的 find。";
    completion(result, nil);
}

- (AXUIElementRef)elementAtPath:(NSString *)path
                           from:(AXUIElementRef)root
                          error:(NSString **)outError CF_RETURNS_RETAINED {
    AXUIElementRef current = root;
    CFRetain(current);
    if (!path.length) return current;

    for (NSString *component in [path componentsSeparatedByString:@"/"]) {
        NSInteger index = component.integerValue;
        CFTypeRef children = NULL;
        if (AXUIElementCopyAttributeValue(current, kAXChildrenAttribute, &children) != kAXErrorSuccess
            || !children) {
            CFRelease(current);
            if (outError) *outError = @"路径走不通：中途某个元素没有子元素。界面可能已经变了，重新 ui_inspect。";
            return NULL;
        }
        NSArray *list = (__bridge_transfer NSArray *)children;
        if (index < 0 || index >= (NSInteger)list.count) {
            CFRelease(current);
            if (outError) *outError = [NSString stringWithFormat:
                @"路径越界（第 %ld 项，实际只有 %lu 个）。界面已经变了，重新 ui_inspect。",
                (long)index, (unsigned long)list.count];
            return NULL;
        }
        AXUIElementRef next = (__bridge AXUIElementRef)list[index];
        CFRetain(next);
        CFRelease(current);
        current = next;
    }
    return current;
}


/// 在元素中心合成一次真实鼠标点击。
///
/// ⚠️ 存在的理由：**Qt 应用的 AXPress 是空操作**。钉钉（Qt 5，Frameworks 里是
/// QtConcurrent/QtNetwork/QtOpenGL）的按钮报告自己 pressable，AXUIElementPerformAction
/// 也返回 success，**但界面什么都不会发生**——实测点侧边栏的图标按钮，前后两次
/// ui_inspect 的文本快照一个字都没变。原始日志里"添加按钮点了但没弹出菜单"是同一回事。
/// 这类应用只认真实的鼠标事件。
///
/// 三条必须遵守的：
///   1. **先把目标应用切到前台**。坐标点击打的是屏幕上那个点，目标窗口在别的窗口
///      底下时，这一下会点进别人的窗口里——那是能造成真实损害的误操作。
///   2. 激活之后**重新读一次坐标**。激活会改变窗口层叠甚至位置，用激活前的坐标点
///      是在赌。
///   3. 点完把鼠标**放回原处**。用户的光标毫无预兆地跳走非常吓人，而且他可能正
///      悬停在别的东西上。

/// 这个点落在某块屏幕里吗。坐标是全局的，多显示器下可能是负数，所以逐屏检查，
/// 不能拿主屏的 frame 去卡。

/// 这个应用现在在前台吗。
///
/// ⚠️ **不能用 `NSRunningApplication.active`**：那是靠 KVO 通知更新的属性，
/// 而通知要 runloop 才会送达。`--tool` 这种一次性进程根本没有 runloop，
/// 于是它永远停在实例创建时的值——表现是"明明已经激活了，仍然报没能切到前台"。
/// 每次实时问 NSWorkspace 拿最新的前台进程，才是可靠的。
- (BOOL)isFrontmost:(NSRunningApplication *)app {
    NSRunningApplication *front = [NSWorkspace sharedWorkspace].frontmostApplication;
    return front && front.processIdentifier == app.processIdentifier;
}

/// 把应用切到前台并等它真的到位。等待期间**必须转 runloop**，
/// 否则激活相关的系统事件送不进来。
- (BOOL)bringToFront:(NSRunningApplication *)app {
    if ([self isFrontmost:app]) return YES;
    [app activateWithOptions:NSApplicationActivateIgnoringOtherApps];
    for (int i = 0; i < 60; i++) {
        [[NSRunLoop currentRunLoop] runUntilDate:[NSDate dateWithTimeIntervalSinceNow:0.025]];
        if ([self isFrontmost:app]) {
            [[NSRunLoop currentRunLoop] runUntilDate:[NSDate dateWithTimeIntervalSinceNow:0.15]];
            return YES;
        }
    }
    return [self isFrontmost:app];
}

- (BOOL)isPointOnScreen:(CGPoint)point {
    CGFloat maxY = NSMaxY([NSScreen screens].firstObject.frame);
    for (NSScreen *screen in [NSScreen screens]) {
        NSRect f = screen.frame;
        // AX 坐标是左上原点，NSScreen 是左下原点，换算一下再比。
        NSRect flipped = NSMakeRect(f.origin.x, maxY - NSMaxY(f), f.size.width, f.size.height);
        if (NSPointInRect(NSMakePoint(point.x, point.y), flipped)) return YES;
    }
    return NO;
}

- (NSString *)clickElement:(AXUIElementRef)element app:(NSRunningApplication *)app {
    [self bringToFront:app];

    CGPoint origin = CGPointZero;
    CGSize size = CGSizeZero;
    CFTypeRef posValue = NULL, sizeValue = NULL;
    if (AXUIElementCopyAttributeValue(element, kAXPositionAttribute, &posValue) != kAXErrorSuccess
        || !posValue) {
        return @"这个元素没有屏幕坐标，没法用鼠标点它";
    }
    BOOL ok = AXValueGetValue((AXValueRef)posValue, kAXValueCGPointType, &origin);
    CFRelease(posValue);
    if (!ok) return @"读不到这个元素的位置";

    if (AXUIElementCopyAttributeValue(element, kAXSizeAttribute, &sizeValue) != kAXErrorSuccess
        || !sizeValue) {
        return @"读不到这个元素的大小";
    }
    AXValueGetValue((AXValueRef)sizeValue, kAXValueCGSizeType, &size);
    CFRelease(sizeValue);

    if (size.width < 1 || size.height < 1) {
        return @"这个元素的尺寸是 0，它可能是隐藏的或者还没布局好";
    }

    CGPoint center = CGPointMake(origin.x + size.width / 2.0, origin.y + size.height / 2.0);

    // ⚠️ 元素滚出可视区时坐标是负的（实测钉钉日报某个栏目在 y=-536），
    // 往那儿点等于什么都没做。用户遇到的"字输进去了但不知道进了哪"很大一部分
    // 来自这里：目标根本不在屏幕上。
    // 先让它滚进来——这一步必须自动做，不能指望调用方先想到要滚屏，
    // 那是白白多花一轮工具调用，而且模型多半想不到。
    if (![self isPointOnScreen:center]) {
        AXUIElementPerformAction(element, CFSTR("AXScrollToVisible"));
        [NSThread sleepForTimeInterval:0.35];
        CFTypeRef again = NULL;
        if (AXUIElementCopyAttributeValue(element, kAXPositionAttribute, &again) == kAXErrorSuccess
            && again) {
            CGPoint moved = CGPointZero;
            if (AXValueGetValue((AXValueRef)again, kAXValueCGPointType, &moved)) {
                origin = moved;
                center = CGPointMake(origin.x + size.width / 2.0, origin.y + size.height / 2.0);
            }
            CFRelease(again);
        }
    }

    if (![self isPointOnScreen:center]) {
        return [NSString stringWithFormat:@"元素中心 (%.0f, %.0f) 不在屏幕上，"
                @"滚动也没能把它带进可视区（可能在折叠区里，或窗口被移出了屏幕）",
                center.x, center.y];
    }

    CGEventRef probe = CGEventCreate(NULL);
    CGPoint restore = probe ? CGEventGetLocation(probe) : CGPointZero;
    if (probe) CFRelease(probe);

    CGEventRef move = CGEventCreateMouseEvent(NULL, kCGEventMouseMoved, center, kCGMouseButtonLeft);
    CGEventRef down = CGEventCreateMouseEvent(NULL, kCGEventLeftMouseDown, center, kCGMouseButtonLeft);
    CGEventRef up   = CGEventCreateMouseEvent(NULL, kCGEventLeftMouseUp, center, kCGMouseButtonLeft);
    if (!move || !down || !up) {
        if (move) CFRelease(move);
        if (down) CFRelease(down);
        if (up) CFRelease(up);
        return @"创建鼠标事件失败";
    }
    CGEventPost(kCGHIDEventTap, move);
    [NSThread sleepForTimeInterval:0.04];          // 让目标先收到 hover，很多控件靠它进入可点状态
    CGEventPost(kCGHIDEventTap, down);
    [NSThread sleepForTimeInterval:0.05];          // 太快的 down/up 会被当成误触丢掉
    CGEventPost(kCGHIDEventTap, up);
    CFRelease(move); CFRelease(down); CFRelease(up);

    [NSThread sleepForTimeInterval:0.08];
    CGEventRef back = CGEventCreateMouseEvent(NULL, kCGEventMouseMoved, restore, kCGMouseButtonLeft);
    if (back) { CGEventPost(kCGHIDEventTap, back); CFRelease(back); }
    return nil;
}


/// 按文字挑一个元素。规则和剧本里的 find 一致：先完全相等再退到包含，
/// 多个候选取文字最短的（最短那个通常是标签本身，长的是把它当子串包含的正文），
/// 并支持用屏幕区域排除同名元素——侧边栏和内容区常常有一模一样的文字。
- (NSDictionary *)bestMatchIn:(NSArray *)nodes for:(NSString *)wanted
                    arguments:(NSDictionary *)arguments {
    NSString *role = [arguments[@"role"] isKindOfClass:[NSString class]] ? arguments[@"role"] : nil;
    NSNumber *xMin = arguments[@"x_min"], *xMax = arguments[@"x_max"];
    NSNumber *yMin = arguments[@"y_min"], *yMax = arguments[@"y_max"];

    NSMutableArray *pool = [NSMutableArray array];
    for (NSDictionary *node in nodes) {
        if (role.length && ![node[@"role"] isEqualToString:role]) continue;
        NSDictionary *frame = node[@"frame"];
        if (xMin && [frame[@"x"] integerValue] < xMin.integerValue) continue;
        if (xMax && [frame[@"x"] integerValue] > xMax.integerValue) continue;
        // 纵向约束用于分栏表单：一页里「无」「请输入」这种占位文字会重复好几次，
        // 只有"在某个栏目标题下面"能把它们区分开。
        if (yMin && [frame[@"y"] integerValue] < yMin.integerValue) continue;
        if (yMax && [frame[@"y"] integerValue] > yMax.integerValue) continue;
        [pool addObject:node];
    }
    // 有纵向下限时按 y 排序，取最靠近它的那个——"标题下面第一个"就是目标。
    if (yMin) {
        [pool sortUsingComparator:^NSComparisonResult(NSDictionary *a, NSDictionary *b) {
            return [a[@"frame"][@"y"] compare:b[@"frame"][@"y"]];
        }];
    }

    NSArray *keys = @[@"inferred_label", @"title", @"label", @"value"];
    NSDictionary *bestPartial = nil;
    NSInteger bestLength = NSIntegerMax;
    for (NSDictionary *node in pool) {
        for (NSString *key in keys) {
            NSString *text = node[key];
            if (![text isKindOfClass:[NSString class]] || !text.length) continue;
            if ([text isEqualToString:wanted]) return node;          // 完全相等，立刻用
            if ([text rangeOfString:wanted].location != NSNotFound &&
                (NSInteger)text.length < bestLength) {
                bestPartial = node;
                bestLength = text.length;
            }
            break;
        }
    }
    return bestPartial;
}

- (void)actUI:(NSDictionary *)arguments completion:(JarvisToolCompletion)completion {
    if (!AXIsProcessTrusted()) {
        completion(nil, @"没有辅助功能权限：系统设置 → 隐私与安全性 → 辅助功能，把 JARVIS 打开");
        return;
    }
    NSString *name = arguments[@"app"];
    NSRunningApplication *app = [self runningAppNamed:name];
    if (!app) {
        completion(nil, [NSString stringWithFormat:@"「%@」没在运行。", name ?: @""]);
        return;
    }
    NSString *path = [arguments[@"path"] isKindOfClass:[NSString class]] ? arguments[@"path"] : @"";
    NSString *action = [arguments[@"action"] isKindOfClass:[NSString class]] ? arguments[@"action"] : @"click";
    NSString *wanted = [arguments[@"find"] isKindOfClass:[NSString class]] ? arguments[@"find"] : nil;

    AXUIElementRef root = [self rootElementForApp:app];
    if (!root) {
        completion(nil, @"拿不到这个应用的界面元素");
        return;
    }

    // find 直接按文字定位，省掉「先 ui_inspect 拿 path 再 ui_action」这一来一回。
    // 那一来一回是工具调用数翻倍的主因，而 inspect 的返回又特别大——
    // 一个多步任务因此很容易撞上步数上限。
    if (wanted.length && !path.length) {
        NSMutableArray *nodes = [NSMutableArray array];
        [self walkElement:root path:@"" depth:0 maxDepth:12 into:nodes];
        [self inferLabelsFor:nodes];
        NSDictionary *hit = [self bestMatchIn:nodes for:wanted arguments:arguments];
        if (!hit) {
            NSMutableArray *nearby = [NSMutableArray array];
            for (NSDictionary *node in nodes) {
                NSString *text = node[@"inferred_label"] ?: node[@"title"] ?: node[@"value"];
                if (text.length && nearby.count < 25 && ![nearby containsObject:text]) {
                    [nearby addObject:text];
                }
            }
            CFRelease(root);
            completion(nil, [NSString stringWithFormat:
                @"界面上找不到「%@」。当前能看到的有：%@", wanted,
                [nearby componentsJoinedByString:@"、"]]);
            return;
        }
        path = hit[@"path"];
    }

    if (!path.length) {
        CFRelease(root);
        completion(nil, @"要么给 find（按文字找，推荐），要么给 path");
        return;
    }

    NSString *failure = nil;
    AXUIElementRef target = [self elementAtPath:path from:root error:&failure];
    CFRelease(root);
    if (!target) {
        completion(nil, failure ?: @"找不到目标元素");
        return;
    }

    NSString *role = [self stringAttribute:kAXRoleAttribute of:target] ?: @"?";
    NSString *title = [self stringAttribute:kAXTitleAttribute of:target] ?: @"";
    AXError status = kAXErrorSuccess;

    if ([action isEqualToString:@"click"]) {
        NSString *clickError = [self clickElement:target app:app];
        CFRelease(target);
        if (clickError) { completion(nil, clickError); return; }
        completion(@{@"ok": @YES, @"action": @"click", @"path": path,
                     @"role": role, @"title": title,
                     @"note": @"用真实鼠标事件点的。界面有没有真的变化要再 ui_inspect 一次确认——"
                              @"点在正确的坐标上不等于那里就有响应。"}, nil);
        return;
    } else if ([action isEqualToString:@"press"]) {
        status = AXUIElementPerformAction(target, kAXPressAction);
    } else if ([action isEqualToString:@"focus"]) {
        status = AXUIElementSetAttributeValue(target, kAXFocusedAttribute, kCFBooleanTrue);
    } else if ([action isEqualToString:@"set_value"]) {
        NSString *value = arguments[@"value"];
        if (![value isKindOfClass:[NSString class]]) {
            CFRelease(target);
            completion(nil, @"set_value 需要 value");
            return;
        }
        status = AXUIElementSetAttributeValue(target, kAXValueAttribute, (__bridge CFStringRef)value);
    } else {
        CFRelease(target);
        completion(nil, [NSString stringWithFormat:@"不支持的动作：%@（press / focus / set_value）", action]);
        return;
    }

    NSString *readback = [self stringAttribute:kAXValueAttribute of:target];
    CFRelease(target);

    if (status != kAXErrorSuccess) {
        NSString *reason;
        switch (status) {
            case kAXErrorAPIDisabled: reason = @"辅助功能权限没开"; break;
            case kAXErrorActionUnsupported: reason = @"这个元素不支持这个动作"; break;
            case kAXErrorAttributeUnsupported: reason = @"这个元素没有这个属性（多半是只读的）"; break;
            case kAXErrorInvalidUIElement: reason = @"元素已经失效，界面变过了，重新 ui_inspect"; break;
            case kAXErrorCannotComplete: reason = @"应用没有响应"; break;
            default: reason = [NSString stringWithFormat:@"AXError %d", (int)status]; break;
        }
        completion(nil, [NSString stringWithFormat:@"操作失败：%@", reason]);
        return;
    }

    completion(@{@"app": app.localizedName ?: (name ?: @""),
                 @"path": path,
                 @"role": role,
                 @"title": title,
                 @"action": action,
                 // 回读当前值：做没做成只能看结果，不能看"调用没报错"
                 @"value_now": readback ?: @"",
                 @"ok": @YES}, nil);
}


#pragma mark - 浏览器控制
//
//  为什么需要它：桌面版应用不是都能驱动的。钉钉是 Qt 应用（Frameworks 里是
//  QtConcurrent/QtNetwork/QtOpenGL），既没有脚本字典，Qt 的 macOS AX 桥接又
//  把大量控件暴露成 static text 而不是 button——`ui_action` 在它上面点不中，
//  不是代码不够好，是那条通道本身就是残的。这类应用的网页版反而是完整可控的。
//
//  通道走浏览器的 AppleScript 字典（Chrome 的 `execute … javascript`、
//  Safari 的 `do JavaScript … in`）。没有走 CDP（--remote-debugging-port），
//  因为那要求用户改浏览器的启动方式并重启，还会让任何本地进程都能接管浏览器；
//  AppleScript 这条路受 TCC 管，权限归属清楚，且不用动用户的日常浏览器。
//
//  ⚠️ 这条通道默认是关的，要用户手动开一次：
//     Chrome：查看 → 开发者 → 允许 Apple 事件中的 JavaScript
//     Safari：开发 → 允许 Apple 事件中的 JavaScript（先在设置里打开"开发"菜单）
//  关着的时候报错文案很具体，必须原样转达而不是笼统说"失败了"——
//  这是一次性设置，说清楚用户点一下就好了。

static NSString *const kChromeName = @"Google Chrome";
static NSString *const kSafariName = @"Safari";

/// JS 执行失败时的标记。Chrome 对抛异常的脚本返回 `missing value`，
/// AppleScript 侧看起来和"成功但没有返回值"一模一样——**静默失败**。
/// 实测踩过：browser_eval 里写了顶层 return（eval 不允许），结果报 ok=true、
/// 值是空的，看着像页面上真没这个东西。所以一律用 try/catch 兜住再把错带回来。
static NSString *const kJSErrorMarker = @"__JARVIS_JS_ERROR__";

/// 把一段 JS **语句**包成带错误捕获的 IIFE。source 里可以直接写 return。
static NSString *JarvisGuardJS(NSString *source) {
    return [NSString stringWithFormat:
            @"(function(){try{\n%@\n}catch(e){return '%@'+(e&&e.message?e.message:String(e));}})()",
            source, kJSErrorMarker];
}

/// JS 源码用 base64 塞进 AppleScript。
/// 直接内联的话要同时逃 AppleScript 的引号/反斜杠和 JS 自己的引号，
/// 嵌套两层转义写出来没人看得懂，而且 JS 里但凡出现一个引号就会炸。
/// base64 之后只剩 [A-Za-z0-9+/=]，两边都不需要转义。
static NSString *JarvisWrapJS(NSString *source) {
    NSData *data = [source dataUsingEncoding:NSUTF8StringEncoding];
    return [NSString stringWithFormat:@"eval(decodeURIComponent(escape(atob('%@'))))",
            [data base64EncodedStringWithOptions:0]];
}

/// 浏览器名归一。默认挑一个"正在运行的"，都没开就用 Chrome。
- (NSString *)resolveBrowser:(NSDictionary *)arguments {
    NSString *wanted = arguments[@"browser"];
    if ([wanted isKindOfClass:[NSString class]] && wanted.length) {
        if ([wanted rangeOfString:@"safari" options:NSCaseInsensitiveSearch].location != NSNotFound) {
            return kSafariName;
        }
        return kChromeName;
    }
    for (NSRunningApplication *app in [NSWorkspace sharedWorkspace].runningApplications) {
        NSString *bundleID = app.bundleIdentifier;
        if (!bundleID) continue;          // 后台守护进程的 bundleIdentifier 是 nil
        if ([bundleID isEqualToString:@"com.google.Chrome"]) return kChromeName;
        if ([bundleID isEqualToString:@"com.apple.Safari"]) return kSafariName;
    }
    return kChromeName;
}

/// 指定哪个标签页。不传就是当前标签页。
- (NSString *)tabExpressionFor:(NSString *)browser arguments:(NSDictionary *)arguments {
    BOOL safari = [browser isEqualToString:kSafariName];
    id window = arguments[@"window"];
    id tab = arguments[@"tab"];
    NSString *windowExpr = [window respondsToSelector:@selector(integerValue)] && [window integerValue] > 0
        ? [NSString stringWithFormat:@"window %ld", (long)[window integerValue]]
        : @"front window";
    if ([tab respondsToSelector:@selector(integerValue)] && [tab integerValue] > 0) {
        return [NSString stringWithFormat:@"tab %ld of %@", (long)[tab integerValue], windowExpr];
    }
    return [NSString stringWithFormat:@"%@ of %@", safari ? @"current tab" : @"active tab", windowExpr];
}

/// 把一段 JS 送进浏览器执行，回调拿到的是 JS 的返回值字符串。
- (void)evaluateJS:(NSString *)js
           browser:(NSString *)browser
         arguments:(NSDictionary *)arguments
        completion:(void (^)(NSString *value, NSString *error))completion {

    NSString *tabExpr = [self tabExpressionFor:browser arguments:arguments];
    NSString *wrapped = JarvisWrapJS(js);
    NSString *script;
    if ([browser isEqualToString:kSafariName]) {
        script = [NSString stringWithFormat:
                  @"tell application \"Safari\"\n"
                  @"  if (count of windows) = 0 then error \"浏览器没有打开的窗口\" number -1728\n"
                  @"  do JavaScript \"%@\" in %@\n"
                  @"end tell", wrapped, tabExpr];
    } else {
        script = [NSString stringWithFormat:
                  @"tell application \"Google Chrome\"\n"
                  @"  if (count of windows) = 0 then error \"浏览器没有打开的窗口\" number -1728\n"
                  @"  execute %@ javascript \"%@\"\n"
                  @"end tell", tabExpr, wrapped];
    }
    [self runRawScript:script app:browser completion:^(NSString *value, NSString *error) {
        if (error) { completion(nil, error); return; }
        if ([value hasPrefix:kJSErrorMarker]) {
            completion(nil, [NSString stringWithFormat:@"页面里的 JavaScript 报错：%@",
                             [value substringFromIndex:kJSErrorMarker.length]]);
            return;
        }
        // chrome:// 、扩展页面和 Chrome 网上应用店禁止注入脚本，Chrome 不报错，
        // 只是什么都不返回。不认出来的话表现是"读到一个空白页面"，
        // 模型会以为页面真的是空的然后开始瞎猜。
        if (!value.length) {
            completion(nil, @"这个标签页拿不到任何结果。多半是 chrome:// 设置页、扩展页面或"
                            @"网上应用店——浏览器禁止在这些页面执行脚本。换一个普通网页的标签页，"
                            @"用 browser_tabs 看有哪些。");
            return;
        }
        completion(value, nil);
    }];
}

/// 跑一段 AppleScript 拿字符串结果。和 runScript: 共用队列与错误翻译，
/// 但不接受 JXA、不暴露给模型——模型碰到的是上面那几个具体工具。
- (void)runRawScript:(NSString *)source
                 app:(NSString *)appName
          completion:(void (^)(NSString *value, NSString *error))completion {

    if (self.scriptRunning) {
        completion(nil, @"上一段脚本还没结束，等它超时或换个方式");
        return;
    }
    __block BOOL settled = NO;
    NSObject *lock = [NSObject new];
    void (^finish)(NSString *, NSString *) = ^(NSString *value, NSString *error) {
        @synchronized (lock) {
            if (settled) return;
            settled = YES;
        }
        completion(value, error);
    };

    self.scriptRunning = YES;
    dispatch_async(self.scriptQueue, ^{
        NSString *blocked = [self automationBlockedFor:appName];
        if (blocked) {
            self.scriptRunning = NO;
            finish(nil, blocked);
            return;
        }
        NSDictionary *scriptError = nil;
        OSAScript *script = [[OSAScript alloc] initWithSource:source
                                                     language:[OSALanguage languageForName:@"AppleScript"]];
        NSAppleEventDescriptor *answer = [script executeAndReturnError:&scriptError];
        self.scriptRunning = NO;
        if (scriptError) {
            finish(nil, [self describeBrowserError:scriptError browser:appName]);
            return;
        }
        finish([self stringFromDescriptor:answer depth:0] ?: @"", nil);
    });

    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(kScriptCeiling * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        finish(nil, [NSString stringWithFormat:@"浏览器脚本超过 %.0fs 没返回。"
                     @"页面可能卡在加载或弹了原生对话框。", kScriptCeiling]);
    });
}

/// 「允许 Apple 事件中的 JavaScript」没开时报的是一条普通脚本错误，
/// 笼统转达会让模型以为是权限没给、跑去让用户改系统设置——那是另一个开关，
/// 改了也没用。这里单独认出来，把真正该点的地方说清楚。
- (NSString *)describeBrowserError:(NSDictionary *)scriptError browser:(NSString *)browser {
    NSString *message = scriptError[OSAScriptErrorMessageKey]
                     ?: scriptError[NSAppleScriptErrorMessage] ?: @"";
    BOOL jsDisabled = [message rangeOfString:@"JavaScript"].location != NSNotFound
        && ([message rangeOfString:@"已关闭"].location != NSNotFound
            || [message rangeOfString:@"not allowed"options:NSCaseInsensitiveSearch].location != NSNotFound
            || [message rangeOfString:@"turned off"options:NSCaseInsensitiveSearch].location != NSNotFound
            || [message rangeOfString:@"disabled"options:NSCaseInsensitiveSearch].location != NSNotFound);
    if (jsDisabled) {
        if ([browser isEqualToString:kSafariName]) {
            return @"Safari 没有允许通过 Apple 事件执行 JavaScript。这是一次性设置，"
                   @"请用户打开：Safari → 设置 → 高级 → 勾选「显示网页开发者功能」，"
                   @"然后在菜单栏「开发」→「允许 Apple 事件中的 JavaScript」。"
                   @"这个开关和系统设置里的权限无关，改系统设置没有用。";
        }
        return @"Chrome 没有允许通过 Apple 事件执行 JavaScript。这是一次性设置，"
               @"请用户在 Chrome 菜单栏打开：查看 → 开发者 → 「允许 Apple 事件中的 JavaScript」。"
               @"这个开关和系统设置里的权限无关，改系统设置没有用。";
    }
    return [self describeScriptError:scriptError];
}

#pragma mark 浏览器工具实现

- (void)browserTabs:(NSDictionary *)arguments completion:(JarvisToolCompletion)completion {
    NSString *browser = [self resolveBrowser:arguments];
    BOOL safari = [browser isEqualToString:kSafariName];
    // 用制表符分隔自己拼串，比让 AppleScript 返回嵌套 list 好解析得多。
    // ⚠️ 分隔符必须在 tell 块**外面**算好。`tab` 是 AppleScript 的制表符常量，
    // 但在浏览器的 tell 块里 `tab` 同时是它字典里的类名，于是 `& tab &` 会被
    // 当成字面字符串 "tab" 拼进去——脚本不报错，只是返回的行里没有制表符，
    // 解析出 0 个标签页。这个坑不报错所以特别费时间，实测过才发现。
    NSString *script = [NSString stringWithFormat:
        @"set d to character id 9\n"
        @"tell application \"%@\"\n"
        @"  set out to \"\"\n"
        @"  set wi to 0\n"
        @"  repeat with w in windows\n"
        @"    set wi to wi + 1\n"
        @"    set ti to 0\n"
        @"    repeat with t in tabs of w\n"
        @"      set ti to ti + 1\n"
        @"      set out to out & wi & d & ti & d & (name of t) & d & (URL of t) & linefeed\n"
        @"    end repeat\n"
        @"  end repeat\n"
        @"  return out\n"
        @"end tell", safari ? @"Safari" : @"Google Chrome"];

    [self runRawScript:script app:browser completion:^(NSString *value, NSString *error) {
        if (error) { completion(nil, error); return; }
        NSMutableArray *tabs = [NSMutableArray array];
        for (NSString *line in [value componentsSeparatedByString:@"\n"]) {
            if (!line.length) continue;
            NSArray *parts = [line componentsSeparatedByString:@"\t"];
            if (parts.count < 4) continue;
            [tabs addObject:@{@"window": @([parts[0] integerValue]),
                              @"tab": @([parts[1] integerValue]),
                              @"title": parts[2],
                              @"url": [[parts subarrayWithRange:NSMakeRange(3, parts.count - 3)]
                                       componentsJoinedByString:@"\t"]}];
        }
        completion(@{@"browser": browser, @"count": @(tabs.count), @"tabs": tabs}, nil);
    }];
}

- (void)browserOpen:(NSDictionary *)arguments completion:(JarvisToolCompletion)completion {
    NSString *url = arguments[@"url"];
    if (![url isKindOfClass:[NSString class]] || !url.length) {
        completion(nil, @"缺少 url");
        return;
    }
    if ([url rangeOfString:@"://"].location == NSNotFound) {
        url = [@"https://" stringByAppendingString:url];
    }
    NSString *browser = [self resolveBrowser:arguments];
    BOOL safari = [browser isEqualToString:kSafariName];
    NSString *escaped = [url stringByReplacingOccurrencesOfString:@"\"" withString:@"\\\""];
    // 没有窗口时 `make new tab` 会失败，所以两种情况分开写。
    NSString *script = safari
        ? [NSString stringWithFormat:
           @"tell application \"Safari\"\n"
           @"  activate\n"
           @"  if (count of windows) = 0 then\n"
           @"    make new document with properties {URL:\"%@\"}\n"
           @"  else\n"
           @"    tell front window to set current tab to (make new tab with properties {URL:\"%@\"})\n"
           @"  end if\n"
           @"  return URL of current tab of front window\n"
           @"end tell", escaped, escaped]
        : [NSString stringWithFormat:
           @"tell application \"Google Chrome\"\n"
           @"  activate\n"
           @"  if (count of windows) = 0 then\n"
           @"    make new window\n"
           @"    set URL of active tab of front window to \"%@\"\n"
           @"  else\n"
           @"    tell front window to make new tab with properties {URL:\"%@\"}\n"
           @"  end if\n"
           @"  return URL of active tab of front window\n"
           @"end tell", escaped, escaped];

    [self runRawScript:script app:browser completion:^(NSString *value, NSString *error) {
        if (error) { completion(nil, error); return; }
        completion(@{@"ok": @YES, @"browser": browser, @"url": value ?: url}, nil);
    }];
}

/// 页面快照：正文 + 可交互元素清单。相当于网页版的 ui_inspect。
/// 每个元素带一个**自包含的 CSS 选择器**，browser_act 直接拿它定位——
/// 不用序号是因为序号会随页面变动错位，而 ui_action 那条"路径只在界面没变时
/// 有效"的限制已经证明了那种设计有多容易出错。
- (void)browserRead:(NSDictionary *)arguments completion:(JarvisToolCompletion)completion {
    NSInteger maxChars = 6000;
    if ([arguments[@"max_chars"] respondsToSelector:@selector(integerValue)]) {
        maxChars = MIN(MAX([arguments[@"max_chars"] integerValue], 500), 20000);
    }
    NSString *filter = [arguments[@"selector"] isKindOfClass:[NSString class]]
        ? arguments[@"selector"] : @"";

    NSString *js = [NSString stringWithFormat:@
        "(function(){\n"
        // 选择器要能穿过 shadow DOM 边界，所以用 ' >>> ' 分段：
        // 'settings-ui >>> settings-main >>> #foo' 表示逐层进 shadowRoot。
        // 那是早年 CSS 的 deep 组合子、现在已经不是合法 CSS，拿来当分隔符不会和
        // 真实选择器撞车。browser_act 按同样的规则解析。
        "function cssPathIn(el,root){\n"
        "  if(el.id){var q='#'+CSS.escape(el.id);try{if(root.querySelectorAll(q).length===1)return q;}catch(e){}}\n"
        "  var parts=[];\n"
        "  while(el&&el.nodeType===1&&el!==root){\n"
        "    var par=el.parentElement,seg=el.tagName.toLowerCase();\n"
        "    if(par){var same=[].filter.call(par.children,function(c){return c.tagName===el.tagName;});\n"
        "      if(same.length>1)seg+=':nth-of-type('+([].indexOf.call(same,el)+1)+')';\n"
        "      parts.unshift(seg);el=par;}\n"
        "    else{parts.unshift(seg);break;}\n"
        "  }\n"
        "  return parts.join('>');\n"
        "}\n"
        "function label(el){\n"
        "  var t=(el.getAttribute('aria-label')||el.getAttribute('title')||el.getAttribute('placeholder')||\n"
        "         el.getAttribute('alt')||el.value||el.innerText||'').replace(/\\s+/g,' ').trim();\n"
        "  return t.slice(0,80);\n"
        "}\n"
        "function visible(el){\n"
        "  var r=el.getBoundingClientRect();\n"
        "  if(r.width<1||r.height<1)return false;\n"
        "  var s=getComputedStyle(el);\n"
        "  return s.visibility!=='hidden'&&s.display!=='none'&&s.opacity!=='0';\n"
        "}\n"
        "var sel='a,button,input,textarea,select,[role=\"button\"],[role=\"link\"],[role=\"tab\"],[role=\"menuitem\"],[onclick],[contenteditable=\"true\"]';\n"
        "var out=[],shadowHosts=0;\n"
        "function collect(root,prefix,depth){\n"
        "  if(depth>8||out.length>=150)return;\n"
        "  try{\n"
        "    [].slice.call(root.querySelectorAll(sel)).forEach(function(el){\n"
        "      if(out.length>=150||!visible(el))return;\n"
        "      var o={tag:el.tagName.toLowerCase(),label:label(el),\n"
        "             selector:prefix+cssPathIn(el,root)};\n"
        "      if(el.type)o.type=el.type;\n"
        "      if(el.disabled)o.disabled=true;\n"
        "      out.push(o);\n"
        "    });\n"
        "    [].slice.call(root.querySelectorAll('*')).forEach(function(el){\n"
        "      if(el.shadowRoot){shadowHosts++;\n"
        "        collect(el.shadowRoot,prefix+cssPathIn(el,root)+' >>> ',depth+1);}\n"
        "    });\n"
        "  }catch(e){}\n"
        "}\n"
        "var root=%@;\n"
        "collect(root,'',0);\n"
        "var text=(root.innerText||'').replace(/\\n{3,}/g,'\\n\\n').trim();\n"
        "var frames=document.querySelectorAll('iframe,frame').length;\n"
        "var truncated=text.length>%ld;\n"
        "return JSON.stringify({title:document.title,url:location.href,\n"
        "  text:text.slice(0,%ld),truncated:truncated,elements:out,\n"
        "  shadow_hosts:shadowHosts,iframes:frames});\n"
        "})()", filter.length ? [NSString stringWithFormat:@"(document.querySelector(%@)||document.body)",
                                 [self jsStringLiteral:filter]] : @"document.body",
        (long)maxChars, (long)maxChars];

    NSString *browser = [self resolveBrowser:arguments];
    [self evaluateJS:JarvisGuardJS([@"return " stringByAppendingString:js])
             browser:browser arguments:arguments
          completion:^(NSString *value, NSString *error) {
        if (error) { completion(nil, error); return; }
        NSDictionary *parsed = [self parseJSON:value];
        if (!parsed) {
            completion(nil, @"页面返回的不是预期的 JSON，可能这个标签页还没加载完");
            return;
        }
        NSMutableDictionary *out = [parsed mutableCopy];
        out[@"browser"] = browser;
        // 读到一张"什么都没有"的页面时必须说明白，别让模型以为页面真是空的。
        // 最常见的两个原因是内容在 shadow DOM（已经会穿了，但闭合的 shadow root
        // 穿不了）或在跨域 iframe 里（拿不到）。silent empty 是最坏的失败方式：
        // 它长得和成功一模一样。
        NSString *text = out[@"text"];
        NSArray *elements = out[@"elements"];
        if (!text.length && !elements.count) {
            NSMutableArray *reasons = [NSMutableArray array];
            if ([out[@"iframes"] integerValue] > 0) {
                [reasons addObject:[NSString stringWithFormat:@"页面里有 %@ 个 iframe，"
                                    @"跨域的读不到", out[@"iframes"]]];
            }
            if ([out[@"shadow_hosts"] integerValue] > 0) {
                [reasons addObject:@"有闭合的 shadow DOM"];
            }
            out[@"note"] = reasons.count
                ? [NSString stringWithFormat:@"这一页没读到任何正文和可操作元素（%@）。"
                   @"别当成页面是空的——换个标签页，或用 browser_eval 针对性地取。",
                   [reasons componentsJoinedByString:@"；"]]
                : @"这一页没读到任何正文和可操作元素。可能还在加载，也可能是浏览器的"
                  @"内部页面（chrome://、扩展页）——那些禁止注入脚本。别当成页面是空的。";
        }
        completion(out, nil);
    }];
}

- (void)browserAct:(NSDictionary *)arguments completion:(JarvisToolCompletion)completion {
    NSString *selector = arguments[@"selector"];
    NSString *action = arguments[@"action"] ?: @"click";
    if (![selector isKindOfClass:[NSString class]] || !selector.length) {
        completion(nil, @"缺少 selector（用 browser_read 拿到的那个）");
        return;
    }
    NSString *value = [arguments[@"value"] isKindOfClass:[NSString class]] ? arguments[@"value"] : @"";

    // 填值必须派发 input/change 事件：React/Vue 这类框架监听的是事件，
    // 直接改 .value 它们收不到，表现是"字填进去了但提交时是空的"。
    NSString *js = [NSString stringWithFormat:@
        "(function(){\n"
        // selector 可能带 ' >>> '，逐层进 shadowRoot。规则和 browser_read 生成时一致。
        "function resolve(path){\n"
        "  var segs=path.split('>>>').map(function(x){return x.trim();}).filter(Boolean);\n"
        "  var ctx=document,el=null;\n"
        "  for(var i=0;i<segs.length;i++){\n"
        "    el=ctx.querySelector(segs[i]);\n"
        "    if(!el)return null;\n"
        "    if(i<segs.length-1){if(!el.shadowRoot)return null;ctx=el.shadowRoot;}\n"
        "  }\n"
        "  return el;\n"
        "}\n"
        "var el=resolve(%@);\n"
        "if(!el)return JSON.stringify({ok:false,error:'选择器没有匹配到元素，页面可能已经变了，重新 browser_read'});\n"
        "if(el.disabled)return JSON.stringify({ok:false,error:'这个元素是禁用状态'});\n"
        "el.scrollIntoView({block:'center'});\n"
        "var act=%@,val=%@;\n"
        "if(act==='fill'){\n"
        "  var proto=el instanceof HTMLTextAreaElement?HTMLTextAreaElement.prototype:HTMLInputElement.prototype;\n"
        "  var setter=Object.getOwnPropertyDescriptor(proto,'value');\n"
        "  if(setter&&setter.set){setter.set.call(el,val);}else{el.value=val;}\n"
        "  el.dispatchEvent(new Event('input',{bubbles:true}));\n"
        "  el.dispatchEvent(new Event('change',{bubbles:true}));\n"
        "}else if(act==='select'){\n"
        "  el.value=val;el.dispatchEvent(new Event('change',{bubbles:true}));\n"
        "}else if(act==='focus'){el.focus();}\n"
        "else{el.click();}\n"
        "return JSON.stringify({ok:true,action:act,tag:el.tagName.toLowerCase(),\n"
        "  label:(el.innerText||el.value||'').replace(/\\s+/g,' ').trim().slice(0,60),\n"
        "  value_now:(el.value!==undefined?String(el.value).slice(0,120):'')});\n"
        "})()", [self jsStringLiteral:selector], [self jsStringLiteral:action],
        [self jsStringLiteral:value]];

    NSString *browser = [self resolveBrowser:arguments];
    [self evaluateJS:JarvisGuardJS([@"return " stringByAppendingString:js])
             browser:browser arguments:arguments
          completion:^(NSString *raw, NSString *error) {
        if (error) { completion(nil, error); return; }
        NSDictionary *parsed = [self parseJSON:raw];
        if (!parsed) { completion(nil, @"页面没有返回预期结果"); return; }
        if (![parsed[@"ok"] boolValue]) {
            completion(nil, parsed[@"error"] ?: @"操作失败");
            return;
        }
        NSMutableDictionary *out = [parsed mutableCopy];
        out[@"browser"] = browser;
        completion(out, nil);
    }];
}

- (void)browserEval:(NSDictionary *)arguments completion:(JarvisToolCompletion)completion {
    NSString *source = arguments[@"javascript"];
    if (![source isKindOfClass:[NSString class]] || !source.length) {
        completion(nil, @"缺少 javascript");
        return;
    }
    NSString *browser = [self resolveBrowser:arguments];
    // 用户/模型给的是语句，包成函数体——`eval` 不允许顶层 return，
    // 而工具说明里让模型用 return，不包的话每次都是静默的 SyntaxError。
    [self evaluateJS:JarvisGuardJS(source) browser:browser arguments:arguments
          completion:^(NSString *value, NSString *error) {
        if (error) { completion(nil, error); return; }
        completion(@{@"ok": @YES, @"browser": browser, @"result": value ?: @""}, nil);
    }];
}

#pragma mark 小工具

/// 把字符串安全地变成一个 JS 字面量。用 JSON 编码器而不是自己拼引号——
/// 引号、反斜杠、换行、Unicode 都得逃，手写迟早漏一种。
- (NSString *)jsStringLiteral:(NSString *)text {
    NSData *data = [NSJSONSerialization dataWithJSONObject:@[text ?: @""]
                                                   options:0 error:NULL];
    NSString *wrapped = [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding];
    // ["..."] → "..."
    return [wrapped substringWithRange:NSMakeRange(1, wrapped.length - 2)];
}

- (NSDictionary *)parseJSON:(NSString *)text {
    if (![text isKindOfClass:[NSString class]] || !text.length) return nil;
    NSData *data = [text dataUsingEncoding:NSUTF8StringEncoding];
    id parsed = [NSJSONSerialization JSONObjectWithData:data options:0 error:NULL];
    return [parsed isKindOfClass:[NSDictionary class]] ? parsed : nil;
}



#pragma mark - 分栏表单：一次调用完成读 / 写 / 验证
//
//  为什么要有这一层：**瓶颈从来不是工具，是模型的轮次。**
//  实测原生工具一次 0.02~0.06s，而模型一轮首字 1.4~12s。所以「找栏目 → 滚动 →
//  点击 → 输入 → 读回验证」拆成五个工具调用意味着五轮模型往返，十几秒起步；
//  合成一次调用之后总耗时由 AX 遍历决定，还是 0.1s 级别。
//
//  这不是把通用能力特化成某个 App 的工具——分栏表单（标题 + 它下面的内容，
//  一页里重复若干组）是极其常见的形态：日报、周报、审批单、工单、问卷。
//  ui_inspect/ui_action 仍然在，任何这层覆盖不到的界面照旧走它们。

/// 一次遍历拿到整棵树（含 webview 内部）。分栏表单的内容常在 AXWebArea 里，
/// 而 AXWebArea 是可读的——别因为"是 webview"就放弃。
- (NSArray<NSDictionary *> *)flatTreeFor:(NSRunningApplication *)app {
    AXUIElementRef root = [self rootElementForApp:app];
    if (!root) return nil;
    NSMutableArray *nodes = [NSMutableArray array];
    [self walkElement:root path:@"" depth:0 maxDepth:14 into:nodes];
    CFRelease(root);
    [self inferLabelsFor:nodes];
    return nodes;
}

static NSString *JarvisNodeText(NSDictionary *node) {
    for (NSString *key in @[@"value", @"title", @"inferred_label", @"label"]) {
        NSString *text = node[key];
        if ([text isKindOfClass:[NSString class]] && text.length) return text;
    }
    return nil;
}

/// 找栏目标题。要求完全相等——分栏表单里标题是确定的字符串，
/// 模糊匹配只会匹到正文里提到同样词的那一行。
static NSDictionary *JarvisFindHeading(NSArray *nodes, NSString *section) {
    for (NSDictionary *node in nodes) {
        NSString *text = JarvisNodeText(node);
        if ([text isEqualToString:section] && node[@"frame"]) return node;
    }
    return nil;
}

/// 取某个标题**下面、下一个标题之前**的所有内容行。
/// 判据是纵坐标顺序，不是树结构——webview 里 DOM 层级和视觉顺序常常对不上，
/// 而"在这个标题下面、在下个标题上面"永远符合人的理解。
static NSArray<NSDictionary *> *JarvisSectionBody(NSArray *nodes, NSDictionary *heading,
                                                  NSArray<NSString *> *allSections) {
    NSInteger headY = [heading[@"frame"][@"y"] integerValue];
    NSInteger headXForBound = [heading[@"frame"][@"x"] integerValue];
    NSInteger nextY = NSIntegerMax;
    // 边界只认调用方声明的栏目标题。
    // 试过按"和标题左对齐且短"自动识别，**不行**：内容行和标题也是左对齐的
    // （这个表单里都是 x=479），于是第一行内容就被当成了边界，每一栏都读成空的。
    // 左对齐区分不了标题和内容，别再往这个方向修。
    (void)headXForBound;
    for (NSDictionary *node in nodes) {
        NSString *text = JarvisNodeText(node);
        if (!text || ![allSections containsObject:text]) continue;
        NSInteger y = [node[@"frame"][@"y"] integerValue];
        if (y > headY && y < nextY) nextY = y;
    }
    // ⚠️ 只按纵坐标切会把**侧边栏**的文字混进来——它和内容区处在同一 y 区间。
    // 实测「今日工作完成内容与进度」读出来夹着"最近使用""写日志""帮助"。
    // 内容行和它的标题是左对齐（或略缩进）的，所以再卡一道横向：
    // 从标题左边缘往右一小段之内。右边远处的窗口装饰（"共 66 个字"）也一并排除。
    NSInteger headX = [heading[@"frame"][@"x"] integerValue];
    NSMutableArray *body = [NSMutableArray array];
    for (NSDictionary *node in nodes) {
        NSDictionary *frame = node[@"frame"];
        if (!frame) continue;
        NSInteger y = [frame[@"y"] integerValue];
        if (y <= headY || y >= nextY) continue;
        NSInteger x = [frame[@"x"] integerValue];
        // 收得比较紧（+160 而不是 +320）：栏目内容和标题基本左对齐，
        // 放宽到 +320 会把**固定在顶部的工具栏**放进来——栏目滚到屏幕上方之后，
        // 工具栏就落在它的 y 区间里了，读出来一堆 toolbar-bold/toolbar-italic。
        if (x < headX - 24 || x > headX + 160) continue;
        NSString *text = JarvisNodeText(node);
        if (!text.length) continue;
        // 图标字体的私用区码位和工具栏图标名不是内容，别混进正文。
        if ([text hasPrefix:@"toolbar-"]) continue;
        unichar first = [text characterAtIndex:0];
        if (first >= 0xE000 && first <= 0xF8FF && text.length <= 2) continue;
        [body addObject:node];
    }
    [body sortUsingComparator:^NSComparisonResult(NSDictionary *a, NSDictionary *b) {
        return [a[@"frame"][@"y"] compare:b[@"frame"][@"y"]];
    }];
    // 去重：富文本编辑器会给同一段文字挂好几个 AX 节点（渲染出来的 AXStaticText、
    // contenteditable 的后备 AXTextArea、以及它的文本子节点），三者坐标重叠、
    // 值相同。不去重的话读回来是同一句话出现两三遍，**看着像被写了两遍**——
    // 用户会以为出了数据问题，实际文档里只有一份。
    NSMutableArray *unique = [NSMutableArray array];
    NSMutableSet *seen = [NSMutableSet set];
    for (NSDictionary *node in body) {
        NSString *text = JarvisNodeText(node);
        if (!text.length || [seen containsObject:text]) continue;
        [seen addObject:text];
        [unique addObject:node];
    }
    // **最后一栏没有下一个标题作边界**，会一路吃到页尾（实测把图片/附件/备注/
    // 发送到人/提交全吞进来）。截断是兜底，真正的保护是写入时点**第一行**而不是
    // 最后一行——见 formWrite 里的说明。
    if (unique.count > 12) {
        return [unique subarrayWithRange:NSMakeRange(0, 12)];
    }
    return unique;
}

/// 猜这一页有哪些栏目标题。用户没传 sections 时用它，省掉"先问一次有哪些栏目"。
/// 判据：短、独占一行、后面跟着别的文字。宁可多认几个——多认只影响分段边界，
/// 少认会让某一栏的内容被并进上一栏。
static NSArray<NSString *> *JarvisGuessSections(NSArray *nodes) {
    NSMutableArray *out = [NSMutableArray array];
    for (NSDictionary *node in nodes) {
        NSString *text = JarvisNodeText(node);
        if (!text.length || text.length > 24) continue;
        if (![node[@"role"] isEqualToString:@"AXStaticText"]) continue;
        if (!node[@"frame"]) continue;
        if (![out containsObject:text]) [out addObject:text];
    }
    return out;
}

- (void)formRead:(NSDictionary *)arguments completion:(JarvisToolCompletion)completion {
    if (!AXIsProcessTrusted()) {
        completion(nil, @"没有辅助功能权限：系统设置 → 隐私与安全性 → 辅助功能，把 JARVIS 打开");
        return;
    }
    NSRunningApplication *app = [self runningAppNamed:arguments[@"app"]];
    if (!app) {
        completion(nil, [NSString stringWithFormat:@"「%@」没在运行", arguments[@"app"] ?: @""]);
        return;
    }
    NSArray *nodes = [self flatTreeFor:app];
    if (!nodes) { completion(nil, @"拿不到界面元素"); return; }

    NSArray *sections = [arguments[@"sections"] isKindOfClass:[NSArray class]]
        ? arguments[@"sections"] : nil;
    if (!sections.count) {
        completion(nil, @"要传 sections（这一页有哪些栏目标题）。"
                        @"不知道有哪些就先 ui_inspect 看一眼。");
        return;
    }

    NSMutableDictionary *out = [NSMutableDictionary dictionary];
    NSMutableArray *missing = [NSMutableArray array];
    for (NSString *section in sections) {
        NSDictionary *heading = JarvisFindHeading(nodes, section);
        if (!heading) { [missing addObject:section]; continue; }
        NSMutableArray *lines = [NSMutableArray array];
        for (NSDictionary *node in JarvisSectionBody(nodes, heading, sections)) {
            NSString *text = JarvisNodeText(node);
            if (text.length) [lines addObject:text];
        }
        out[section] = lines;
    }
    NSMutableDictionary *result = [@{@"app": app.localizedName ?: @"",
                                     @"sections": out} mutableCopy];
    if (missing.count) result[@"not_found"] = missing;
    // 标题滚出可视区时，按纵坐标切分不可靠（页面上固定不动的元素会落进它的区间）。
    // 说出来，别让调用方拿一份可能掺了杂质的结果当准。
    NSMutableArray *offscreen = [NSMutableArray array];
    for (NSString *section in sections) {
        NSDictionary *h = JarvisFindHeading(nodes, section);
        if (h && [h[@"frame"][@"y"] integerValue] < 0) [offscreen addObject:section];
    }
    if (offscreen.count) {
        result[@"offscreen"] = offscreen;
        result[@"note"] = @"这些栏目滚出了可视区，读回的内容可能掺进页面上固定不动的元素。"
                          @"要准确的话先把它滚进来（ui_action click 它的标题会自动滚动）。";
    }
    completion(result, nil);
}

- (void)formWrite:(NSDictionary *)arguments completion:(JarvisToolCompletion)completion {
    if (!AXIsProcessTrusted()) {
        completion(nil, @"没有辅助功能权限：系统设置 → 隐私与安全性 → 辅助功能，把 JARVIS 打开");
        return;
    }
    NSString *section = arguments[@"section"];
    NSString *text = arguments[@"text"];
    if (![section isKindOfClass:[NSString class]] || !section.length) {
        completion(nil, @"缺少 section（要写进哪个栏目，填栏目标题的原文）");
        return;
    }
    if (![text isKindOfClass:[NSString class]] || !text.length) {
        completion(nil, @"缺少 text");
        return;
    }
    NSRunningApplication *app = [self runningAppNamed:arguments[@"app"]];
    if (!app) {
        completion(nil, [NSString stringWithFormat:@"「%@」没在运行", arguments[@"app"] ?: @""]);
        return;
    }
    NSString *mode = [arguments[@"mode"] isKindOfClass:[NSString class]]
        ? arguments[@"mode"] : @"line_replace";
    NSDate *started = [NSDate date];

    NSArray *nodes = [self flatTreeFor:app];
    if (!nodes) { completion(nil, @"拿不到界面元素"); return; }
    NSArray *sections = [arguments[@"sections"] isKindOfClass:[NSArray class]]
        ? arguments[@"sections"] : JarvisGuessSections(nodes);

    NSDictionary *heading = JarvisFindHeading(nodes, section);
    if (!heading) {
        NSMutableArray *seen = [NSMutableArray array];
        for (NSDictionary *node in nodes) {
            NSString *t = JarvisNodeText(node);
            if (t.length && t.length <= 24 && ![seen containsObject:t] && seen.count < 30) {
                [seen addObject:t];
            }
        }
        completion(nil, [NSString stringWithFormat:
            @"这一页没有叫「%@」的栏目。看到的有：%@", section,
            [seen componentsJoinedByString:@"、"]]);
        return;
    }

    NSArray *body = JarvisSectionBody(nodes, heading, sections);
    NSMutableArray *before = [NSMutableArray array];
    for (NSDictionary *node in body) {
        NSString *t = JarvisNodeText(node);
        if (t.length) [before addObject:t];
    }

    // ⚠️ 点这一栏的**第一行**，不是最后一行。
    // 最后一行看着更合理（"接着往后写"），但**最后一个栏目没有下一个标题作边界**，
    // 它的 body 会一路延伸到页尾——那样 lastObject 就是「提 交」按钮，
    // 一点就把日报发出去了，而且不可撤销。第一行永远在这一栏内，没有这个风险。
    // 代价是 line_end 追加时接在第一行末尾而不是整栏末尾，可以接受。
    NSDictionary *target = body.firstObject ?: heading;
    AXUIElementRef root = [self rootElementForApp:app];
    if (!root) { completion(nil, @"拿不到界面元素"); return; }
    NSString *failure = nil;
    AXUIElementRef element = [self elementAtPath:target[@"path"] from:root error:&failure];
    CFRelease(root);
    if (!element) { completion(nil, failure ?: @"定位不到这一栏的内容行"); return; }

    NSString *clickError = [self clickElement:element app:app];
    CFRelease(element);
    if (clickError) { completion(nil, [NSString stringWithFormat:@"点不进「%@」：%@",
                                       section, clickError]); return; }
    [NSThread sleepForTimeInterval:0.15];

    NSDictionary *typed = nil;
    __block NSString *typeError = nil;
    __block NSDictionary *typeResult = nil;
    [self typeText:@{@"app": app.localizedName ?: @"", @"text": text, @"mode": mode}
        completion:^(NSDictionary *r, NSString *e) { typeResult = r; typeError = e; }];
    typed = typeResult;
    if (typeError) { completion(nil, [NSString stringWithFormat:@"写入失败：%@", typeError]); return; }
    [NSThread sleepForTimeInterval:0.35];

    // 读回验证。**这一步不能省**：写进去了不等于写对了地方，而分栏表单最容易犯的错
    // 就是内容落到隔壁栏。省掉它就只能报告"我不确定"，那等于没做完。
    NSArray *after = [self flatTreeFor:app];
    NSDictionary *headingAfter = JarvisFindHeading(after, section);
    NSMutableArray *now = [NSMutableArray array];
    if (headingAfter) {
        for (NSDictionary *node in JarvisSectionBody(after, headingAfter, sections)) {
            NSString *t = JarvisNodeText(node);
            if (t.length) [now addObject:t];
        }
    }
    BOOL landed = NO;
    for (NSString *line in now) {
        if ([line rangeOfString:text].location != NSNotFound) { landed = YES; break; }
    }

    NSMutableDictionary *result = [@{@"ok": @(landed),
                                     @"section": section,
                                     @"mode": mode,
                                     @"before": before,
                                     @"after": now,
                                     @"verified": @(landed),
                                     @"ms": @((NSInteger)([[NSDate date] timeIntervalSinceDate:started] * 1000))}
                                   mutableCopy];
    if (!landed) {
        // 没落在目标栏就要找出它落哪儿了——只说"失败"会让人以为什么都没发生，
        // 而实际上字很可能写进了别的栏目，那是需要人去清理的。
        NSMutableArray *elsewhere = [NSMutableArray array];
        for (NSDictionary *node in after) {
            NSString *t = JarvisNodeText(node);
            if (t.length && [t rangeOfString:text].location != NSNotFound) {
                [elsewhere addObject:t];
            }
        }
        result[@"landed_elsewhere"] = elsewhere;
        result[@"note"] = elsewhere.count
            ? @"⚠️ 文字没有出现在目标栏，但在页面别处找到了——它写进了错误的位置，需要清理。"
            : @"文字没有出现在目标栏，页面上也找不到它。可能焦点没进编辑区。";
    }
    completion(result, nil);
}

- (void)formRead2Unused:(NSDictionary *)arguments completion:(JarvisToolCompletion)completion {
    completion(nil, nil);
}


@end
