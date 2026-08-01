//
//  StatusItemController —— 菜单栏入口。
//
//  App 是 LSUIElement，没有 Dock 图标也没有主菜单，菜单栏是唯一能"看见它还活着"
//  的地方，所以大脑连接状态直接显示在菜单里，排障不用翻日志。
//

#import <Cocoa/Cocoa.h>

NS_ASSUME_NONNULL_BEGIN

@class StatusItemController;

@protocol StatusItemControllerDelegate <NSObject>
- (void)statusItemDidRequestToggleConversation:(StatusItemController *)controller;
- (void)statusItemDidRequestVoice:(StatusItemController *)controller;
- (void)statusItemDidRequestNewSession:(StatusItemController *)controller;
- (void)statusItemDidRequestRestartBrain:(StatusItemController *)controller;
@end

@interface StatusItemController : NSObject

@property (nonatomic, weak) id<StatusItemControllerDelegate> delegate;

- (void)install;

/// 菜单里那行状态文案
- (void)updateBrainStatus:(NSString *)status healthy:(BOOL)healthy;
/// 球体状态影响图标（thinking 时用实心点）
- (void)updateSessionState:(NSString *)state;

@end

NS_ASSUME_NONNULL_END
