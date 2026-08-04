#import "AppDelegate.h"

#import "JarvisPaths.h"
#import "Audio/AudioHub.h"
#import "Audio/SpeechPlayer.h"
#import "Audio/VoiceInputController.h"
#import "Audio/WakeWordDetector.h"
#import "Bridge/BrainIPCClient.h"
#import "MenuBar/StatusItemController.h"
#import "Process/BrainProcessManager.h"
#import "Tools/NativeToolExecutor.h"
#import "Window/ConversationPanelController.h"
#import "Window/OrbWindowController.h"

#import <Carbon/Carbon.h>

static const uint32_t kHotKeySignature = 'jrvs';
static const uint32_t kHotKeyPanel = 1;
static const uint32_t kHotKeyVoice = 2;

/// 唤醒词是常驻麦克风 + 持续跑模型推理，最费 CPU 的就是它。
/// 闲着没人说话时没必要一直听，30s 没有对话就把它关掉；
/// 一旦又忙起来（收音/播报）过后重新闲下来，refreshWakeGate 会自动拉回来。
static const NSTimeInterval kWakeIdleTimeout = 30.0;

/// 关掉之后不能永远不管——那样"贾维斯"就再也叫不动它了，只能靠快捷键。
/// 停 2 分钟、听 30 秒地占空转，CPU 省下来的同时唤醒词不会彻底死掉。
static const NSTimeInterval kWakeRestartInterval = 120.0;

@interface AppDelegate () <BrainIPCClientDelegate,
                           BrainProcessManagerDelegate,
                           ConversationPanelDelegate,
                           SpeechPlayerDelegate,
                           StatusItemControllerDelegate,
                           VoiceInputControllerDelegate,
                           WakeWordDetectorDelegate>
@property (nonatomic, strong) OrbWindowController *orb;
@property (nonatomic, strong) ConversationPanelController *conversation;
@property (nonatomic, strong) StatusItemController *statusItem;
@property (nonatomic, strong) BrainProcessManager *brainProcess;
@property (nonatomic, strong) BrainIPCClient *brain;
@property (nonatomic, strong) NativeToolExecutor *tools;
@property (nonatomic, strong) SpeechPlayer *player;
@property (nonatomic, strong) VoiceInputController *voice;
@property (nonatomic, strong) WakeWordDetector *wake;

@property (nonatomic, assign) EventHotKeyRef panelHotKey;
@property (nonatomic, assign) EventHotKeyRef voiceHotKey;
@property (nonatomic, copy)   NSString *brainState;
@property (nonatomic, copy)   NSString *uiState;
@property (nonatomic, copy)   NSString *uiDetail;
@property (nonatomic, copy)   NSDictionary *wakeConfig;
@property (nonatomic, assign) NSUInteger messageCounter;
@property (nonatomic, assign) BOOL voiceEnabled;
@property (nonatomic, copy)   NSDictionary *voiceConfig;
@property (nonatomic, copy)   NSString *brainDetail;
@property (nonatomic, assign) BOOL transcribing;
@property (nonatomic, assign) BOOL sleeping;
@property (nonatomic, strong) NSTimer *wakeIdleTimer;
@property (nonatomic, strong) NSTimer *wakeRestartTimer;
@property (nonatomic, assign) BOOL bootComplete;
@property (nonatomic, strong) NSMutableOrderedSet<NSString *> *seenAppsToday;
@property (nonatomic, strong) NSDate *seenAppsDay;
@property (nonatomic, copy)   NSString *pendingWakeContext;
@end

@implementation AppDelegate

#pragma mark - 生命周期

- (void)applicationDidFinishLaunching:(NSNotification *)note {
    [NSApp setActivationPolicy:NSApplicationActivationPolicyAccessory];   // 无 Dock 图标
    [self installEditingMenuForKeyboardShortcuts];
    [self terminateOtherInstances];

    self.brainState = @"idle";
    self.uiState = @"idle";
    self.voiceEnabled = YES;

    self.orb = [[OrbWindowController alloc] init];
    [self.orb start];
    [self.orb applyBootProgress:8];

    [self startAppUsageTracking];

    self.conversation = [[ConversationPanelController alloc] init];
    self.conversation.delegate = self;

    self.statusItem = [[StatusItemController alloc] init];
    self.statusItem.delegate = self;
    [self.statusItem install];

    self.tools = [[NativeToolExecutor alloc] init];
    [self checkAccessibilityTrust];

    self.player = [[SpeechPlayer alloc] init];
    self.player.delegate = self;

    self.brain = [[BrainIPCClient alloc] initWithSocketPath:[JarvisPaths socketPath]];
    self.brain.delegate = self;

    self.brainProcess = [[BrainProcessManager alloc] init];
    self.brainProcess.delegate = self;
    [self.brainProcess start];
    [self.brain start];
    [self.orb applyBootProgress:20];

    [self registerHotKeys];
}

