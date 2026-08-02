#import "ConversationPanelController.h"
#import "JarvisPaths.h"

#import <WebKit/WebKit.h>
#import <PDFKit/PDFKit.h>

static NSString *const kBridgeName = @"jarvis";
static NSString *const kOpacityDefaultsKey = @"JarvisPanelOpacity";
static NSString *const kHeightDefaultsKey  = @"JarvisPanelExpandedHeight";
static NSString *const kFrameAutosaveName  = @"JarvisConversationPanel";
static const CGFloat kPanelWidth  = 460.0;
static const CGFloat kPanelHeight = 620.0;
static const CGFloat kScreenMargin = 24.0;
static const CGFloat kDefaultOpacity = 0.82;
/// 低于这个高度就认为是收起态，而不是用户手动拖出来的尺寸
static const CGFloat kMinExpandedHeight = 200.0;

#pragma mark - 面板窗口

/// NSPanel 默认不能成为 key window，输入框会收不到键盘。
@interface ConversationPanel : NSPanel
@end

@implementation ConversationPanel
- (BOOL)canBecomeKeyWindow { return YES; }
@end

#pragma mark -

/// WKWebView 会吃掉整块内容区的 mouseDown（它的 -mouseDownCanMoveWindow 固定是 NO，
/// 这是为了保证网页里的文字选择/链接点击不被窗口拖拽截胡），所以纯 CSS 的
/// `-webkit-app-region: drag` 在 WKWebView 里从来没被实现过，只是被静默忽略——
/// 面板"偶尔能拖动"其实是点到了 webView 视觉范围之外的极小缝隙。
/// 这里在原生层重建同样的语义：页面把顶栏（可拖）和按钮（不可拖）的矩形上报，
/// -hitTest: 在可拖区域内且不落在任何按钮矩形里时返回 nil，
/// 命中测试会落到下一层的毛玻璃视图（默认 mouseDownCanMoveWindow = YES），
/// movableByWindowBackground 才真正生效。
@interface JarvisDraggableWebView : WKWebView
@property (nonatomic, assign) NSRect dragRegion;
@property (nonatomic, strong) NSArray<NSValue *> *excludeRegions;
@end

@implementation JarvisDraggableWebView

- (NSView *)hitTest:(NSPoint)point {
    if (!NSIsEmptyRect(self.dragRegion)) {
        NSPoint local = [self convertPoint:point fromView:self.superview];
        if (NSPointInRect(local, self.dragRegion)) {
            BOOL excluded = NO;
            for (NSValue *value in self.excludeRegions) {
                if (NSPointInRect(local, value.rectValue)) { excluded = YES; break; }
            }
            if (!excluded) return nil;
        }
    }
    return [super hitTest:point];
}

@end

#pragma mark -

@interface ConversationPanelController () <WKScriptMessageHandler, WKNavigationDelegate, WKUIDelegate>
@property (nonatomic, strong) ConversationPanel *panel;
@property (nonatomic, strong) JarvisDraggableWebView *webView;
@property (nonatomic, strong) NSVisualEffectView *blur;
@property (nonatomic, assign) BOOL pageReady;
@property (nonatomic, strong) NSMutableArray<NSDictionary *> *pendingEvents;
@property (nonatomic, assign) CGFloat expandedHeight;    ///< 收起前的高度，展开时还原
@property (nonatomic, assign) NSTimeInterval lastLevelAt;
@end

@implementation ConversationPanelController

- (instancetype)init {
    if ((self = [super init])) {
        _pendingEvents = [NSMutableArray array];
        NSNumber *saved = [[NSUserDefaults standardUserDefaults] objectForKey:kOpacityDefaultsKey];
        _panelOpacity = saved ? MAX(0.0, MIN(1.0, saved.doubleValue)) : kDefaultOpacity;
    }
    return self;
}

- (BOOL)isVisible { return self.panel.isVisible; }

