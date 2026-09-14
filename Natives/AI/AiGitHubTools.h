//
//  AiGitHubTools.h
//  Amethyst
//
//  Air AI Agent GitHub 代码推送工具（3d 阶段）：
//  - github_set_token：保存 GitHub Personal Access Token（存 NSUserDefaults，供 github_push 认证）。
//  - github_push：把一组文件以一次 commit 推送到指定 GitHub 仓库的指定分支（走 GitHub Git Data API）。
//  权限 ExternalNetwork：Ask 模式会弹确认，YOLO 模式免确认直接执行。
//

#import <Foundation/Foundation.h>
#import "AiTool.h"

NS_ASSUME_NONNULL_BEGIN

@interface AiGitHubTool : NSObject <AiTool>

@property (nonatomic, readonly) NSString *name;
@property (nonatomic, readonly) NSString *summary;
@property (nonatomic, readonly) AiToolPermission permission;

/// 按 internalName 区分 github_set_token / github_push
- (instancetype)initWithName:(NSString *)name;

@end

NS_ASSUME_NONNULL_END
