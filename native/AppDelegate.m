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
@property (nonatomic, assign) NSUInteger messageCounter;
@property (nonatomic, assign) BOOL voiceEnabled;
@property (nonatomic, copy)   NSDictionary *voiceConfig;
@end

@implementation AppDelegate

#pragma mark - 生命周期

- (void)applicationDidFinishLaunching:(NSNotification *)note {
    [NSApp setActivationPolicy:NSApplicationActivationPolicyAccessory];   // 无 Dock 图标
    [self terminateOtherInstances];

    self.brainState = @"idle";
    self.uiState = @"idle";
    self.voiceEnabled = YES;

    self.orb = [[OrbWindowController alloc] init];
    [self.orb start];

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

    [self registerHotKeys];
}

- (void)applicationWillTerminate:(NSNotification *)note {
    [self unregisterHotKeys];
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
    NSString *state = self.brainState ?: @"idle";
    if (self.voice.isListening) state = @"listening";
    else if (self.player.isPlaying) state = @"speaking";

    if ([state isEqualToString:self.uiState]) return;
    self.uiState = state;

    [self.orb applyState:state];
    [self.statusItem updateSessionState:state];
    [self.conversation pushEvent:@{@"type": @"state", @"state": state}];
}

#pragma mark - 语音

- (void)toggleVoice {
    if (!self.voiceEnabled) {
        [self.conversation pushEvent:@{@"type": @"error", @"message": @"语音输入已在配置里关闭"}];
        return;
    }
    if (self.voice.isListening) { [self.voice stop]; return; }

    // 打断：正在播报就掐掉，正在生成就取消。用户开口的优先级最高。
    if (self.player.isPlaying) {
        [self.player stopAll];
        [self.brain send:@{@"type": @"cancel"}];
    } else if ([self.brainState isEqualToString:@"thinking"]) {
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
    [words addObjectsFromArray:@[@"贾维斯", @"Jarvis", @"J.A.R.V.I.S.",
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

#pragma mark - 唤醒词

- (void)setUpWakeWordWithConfig:(NSDictionary *)config {
    BOOL enabled = [config[@"enabled"] boolValue];
    if (!enabled) { [self.wake stop]; self.wake = nil; return; }
    if (self.wake.isRunning) return;

    NSString *modelDir = [JarvisPaths kwsModelDirectory];
    NSString *keywords = [JarvisPaths wakeKeywordsFile];
    if (!modelDir || !keywords) {
        NSLog(@"[jarvis] 唤醒词模型不存在，跳过（models/kws-zh-en 与 models/kws-jarvis.txt）");
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
            return;
        }
        [self.wake start];
    }];
}

/// 半双工门（评审 §6.5 第一层）：播报和收音期间都不让唤醒词触发。
/// 前者防止 Jarvis 把自己念出来的"贾维斯"当成唤醒，后者防止一句话里
/// 提到"贾维斯"时在收音中途再唤醒一次。
- (void)refreshWakeGate {
    self.wake.muted = self.player.isPlaying || self.voice.isListening;
}

- (void)wakeWordDetector:(WakeWordDetector *)detector didDetect:(NSString *)keyword {
    NSLog(@"[jarvis] 唤醒：%@", keyword);
    [self.conversation pushEvent:@{@"type": @"wake", @"keyword": keyword ?: @""}];
    [self toggleVoice];
}

- (void)wakeWordDetector:(WakeWordDetector *)detector failed:(NSString *)message {
    NSLog(@"[jarvis] 唤醒词故障：%@", message);
    [self.conversation pushEvent:@{@"type": @"log", @"message":
                                   [NSString stringWithFormat:@"唤醒词不可用：%@", message]}];
}

#pragma mark - VoiceInputControllerDelegate

- (void)voiceInputDidStart:(VoiceInputController *)controller {
    [self.conversation pushEvent:@{@"type": @"listening", @"active": @YES}];
    [self refreshWakeGate];
    [self refreshUIState];
}

- (void)voiceInput:(VoiceInputController *)controller partialText:(NSString *)text {
    [self.conversation pushEvent:@{@"type": @"transcript_partial", @"text": text}];
}

- (void)voiceInput:(VoiceInputController *)controller finalText:(NSString *)text {
    [self.conversation pushEvent:@{@"type": @"listening", @"active": @NO}];
    [self refreshWakeGate];
    [self refreshUIState];

    NSString *trimmed = [text stringByTrimmingCharactersInSet:
                         [NSCharacterSet whitespaceAndNewlineCharacterSet]];
    if (trimmed.length == 0) {
        [self.conversation pushEvent:@{@"type": @"transcript_empty"}];
        return;
    }
    [self.conversation pushEvent:@{@"type": @"transcript_final", @"text": trimmed}];
    [self sendUserMessage:trimmed];
}

- (void)voiceInput:(VoiceInputController *)controller level:(float)level {
    if (self.voice.isListening) [self.orb applyLevel:level];
}

- (void)voiceInput:(VoiceInputController *)controller failed:(NSString *)message {
    [self.conversation pushEvent:@{@"type": @"listening", @"active": @NO}];
    [self refreshWakeGate];
    [self.conversation pushEvent:@{@"type": @"error", @"message": message}];
    [self.conversation show];
    [self refreshUIState];
}

#pragma mark - SpeechPlayerDelegate

- (void)speechPlayerDidStart:(SpeechPlayer *)player  { [self refreshWakeGate]; [self refreshUIState]; }

- (void)speechPlayerDidFinish:(SpeechPlayer *)player {
    [self.orb applyLevel:0];
    [self refreshWakeGate];
    [self refreshUIState];
}

- (void)speechPlayer:(SpeechPlayer *)player level:(float)level {
    if (!self.voice.isListening) [self.orb applyLevel:level];
}

#pragma mark - Brain 进程

- (void)brainProcess:(BrainProcessManager *)manager isRunning:(BOOL)running detail:(NSString *)detail {
    if (running) return;                       // 真正的"就绪"以 IPC 连上为准
    [self.statusItem updateBrainStatus:(detail ?: @"已停止") healthy:NO];
    self.brainState = @"idle";
    [self refreshUIState];
    if (detail) [self.conversation pushEvent:@{@"type": @"error", @"message": detail}];
}

#pragma mark - Brain IPC

- (void)brainClientDidConnect:(BrainIPCClient *)client {
    [self.statusItem updateBrainStatus:@"已连接" healthy:YES];
    [self.conversation pushEvent:@{@"type": @"connection", @"connected": @YES}];
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
    if ([type isEqualToString:@"tool_confirm_request"]) {
        [self.conversation show];               // 要确认就得让用户看得见
    } else if ([type isEqualToString:@"ready"]) {
        BOOL configured = [event[@"configured"] boolValue];
        [self.statusItem updateBrainStatus:configured ? @"已连接" : @"缺 API Key" healthy:configured];

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
          @"重新构建过的话要去系统设置里把 J.A.R.V.I.S. 关掉再打开（cdhash 变了）");
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
    self.messageCounter += 1;
    NSString *messageID = [NSString stringWithFormat:@"msg_%lu", (unsigned long)self.messageCounter];
    [self.brain send:@{@"type": @"user_message", @"text": text, @"id": messageID}];
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

- (void)conversationPanel:(ConversationPanelController *)panel
   didAnswerConfirmation:(NSString *)requestID
                approved:(BOOL)approved {
    [self.brain send:@{@"type": @"tool_confirm_response",
                       @"request_id": requestID,
                       @"approved": @(approved)}];
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