/// App 是 accessory 策略，但对话面板成为前台窗口时仍会显示应用菜单栏。
/// 同时保留标准编辑快捷键和明确的退出入口，避免只能去状态栏图标里退出。
/// 在 AppKit 里靠 `[NSApp mainMenu]` 做 key equivalent 匹配、再转发成
/// copy:/paste:/cut:/selectAll: 发给第一响应者（这里就是 WKWebView）。
/// 没有 mainMenu 的话，哪怕菜单本身不显示，这几个快捷键在对话面板的
/// 输入框和消息区里也一律不生效。建一个不出现在屏幕上的 Edit 菜单，
/// 只为了让这条路由链路存在。
- (void)installEditingMenuForKeyboardShortcuts {
    NSMenu *mainMenu = [[NSMenu alloc] init];

    NSMenuItem *appMenuItem = [[NSMenuItem alloc] init];
    [mainMenu addItem:appMenuItem];
    NSMenu *appMenu = [[NSMenu alloc] initWithTitle:@"Jarvis"];
    NSMenuItem *quit = [appMenu addItemWithTitle:@"退出 J.A.R.V.I.S."
                                          action:@selector(terminate:)
                                   keyEquivalent:@"q"];
    quit.target = NSApp;
    appMenuItem.submenu = appMenu;

    NSMenuItem *editMenuItem = [[NSMenuItem alloc] init];
    [mainMenu addItem:editMenuItem];

    NSMenu *editMenu = [[NSMenu alloc] initWithTitle:@"Edit"];
    [editMenu addItemWithTitle:@"撤销" action:@selector(undo:) keyEquivalent:@"z"];
    NSMenuItem *redo = [editMenu addItemWithTitle:@"重做" action:@selector(redo:) keyEquivalent:@"z"];
    redo.keyEquivalentModifierMask = NSEventModifierFlagCommand | NSEventModifierFlagShift;
    [editMenu addItem:[NSMenuItem separatorItem]];
    [editMenu addItemWithTitle:@"剪切" action:@selector(cut:) keyEquivalent:@"x"];
    [editMenu addItemWithTitle:@"拷贝" action:@selector(copy:) keyEquivalent:@"c"];
    [editMenu addItemWithTitle:@"粘贴" action:@selector(paste:) keyEquivalent:@"v"];
    [editMenu addItemWithTitle:@"全选" action:@selector(selectAll:) keyEquivalent:@"a"];
    editMenuItem.submenu = editMenu;

    [NSApp setMainMenu:mainMenu];
}

/// 启动进度只前进不回退、只完成一次——refreshWakeGate 之后每次闲下来都会
/// 重新拉唤醒词，那条路不该把开机动画又拉回来放一遍。
/// reason 只进日志，不进壁纸——壁纸上的启动动效只显示 "LOADING NN%"，不接受文案。
- (void)markBootComplete:(NSString *)reason {
    if (self.bootComplete) return;
    self.bootComplete = YES;
    NSLog(@"[jarvis] 启动完成：%@", reason ?: @"就绪");
    [self.orb applyBootProgress:100];
}

- (void)applicationWillTerminate:(NSNotification *)note {
    [self unregisterHotKeys];
    [self cancelWakeIdleTimer];
    [self cancelWakeRestartTimer];
    [self.wake stop];
    [self.voice abort];
    [self.player stopAll];
    [self.brain stop];
    [self.brainProcess stop];
    [self.orb stop];
}

- (BOOL)applicationShouldTerminateAfterLastWindowClosed:(NSApplication *)sender { return NO; }

/// App 是 LSUIElement，没有 Dock 图标，但在访达里双击、或 `open -a Jarvis`
/// 仍会走到这里。既然用户明确点了它，就把对话面板给他。
- (BOOL)applicationShouldHandleReopen:(NSApplication *)sender hasVisibleWindows:(BOOL)hasWindows {
    [self.conversation show];
    return YES;
}

#pragma mark - 全局快捷键

// 用 Carbon 的 RegisterEventHotKey：不需要辅助功能权限，
// NSEvent 的全局监听则需要，那对唤出输入框和开麦这两件事来说太贵了。
static OSStatus JarvisHotKeyHandler(EventHandlerCallRef caller, EventRef event, void *context) {
    EventHotKeyID hotKeyID;
    if (GetEventParameter(event, kEventParamDirectObject, typeEventHotKeyID, NULL,
                          sizeof(hotKeyID), NULL, &hotKeyID) != noErr) return noErr;

    AppDelegate *self_ = (__bridge AppDelegate *)context;
    dispatch_async(dispatch_get_main_queue(), ^{
        if (hotKeyID.id == kHotKeyPanel) [self_.conversation toggle];
        else if (hotKeyID.id == kHotKeyVoice) [self_ toggleVoice];
    });
    return noErr;
}

- (void)registerHotKeys {
    EventTypeSpec spec = { .eventClass = kEventClassKeyboard, .eventKind = kEventHotKeyPressed };
    InstallApplicationEventHandler(&JarvisHotKeyHandler, 1, &spec, (__bridge void *)self, NULL);

    self.panelHotKey = [self registerKey:kVK_Space modifiers:optionKey identifier:kHotKeyPanel name:@"⌥Space"];
    self.voiceHotKey = [self registerKey:kVK_ANSI_V modifiers:optionKey identifier:kHotKeyVoice name:@"⌥V"];
}

- (EventHotKeyRef)registerKey:(UInt32)keyCode
                    modifiers:(UInt32)modifiers
                   identifier:(uint32_t)identifier
                         name:(NSString *)name {
    EventHotKeyID hotKeyID = { .signature = kHotKeySignature, .id = identifier };
    EventHotKeyRef ref = NULL;
    OSStatus status = RegisterEventHotKey(keyCode, modifiers, hotKeyID,
                                          GetApplicationEventTarget(), 0, &ref);
    if (status != noErr) {
        NSLog(@"[jarvis] %@ 注册失败（%d），可能被别的程序占了", name, (int)status);
        return NULL;
    }
    return ref;
}

