#import "ConversationPanelController.h"
#import "JarvisPaths.h"

#import <WebKit/WebKit.h>

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

@interface ConversationPanelController () <WKScriptMessageHandler, WKNavigationDelegate>
@property (nonatomic, strong) ConversationPanel *panel;
@property (nonatomic, strong) WKWebView *webView;
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
    self.webView = [[WKWebView alloc] initWithFrame:frame configuration:config];
    self.webView.navigationDelegate = self;
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
    } else if ([action isEqualToString:@"sleep"]) {
        [self.delegate conversationPanel:self didRequestSleep:[body[@"sleeping"] boolValue]];
    } else if ([action isEqualToString:@"speak"]) {
        NSString *text = body[@"text"];
        if ([text isKindOfClass:[NSString class]] && text.length) {
            [self.delegate conversationPanel:self didRequestSpeak:text];
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
