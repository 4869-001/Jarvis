//
//  VoiceInputController —— 麦克风采集 + 语音识别。
//
//  音频入口一律启用 AVAudioEngine 的 Voice Processing（AEC + 降噪 + AGC），
//  这是评审 §6.5 的第二层防护，比自己写能量阈值靠谱得多，而且有完整 ObjC API。
//
//  识别用 SFSpeechRecognizer。本机实测 zh-CN / en-US / en-GB 的
//  supportsOnDeviceRecognition 均为真，所以默认强制离线，不走网络。
//
//  收句时机由这里判断，分三步：
//    1) 自适应噪声门 + 文本停顿 → 判定用户说完了（见 .m 里的 checkTimeouts）
//    2) endAudio，同时立刻摘掉麦克风 tap（麦克风该关就关，不等识别器）
//    3) 最多再等 finalWait 秒拿识别器的终版结果——终版经过重打分、带标点，
//       比最后一版 partial 明显准。等不到就用 partial，不会卡住。
//

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

@class VoiceInputController;

@protocol VoiceInputControllerDelegate <NSObject>
- (void)voiceInputDidStart:(VoiceInputController *)controller;
/// 麦克风已关、正在等识别器出终版结果。UI 该显示"正在识别"而不是还在"聆听"。
- (void)voiceInputDidFinishCapturing:(VoiceInputController *)controller;
- (void)voiceInput:(VoiceInputController *)controller partialText:(NSString *)text;
/// text 为空表示什么都没听清
- (void)voiceInput:(VoiceInputController *)controller finalText:(NSString *)text;
- (void)voiceInput:(VoiceInputController *)controller level:(float)level;
- (void)voiceInput:(VoiceInputController *)controller failed:(NSString *)message;
@end

/// 识别参数。字段和 config.json 的 voice_input 一一对应。
typedef struct {
    NSTimeInterval silenceTimeout;   ///< 说完之后静音多久收句
    NSTimeInterval finalWait;        ///< 收句后等终版结果的上限
    NSTimeInterval idleTimeout;      ///< 一个字都没识别出来时，多久自动关麦
    NSTimeInterval maxSeconds;       ///< 单句硬上限
    BOOL preferOnDevice;
    BOOL addsPunctuation;
} JarvisVoiceOptions;

@interface VoiceInputController : NSObject

@property (nonatomic, weak) id<VoiceInputControllerDelegate> delegate;
@property (nonatomic, readonly, getter=isListening) BOOL listening;

/// 专有名词提示。识别器会优先考虑这些词，对应用名、人名、项目名提升非常明显。
/// 随时可改，下次开麦生效。
@property (nonatomic, copy) NSArray<NSString *> *contextualStrings;

/// locale 形如 zh-CN
- (instancetype)initWithLocale:(NSString *)localeIdentifier
                       options:(JarvisVoiceOptions)options;

/// 首次调用会触发系统的麦克风与语音识别授权弹窗。
/// 之后走缓存的授权状态，不再每次都发 XPC——那是开麦延迟里最容易被忽略的一段。
- (void)start;
- (void)stop;            // 正常收句：等一下终版结果，再把文本交出去
- (void)abort;           // 放弃这次，不产出文本

/// 提前把识别器建好并暖起来。冷启动第一次开麦会明显慢，暖过就没有了。
- (void)prewarm;

@end

NS_ASSUME_NONNULL_END