- (void)unregisterHotKeys {
    if (self.panelHotKey) { UnregisterEventHotKey(self.panelHotKey); self.panelHotKey = NULL; }
    if (self.voiceHotKey) { UnregisterEventHotKey(self.voiceHotKey); self.voiceHotKey = NULL; }
}

#pragma mark - 球体状态

/// 球体状态由宿主裁决，不直接照搬 Brain 的 state：
/// 正在收音 > 正在播报 > Brain 的状态。否则 Brain 说完就报 idle，
/// 而音频还在播，球体会提前熄下去。
- (void)refreshUIState {
    // 优先级从高到低。睡眠压一切——它的语义就是"什么都别做"。
    NSString *state = self.brainState ?: @"idle";
    NSString *detail = self.brainDetail;
    if (self.sleeping) {
        state = @"sleeping"; detail = nil;
    } else if (self.transcribing) {
        state = @"transcribing"; detail = nil;
    } else if (self.voice.isListening) {
        state = @"listening"; detail = nil;
    } else if (self.player.isPlaying) {
        state = @"speaking"; detail = nil;
    }

    BOOL same = [state isEqualToString:self.uiState]
             && ((detail == nil && self.uiDetail == nil) || [detail isEqualToString:self.uiDetail]);
    if (same) return;
    self.uiState = state;
    self.uiDetail = detail;

    // 球体只认四个状态，executing/transcribing 这类细分对它没意义
    [self.orb applyState:[self orbStateFor:state]];
    [self.statusItem updateSessionState:state];
    NSMutableDictionary *event = [@{@"type": @"state", @"state": state} mutableCopy];
    if (detail.length) event[@"detail"] = detail;
    [self.conversation pushEvent:event];
}

/// 球体的状态词表比面板窄。多出来的状态映射到最接近的那个，别让球体收到不认识的词。
- (NSString *)orbStateFor:(NSString *)state {
    if ([state isEqualToString:@"transcribing"]) return @"listening";
    if ([state isEqualToString:@"executing"])    return @"thinking";
    if ([state isEqualToString:@"error"] || [state isEqualToString:@"sleeping"]) return @"idle";
    return state;
}

#pragma mark - 睡眠

/// 睡眠 = 停掉一切主动行为，但不退出、不清历史。
///
/// 和"收起面板"是两回事：收起只是把窗口缩成一条，语音唤醒照常工作；
/// 睡眠会把麦克风、唤醒词、模型请求、播报全部按下去。
- (void)setSleepMode:(BOOL)sleeping {
    if (self.sleeping == sleeping) return;
    self.sleeping = sleeping;

    if (sleeping) {
        [self.voice abort];             // 停采集，且不产出文本
        [self.player stopAll];          // 停播报
        [self.brain send:@{@"type": @"cancel"}];   // 取消模型请求与待执行工具
        [self cancelWakeIdleTimer];     // 已经手动睡了，用不着空闲计时器再补一刀
        [self cancelWakeRestartTimer];  // 睡眠期间不该有省电定时器把它自己叫醒
        [self.wake stop];               // 唤醒词一并停掉，麦克风才真的还回系统
        self.wake = nil;
        self.transcribing = NO;
    } else if (self.wakeConfig) {
        [self setUpWakeWordWithConfig:self.wakeConfig];
    }

    [self.conversation pushEvent:@{@"type": @"sleep", @"sleeping": @(sleeping)}];
    [self refreshWakeGate];
    [self refreshUIState];
}

#pragma mark - 语音

- (void)toggleVoice {
    if (self.sleeping) {
        [self.conversation pushEvent:@{@"type": @"error",
                                       @"message": @"J.A.R.V.I.S. 在睡眠中，先唤醒再说话"}];
        [self.conversation show];
        return;
    }
    if (!self.voiceEnabled) {
        [self.conversation pushEvent:@{@"type": @"error", @"message": @"语音输入已在配置里关闭"}];
        return;
    }
    if (self.voice.isListening) { [self.voice stop]; return; }

    // 打断：正在播报就掐掉；思考、工具执行和生成都取消。用户开口优先级最高。
    if (self.player.isPlaying) {
        [self.player stopAll];
        [self.brain send:@{@"type": @"cancel"}];
    } else if ([self.brainState isEqualToString:@"thinking"]
               || [self.brainState isEqualToString:@"executing"]
               || [self.brainState isEqualToString:@"speaking"]) {
        [self.brain send:@{@"type": @"cancel"}];
    }

    if (!self.voice) [self buildVoiceControllerWithConfig:self.voiceConfig];
    // 每次开麦都重取一遍应用名——用户想说的那个应用往往是刚打开的那个
    self.voice.contextualStrings = [self contextualStringsFromConfig:self.voiceConfig];
    [self.conversation show];
    [self.voice start];
}

- (void)buildVoiceControllerWithConfig:(NSDictionary *)config {
    NSString *locale = config[@"locale"] ?: @"zh-CN";

    JarvisVoiceOptions options = {
        .silenceTimeout  = [self seconds:config[@"silence_timeout"] fallback:0.9],
        .finalWait       = [self seconds:config[@"final_wait"]      fallback:0.6],
        .idleTimeout     = [self seconds:config[@"idle_timeout"]    fallback:30.0],
        .maxSeconds      = [self seconds:config[@"max_seconds"]     fallback:60.0],
        .preferOnDevice  = config[@"prefer_on_device"] ? [config[@"prefer_on_device"] boolValue] : YES,
        .addsPunctuation = config[@"punctuation"] ? [config[@"punctuation"] boolValue] : YES,
    };

    self.voice = [[VoiceInputController alloc] initWithLocale:locale options:options];
    self.voice.delegate = self;
    self.voice.contextualStrings = [self contextualStringsFromConfig:config];

    // 先把识别器建起来。冷启动第一次开麦要现加载语言资源，能明显感觉到卡一下；
    // 在这儿暖掉，用户按 ⌥V 时就是即时的。
    [self.voice prewarm];
}

