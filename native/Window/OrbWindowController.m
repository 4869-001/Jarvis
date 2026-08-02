#import "OrbWindowController.h"
#import "JarvisPaths.h"

#import <WebKit/WebKit.h>
#import <IOKit/ps/IOPowerSources.h>
#import <IOKit/ps/IOPSKeys.h>
#import <mach/mach.h>
#import <mach/mach_host.h>

#pragma mark - 壁纸窗口

/// 永不成为 key / main 窗口，避免抢走键盘焦点。
@interface OrbWindow : NSWindow
@end

@implementation OrbWindow
- (BOOL)canBecomeKeyWindow  { return NO; }
- (BOOL)canBecomeMainWindow { return NO; }
@end

#pragma mark -

/// WKUserContentController 会强引用它的 message handler；直接传 self 会形成
/// self → webViews → webView → userContentController → self 的引用环，
/// 换屏重建窗口时旧 webView 永远释放不掉。用这层弱引用代理断环。
@interface JarvisScriptMessageProxy : NSObject <WKScriptMessageHandler>
@property (nonatomic, weak) id<WKScriptMessageHandler> target;
@end

@implementation JarvisScriptMessageProxy
- (void)userContentController:(WKUserContentController *)userContentController
       didReceiveScriptMessage:(WKScriptMessage *)message {
    [self.target userContentController:userContentController didReceiveScriptMessage:message];
}
@end

#pragma mark -

@interface OrbWindowController () <WKNavigationDelegate, WKScriptMessageHandler>
@property (nonatomic, strong) NSMutableArray<OrbWindow *> *windows;
@property (nonatomic, strong) NSMutableArray<WKWebView *> *webViews;
@property (nonatomic, strong) NSTimer *powerTimer;
@property (nonatomic, copy)   NSString *lastPower;
@property (nonatomic, copy)   NSString *orbState;
@property (nonatomic, assign) float lastLevel;

@property (nonatomic, strong) NSTimer *cpuTimer;
@property (nonatomic, assign) BOOL hasPrevCPUSample;
@property (nonatomic, assign) unsigned long long prevCPUBusy;
@property (nonatomic, assign) unsigned long long prevCPUTotal;
@property (nonatomic, assign) double lastCPUPercent;

@property (nonatomic, assign) NSInteger lastBootPercent;
@end

@implementation OrbWindowController

- (void)start {
    self.windows = [NSMutableArray array];
    self.webViews = [NSMutableArray array];
    self.lastPower = @"";
    self.orbState = @"idle";

    [self rebuildWindows];

    // 接显示器 / 改分辨率 / 改缩放后重建窗口
    [[NSNotificationCenter defaultCenter] addObserver:self
                                             selector:@selector(rebuildWindows)
                                                 name:NSApplicationDidChangeScreenParametersNotification
                                               object:nil];

    // 电源状态轮询（30 秒一次足够，比 IOKit 回调好维护）
    self.powerTimer = [NSTimer scheduledTimerWithTimeInterval:30.0 repeats:YES
                                                        block:^(NSTimer *t) { [self pushPowerState]; }];
    [self pushPowerState];

    // CPU 占用轮询。host_statistics 只是读一次内核计数器，比拉起 top/ps 便宜得多，
    // 2 秒一次的开销可以忽略——不会出现"为了显示 CPU 占用反而多耗 CPU"的荒谬情况。
    self.cpuTimer = [NSTimer scheduledTimerWithTimeInterval:2.0 repeats:YES
                                                      block:^(NSTimer *t) { [self pushCPUState]; }];
    [self pushCPUState];
}

- (void)stop {
    [[NSNotificationCenter defaultCenter] removeObserver:self];
    [self.powerTimer invalidate];
    [self.cpuTimer invalidate];
    for (OrbWindow *window in self.windows) [window orderOut:nil];
    [self.windows removeAllObjects];
    [self.webViews removeAllObjects];
}

