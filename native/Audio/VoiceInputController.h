//
//  VoiceInputController —— 麦克风采集 + 语音识别。
//
//  音频入口一律启用 AVAudioEngine 的 Voice Processing（AEC + 降噪 + AGC），
//  这是评审 §6.5 的第二层防护，比自己写能量阈值靠谱得多，而且有完整 ObjC API。
//  ⚠️ 它会把输入格式强制成 16k 单声道，识别质量需实测确认。
//
//  识别用 SFSpeechRecognizer。本机实测 zh-CN / en-US / en-GB 的
//  supportsOnDeviceRecognition 均为真，所以默认强制离线，不走网络。
//
//  结束时机由这里判断：静音超过阈值就收句，不需要用户按第二下。
//

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

@class VoiceInputController;

@protocol VoiceInputControllerDelegate <NSObject>
- (void)voiceInputDidStart:(VoiceInputController *)controller;
- (void)voiceInput:(VoiceInputController *)controller partialText:(NSString *)text;
/// text 为空表示什么都没听清
- (void)voiceInput:(VoiceInputController *)controller finalText:(NSString *)text;
- (void)voiceInput:(VoiceInputController *)controller level:(float)level;
- (void)voiceInput:(VoiceInputController *)controller failed:(NSString *)message;
@end

@interface VoiceInputController : NSObject

@property (nonatomic, weak) id<VoiceInputControllerDelegate> delegate;
@property (nonatomic, readonly, getter=isListening) BOOL listening;

/// locale 形如 zh-CN；silenceTimeout 秒数；maxSeconds 单句上限
- (instancetype)initWithLocale:(NSString *)localeIdentifier
                silenceTimeout:(NSTimeInterval)silenceTimeout
                    maxSeconds:(NSTimeInterval)maxSeconds
                preferOnDevice:(BOOL)preferOnDevice;

/// 首次调用会触发系统的麦克风与语音识别授权弹窗
- (void)start;
- (void)stop;            // 正常收句：把已识别的文本作为 final 交出去
- (void)abort;           // 放弃这次，不产出文本

@end

NS_ASSUME_NONNULL_END
