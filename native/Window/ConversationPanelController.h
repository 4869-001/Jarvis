//
//  ConversationPanelController —— 对话面板（第二个 WKWebView）。
//
//  用 NSPanel + NonactivatingPanel：平时不抢焦点，只有主动唤出时才激活并成为
//  key window，好让输入框能收键盘。面板浮在普通窗口之上、跟随所有 Space。
//

#import <Cocoa/Cocoa.h>

NS_ASSUME_NONNULL_BEGIN

@class ConversationPanelController;

@protocol ConversationPanelDelegate <NSObject>
- (void)conversationPanel:(ConversationPanelController *)panel didSubmitText:(NSString *)text;
- (void)conversationPanelDidRequestCancel:(ConversationPanelController *)panel;
- (void)conversationPanelDidRequestNewSession:(ConversationPanelController *)panel;
- (void)conversationPanelDidRequestRestartBrain:(ConversationPanelController *)panel;
- (void)conversationPanelDidRequestVoiceToggle:(ConversationPanelController *)panel;
- (void)conversationPanel:(ConversationPanelController *)panel didRequestSleep:(BOOL)sleeping;
/// 用户在文件卡片上点了「在访达中显示」或「打开」
- (void)conversationPanel:(ConversationPanelController *)panel
          didRequestOpen:(NSString *)path reveal:(BOOL)reveal;
- (void)conversationPanel:(ConversationPanelController *)panel
   didAnswerConfirmation:(NSString *)requestID
                approved:(BOOL)approved;
@end

@interface ConversationPanelController : NSObject

@property (nonatomic, weak) id<ConversationPanelDelegate> delegate;
@property (nonatomic, readonly) BOOL isVisible;

/// 面板不透明度 0…1。0 = 完全清透（只剩文字浮在桌面上），1 = 实心毛玻璃。
/// 由页面上的滑块驱动，存在 NSUserDefaults 里，重启后保持。
@property (nonatomic, assign) CGFloat panelOpacity;

- (void)show;
- (void)hide;
- (void)toggle;

/// 把一条 Brain 事件转发给页面。页面还没加载完时会先攒着。
- (void)pushEvent:(NSDictionary *)event;

/// 音频电平，驱动顶栏的动态条。高频调用，内部会限流并在面板不可见时直接丢弃。
- (void)pushMicLevel:(float)level;

@end

NS_ASSUME_NONNULL_END