- (NSTimeInterval)seconds:(id)value fallback:(NSTimeInterval)fallback {
    return [value isKindOfClass:[NSNumber class]] ? [value doubleValue] : fallback;
}

/// 喂给识别器的专有名词。
///
/// 这是提高识别准确率最划算的一招：识别器对"贾维斯""网易云音乐"这类专名
/// 本来最容易听错，提前告诉它有这些词之后基本一次听对。
/// 词表 = 唤醒词与固定术语 + 当前在跑的应用名（用户提到的应用几乎都在这里面）。
- (NSArray<NSString *> *)contextualStringsFromConfig:(NSDictionary *)config {
    NSMutableOrderedSet<NSString *> *words = [NSMutableOrderedSet orderedSet];
    [words addObjectsFromArray:@[@"贾维斯", @"Jarvis", @"JARVIS",
                                 @"网易云音乐", @"访达", @"剪贴板", @"截图",
                                 @"终端", @"系统设置", @"下一首", @"上一首"]];

    NSArray *extra = config[@"contextual_strings"];
    if ([extra isKindOfClass:[NSArray class]]) {
        for (id item in extra) {
            if ([item isKindOfClass:[NSString class]] && [item length]) [words addObject:item];
        }
    }

    for (NSRunningApplication *app in [NSWorkspace sharedWorkspace].runningApplications) {
        if (app.activationPolicy != NSApplicationActivationPolicyRegular) continue;
        if (app.localizedName.length) [words addObject:app.localizedName];
    }
    return words.array;
}

#pragma mark - 场景信息

/// 「今天用过的应用」不是历史日志——没有单独去记，就用 Jarvis 常驻期间
/// 观察到的启动事件累积，每天早上第一次触发时清空重来。
/// 这是"今天"这个词能诚实覆盖的范围：Jarvis 不在跑的那段时间不算数。
- (void)startAppUsageTracking {
    self.seenAppsToday = [NSMutableOrderedSet orderedSet];
    self.seenAppsDay = [NSDate date];
    for (NSRunningApplication *app in [NSWorkspace sharedWorkspace].runningApplications) {
        if (app.activationPolicy == NSApplicationActivationPolicyRegular && app.localizedName.length) {
            [self.seenAppsToday addObject:app.localizedName];
        }
    }
    [[[NSWorkspace sharedWorkspace] notificationCenter]
        addObserver:self selector:@selector(appDidLaunch:)
               name:NSWorkspaceDidLaunchApplicationNotification object:nil];
}

- (void)appDidLaunch:(NSNotification *)note {
    if (![[NSCalendar currentCalendar] isDateInToday:self.seenAppsDay]) {
        [self.seenAppsToday removeAllObjects];
        self.seenAppsDay = [NSDate date];
    }
    NSRunningApplication *app = note.userInfo[NSWorkspaceApplicationKey];
    if (app.activationPolicy == NSApplicationActivationPolicyRegular && app.localizedName.length) {
        [self.seenAppsToday addObject:app.localizedName];
    }
}

/// 唤醒时把这段拼在用户话之前一起发给 Brain（只拼给 Brain 看，面板里仍然只显示
/// 用户实际说的话，跟文件附件走的是同一个"面板干净、payload 带料"的路子）。
/// 用词特意说"仅供参考、不必逐条复述"——不然模型会把这几行读成台词背一遍。
- (NSString *)buildSceneContext {
    NSDateFormatter *fmt = [[NSDateFormatter alloc] init];
    fmt.locale = [NSLocale localeWithLocaleIdentifier:@"zh_CN"];
    fmt.dateFormat = @"yyyy年M月d日 EEEE HH:mm";
    NSString *now = [fmt stringFromDate:[NSDate date]];

    NSTimeInterval uptime = [NSProcessInfo processInfo].systemUptime;
    NSInteger hours = (NSInteger)uptime / 3600;
    NSInteger minutes = ((NSInteger)uptime % 3600) / 60;
    NSString *uptimeStr = hours > 0
        ? [NSString stringWithFormat:@"%ld 小时 %ld 分钟", (long)hours, (long)minutes]
        : [NSString stringWithFormat:@"%ld 分钟", (long)minutes];

    NSString *appsStr = self.seenAppsToday.count
        ? [self.seenAppsToday.array componentsJoinedByString:@"、"]
        : @"（还没观察到）";

    return [NSString stringWithFormat:
        @"[场景信息，仅供参考，不必逐条复述，自然的时候才提]\n"
        @"当前时间：%@\n本机已开机：%@\n今天用过的应用：%@\n\n", now, uptimeStr, appsStr];
}

#pragma mark - 唤醒词