#pragma mark - 状态

- (void)applyState:(NSString *)state {
    if (state.length == 0 || [state isEqualToString:self.orbState]) return;
    self.orbState = state;

    NSString *js = [NSString stringWithFormat:
        @"window.__jarvisSetState && window.__jarvisSetState('%@')", state];
    for (WKWebView *webView in self.webViews) {
        [webView evaluateJavaScript:js completionHandler:nil];
    }
}

- (void)applyLevel:(float)level {
    level = MIN(1.0f, MAX(0.0f, level));
    // 20Hz × 屏幕数的 evaluateJavaScript 不便宜，肉眼看不出的变化就别发
    if (fabsf(level - self.lastLevel) < 0.02f && !(level == 0.0f && self.lastLevel != 0.0f)) return;
    self.lastLevel = level;

    NSString *js = [NSString stringWithFormat:
        @"window.__jarvisSetLevel && window.__jarvisSetLevel(%.3f)", level];
    for (WKWebView *webView in self.webViews) {
        [webView evaluateJavaScript:js completionHandler:nil];
    }
}

- (void)applyBootProgress:(NSInteger)percent {
    self.lastBootPercent = MAX(0, MIN(100, percent));
    NSString *js = [NSString stringWithFormat:
        @"window.__jarvisSetBoot && window.__jarvisSetBoot(%ld)", (long)self.lastBootPercent];
    for (WKWebView *webView in self.webViews) [webView evaluateJavaScript:js completionHandler:nil];
}

#pragma mark - 窗口构建

- (void)rebuildWindows {
    for (OrbWindow *window in self.windows) [window orderOut:nil];
    [self.windows removeAllObjects];
    [self.webViews removeAllObjects];

    for (NSScreen *screen in [NSScreen screens]) {
        [self.windows addObject:[self makeWindowForScreen:screen]];
    }
    self.lastPower = @"";       // 强制向新窗口重推一次电源状态
    [self pushPowerState];
}

- (OrbWindow *)makeWindowForScreen:(NSScreen *)screen {
    OrbWindow *window = [[OrbWindow alloc] initWithContentRect:screen.frame
                                                     styleMask:NSWindowStyleMaskBorderless
                                                       backing:NSBackingStoreBuffered
                                                         defer:NO
                                                        screen:screen];

    // 关键：压到桌面图标之下、系统壁纸之上
    window.level = CGWindowLevelForKey(kCGDesktopIconWindowLevelKey) - 1;
    window.collectionBehavior = NSWindowCollectionBehaviorCanJoinAllSpaces
                              | NSWindowCollectionBehaviorStationary
                              | NSWindowCollectionBehaviorIgnoresCycle
                              | NSWindowCollectionBehaviorFullScreenNone;
    window.opaque = NO;
    window.backgroundColor = [NSColor clearColor];
    window.hasShadow = NO;
    window.ignoresMouseEvents = YES;        // 点击穿透到桌面
    window.releasedWhenClosed = NO;
    window.movable = NO;

    WKWebViewConfiguration *config = [[WKWebViewConfiguration alloc] init];
    config.suppressesIncrementalRendering = YES;
    // 页面用两次 requestAnimationFrame 确认球体真的合成上屏后才回报这条消息，
    // 比 didFinishNavigation（只代表 DOM/CSS 加载完，不代表 WebGL 已合成）更准，
    // 否则窗口一淡入会看见进度条先到、球体隔一拍才跟上。
    JarvisScriptMessageProxy *readyProxy = [[JarvisScriptMessageProxy alloc] init];
    readyProxy.target = self;
    [config.userContentController addScriptMessageHandler:readyProxy name:@"jarvisSphereReady"];

    WKWebView *webView = [[WKWebView alloc] initWithFrame:screen.frame configuration:config];
    webView.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
    webView.navigationDelegate = self;

    // 透明底，露出系统壁纸。drawsBackground 是 WKWebView 的私有 KVC 键，
    // 若未来系统改名会抛异常，故先探测再设置；失败也只是变成不透明底。
    @try {
        [webView setValue:@NO forKey:@"drawsBackground"];
    } @catch (NSException *exception) {
        NSLog(@"[jarvis] drawsBackground 不可用：%@", exception.reason);
    }
    if ([webView respondsToSelector:@selector(setUnderPageBackgroundColor:)]) {
        webView.underPageBackgroundColor = [NSColor clearColor];
    }

    NSURL *page = [JarvisPaths webPage:@"wallpaper.html"];
    [webView loadFileURL:page allowingReadAccessToURL:[page URLByDeletingLastPathComponent]];

    window.contentView = webView;
    // WKWebView 在拿到首帧前会先合成一层黑，早于 CSS 的暗晕、更早于 boot 进度条、
    // 更更早于球体本身——window 一 orderFrontRegardless 用户就先看见这一下黑闪。
    // 干脆先零透明度上屏，等 didFinishNavigation 里页面已经画出东西了再一次性淡入，
    // 黑闪、进度条弹出、球体延迟成型这三段就合并成一次干净的渐显。
    window.alphaValue = 0.0;
    [window orderFrontRegardless];

    // 保险丝：WebGL 初始化失败、或页面因为某种原因从没发出 ready 消息时，
    // 窗口不能永远隐身——1.2s 后没等到信号就直接淡入，只是画面里可能缺球体。
    __weak OrbWindow *weakWindow = window;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.2 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        [self revealWindow:weakWindow];
    });

    [[NSNotificationCenter defaultCenter] addObserver:self
                                             selector:@selector(occlusionChanged:)
                                                 name:NSWindowDidChangeOcclusionStateNotification
                                               object:window];

    [self.webViews addObject:webView];
    return window;
}