#pragma mark - 构建

- (void)buildIfNeeded {
    if (self.panel) return;

    WKWebViewConfiguration *config = [[WKWebViewConfiguration alloc] init];
    WKUserContentController *content = [[WKUserContentController alloc] init];
    [content addScriptMessageHandler:self name:kBridgeName];
    config.userContentController = content;

    NSRect frame = NSMakeRect(0, 0, kPanelWidth, kPanelHeight);
    self.webView = [[JarvisDraggableWebView alloc] initWithFrame:frame configuration:config];
    self.webView.navigationDelegate = self;
    self.webView.UIDelegate = self;
    self.webView.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
    @try {
        [self.webView setValue:@NO forKey:@"drawsBackground"];
    } @catch (NSException *exception) {
        NSLog(@"[jarvis] 面板透明底不可用：%@", exception.reason);
    }

    self.panel = [[ConversationPanel alloc]
                  initWithContentRect:frame
                            // 不能加 NonactivatingPanel：那样鼠标点面板不会激活 App，
                            // 面板虽然成了 key window，键盘事件却仍发给前台程序，
                            // 结果是"点了输入框但打不出字"。唤出时的抢焦点问题
                            // 由 show 里的 activateIgnoringOtherApps 显式控制即可。
                            styleMask:NSWindowStyleMaskTitled
                                    | NSWindowStyleMaskClosable
                                    | NSWindowStyleMaskResizable
                                    | NSWindowStyleMaskFullSizeContentView
                              backing:NSBackingStoreBuffered
                                defer:NO];
    self.panel.title = @"J.A.R.V.I.S.";
    self.panel.titleVisibility = NSWindowTitleHidden;
    self.panel.titlebarAppearsTransparent = YES;
    self.panel.movableByWindowBackground = YES;
    self.panel.level = NSFloatingWindowLevel;
    self.panel.collectionBehavior = NSWindowCollectionBehaviorCanJoinAllSpaces
                                  | NSWindowCollectionBehaviorFullScreenAuxiliary;
    self.panel.hidesOnDeactivate = NO;
    self.panel.releasedWhenClosed = NO;
    self.panel.opaque = NO;
    self.panel.backgroundColor = [NSColor clearColor];
    self.panel.appearance = [NSAppearance appearanceNamed:NSAppearanceNameVibrantDark];
    self.panel.minSize = NSMakeSize(360, 360);

    // 毛玻璃必须由 AppKit 做：WKWebView 关掉 drawsBackground 后，CSS 的
    // backdrop-filter 没有可模糊的内容，窗口就只是半透明，后面的字看得一清二楚。
    self.blur = [[NSVisualEffectView alloc] initWithFrame:frame];
    self.blur.material = NSVisualEffectMaterialUnderWindowBackground;
    self.blur.blendingMode = NSVisualEffectBlendingModeBehindWindow;
    self.blur.state = NSVisualEffectStateActive;
    self.blur.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;

    // 毛玻璃和网页是**兄弟**，不是父子。调透明度改的是 blur.alphaValue，
    // 如果网页是它的子视图，文字会跟着一起淡掉——那就成了"调可读性"而不是"调透明度"。
    NSView *container = [[NSView alloc] initWithFrame:frame];
    container.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
    [container addSubview:self.blur];
    [container addSubview:self.webView positioned:NSWindowAbove relativeTo:self.blur];

    self.panel.contentView = container;
    self.panel.frameAutosaveName = kFrameAutosaveName;
    [self applyOpacity];

    [self positionAtDefaultCorner];

    NSURL *page = [JarvisPaths webPage:@"conversation.html"];
    [self.webView loadFileURL:page allowingReadAccessToURL:[page URLByDeletingLastPathComponent]];

    // 技能列表 + 常用短语频率都是面板自己的东西，不用等 Brain——self.panel 已经赋值，
    // pushEvent 里的 buildIfNeeded 会在守卫那行直接返回，不会递归重建。
    [self pushEvent:@{@"type": @"skills", @"items": [self loadSkills]}];
    [self pushEvent:@{@"type": @"usage", @"items": [self topUsageItemsFromCounts:[self loadUsageCounts]]}];
}