- (void)setUpWakeWordWithConfig:(NSDictionary *)config {
    self.wakeConfig = config;
    [self cancelWakeRestartTimer];              // 走到这儿说明有别的路径在管唤醒词了，省电定时器让路
    if (self.sleeping) return;                 // 睡着时不重建，醒来那一刻才建
    BOOL enabled = [config[@"enabled"] boolValue];
    if (!enabled) {
        [self.wake stop]; self.wake = nil;
        [self markBootComplete:@"就绪（唤醒词已关闭）"];
        return;
    }
    if (self.wake.isRunning) return;

    NSString *modelDir = [JarvisPaths kwsModelDirectory];
    NSString *keywords = [JarvisPaths wakeKeywordsFile];
    if (!modelDir || !keywords) {
        NSLog(@"[jarvis] 唤醒词模型不存在，跳过（models/kws-zh-en 与 models/kws-jarvis.txt）");
        [self markBootComplete:@"就绪"];
        return;
    }

    NSNumber *score = config[@"score"];
    NSNumber *threshold = config[@"threshold"];
    self.wake = [[WakeWordDetector alloc] initWithModelDirectory:modelDir
                                                    keywordsFile:keywords
                                                           score:score ? score.floatValue : 1.5f
                                                       threshold:threshold ? threshold.floatValue : 0.25f];
    self.wake.delegate = self;

    // 唤醒词要开常驻麦克风，先确认授权，别在没权限时反复重试
    [[AudioHub shared] requestPermission:^(BOOL granted, NSString *reason) {
        if (!granted) {
            NSLog(@"[jarvis] 唤醒词未启动：%@", reason);
            [self markBootComplete:@"就绪（麦克风权限未授权）"];
            return;
        }
        [self.wake start];
        [self scheduleWakeIdleTimer];
        [self markBootComplete:nil];
    }];
}

/// 收音期间一定关闭唤醒词，避免一句话里提到 Jarvis 时再次触发。
/// 播报期间默认允许唤醒词，以支持用户直接说 Jarvis 打断；AudioHub 的
/// Voice Processing（AEC）负责先消掉扬声器回声。配置 barge_in=false
/// 可退回严格半双工。
///
/// 兼职做空闲计时的入口：忙的时候（收音/播报）先把倒计时按住；
/// 一旦又闲下来——唤醒词之前被空闲关掉了就重新拉起来，没关掉就重新数 30s。
- (void)refreshWakeGate {
    BOOL playing = self.player.isPlaying;
    BOOL listening = self.voice.isListening;
    BOOL bargeIn = [self.wakeConfig[@"barge_in"] boolValue];
    BOOL busy = playing || listening;
    self.wake.muted = listening || (playing && !bargeIn);
    if (busy || self.sleeping) {
        [self cancelWakeIdleTimer];
        // 唤醒词可能刚被省电计时器关掉；开始播报时为了允许打断，要临时拉回来。
        if (playing && bargeIn && !self.wake.isRunning && self.wakeConfig) {
            [self setUpWakeWordWithConfig:self.wakeConfig];
        }
        return;
    }
    if (self.wakeConfig && !self.wake.isRunning) {
        [self setUpWakeWordWithConfig:self.wakeConfig];
    } else {
        [self scheduleWakeIdleTimer];
    }
}

- (void)scheduleWakeIdleTimer {
    [self.wakeIdleTimer invalidate];
    __weak typeof(self) weakSelf = self;
    self.wakeIdleTimer = [NSTimer scheduledTimerWithTimeInterval:kWakeIdleTimeout
                                                           repeats:NO
                                                             block:^(NSTimer *timer) {
        [weakSelf wakeIdleTimerFired];
    }];
}

- (void)cancelWakeIdleTimer {
    [self.wakeIdleTimer invalidate];
    self.wakeIdleTimer = nil;
}

- (void)wakeIdleTimerFired {
    self.wakeIdleTimer = nil;
    if (self.sleeping || !self.wake.isRunning) return;
    NSLog(@"[jarvis] 闲置 %.0f 秒无对话，关闭常开麦克风省 CPU，%.0f 秒后自动恢复",
          kWakeIdleTimeout, kWakeRestartInterval);
    [self.wake stop];
    self.wake = nil;
    [self scheduleWakeRestartTimer];
}

- (void)scheduleWakeRestartTimer {
    [self.wakeRestartTimer invalidate];
    __weak typeof(self) weakSelf = self;
    self.wakeRestartTimer = [NSTimer scheduledTimerWithTimeInterval:kWakeRestartInterval
                                                              repeats:NO
                                                                block:^(NSTimer *timer) {
        [weakSelf wakeRestartTimerFired];
    }];
}

- (void)cancelWakeRestartTimer {
    [self.wakeRestartTimer invalidate];
    self.wakeRestartTimer = nil;
}

/// 省电窗口到点了，自己把唤醒词拉回来——不能指望用户先按一次快捷键才能救活它。
- (void)wakeRestartTimerFired {
    self.wakeRestartTimer = nil;
    if (self.sleeping || !self.wakeConfig) return;
    if (self.player.isPlaying || self.voice.isListening) return;   // 忙着就不插手，refreshWakeGate 会在闲下来时自己处理
    NSLog(@"[jarvis] 省电窗口结束，恢复唤醒词监听");
    [self setUpWakeWordWithConfig:self.wakeConfig];
}

- (void)wakeWordDetector:(WakeWordDetector *)detector didDetect:(NSString *)keyword {
    NSLog(@"[jarvis] 唤醒：%@", keyword);
    if (self.player.isPlaying) {
        NSLog(@"[jarvis] 用户打断播报：%@", keyword);
        [self.conversation pushEvent:@{@"type": @"barge_in", @"keyword": keyword ?: @""}];
    }
    [self.conversation pushEvent:@{@"type": @"wake", @"keyword": keyword ?: @""}];
    self.pendingWakeContext = [self buildSceneContext];   // 只用这一次，sendUserMessage 里消费掉
    [self toggleVoice];
}