#pragma mark - 省电

/// 窗口被完全遮挡时停帧，重新可见时恢复。
- (void)occlusionChanged:(NSNotification *)note {
    NSWindow *window = note.object;
    if (![window.contentView isKindOfClass:[WKWebView class]]) return;
    WKWebView *webView = (WKWebView *)window.contentView;
    BOOL visible = (window.occlusionState & NSWindowOcclusionStateVisible) != 0;
    NSString *js = [NSString stringWithFormat:
        @"window.__jarvisSetVisible && window.__jarvisSetVisible(%@)", visible ? @"true" : @"false"];
    [webView evaluateJavaScript:js completionHandler:nil];
}

- (void)pushPowerState {
    NSString *state = [self onBattery] ? @"battery" : @"ac";
    if ([state isEqualToString:self.lastPower]) return;
    self.lastPower = state;
    for (WKWebView *webView in self.webViews) [self pushPower:state to:webView];
}

- (void)pushPower:(NSString *)state to:(WKWebView *)webView {
    NSString *js = [NSString stringWithFormat:
        @"window.__jarvisSetPower && window.__jarvisSetPower('%@')", state];
    [webView evaluateJavaScript:js completionHandler:nil];
}

/// 整机（不是 Jarvis 自己）CPU 占用。跟 top 显示的口径一致：
/// busy = user + system + nice，除以总 ticks（含 idle），两次采样求增量百分比。
- (void)pushCPUState {
    host_cpu_load_info_data_t info;
    mach_msg_type_number_t count = HOST_CPU_LOAD_INFO_COUNT;
    kern_return_t kr = host_statistics(mach_host_self(), HOST_CPU_LOAD_INFO,
                                        (host_info_t)&info, &count);
    if (kr != KERN_SUCCESS) return;

    unsigned long long busy = info.cpu_ticks[CPU_STATE_USER]
                             + info.cpu_ticks[CPU_STATE_SYSTEM]
                             + info.cpu_ticks[CPU_STATE_NICE];
    unsigned long long total = busy + info.cpu_ticks[CPU_STATE_IDLE];

    if (self.hasPrevCPUSample && total > self.prevCPUTotal) {
        unsigned long long busyDelta = busy - self.prevCPUBusy;
        unsigned long long totalDelta = total - self.prevCPUTotal;
        self.lastCPUPercent = 100.0 * (double)busyDelta / (double)totalDelta;
        for (WKWebView *webView in self.webViews) [self pushCPU:self.lastCPUPercent to:webView];
    }
    self.prevCPUBusy = busy;
    self.prevCPUTotal = total;
    self.hasPrevCPUSample = YES;
}