#pragma mark - 网页文件选择

/// WKWebView 不会自动替网页里的 <input type="file"> 弹出文件选择器；必须由
/// WKUIDelegate 接住请求。缺这段时输入区的「＋」事件虽然触发了，界面却毫无反应。
- (void)webView:(WKWebView *)webView
runOpenPanelWithParameters:(WKOpenPanelParameters *)parameters
initiatedByFrame:(WKFrameInfo *)frame
completionHandler:(void (^)(NSArray<NSURL *> * _Nullable URLs))completionHandler {
    NSOpenPanel *panel = [NSOpenPanel openPanel];
    panel.canChooseFiles = YES;
    panel.canChooseDirectories = parameters.allowsDirectories;
    panel.allowsMultipleSelection = parameters.allowsMultipleSelection;
    panel.resolvesAliases = YES;

    void (^finish)(NSModalResponse) = ^(NSModalResponse result) {
        completionHandler(result == NSModalResponseOK ? panel.URLs : nil);
    };
    if (self.panel) {
        [panel beginSheetModalForWindow:self.panel completionHandler:finish];
    } else {
        finish([panel runModal]);
    }
}

/// 默认贴主屏右下角。用户拖过之后 frameAutosaveName 会接管，不再重定位。
- (void)positionAtDefaultCorner {
    if ([self.panel setFrameUsingName:self.panel.frameAutosaveName]) {
        // 面板永远以展开状态启动。存下来的可能是收起态（甚至已被 minSize 钳成 360），
        // 所以判据是"小于等于 minSize"，不能只判"小于 200"——那样钳过的值会漏网。
        if (self.panel.frame.size.height <= self.panel.minSize.height) {
            CGFloat saved = [[NSUserDefaults standardUserDefaults] doubleForKey:kHeightDefaultsKey];
            CGFloat height = saved >= kMinExpandedHeight ? saved : kPanelHeight;
            NSRect frame = self.panel.frame;
            frame.origin.y -= (height - frame.size.height);
            frame.size.height = height;
            [self.panel setFrame:frame display:NO];
        }
        self.expandedHeight = self.panel.frame.size.height;
        return;
    }
    NSScreen *screen = [NSScreen mainScreen] ?: [NSScreen screens].firstObject;
    NSRect visible = screen.visibleFrame;
    NSRect frame = self.panel.frame;
    frame.origin.x = NSMaxX(visible) - frame.size.width - kScreenMargin;
    frame.origin.y = NSMinY(visible) + kScreenMargin;
    [self.panel setFrame:frame display:NO];
}

#pragma mark - 透明度

- (void)setPanelOpacity:(CGFloat)panelOpacity {
    _panelOpacity = MAX(0.0, MIN(1.0, panelOpacity));
    [[NSUserDefaults standardUserDefaults] setDouble:_panelOpacity forKey:kOpacityDefaultsKey];
    [self applyOpacity];
}

/// 两件事一起动，缺一样都不像"变透明"：
///   毛玻璃层的 alpha —— 决定背后的东西糊到什么程度；
///   页面里那层暗色 —— 决定文字底下有多少衬底。
/// 只调前者，浅色壁纸下文字会糊；只调后者，背后永远是一块磨砂。
- (void)applyOpacity {
    self.blur.alphaValue = _panelOpacity;
    // 全透明时索性把整层摘掉，省一次离屏合成
    self.blur.hidden = (_panelOpacity <= 0.01);
    [self pushEvent:@{@"type": @"opacity", @"value": @(_panelOpacity)}];
}

#pragma mark - 音频电平