- (void)wakeWordDetector:(WakeWordDetector *)detector failed:(NSString *)message {
    NSLog(@"[jarvis] 唤醒词故障：%@", message);
    [self.conversation pushEvent:@{@"type": @"log", @"message":
                                   [NSString stringWithFormat:@"唤醒词不可用：%@", message]}];
}

#pragma mark - VoiceInputControllerDelegate

- (void)voiceInputDidStart:(VoiceInputController *)controller {
    self.transcribing = NO;
    [self.conversation pushEvent:@{@"type": @"listening", @"active": @YES}];
    [self refreshWakeGate];
    [self refreshUIState];
}

/// 麦克风已关、在等终版结果。这段该显示"正在识别"，不该还写着"正在聆听"。
- (void)voiceInputDidFinishCapturing:(VoiceInputController *)controller {
    self.transcribing = YES;
    [self.conversation pushEvent:@{@"type": @"transcribing"}];
    [self refreshUIState];
}

- (void)voiceInput:(VoiceInputController *)controller partialText:(NSString *)text {
    [self.conversation pushEvent:@{@"type": @"transcript_partial", @"text": text}];
}

- (void)voiceInput:(VoiceInputController *)controller finalText:(NSString *)text {
    self.transcribing = NO;
    [self.conversation pushEvent:@{@"type": @"listening", @"active": @NO}];
    [self refreshWakeGate];
    [self refreshUIState];

    NSString *trimmed = [text stringByTrimmingCharactersInSet:
                         [NSCharacterSet whitespaceAndNewlineCharacterSet]];
    if (trimmed.length == 0) {
        [self.conversation pushEvent:@{@"type": @"transcript_empty"}];
        self.pendingWakeContext = nil;   // 唤醒了但没听清，别把这份场景信息拖到下一条不相关的消息里
        return;
    }
    [self.conversation pushEvent:@{@"type": @"transcript_final", @"text": trimmed}];
    [self sendUserMessage:trimmed];
}

- (void)voiceInput:(VoiceInputController *)controller level:(float)level {
    if (!self.voice.isListening) return;
    [self.orb applyLevel:level];
    [self.conversation pushMicLevel:level];
}

- (void)voiceInput:(VoiceInputController *)controller failed:(NSString *)message {
    self.transcribing = NO;
    [self.conversation pushEvent:@{@"type": @"listening", @"active": @NO}];
    [self refreshWakeGate];
    [self.conversation pushEvent:@{@"type": @"error", @"message": message}];
    [self.conversation show];
    [self refreshUIState];
    self.pendingWakeContext = nil;   // 识别失败，同样别把场景信息拖到下一条不相关的消息里
}

#pragma mark - SpeechPlayerDelegate

- (void)speechPlayerDidStart:(SpeechPlayer *)player  { [self refreshWakeGate]; [self refreshUIState]; }

- (void)speechPlayerDidFinish:(SpeechPlayer *)player {
    [self.orb applyLevel:0];
    [self refreshWakeGate];
    [self refreshUIState];
}

- (void)speechPlayer:(SpeechPlayer *)player level:(float)level {
    if (self.voice.isListening) return;         // 收音优先，别两个源抢同一根条
    [self.orb applyLevel:level];
    [self.conversation pushMicLevel:level];
}

#pragma mark - Brain 进程

- (void)brainProcess:(BrainProcessManager *)manager isRunning:(BOOL)running detail:(NSString *)detail {
    if (running) return;                       // 真正的"就绪"以 IPC 连上为准
    [self.statusItem updateBrainStatus:(detail ?: @"已停止") healthy:NO];
    // 大脑没了不是"闲着"，是这一轮失败了。悄悄回 idle 会让人以为任务正常结束。
    self.brainState = @"error";
    [self refreshUIState];
    if (detail) [self.conversation pushEvent:@{@"type": @"error", @"message": detail}];
}

#pragma mark - Brain IPC

- (void)brainClientDidConnect:(BrainIPCClient *)client {
    [self.statusItem updateBrainStatus:@"已连接" healthy:YES];
    [self.conversation pushEvent:@{@"type": @"connection", @"connected": @YES}];
    [self.orb applyBootProgress:55];
}

- (void)brainClient:(BrainIPCClient *)client didDisconnectWithReason:(NSString *)reason {
    [self.statusItem updateBrainStatus:@"连接中断" healthy:NO];
    self.brainState = @"idle";                 // 大脑没了，球体不能停在 thinking
    [self.player stopAll];
    [self refreshUIState];
    [self.conversation pushEvent:@{@"type": @"connection", @"connected": @NO,
                                   @"reason": reason ?: @""}];
}

