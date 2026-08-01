#import "StatusItemController.h"
#import "JarvisPaths.h"

@interface StatusItemController ()
@property (nonatomic, strong) NSStatusItem *statusItem;
@property (nonatomic, strong) NSMenuItem *brainStatusItem;
@end

@implementation StatusItemController

- (void)install {
    self.statusItem = [[NSStatusBar systemStatusBar] statusItemWithLength:NSVariableStatusItemLength];
    self.statusItem.button.toolTip = @"J.A.R.V.I.S.";
    [self setSymbol:@"circle.dotted"];

    NSMenu *menu = [[NSMenu alloc] init];
    menu.autoenablesItems = NO;

    NSMenuItem *conversation = [menu addItemWithTitle:@"对话…"
                                               action:@selector(toggleConversation:)
                                        keyEquivalent:@" "];
    conversation.keyEquivalentModifierMask = NSEventModifierFlagOption;
    conversation.target = self;

    NSMenuItem *voice = [menu addItemWithTitle:@"说话…"
                                        action:@selector(startVoice:)
                                 keyEquivalent:@"v"];
    voice.keyEquivalentModifierMask = NSEventModifierFlagOption;
    voice.target = self;

    NSMenuItem *newSession = [menu addItemWithTitle:@"新会话"
                                             action:@selector(newSession:)
                                      keyEquivalent:@"n"];
    newSession.keyEquivalentModifierMask = NSEventModifierFlagCommand | NSEventModifierFlagShift;
    newSession.target = self;

    [menu addItem:[NSMenuItem separatorItem]];

    self.brainStatusItem = [menu addItemWithTitle:@"大脑：启动中…" action:nil keyEquivalent:@""];
    self.brainStatusItem.enabled = NO;

    NSMenuItem *restart = [menu addItemWithTitle:@"重启大脑" action:@selector(restartBrain:) keyEquivalent:@""];
    restart.target = self;

    [menu addItem:[NSMenuItem separatorItem]];

    NSMenuItem *config = [menu addItemWithTitle:@"打开配置文件" action:@selector(openConfig:) keyEquivalent:@""];
    config.target = self;
    NSMenuItem *log = [menu addItemWithTitle:@"查看大脑日志" action:@selector(openLog:) keyEquivalent:@""];
    log.target = self;
    if ([JarvisPaths projectDirectory]) {
        NSMenuItem *project = [menu addItemWithTitle:@"打开项目目录" action:@selector(openProject:) keyEquivalent:@""];
        project.target = self;
    }

    [menu addItem:[NSMenuItem separatorItem]];

    NSMenuItem *quit = [menu addItemWithTitle:@"退出 J.A.R.V.I.S." action:@selector(quit:) keyEquivalent:@"q"];
    quit.target = self;

    self.statusItem.menu = menu;
}

- (void)setSymbol:(NSString *)symbolName {
    NSImage *image = [NSImage imageWithSystemSymbolName:symbolName accessibilityDescription:@"J.A.R.V.I.S."];
    if (!image) {                       // 万一符号名在这版系统里不存在
        self.statusItem.button.title = @"J";
        return;
    }
    [image setTemplate:YES];
    self.statusItem.button.image = image;
}

- (void)updateBrainStatus:(NSString *)status healthy:(BOOL)healthy {
    self.brainStatusItem.title = [NSString stringWithFormat:@"大脑：%@", status];
    if (!healthy) [self setSymbol:@"exclamationmark.circle"];
}

- (void)updateSessionState:(NSString *)state {
    NSDictionary *symbols = @{
        @"idle":      @"circle.dotted",
        @"listening": @"circle.circle",
        @"thinking":  @"circle.hexagongrid.circle",
        @"speaking":  @"waveform.circle",
        @"error":     @"exclamationmark.circle",
    };
    [self setSymbol:symbols[state] ?: @"circle.dotted"];
}

#pragma mark - 动作

- (void)toggleConversation:(id)sender { [self.delegate statusItemDidRequestToggleConversation:self]; }
- (void)startVoice:(id)sender         { [self.delegate statusItemDidRequestVoice:self]; }
- (void)newSession:(id)sender         { [self.delegate statusItemDidRequestNewSession:self]; }
- (void)restartBrain:(id)sender       { [self.delegate statusItemDidRequestRestartBrain:self]; }

- (void)openConfig:(id)sender {
    NSString *path = [JarvisPaths configPath];
    if (![[NSFileManager defaultManager] fileExistsAtPath:path]) {
        // Brain 第一次跑会写模板；还没写出来时先建个空的，免得打开报错
        [@"{}" writeToFile:path atomically:YES encoding:NSUTF8StringEncoding error:nil];
    }
    [[NSWorkspace sharedWorkspace] openURL:[NSURL fileURLWithPath:path]];
}

- (void)openLog:(id)sender {
    [[NSWorkspace sharedWorkspace] openURL:[NSURL fileURLWithPath:[JarvisPaths brainLogPath]]];
}

- (void)openProject:(id)sender {
    NSString *path = [JarvisPaths projectDirectory];
    if (path) [[NSWorkspace sharedWorkspace] openURL:[NSURL fileURLWithPath:path]];
}

- (void)quit:(id)sender { [NSApp terminate:nil]; }

@end
