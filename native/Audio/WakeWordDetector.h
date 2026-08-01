//
//  WakeWordDetector —— sherpa-onnx KWS，常听「贾维斯 / Jarvis」。
//
//  为什么是 sherpa-onnx 而不是 Porcupine：
//    · 不需要 AccessKey，无账户、无配额、无云端依赖
//    · 开放词表，加词只改 txt，不必为每个关键词重训模型
//    · 官方有中英双语 3M 参数模型，中文带声调拼音和英文 ARPAbet 可混在同一文件
//    · 逐词可调提升分与阈值
//
//  KWS 放在宿主进程而非 Python 侧：音频采集与唤醒检测在同一进程内完成，
//  不必把 PCM 流跨进程传；更重要的是「播报时暂停唤醒」变成进程内的一个 bool，
//  而不是跨进程同步问题。
//

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

@class WakeWordDetector;

@protocol WakeWordDetectorDelegate <NSObject>
- (void)wakeWordDetector:(WakeWordDetector *)detector didDetect:(NSString *)keyword;
- (void)wakeWordDetector:(WakeWordDetector *)detector failed:(NSString *)message;
@end

@interface WakeWordDetector : NSObject

@property (nonatomic, weak) id<WakeWordDetectorDelegate> delegate;
@property (nonatomic, readonly, getter=isRunning) BOOL running;

/// 播报期间置 YES：半双工门，防止 Jarvis 把自己念的"贾维斯"当成唤醒。
/// 这是评审 §6.5 的第一层防护，也是最稳的一层。
@property (nonatomic, assign) BOOL muted;

/// modelDir 是解压后的 sherpa-onnx KWS 模型目录；keywordsFile 是音素词表
- (instancetype)initWithModelDirectory:(NSString *)modelDirectory
                          keywordsFile:(NSString *)keywordsFile
                                 score:(float)score
                             threshold:(float)threshold;

- (BOOL)start;
- (void)stop;

@end

NS_ASSUME_NONNULL_END