- (void)brainClient:(BrainIPCClient *)client didReceiveEvent:(NSDictionary *)event {
    NSString *type = event[@"type"];

    if ([type isEqualToString:@"state"]) {
        self.brainState = event[@"state"] ?: @"idle";
        self.brainDetail = event[@"detail"];
        [self refreshUIState];
        return;                                 // 面板收的是 refreshUIState 合成后的状态
    }
    if ([type isEqualToString:@"speak"]) {
        [self.player enqueue:event[@"path"]];
        return;
    }
    if ([type isEqualToString:@"speak_stop"]) {
        [self.player stopAll];
        return;
    }
    if ([type isEqualToString:@"native_tool_request"]) {
        [self runNativeTool:event];
        return;
    }
    if ([type isEqualToString:@"wake_word"]) {
        // 用户在设置里切换了唤醒方式：立即生效，不用等下次连接/重启。
        [self setUpWakeWordWithConfig:event];
    }
    if ([type isEqualToString:@"tool_confirm_request"]) {
        [self.conversation show];               // 要确认就得让用户看得见
    } else if ([type isEqualToString:@"ready"]) {
        BOOL configured = [event[@"configured"] boolValue];
        [self.statusItem updateBrainStatus:configured ? @"已连接" : @"缺 API Key" healthy:configured];
        [self.orb applyBootProgress:80];

        NSDictionary *voiceConfig = event[@"voice_input"];
        if ([voiceConfig isKindOfClass:[NSDictionary class]]) {
            self.voiceEnabled = [voiceConfig[@"enabled"] boolValue];
            self.voiceConfig = voiceConfig;
            [self buildVoiceControllerWithConfig:voiceConfig];
        }
        NSDictionary *wakeConfig = event[@"wake_word"];
        if ([wakeConfig isKindOfClass:[NSDictionary class]]) {
            [self setUpWakeWordWithConfig:wakeConfig];
        }
    }

    [self.conversation pushEvent:event];
}

/// 只允许一个实例活着。
///
/// 每个实例都会拉起自己的 Brain，两个 Brain 抢同一个 `~/.jarvis/brain.sock`：
/// 后绑定的顶掉先绑定的，宿主连上就被踢、踢了又重连，面板一直显示「未连接」。
/// 日志里的样子是 brain.log 疯狂刷「宿主已连接 / 宿主断开 / Bad file descriptor」。
///
/// 多出来的实例主要有两个来源：从访达或系统设置里双击了 Jarvis.app；
/// 以及 `launchctl bootout` 是异步的，旧进程还没死 bootstrap 就拉起了新的，
/// 旧的从此脱离 launchd 管理，永远不会退。**新的赢**——它才是 launchd 认的那个。
- (void)terminateOtherInstances {
    NSString *bundleID = [[NSBundle mainBundle] bundleIdentifier];
    if (bundleID.length == 0) return;

    pid_t mine = [[NSProcessInfo processInfo] processIdentifier];
    for (NSRunningApplication *app in
         [NSRunningApplication runningApplicationsWithBundleIdentifier:bundleID]) {
        if (app.processIdentifier == mine) continue;
        NSLog(@"[jarvis] 发现另一个实例 pid=%d，终止它（一个 socket 只能有一个主人）",
              app.processIdentifier);
        if (![app terminate]) [app forceTerminate];
    }
}

/// 辅助功能权限没了就控制不了播放器（媒体键、GUI 脚本都要它）。
///
/// 这个权限**每次重新构建都会失效**：本地是 ad-hoc 签名，TCC 存的是 cdhash，
/// 二进制一变就对不上。系统设置里的开关看着还是开的，实际已经不作数。
/// 所以这里不能只在启动时看一眼日志，要主动弹系统那个"打开系统设置"的对话框。
- (void)checkAccessibilityTrust {
    if (AXIsProcessTrusted()) {
        NSLog(@"[jarvis] 辅助功能权限：已授权");
        return;
    }
    NSLog(@"[jarvis] 辅助功能权限：未授权——播放器控制、媒体键都会失败。"
          @"重新构建过的话要去系统设置里把 JARVIS 关掉再打开（cdhash 变了）");
    NSDictionary *options = @{(__bridge NSString *)kAXTrustedCheckOptionPrompt: @YES};
    AXIsProcessTrustedWithOptions((__bridge CFDictionaryRef)options);
}

- (void)runNativeTool:(NSDictionary *)event {
    NSString *name = event[@"name"];
    NSString *requestID = event[@"request_id"];
    NSDictionary *arguments = [event[@"arguments"] isKindOfClass:[NSDictionary class]] ? event[@"arguments"] : @{};
    if (![name isKindOfClass:[NSString class]] || ![requestID isKindOfClass:[NSString class]]) return;

    __weak typeof(self) weakSelf = self;
    [self.tools execute:name arguments:arguments completion:^(NSDictionary *result, NSString *error) {
        NSMutableDictionary *reply = [@{@"type": @"native_tool_result",
                                        @"request_id": requestID} mutableCopy];
        if (error) reply[@"error"] = error;
        else reply[@"result"] = result ?: @{};
        [weakSelf.brain send:reply];
    }];
}

#pragma mark - 对话面板

- (void)sendUserMessage:(NSString *)text {
    if (self.sleeping) {
        [self.conversation pushEvent:@{@"type": @"error",
                                       @"message": @"J.A.R.V.I.S. 在睡眠中，先唤醒再发送"}];
        return;
    }

    // 记的是干净的原话（这个函数唯一同时接文字输入和语音终版结果的入口），
    // 不是拼过场景信息/附件之后的 payload——"/" 菜单要的是用户真正说过什么。
    [self.conversation trackUsage:text];

    // 刚被唤醒词唤醒说的第一句话，把场景信息拼在前面一起发给 Brain——
    // 面板里仍然只显示用户实际打的/说的这句，跟文件附件是同一套"面板干净、
    // payload 带料"的路子。只用一次，用完就清，免得往后每条消息都夹带。
    NSString *payload = text;
    if (self.pendingWakeContext.length) {
        payload = [self.pendingWakeContext stringByAppendingString:text];
        self.pendingWakeContext = nil;
    }

    self.messageCounter += 1;
    NSString *messageID = [NSString stringWithFormat:@"msg_%lu", (unsigned long)self.messageCounter];
    [self.brain send:@{@"type": @"user_message", @"text": payload, @"id": messageID}];
}