/// 每秒最多 15 次。电平回调来自 20Hz 的采样定时器，每次都过一趟 evaluateJavaScript
/// 会在收音全程持续占着主线程——而这条信息只是让顶栏那几根条动一动。
/// 面板不可见时干脆不发：没人看的动画不值得付出任何代价。
- (void)pushMicLevel:(float)level {
    if (!self.pageReady || !self.panel.isVisible) return;
    NSTimeInterval now = [NSDate timeIntervalSinceReferenceDate];
    if (now - self.lastLevelAt < 1.0 / 15.0) return;
    self.lastLevelAt = now;
    [self.webView evaluateJavaScript:
     [NSString stringWithFormat:@"window.__jarvisLevel && window.__jarvisLevel(%.3f)", level]
                   completionHandler:nil];
}

#pragma mark - 收起 / 展开

/// 收起只留顶栏。高度由页面量出来后传上来——写死一个数字迟早会和 CSS 对不上，
/// 差一点就会把顶栏切掉或者露出半行内容。
- (void)setCollapsed:(BOOL)collapsed headerHeight:(CGFloat)headerHeight {
    if (!self.panel) return;

    NSRect frame = self.panel.frame;
    // FullSizeContentView 下 contentRect 基本等于 frame，但别假设，按 API 算
    CGFloat chrome = frame.size.height - [self.panel contentRectForFrameRect:frame].size.height;

    CGFloat target;
    if (collapsed) {
        if (frame.size.height >= kMinExpandedHeight) self.expandedHeight = frame.size.height;
        [[NSUserDefaults standardUserDefaults] setDouble:self.expandedHeight forKey:kHeightDefaultsKey];
        target = MAX(32.0, headerHeight) + chrome;
        // 收起期间关掉窗口尺寸自动保存。开着的话保存下来的就是这条 56px 的顶栏，
        // 下次启动 setFrameUsingName 把它读回来、又被 minSize 钳到 360，
        // 面板于是以一个不高不矮的空壳启动——这条排查起来很费劲，因为看着"只是变矮了"。
        self.panel.frameAutosaveName = @"";
    } else {
        target = self.expandedHeight >= kMinExpandedHeight ? self.expandedHeight : kPanelHeight;
    }

    // minSize 拦在这儿：不放开的话 setFrame 会被静默钳回 360，收起看着「没反应」。
    // 收起态也不该让用户手动拖高度，所以顺手把 max 一起钉死。
    self.panel.minSize = NSMakeSize(360, collapsed ? target : 360);
    self.panel.maxSize = collapsed ? NSMakeSize(CGFLOAT_MAX, target)
                                   : NSMakeSize(CGFLOAT_MAX, CGFLOAT_MAX);

    // 窗口原点在左下角：改高度时要把 origin 一起挪，否则收起会变成「顶栏往下掉」
    frame.origin.y += frame.size.height - target;
    frame.size.height = target;
    [self.panel setFrame:frame display:YES animate:NO];

    if (!collapsed) self.panel.frameAutosaveName = kFrameAutosaveName;   // 重新开始记尺寸
}

#pragma mark - 显示

- (void)show {
    [self buildIfNeeded];
    [NSApp activateIgnoringOtherApps:YES];
    [self.panel makeKeyAndOrderFront:nil];
    [self.webView evaluateJavaScript:@"window.__jarvisFocusInput && window.__jarvisFocusInput()"
                   completionHandler:nil];
}

- (void)hide {
    [self.panel orderOut:nil];
}

- (void)toggle {
    if (self.panel.isVisible && self.panel.isKeyWindow) [self hide];
    else [self show];
}

#pragma mark - ObjC → 页面

- (void)pushEvent:(NSDictionary *)event {
    if (!self.pageReady) {
        [self buildIfNeeded];
        [self.pendingEvents addObject:event];
        // 攒太多说明页面根本没起来，丢掉早的，别无限涨
        if (self.pendingEvents.count > 500) [self.pendingEvents removeObjectAtIndex:0];
        return;
    }
    [self deliver:event];
}

