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
                                      @"ui_inspect", @"ui_action"]];
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
        case procNotFound:
            return [NSString stringWithFormat:@"「%@」没在运行，先用 app_open 打开它。", appName];
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

@end
