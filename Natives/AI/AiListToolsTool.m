//
//  AiListToolsTool.m
//  Amethyst
//

#import "AiListToolsTool.h"
#import "AiToolRegistry.h"

@interface AiListToolsTool ()
@property (nonatomic, copy) NSString *internalName;
@end

@implementation AiListToolsTool

- (instancetype)initWithName:(NSString *)name {
    self = [super init];
    if (self) {
        _internalName = name ?: @"list_tools";
    }
    return self;
}

- (NSString *)name { return self.internalName; }

- (AiToolPermission)permission { return AiToolPermissionReadOnly; }

- (NSString *)summary {
    return @"列出当前运行时已注册的全部工具（名称 + 用途摘要）。"
           "\n参数：无。"
           "\n返回：JSON，含 count（工具总数）与 tools（每项 name/description 首行）。"
           "\n用途："
           "\n  1. 你不确定自己能调哪些工具时，先调它确认，不要凭空猜测工具名；"
           "\n  2. 调用某个工具报「未知工具」时，调它拿到正确名称再重试；"
           "\n  3. 用户问「你有哪些能力 / 有没有 xx 工具」时，用它给出准确答案而不是凭记忆回答。";
}

- (void)execute:(NSDictionary<NSString *,id> *)params
     completion:(void (^)(NSString * _Nullable, NSError * _Nullable))completion {
    AiToolRegistry *registry = [AiToolRegistry sharedRegistry];
    NSArray<NSString *> *names = [registry allToolNames];

    NSMutableArray *items = [NSMutableArray array];
    for (NSString *n in names) {
        id<AiTool> t = [registry toolForName:n];
        NSString *summary = t.summary ?: @"";
        // 只取首行做摘要，完整说明太长
        NSString *firstLine = [[summary componentsSeparatedByCharactersInSet:
                                [NSCharacterSet newlineCharacterSet]] firstObject] ?: @"";
        [items addObject:@{
            @"name": n,
            @"permission": @(t.permission),
            @"description": firstLine,
        }];
    }

    NSDictionary *result = @{
        @"count": @(items.count),
        @"tools": items,
    };

    NSError *jsonError = nil;
    NSData *data = [NSJSONSerialization dataWithJSONObject:result
                                                   options:NSJSONWritingPrettyPrinted
                                                     error:&jsonError];
    if (data == nil) {
        if (completion) completion(nil, jsonError);
        return;
    }
    NSString *json = [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding];
    if (completion) completion(json, nil);
}

@end
