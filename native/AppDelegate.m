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
@end

@implementation AppDelegate

#pragma mark - 生命周期

- (void)applicationDidFinishLaunching:(NSNotification *)note {
    [NSApp setActivationPolicy:NSApplicationActivationPolicyAccessory];   // 无 Dock 图标

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

    if (!self.voice) [self buildVoiceControllerWithConfig:nil];
    [self.conversation show];
    [self.voice start];
}

- (void)buildVoiceControllerWithConfig:(NSDictionary *)config {
    NSString *locale = config[@"locale"] ?: @"zh-CN";
    NSNumber *silence = config[@"silence_timeout"];
    NSNumber *maxSeconds = config[@"max_seconds"];
    NSNumber *onDevice = config[@"prefer_on_device"];

    self.voice = [[VoiceInputController alloc]
                  initWithLocale:locale
                  silenceTimeout:silence ? silence.doubleValue : 1.6
                      maxSeconds:maxSeconds ? maxSeconds.doubleValue : 30.0
                  preferOnDevice:onDevice ? onDevice.boolValue : YES];
    self.voice.delegate = self;
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
            [self buildVoiceControllerWithConfig:voiceConfig];
        }
        NSDictionary *wakeConfig = event[@"wake_word"];
        if ([wakeConfig isKindOfClass:[NSDictionary class]]) {
            [self setUpWakeWordWithConfig:wakeConfig];
        }
    }

    [self.conversation pushEvent:event];
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