- (void)deliver:(NSDictionary *)event {
    NSData *json = [NSJSONSerialization dataWithJSONObject:event options:0 error:nil];
    if (!json) return;
    NSString *text = [[NSString alloc] initWithData:json encoding:NSUTF8StringEncoding];
    // 作为字符串参数传进去再在 JS 里 parse，省得为 JS 字面量做转义
    NSString *js = [NSString stringWithFormat:@"window.__jarvisReceive && window.__jarvisReceive(%@)",
                    [self jsStringLiteral:text]];
    [self.webView evaluateJavaScript:js completionHandler:nil];
}

- (NSString *)jsStringLiteral:(NSString *)text {
    NSData *encoded = [NSJSONSerialization dataWithJSONObject:@[text] options:0 error:nil];
    NSString *array = [[NSString alloc] initWithData:encoded encoding:NSUTF8StringEncoding];
    // ["..."] → "..."
    return [array substringWithRange:NSMakeRange(1, array.length - 2)];
}

#pragma mark - 页面 → ObjC

- (void)userContentController:(WKUserContentController *)controller
      didReceiveScriptMessage:(WKScriptMessage *)message {
    if (![message.body isKindOfClass:[NSDictionary class]]) return;
    NSDictionary *body = message.body;
    NSString *action = body[@"action"];

    if ([action isEqualToString:@"submit"]) {
        NSString *text = body[@"text"];
        if ([text isKindOfClass:[NSString class]] && text.length > 0) {
            [self.delegate conversationPanel:self didSubmitText:text];
        }
    } else if ([action isEqualToString:@"cancel"]) {
        [self.delegate conversationPanelDidRequestCancel:self];
    } else if ([action isEqualToString:@"new_session"]) {
        [self.delegate conversationPanelDidRequestNewSession:self];
    } else if ([action isEqualToString:@"restart_brain"]) {
        [self.delegate conversationPanelDidRequestRestartBrain:self];
    } else if ([action isEqualToString:@"voice_toggle"]) {
        [self.delegate conversationPanelDidRequestVoiceToggle:self];
    } else if ([action isEqualToString:@"confirm"]) {
        NSString *requestID = body[@"request_id"];
        if ([requestID isKindOfClass:[NSString class]]) {
            [self.delegate conversationPanel:self
                       didAnswerConfirmation:requestID
                                    approved:[body[@"approved"] boolValue]];
        }
    } else if ([action isEqualToString:@"collapse"]) {
        NSNumber *header = body[@"header"];
        [self setCollapsed:[body[@"collapsed"] boolValue]
              headerHeight:[header isKindOfClass:[NSNumber class]] ? header.doubleValue : 56.0];
    } else if ([action isEqualToString:@"drag_zones"]) {
        [self applyDragZonesFromMessage:body];
    } else if ([action isEqualToString:@"extract_file"]) {
        [self extractFileFromMessage:body];
    } else if ([action isEqualToString:@"sleep"]) {
        [self.delegate conversationPanel:self didRequestSleep:[body[@"sleeping"] boolValue]];
    } else if ([action isEqualToString:@"speak"]) {
        NSString *text = body[@"text"];
        if ([text isKindOfClass:[NSString class]] && text.length) {
            [self.delegate conversationPanel:self didRequestSpeak:text];
        }
    } else if ([action isEqualToString:@"set_model"]) {
        NSString *modelID = body[@"id"];
        if ([modelID isKindOfClass:[NSString class]] && modelID.length) {
            [self.delegate conversationPanel:self didRequestSetModel:modelID];
        }
    } else if ([action isEqualToString:@"add_model"]) {
        [self.delegate conversationPanel:self didRequestAddModel:body];
    } else if ([action isEqualToString:@"update_model"]) {
        [self.delegate conversationPanel:self didRequestUpdateModel:body];
    } else if ([action isEqualToString:@"remove_model"]) {
        NSString *modelID = body[@"id"];
        if ([modelID isKindOfClass:[NSString class]] && modelID.length) {
            [self.delegate conversationPanel:self didRequestRemoveModel:modelID];
        }
    } else if ([action isEqualToString:@"open_path"]) {
        NSString *path = body[@"path"];
        if ([path isKindOfClass:[NSString class]] && path.length) {
            [self.delegate conversationPanel:self
                              didRequestOpen:path
                                      reveal:[body[@"reveal"] boolValue]];
        }
    } else if ([action isEqualToString:@"set_opacity"]) {
        NSNumber *value = body[@"value"];
        if ([value isKindOfClass:[NSNumber class]]) self.panelOpacity = value.doubleValue;
    } else if ([action isEqualToString:@"close"]) {
        [self hide];
    } else if ([action isEqualToString:@"open_log"]) {
        // 断线时的「查看诊断」。Brain 日志比宿主日志有用得多——
        // 连不上的原因（缺 Key、端口被占、依赖装歪）基本都写在里面。
        [[NSWorkspace sharedWorkspace] openURL:
            [NSURL fileURLWithPath:[JarvisPaths brainLogPath]]];
    } else if ([action isEqualToString:@"open_config"]) {
        [[NSWorkspace sharedWorkspace] openURL:[NSURL fileURLWithPath:[JarvisPaths configPath]]];
    }
}

