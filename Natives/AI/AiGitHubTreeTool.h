//
//  AiGitHubTreeTool.h
//  Amethyst
//
//  Air AI Agent GitHub 仓库源码浏览工具：
//  让 AI 一次性看到整个仓库的源码结构，并批量读取文件内容，
//  而不是像 fetch_url 那样一个文件一个文件地抓。
//
//  provisioned tools:
//    - github_tree        列出仓库完整文件树（递归），一次拿到所有文件路径（ReadOnly）
//    - github_read_files  批量读取仓库中多个源文件内容（ReadOnly）
//    - github_search_code 在仓库内按关键词搜索代码（ReadOnly）
//

#import <Foundation/Foundation.h>
#import "AiTool.h"

NS_ASSUME_NONNULL_BEGIN

@interface AiGitHubTreeTool : NSObject <AiTool>

- (instancetype)initWithName:(NSString *)name;

@end

NS_ASSUME_NONNULL_END
