#import "AutomationController.h"

#import <AppKit/AppKit.h>
#import <ApplicationServices/ApplicationServices.h>
#import <Carbon/Carbon.h>
#import <OSAKit/OSAKit.h>

/// 一次脚本最多跑多久。Brain 侧 native 工具的等待上限是 60s，这里必须更小，
/// 否则超时的是 Brain、宿主这边还在跑，用户会看到"报了超时但事情又做了"。
static const NSTimeInterval kScriptCeiling = 45.0;
static const NSInteger kMaxDictionaryChars = 9000;
static const NSInteger kMaxUINodes = 220;

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
                                      @"browser_eval", @"browser_open"]];
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

    completion(@{@"app": app.localizedName ?: (name ?: @""),
                 @"window": windowTitle ?: @"",
                 @"count": @(nodes.count),
                 @"truncated": @(nodes.count >= kMaxUINodes),
                 @"elements": nodes,
                 @"note": @"path 是子元素下标路径，只在界面没变的情况下有效。"
                          @"要操作某一项就把它的 path 传给 ui_action；界面变过就重新 inspect。"}, nil);
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
    NSString *action = [arguments[@"action"] isKindOfClass:[NSString class]] ? arguments[@"action"] : @"press";

    AXUIElementRef root = [self rootElementForApp:app];
    if (!root) {
        completion(nil, @"拿不到这个应用的界面元素");
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

    if ([action isEqualToString:@"press"]) {
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


@end