/// 页面上报顶栏可拖区域，及区域内不可拖的按钮矩形（都是 getBoundingClientRect()
/// 的原始值，坐标系跟 WKWebView 自身的 flipped bounds 完全一致，不用转换）。
- (void)applyDragZonesFromMessage:(NSDictionary *)body {
    NSRect (^rectFrom)(id) = ^NSRect(id raw) {
        if (![raw isKindOfClass:[NSDictionary class]]) return NSZeroRect;
        NSDictionary *r = raw;
        return NSMakeRect([r[@"x"] doubleValue], [r[@"y"] doubleValue],
                           [r[@"w"] doubleValue], [r[@"h"] doubleValue]);
    };

    self.webView.dragRegion = rectFrom(body[@"header"]);

    NSMutableArray<NSValue *> *excludes = [NSMutableArray array];
    NSArray *buttons = body[@"buttons"];
    if ([buttons isKindOfClass:[NSArray class]]) {
        for (id raw in buttons) [excludes addObject:[NSValue valueWithRect:rectFrom(raw)]];
    }
    self.webView.excludeRegions = excludes;
}

#pragma mark - 技能

/// 输入框敲 "/" 弹出的常用短语菜单，两部分拼起来：这几条固定的预设技能
/// （改配置只能手改 ~/.jarvis/skills.json，面板里没有编辑界面——
/// 真正常用的东西应该是"说得多"，不是"手动收藏"），
/// 加上下面按频率自动涌现的历史高频原话。
- (NSArray<NSDictionary *> *)defaultSkills {
    return @[
        @{@"id": @"s1", @"text": @"找一下桌面上的 Markdown 文档"},
        @{@"id": @"s2", @"text": @"打开 Safari，再看看我这台 Mac 现在状态怎么样"},
        @{@"id": @"s3", @"text": @"把桌面上的 Jarvis-temp-test.txt 重命名成 test-renamed.txt"},
    ];
}