- (void)conversationPanel:(ConversationPanelController *)panel didSubmitText:(NSString *)text {
    [self sendUserMessage:text];
}

- (void)conversationPanelDidRequestCancel:(ConversationPanelController *)panel {
    [self.player stopAll];
    [self.brain send:@{@"type": @"cancel"}];
}

- (void)conversationPanelDidRequestNewSession:(ConversationPanelController *)panel {
    [self.player stopAll];
    [self.brain send:@{@"type": @"new_session"}];
}

- (void)conversationPanelDidRequestRestartBrain:(ConversationPanelController *)panel {
    [self restartBrain];
}

- (void)conversationPanelDidRequestVoiceToggle:(ConversationPanelController *)panel {
    [self toggleVoice];
}

- (void)conversationPanel:(ConversationPanelController *)panel didRequestSleep:(BOOL)sleeping {
    [self setSleepMode:sleeping];
}

- (void)conversationPanel:(ConversationPanelController *)panel didRequestSpeak:(NSString *)text {
    if (self.sleeping) return;
    [self.brain send:@{@"type": @"speak_text", @"text": text}];
}

- (void)conversationPanel:(ConversationPanelController *)panel didRequestSetModel:(NSString *)modelID {
    [self.brain send:@{@"type": @"set_model", @"id": modelID}];
}

- (void)conversationPanel:(ConversationPanelController *)panel didRequestAddModel:(NSDictionary *)fields {
    NSString *(^str)(id) = ^NSString *(id value) {
        return [value isKindOfClass:[NSString class]] ? value : @"";
    };
    [self.brain send:@{@"type": @"add_model",
                       @"label": str(fields[@"label"]),
                       @"base_url": str(fields[@"base_url"]),
                       @"api_key": str(fields[@"api_key"]),
                       @"model": str(fields[@"model"])}];
}

- (void)conversationPanel:(ConversationPanelController *)panel didRequestUpdateModel:(NSDictionary *)fields {
    NSString *(^str)(id) = ^NSString *(id value) {
        return [value isKindOfClass:[NSString class]] ? value : @"";
    };
    [self.brain send:@{@"type": @"update_model",
                       @"id": str(fields[@"id"]),
                       @"label": str(fields[@"label"]),
                       @"base_url": str(fields[@"base_url"]),
                       @"api_key": str(fields[@"api_key"]),
                       @"model": str(fields[@"model"])}];
}

- (void)conversationPanel:(ConversationPanelController *)panel didRequestRemoveModel:(NSString *)modelID {
    [self.brain send:@{@"type": @"remove_model", @"id": modelID}];
}

- (void)conversationPanel:(ConversationPanelController *)panel didRequestSetWakeWordEnabled:(BOOL)enabled {
    [self.brain send:@{@"type": @"set_wake_word", @"enabled": @(enabled)}];
}

/// 文件卡片上的「在访达中显示 / 打开」。走 NSWorkspace 而不是 open(1)：
/// TCC 按 bundle 归属，从宿主进程发起，授权才算在 Jarvis.app 头上。
- (void)conversationPanel:(ConversationPanelController *)panel
          didRequestOpen:(NSString *)path reveal:(BOOL)reveal {
    NSString *full = [path stringByExpandingTildeInPath];
    if (![[NSFileManager defaultManager] fileExistsAtPath:full]) {
        [self.conversation pushEvent:@{@"type": @"error",
                                       @"message": [NSString stringWithFormat:@"文件不在了：%@", path]}];
        return;
    }
    NSURL *url = [NSURL fileURLWithPath:full];
    if (reveal) {
        [[NSWorkspace sharedWorkspace] activateFileViewerSelectingURLs:@[url]];
    } else {
        [[NSWorkspace sharedWorkspace] openURL:url];
    }
}

- (void)conversationPanel:(ConversationPanelController *)panel
   didAnswerConfirmation:(NSString *)requestID
                approved:(BOOL)approved
                   scope:(NSString *)scope {
    [self.brain send:@{@"type": @"tool_confirm_response",
                       @"request_id": requestID,
                       @"approved": @(approved),
                       @"scope": ([scope isKindOfClass:[NSString class]] ? scope : @"once")}];
}

- (void)conversationPanel:(ConversationPanelController *)panel
   didRequestBrainMessage:(NSDictionary *)message {
    [self.brain send:message];
}

#pragma mark - 菜单栏

- (void)statusItemDidRequestToggleConversation:(StatusItemController *)controller {
    [self.conversation toggle];
}

- (void)statusItemDidRequestVoice:(StatusItemController *)controller {
    [self toggleVoice];
}

- (void)statusItemDidRequestNewSession:(StatusItemController *)controller {
    [self.player stopAll];
    [self.brain send:@{@"type": @"new_session"}];
    [self.conversation show];
}

- (void)statusItemDidRequestRestartBrain:(StatusItemController *)controller {
    [self restartBrain];
}

- (void)restartBrain {
    [self.player stopAll];
    [self.statusItem updateBrainStatus:@"重启中…" healthy:YES];
    [self.conversation pushEvent:@{@"type": @"log", @"message": @"正在重启大脑…"}];
    [self.brainProcess restart];
}

@end
