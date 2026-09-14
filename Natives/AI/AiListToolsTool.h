//
//  AiListToolsTool.h
//  Amethyst
//
//  Air AI Agent 自省工具：
//  让 AI 能主动询问「我现在到底有哪些工具可用」，不依赖它对 system prompt 的记忆。
//  排查工具缺失时也可让用户直接问 AI「你有哪些工具」来快速确认运行时状态。
//
//  provisioned tools:
//    - list_tools  列出当前已注册的全部工具名与用途（ReadOnly）
//

#import <Foundation/Foundation.h>
#import "AiTool.h"

NS_ASSUME_NONNULL_BEGIN

@interface AiListToolsTool : NSObject <AiTool>

- (instancetype)initWithName:(NSString *)name;

@end

NS_ASSUME_NONNULL_END