/// 第一次跑没有这个文件就把默认三条落盘。
- (NSArray<NSDictionary *> *)loadSkills {
    NSData *data = [NSData dataWithContentsOfFile:[JarvisPaths skillsPath]];
    if (data) {
        id parsed = [NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
        if ([parsed isKindOfClass:[NSArray class]]) return parsed;
    }
    NSArray *defaults = [self defaultSkills];
    [self writeSkills:defaults];
    return defaults;
}

- (void)writeSkills:(NSArray *)items {
    NSData *data = [NSJSONSerialization dataWithJSONObject:items options:NSJSONWritingPrettyPrinted error:nil];
    if (data) [data writeToFile:[JarvisPaths skillsPath] atomically:YES];
}

#pragma mark - 常用短语频率

static const NSInteger kUsageMaxEntries = 300;   // 超过这个数就修剪，文件不能无限涨
static const NSInteger kUsagePruneKeep  = 150;
static const NSInteger kUsageTopN       = 8;     // "/" 菜单里最多展示几条高频项

- (NSMutableDictionary<NSString *, NSNumber *> *)loadUsageCounts {
    NSData *data = [NSData dataWithContentsOfFile:[JarvisPaths skillUsagePath]];
    if (!data) return [NSMutableDictionary dictionary];
    id parsed = [NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
    return [parsed isKindOfClass:[NSDictionary class]] ? [parsed mutableCopy] : [NSMutableDictionary dictionary];
}

- (void)saveUsageCounts:(NSDictionary<NSString *, NSNumber *> *)counts {
    NSDictionary *toSave = counts;
    if (counts.count > kUsageMaxEntries) {
        // 修剪只留高频那批：偶发的一次性长尾没必要陪着文件一起长胖
        NSArray *keys = [counts keysSortedByValueUsingComparator:^NSComparisonResult(NSNumber *a, NSNumber *b) {
            return [b compare:a];
        }];
        NSMutableDictionary *pruned = [NSMutableDictionary dictionary];
        NSInteger keep = MIN(kUsagePruneKeep, (NSInteger)keys.count);
        for (NSString *key in [keys subarrayWithRange:NSMakeRange(0, keep)]) pruned[key] = counts[key];
        toSave = pruned;
    }
    NSData *data = [NSJSONSerialization dataWithJSONObject:toSave options:NSJSONWritingPrettyPrinted error:nil];
    if (data) [data writeToFile:[JarvisPaths skillUsagePath] atomically:YES];
}

/// 只说过一次的不算"常说"——不然随便一句话都会立刻挤进菜单，反而是噪音。
- (NSArray<NSDictionary *> *)topUsageItemsFromCounts:(NSDictionary<NSString *, NSNumber *> *)counts {
    NSArray *keys = [counts keysSortedByValueUsingComparator:^NSComparisonResult(NSNumber *a, NSNumber *b) {
        return [b compare:a];
    }];
    NSMutableArray *items = [NSMutableArray array];
    for (NSString *key in keys) {
        if (items.count >= kUsageTopN) break;
        if (counts[key].integerValue < 2) continue;
        [items addObject:@{@"text": key, @"count": counts[key]}];
    }
    return items;
}

- (void)trackUsage:(NSString *)text {
    NSString *trimmed = [text stringByTrimmingCharactersInSet:
                          [NSCharacterSet whitespaceAndNewlineCharacterSet]];
    // 太长的多半是夹了附件内容或场景信息，不是"一句常用话"，且反正也不会重复
    if (trimmed.length == 0 || trimmed.length > 200) return;

    NSMutableDictionary<NSString *, NSNumber *> *counts = [self loadUsageCounts];
    counts[trimmed] = @([counts[trimmed] integerValue] + 1);
    [self saveUsageCounts:counts];
    [self pushEvent:@{@"type": @"usage", @"items": [self topUsageItemsFromCounts:counts]}];
}

#pragma mark - 文件解析

/// doc/docx/pdf/rtf 在页面里解析不了文档结构，页面把字节转 base64 发过来，
/// 这边用 PDFKit / NSAttributedString 原生提文字——都是系统自带框架，
/// 不为了这个给 Brain 添 Python 依赖（Brain 只用标准库这条线是刻意的）。
/// 解析挪到后台队列，大文件不卡 UI；回调切回主线程才能碰 WKWebView。
- (void)extractFileFromMessage:(NSDictionary *)body {
    NSString *requestID = body[@"request_id"];
    NSString *name = body[@"name"];
    NSString *ext = [body[@"ext"] lowercaseString];
    NSString *base64 = body[@"data_base64"];
    if (![requestID isKindOfClass:[NSString class]] || ![base64 isKindOfClass:[NSString class]]) return;

    NSData *data = [[NSData alloc] initWithBase64EncodedString:base64
                                                         options:NSDataBase64DecodingIgnoreUnknownCharacters];
    if (!data) {
        [self replyFileExtraction:requestID ok:NO payload:@"文件解码失败"];
        return;
    }

    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        NSString *error = nil;
        NSString *text = [ext isEqualToString:@"pdf"]
            ? [self extractPDFText:data error:&error]
            : [self extractDocumentText:data ext:ext error:&error];
        dispatch_async(dispatch_get_main_queue(), ^{
            if (text) [self replyFileExtraction:requestID ok:YES payload:text];
            else [self replyFileExtraction:requestID ok:NO
                                    payload:error ?: [NSString stringWithFormat:@"解析失败：%@", name]];
        });
    });
}