- (void)pushCPU:(double)percent to:(WKWebView *)webView {
    NSString *js = [NSString stringWithFormat:
        @"window.__jarvisSetCPU && window.__jarvisSetCPU(%.1f)", percent];
    [webView evaluateJavaScript:js completionHandler:nil];
}

- (BOOL)onBattery {
    if ([[NSProcessInfo processInfo] isLowPowerModeEnabled]) return YES;

    CFTypeRef blob = IOPSCopyPowerSourcesInfo();
    if (!blob) return NO;
    CFArrayRef sources = IOPSCopyPowerSourcesList(blob);
    if (!sources) { CFRelease(blob); return NO; }

    BOOL onBattery = NO;
    for (CFIndex i = 0; i < CFArrayGetCount(sources); i++) {
        CFDictionaryRef info = IOPSGetPowerSourceDescription(blob, CFArrayGetValueAtIndex(sources, i));
        if (!info) continue;
        NSString *sourceState = (__bridge NSString *)CFDictionaryGetValue(info, CFSTR(kIOPSPowerSourceStateKey));
        if ([sourceState isEqualToString:@kIOPSBatteryPowerValue]) { onBattery = YES; break; }
    }
    CFRelease(sources);
    CFRelease(blob);
    return onBattery;
}

#pragma mark - WKNavigationDelegate

- (void)webView:(WKWebView *)webView didFinishNavigation:(WKNavigation *)navigation {
    // 页面就绪后同步当前电源档位、状态与最近一次 CPU 读数，避免重建窗口后回到默认值
    [self pushPower:([self onBattery] ? @"battery" : @"ac") to:webView];
    if (self.hasPrevCPUSample) [self pushCPU:self.lastCPUPercent to:webView];
    // 接显示器时新建的窗口：启动早就跑完了就直接同步到 100，别在新屏幕上重播一遍开机动画
    if (self.lastBootPercent > 0) {
        NSString *bootJs = [NSString stringWithFormat:
            @"window.__jarvisSetBoot && window.__jarvisSetBoot(%ld)", (long)self.lastBootPercent];
        [webView evaluateJavaScript:bootJs completionHandler:nil];
    }
    NSString *js = [NSString stringWithFormat:
        @"window.__jarvisSetState && window.__jarvisSetState('%@')", self.orbState ?: @"idle"];
    [webView evaluateJavaScript:js completionHandler:nil];
    // 窗口的淡入不在这里触发——didFinishNavigation 只代表 DOM/CSS 加载完，
    // WebGL 球体是否已经合成上屏还得等页面自己回报，见 userContentController:didReceiveScriptMessage:。
}

#pragma mark - WKScriptMessageHandler

- (void)userContentController:(WKUserContentController *)userContentController
        didReceiveScriptMessage:(WKScriptMessage *)message {
    if (![message.name isEqualToString:@"jarvisSphereReady"]) return;
    [self revealWindow:(NSWindow *)message.webView.window];
}

/// 淡入只做一次；已经可见（或窗口已经没了）时安全地什么都不做。
- (void)revealWindow:(NSWindow *)window {
    if (!window || window.alphaValue >= 1.0) return;
    [NSAnimationContext runAnimationGroup:^(NSAnimationContext *ctx) {
        ctx.duration = 0.45;
        window.animator.alphaValue = 1.0;
    } completionHandler:nil];
}

@end
