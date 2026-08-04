#import <Foundation/Foundation.h>

typedef void (^JarvisWeChatCompletion)(NSDictionary *result, NSString *error);

/// 微信能力：**只读**。
///
/// 只读 macOS 通知中心数据库里微信产生的结构化通知记录，不截屏、不 OCR、
/// 不注入微信进程、不模拟键鼠。没有发送能力，也不提供任何写入接口——
/// 个人微信不返回联系人 ID、消息 ID 和发送回执，任何自动发送都无法验证收件人。
/// 背景与实测过程见 refs/Jarvis微信读写能力技术方案.md。
@interface WeChatController : NSObject
- (void)read:(NSDictionary *)arguments completion:(JarvisWeChatCompletion)completion;
@end