- (NSString *)extractPDFText:(NSData *)data error:(NSString **)error {
    PDFDocument *doc = [[PDFDocument alloc] initWithData:data];
    if (!doc) { *error = @"不是有效的 PDF"; return nil; }

    NSMutableString *text = [NSMutableString string];
    for (NSInteger i = 0; i < doc.pageCount; i++) {
        NSString *pageText = [doc pageAtIndex:i].string;
        if (pageText.length == 0) continue;
        if (text.length) [text appendString:@"\n\n"];
        [text appendString:pageText];
    }
    if (text.length == 0) { *error = @"PDF 里没有可提取的文字（可能是扫描件）"; return nil; }
    return text;
}

- (NSString *)extractDocumentText:(NSData *)data ext:(NSString *)ext error:(NSString **)error {
    NSString *docType = NSPlainTextDocumentType;
    if ([ext isEqualToString:@"docx"])      docType = NSOfficeOpenXMLTextDocumentType;
    else if ([ext isEqualToString:@"doc"])  docType = NSDocFormatTextDocumentType;
    else if ([ext isEqualToString:@"rtf"])  docType = NSRTFTextDocumentType;

    NSError *nsError = nil;
    NSAttributedString *attributed =
        [[NSAttributedString alloc] initWithData:data
                                          options:@{NSDocumentTypeDocumentAttribute: docType}
                               documentAttributes:nil
                                            error:&nsError];
    if (!attributed) {
        *error = nsError.localizedDescription ?: @"文档解析失败";
        return nil;
    }
    return attributed.string;
}

- (void)replyFileExtraction:(NSString *)requestID ok:(BOOL)ok payload:(NSString *)payload {
    NSString *js = [NSString stringWithFormat:
        @"window.__jarvisFileExtracted && window.__jarvisFileExtracted(%@, %@, %@)",
        [self jsStringLiteral:requestID], ok ? @"true" : @"false", [self jsStringLiteral:payload ?: @""]];
    [self.webView evaluateJavaScript:js completionHandler:nil];
}

#pragma mark - WKNavigationDelegate

- (void)webView:(WKWebView *)webView didFinishNavigation:(WKNavigation *)navigation {
    self.pageReady = YES;
    NSArray *queued = [self.pendingEvents copy];
    [self.pendingEvents removeAllObjects];
    for (NSDictionary *event in queued) [self deliver:event];
    // 页面自己不知道上次调到了几，由这边告诉它——滑块和暗色衬底才不会和实际错位
    [self deliver:@{@"type": @"opacity", @"value": @(self.panelOpacity)}];
}

- (void)webView:(WKWebView *)webView didFailNavigation:(WKNavigation *)navigation withError:(NSError *)error {
    NSLog(@"[jarvis] 对话面板加载失败：%@", error.localizedDescription);
}

@end
