#import "OrbWindowController.h"
#import "JarvisPaths.h"

#import <WebKit/WebKit.h>
#import <IOKit/ps/IOPowerSources.h>
#import <IOKit/ps/IOPSKeys.h>

#pragma mark - 壁纸窗口

/// 永不成为 key / main 窗口，避免抢走键盘焦点。
@interface OrbWindow : NSWindow
@end

@implementation OrbWindow
- (BOOL)canBecomeKeyWindow  { return NO; }
- (BOOL)canBecomeMainWindow { return NO; }
@end

#pragma mark -

@interface OrbWindowController () <WKNavigationDelegate>
@property (nonatomic, strong) NSMutableArray<OrbWindow *> *windows;
@property (nonatomic, strong) NSMutableArray<WKWebView *> *webViews;
@property (nonatomic, strong) NSTimer *powerTimer;
@property (nonatomic, copy)   NSString *lastPower;
@property (nonatomic, copy)   NSString *orbState;
@property (nonatomic, assign) float lastLevel;
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
}

- (void)stop {
    [[NSNotificationCenter defaultCenter] removeObserver:self];
    [self.powerTimer invalidate];
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
    [window orderFrontRegardless];

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
    // 页面就绪后同步当前电源档位与状态，避免重建窗口后回到默认值
    [self pushPower:([self onBattery] ? @"battery" : @"ac") to:webView];
    NSString *js = [NSString stringWithFormat:
        @"window.__jarvisSetState && window.__jarvisSetState('%@')", self.orbState ?: @"idle"];
    [webView evaluateJavaScript:js completionHandler:nil];
}

@end
