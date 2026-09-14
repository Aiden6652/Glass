//
//  AiWebFetchTool.h
//  Amethyst
//
//  Air AI Agent 通用网络浏览工具（fetch_url）：
//  对任意 http/https URL 发起 GET 请求并返回内容文本（HTML 自动剥离标签、JSON 原样返回），
//  供 AI 查看 GitHub、Modrinth 之外的资源站、文档、Wiki 等任意公开网页/API。
//  权限声明为 ReadOnly：仅只读 GET、无副作用，任何安全模式（Safe/Ask/YOLO）均直接放行、不弹确认框。
//

#import <Foundation/Foundation.h>
#import "AiTool.h"

NS_ASSUME_NONNULL_BEGIN

@interface AiWebFetchTool : NSObject <AiTool>

@property (nonatomic, readonly) NSString *name;
@property (nonatomic, readonly) NSString *summary;
@property (nonatomic, readonly) AiToolPermission permission;

@end

NS_ASSUME_NONNULL_END
