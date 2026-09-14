//
//  AiGitHubTreeTool.m
//  Amethyst
//
//  设计要点：
//  - 全部走 GitHub REST v3，Token 复用 @"ai.github_token"（与 AiGitHubTool 一致）。
//  - github_tree 用 GET /repos/{o}/{r}/git/trees/{ref}?recursive=1 一次拿到整棵树的 path+type+size，
//    本地组装为紧凑文本树（带目录缩进 + 字节大小），解决「只能一个一个看文件」的痛点。
//  - 大仓库（> 2000 项）自动截断并提示，避免上下文爆炸。
//  - github_read_files 并发/串行批量拉取 raw 内容，逐文件截断，总输出再限长。
//  - 全部 ReadOnly：仅 GET，任何安全模式免确认。
//

#import "AiGitHubTreeTool.h"

static NSString * const kAiGitHubTokenKey = @"ai.github_token";
static NSString * const kAiToolDomain = @"AiTool";
static NSString * const kGitHubAPIBase = @"https://api.github.com";
static NSString * const kGitHubRawBase = @"https://raw.githubusercontent.com";

@interface AiGitHubTreeTool ()
@property (nonatomic, copy) NSString *internalName;
@end

/// 整棵树最多展示条目数
static const NSInteger kMaxTreeEntries = 2000;
/// 单文件读取默认/最大字符数
static const NSInteger kDefaultFileChars = 12000;
static const NSInteger kMaxFileChars = 40000;
/// 批量读取单次最多文件数
static const NSInteger kMaxBatchFiles = 20;

@implementation AiGitHubTreeTool

- (instancetype)initWithName:(NSString *)name {
    self = [super init];
    if (self) {
        _internalName = name ?: @"";
    }
    return self;
}

#pragma mark - 描述

- (NSString *)name { return self.internalName; }

- (AiToolPermission)permission { return AiToolPermissionReadOnly; }

- (NSString *)summary {
    if ([self.internalName isEqualToString:@"github_tree"]) {
        return @"一次性列出 GitHub 仓库的完整源码文件树（递归所有子目录），用于快速掌握项目结构。"
               "\n参数："
               "\n  - repo（string，必填）：owner/repo，例如 Aiden6652/Air。"
               "\n  - ref（string，可选）：分支/标签/commit，默认仓库默认分支。"
               "\n  - path（string，可选）：只看某个子目录（前缀过滤），例如 Natives/AI。"
               "\n  - maxEntries（integer，可选）：最多返回条目数，默认 2000。"
               "\n返回：紧凑文本树（目录在前、按路径排序，附文件字节大小），末尾附「共 N 个文件」统计。"
               "\n典型用法：先调 github_tree 拿到全部文件路径 → 再挑重点文件调 github_read_files 批量读取，"
               "不要对每个文件单独调用；这样能一次看完整仓库而不是一个个翻。"
               "\n若用户给了 token（github_set_token）会自动带上，避免限流。";
    }
    if ([self.internalName isEqualToString:@"github_read_files"]) {
        return @"批量读取 GitHub 仓库中一个或多个文件的内容（一次最多 20 个），避免逐文件多次请求。"
               "\n参数："
               "\n  - repo（string，必填）：owner/repo。"
               "\n  - paths（array<string>，必填）：仓库内相对路径数组，例如 [\"README.md\",\"Natives/AI/AiTool.h\"]。"
               "\n  - ref（string，可选）：分支/标签/commit。"
               "\n  - maxCharsPerFile（integer，可选）：单文件最大字符数，默认 12000，最大 40000。"
               "\n返回：按文件分隔的文本块，每块以「=== 文件路径 ===」开头；二进制/不存在/超限会给出说明。";
    }
    if ([self.internalName isEqualToString:@"github_search_code"]) {
        return @"在某个 GitHub 仓库内按关键词搜索代码。"
               "\n参数："
               "\n  - repo（string，必填）：owner/repo。"
               "\n  - query（string，必填）：搜索关键词或代码片段。"
               "\n  - maxResults（integer，可选）：最多返回条数，默认 20。"
               "\n返回：JSON 数组，每项含 path（文件路径）、lineNumber、line（命中行）。"
               "\n注意：GitHub Code Search API 对无 token 的匿名调用限制严格，建议先 github_set_token。"
               "\n用法：已知大概想找什么（如函数名、字符串常量）时比逐个读文件快得多。";
    }
    return @"GitHub 仓库源码浏览工具";
}

#pragma mark - Token / 请求

+ (nullable NSString *)savedToken {
    NSString *token = [[NSUserDefaults standardUserDefaults] stringForKey:kAiGitHubTokenKey];
    return (token.length > 0) ? token : nil;
}

+ (void)applyHeadersToRequest:(NSMutableURLRequest *)request {
    [request setValue:@"Air/1.0 (iOS; MC Launcher)" forHTTPHeaderField:@"User-Agent"];
    [request setValue:@"application/vnd.github+json" forHTTPHeaderField:@"Accept"];
    [request setValue:@"2022-11-28" forHTTPHeaderField:@"X-GitHub-Api-Version"];
    NSString *token = [self savedToken];
    if (token) {
        [request setValue:[NSString stringWithFormat:@"Bearer %@", token] forHTTPHeaderField:@"Authorization"];
    }
}

/// 执行 GET，回调原始 data + HTTP 状态码
+ (void)getURL:(NSString *)urlString
     completion:(void (^)(NSData * _Nullable data, NSInteger statusCode, NSError * _Nullable error))completion {
    NSURL *url = [NSURL URLWithString:urlString];
    if (!url) {
        if (completion) completion(nil, 0, [NSError errorWithDomain:kAiToolDomain code:400
            userInfo:@{NSLocalizedDescriptionKey: [NSString stringWithFormat:@"无效 URL：%@", urlString]}]);
        return;
    }
    NSMutableURLRequest *request = [NSMutableURLRequest requestWithURL:url];
    request.HTTPMethod = @"GET";
    request.timeoutInterval = 30.0;
    [self applyHeadersToRequest:request];

    [[[NSURLSession sharedSession] dataTaskWithRequest:request
        completionHandler:^(NSData *data, NSURLResponse *response, NSError *error) {
        NSHTTPURLResponse *http = (NSHTTPURLResponse *)response;
        NSInteger code = (http && [http respondsToSelector:@selector(statusCode)]) ? http.statusCode : 200;
        if (completion) completion(data, code, error);
    }] resume];
}

/// 把 HTTP 状态码翻译为用户可读的错误
+ (NSError *)errorForStatus:(NSInteger)code body:(NSData *)data {
    NSString *msg = [NSString stringWithFormat:@"GitHub 返回 HTTP %ld", (long)code];
    if (code == 401) msg = @"Token 无效或已过期（HTTP 401），请重新用 github_set_token 设置";
    else if (code == 403) msg = @"访问被拒绝（HTTP 403）：可能是未授权访问私有仓库，或触发了 API 限流（匿名 60 次/小时，建议 github_set_token）";
    else if (code == 404) msg = @"仓库或路径不存在，或对当前 token 不可见（HTTP 404）";
    else if (code == 409) msg = @"仓库为空（HTTP 409）";
    else if (code == 422) msg = @"请求参数无法处理（HTTP 422），请检查 repo/ref/path 是否正确";
    if (data.length > 0) {
        id obj = [NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
        if ([obj isKindOfClass:[NSDictionary class]] && obj[@"message"]) {
            msg = [NSString stringWithFormat:@"%@（%@）", msg, obj[@"message"]];
        }
    }
    return [NSError errorWithDomain:kAiToolDomain code:code userInfo:@{NSLocalizedDescriptionKey: msg}];
}

#pragma mark - 执行分发

- (void)execute:(NSDictionary<NSString *, id> *)params
     completion:(void (^)(NSString * _Nullable, NSError * _Nullable))completion {
    if (!completion) return;
    if ([self.internalName isEqualToString:@"github_tree"]) {
        [self performTree:params completion:completion];
        return;
    }
    if ([self.internalName isEqualToString:@"github_read_files"]) {
        [self performReadFiles:params completion:completion];
        return;
    }
    if ([self.internalName isEqualToString:@"github_search_code"]) {
        [self performSearchCode:params completion:completion];
        return;
    }
    completion(nil, [NSError errorWithDomain:kAiToolDomain code:404
        userInfo:@{NSLocalizedDescriptionKey: [NSString stringWithFormat:@"未知工具 %@", self.internalName]}]);
}

- (NSError *)errorWithCode:(NSInteger)code message:(NSString *)message {
    return [NSError errorWithDomain:kAiToolDomain code:code
                           userInfo:@{NSLocalizedDescriptionKey: message}];
}

#pragma mark - 参数工具

- (nullable NSString *)stringParam:(id)value {
    if ([value isKindOfClass:[NSString class]] && [(NSString *)value length] > 0) return value;
    return nil;
}

/// 校验 owner/repo
- (nullable NSString *)validatedRepoFromParams:(NSDictionary *)params error:(NSError **)error {
    NSString *repo = [self stringParam:params[@"repo"]];
    if (!repo) {
        if (error) *error = [self errorWithCode:400 message:@"缺少必填参数 repo（格式：owner/repo）"];
        return nil;
    }
    if ([[repo componentsSeparatedByString:@"/"] count] != 2) {
        if (error) *error = [self errorWithCode:400 message:[NSString stringWithFormat:@"repo 格式应为 owner/repo，收到：%@", repo]];
        return nil;
    }
    return repo;
}

#pragma mark - github_tree

- (void)performTree:(NSDictionary *)params completion:(void (^)(NSString *, NSError *))completion {
    NSError *verr = nil;
    NSString *repo = [self validatedRepoFromParams:params error:&verr];
    if (!repo) { completion(nil, verr); return; }

    NSString *ref = [self stringParam:params[@"ref"]];
    NSString *pathFilter = [self stringParam:params[@"path"]];

    NSInteger maxEntries = kMaxTreeEntries;
    id maxValue = params[@"maxEntries"];
    if ([maxValue respondsToSelector:@selector(integerValue)]) {
        NSInteger v = [maxValue integerValue];
        if (v > 0) maxEntries = MIN(v, 20000);
    }

    // 未指定 ref 时先取默认分支
    void (^proceed)(NSString *) = ^(NSString *resolvedRef) {
        NSString *urlString = [NSString stringWithFormat:@"%@/repos/%@/git/trees/%@?recursive=1",
                               kGitHubAPIBase, repo, resolvedRef];
        [AiGitHubTreeTool getURL:urlString completion:^(NSData *data, NSInteger statusCode, NSError *error) {
            dispatch_async(dispatch_get_main_queue(), ^{
                if (error) {
                    completion(nil, [self errorWithCode:-1 message:[NSString stringWithFormat:@"网络请求失败：%@", error.localizedDescription ?: @"未知"]]);
                    return;
                }
                if (statusCode >= 400) { completion(nil, [AiGitHubTreeTool errorForStatus:statusCode body:data]); return; }
                id obj = data ? [NSJSONSerialization JSONObjectWithData:data options:0 error:nil] : nil;
                if (![obj isKindOfClass:[NSDictionary class]]) {
                    completion(nil, [self errorWithCode:-1 message:@"无法解析 GitHub 响应"]); return;
                }
                NSArray *tree = obj[@"tree"];
                if (![tree isKindOfClass:[NSArray class]]) {
                    completion(nil, [self errorWithCode:-1 message:@"仓库树为空或格式异常"]); return;
                }
                BOOL truncated = [obj[@"truncated"] boolValue];

                // 收集条目
                NSMutableArray<NSDictionary *> *entries = [NSMutableArray array];
                NSInteger fileCount = 0;
                NSInteger totalSize = 0;
                for (NSDictionary *node in tree) {
                    if (![node isKindOfClass:[NSDictionary class]]) continue;
                    NSString *nodePath = node[@"path"];
                    NSString *type = node[@"type"];
                    if (![nodePath isKindOfClass:[NSString class]]) continue;
                    if ([type isEqualToString:@"tree"] || [type isEqualToString:@"blob"]) {
                        if (pathFilter.length > 0) {
                            NSString *pf = [pathFilter hasSuffix:@"/"] ? pathFilter : [pathFilter stringByAppendingString:@"/"];
                            if (![nodePath hasPrefix:pf] && ![nodePath isEqualToString:pathFilter]) continue;
                        }
                        [entries addObject:node];
                        if ([type isEqualToString:@"blob"]) {
                            fileCount++;
                            totalSize += [node[@"size"] longLongValue];
                        }
                    }
                }

                // 按 path 排序
                [entries sortUsingComparator:^NSComparisonResult(NSDictionary *a, NSDictionary *b) {
                    return [a[@"path"] compare:b[@"path"]];
                }];

                NSInteger shown = MIN((NSInteger)entries.count, maxEntries);
                NSMutableString *out = [NSMutableString string];
                [out appendFormat:@"仓库 %@ @ %@%@\n", repo, resolvedRef,
                    pathFilter.length ? [NSString stringWithFormat:@"  子目录前缀：%@", pathFilter] : @""];
                [out appendString:@"----------------------------------------\n"];

                for (NSInteger i = 0; i < shown; i++) {
                    NSDictionary *node = entries[i];
                    NSString *nodePath = node[@"path"];
                    BOOL isDir = [node[@"type"] isEqualToString:@"tree"];
                    if (isDir) {
                        [out appendFormat:@"%@/\n", nodePath];
                    } else {
                        long long size = [node[@"size"] longLongValue];
                        [out appendFormat:@"%@  (%lld B)\n", nodePath, size];
                    }
                }

                if ((NSInteger)entries.count > shown) {
                    [out appendFormat:@"\n…（共 %ld 项，已截断显示前 %ld 项，可用 path/maxEntries 收窄）\n",
                        (long)entries.count, (long)shown];
                }
                [out appendFormat:@"\n统计：%ld 个文件，共 %ld 字节%@\n",
                    (long)fileCount, (long)totalSize,
                    truncated ? @"；⚠️ GitHub 标记该树被截断（仓库过大），建议用 path 逐个子目录查看" : @""];

                completion(out, nil);
            });
        }];
    };

    if (ref.length > 0) {
        proceed(ref);
        return;
    }
    // 取默认分支
    [AiGitHubTreeTool getURL:[NSString stringWithFormat:@"%@/repos/%@", kGitHubAPIBase, repo]
                  completion:^(NSData *data, NSInteger statusCode, NSError *error) {
        dispatch_async(dispatch_get_main_queue(), ^{
            if (error) {
                completion(nil, [self errorWithCode:-1 message:[NSString stringWithFormat:@"网络请求失败：%@", error.localizedDescription ?: @"未知"]]);
                return;
            }
            if (statusCode >= 400) { completion(nil, [AiGitHubTreeTool errorForStatus:statusCode body:data]); return; }
            id obj = data ? [NSJSONSerialization JSONObjectWithData:data options:0 error:nil] : nil;
            NSString *defaultBranch = [obj isKindOfClass:[NSDictionary class]] ? obj[@"default_branch"] : nil;
            if (![defaultBranch isKindOfClass:[NSString class]] || defaultBranch.length == 0) defaultBranch = @"main";
            proceed(defaultBranch);
        });
    }];
}

#pragma mark - github_read_files

- (void)performReadFiles:(NSDictionary *)params completion:(void (^)(NSString *, NSError *))completion {
    NSError *verr = nil;
    NSString *repo = [self validatedRepoFromParams:params error:&verr];
    if (!repo) { completion(nil, verr); return; }

    NSArray *paths = params[@"paths"];
    if (![paths isKindOfClass:[NSArray class]] || paths.count == 0) {
        completion(nil, [self errorWithCode:400 message:@"缺少必填参数 paths（字符串数组）"]); return;
    }
    NSMutableArray<NSString *> *filePaths = [NSMutableArray array];
    for (id p in paths) {
        if ([p isKindOfClass:[NSString class]] && [(NSString *)p length] > 0) [filePaths addObject:p];
        if (filePaths.count >= kMaxBatchFiles) break;
    }
    if (filePaths.count == 0) {
        completion(nil, [self errorWithCode:400 message:@"paths 中没有有效文件路径"]); return;
    }

    NSString *ref = [self stringParam:params[@"ref"]];
    if (!ref) ref = @"HEAD"; // raw 支持 HEAD

    NSInteger maxChars = kDefaultFileChars;
    id maxValue = params[@"maxCharsPerFile"];
    if ([maxValue respondsToSelector:@selector(integerValue)]) {
        NSInteger v = [maxValue integerValue];
        if (v > 0) maxChars = MIN(v, kMaxFileChars);
    }

    dispatch_group_t group = dispatch_group_create();
    NSMutableDictionary<NSString *, NSString *> *results = [NSMutableDictionary dictionary];
    NSMutableDictionary<NSString *, NSString *> *failures = [NSMutableDictionary dictionary];
    NSObject *lock = [[NSObject alloc] init];

    for (NSString *filePath in filePaths) {
        dispatch_group_enter(group);
        // 用 raw 内容接口（不经 base64），未编码路径需做百分号转义
        NSString *encoded = [filePath stringByAddingPercentEncodingWithAllowedCharacters:
                             [NSCharacterSet URLPathAllowedCharacterSet]];
        NSString *urlString = [NSString stringWithFormat:@"%@/%@/%@/%@", kGitHubRawBase, repo, ref, encoded];
        [AiGitHubTreeTool getURL:urlString completion:^(NSData *data, NSInteger statusCode, NSError *error) {
            @synchronized (lock) {
                if (error) {
                    failures[filePath] = [NSString stringWithFormat:@"请求失败：%@", error.localizedDescription ?: @"未知"];
                } else if (statusCode >= 400) {
                    failures[filePath] = [NSString stringWithFormat:@"HTTP %ld（文件不存在或无权限）", (long)statusCode];
                } else if (data.length == 0) {
                    results[filePath] = @"(空文件)";
                } else {
                    NSString *text = [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding];
                    if (!text) {
                        failures[filePath] = [NSString stringWithFormat:@"二进制文件（%lu 字节），不可作为文本读取", (unsigned long)data.length];
                    } else if (text.length > maxChars) {
                        results[filePath] = [text substringToIndex:maxChars];
                        failures[filePath] = [NSString stringWithFormat:@"（已截断，原文件 %lu 字符，仅显示前 %ld 字符）", (unsigned long)text.length, (long)maxChars];
                    } else {
                        results[filePath] = text;
                    }
                }
            }
            dispatch_group_leave(group);
        }];
    }

    dispatch_group_notify(group, dispatch_get_main_queue(), ^{
        NSMutableString *out = [NSMutableString string];
        [out appendFormat:@"仓库 %@ @ %@ —— 共读取 %ld 个文件（成功 %lu）\n",
            repo, ref, (long)filePaths.count, (unsigned long)results.count];
        for (NSString *filePath in filePaths) {
            [out appendFormat:@"\n=========== 文件：%@ ===========\n", filePath];
            NSString *content = results[filePath];
            if (content) {
                [out appendString:content];
                NSString *note = failures[filePath];
                if (note) [out appendFormat:@"\n[%@]", note];
            } else {
                [out appendFormat:@"[读取失败：%@]", failures[filePath] ?: @"未知原因"];
            }
            [out appendString:@"\n"];
        }
        completion(out, nil);
    });
}

#pragma mark - github_search_code

- (void)performSearchCode:(NSDictionary *)params completion:(void (^)(NSString *, NSError *))completion {
    NSError *verr = nil;
    NSString *repo = [self validatedRepoFromParams:params error:&verr];
    if (!repo) { completion(nil, verr); return; }

    NSString *query = [self stringParam:params[@"query"]];
    if (!query) { completion(nil, [self errorWithCode:400 message:@"缺少必填参数 query"]); return; }

    NSInteger maxResults = 20;
    id mv = params[@"maxResults"];
    if ([mv respondsToSelector:@selector(integerValue)]) {
        NSInteger v = [mv integerValue];
        if (v > 0) maxResults = MIN(v, 100);
    }

    NSString *encodedQuery = [query stringByAddingPercentEncodingWithAllowedCharacters:
                              [NSCharacterSet URLQueryAllowedCharacterSet]];
    // GitHub Code Search：q=关键词 repo:owner/name
    NSString *urlString = [NSString stringWithFormat:@"%@/search/code?q=%@+repo:%@&per_page=%ld",
                           kGitHubAPIBase, encodedQuery, repo, (long)maxResults];

    [AiGitHubTreeTool getURL:urlString completion:^(NSData *data, NSInteger statusCode, NSError *error) {
        dispatch_async(dispatch_get_main_queue(), ^{
            if (error) {
                completion(nil, [self errorWithCode:-1 message:[NSString stringWithFormat:@"网络请求失败：%@", error.localizedDescription ?: @"未知"]]);
                return;
            }
            if (statusCode >= 400) { completion(nil, [AiGitHubTreeTool errorForStatus:statusCode body:data]); return; }
            id obj = data ? [NSJSONSerialization JSONObjectWithData:data options:0 error:nil] : nil;
            NSArray *items = [obj isKindOfClass:[NSDictionary class]] ? obj[@"items"] : nil;
            if (![items isKindOfClass:[NSArray class]]) {
                completion(@"未找到匹配结果。", nil); return;
            }
            NSMutableArray *out = [NSMutableArray array];
            for (NSDictionary *item in items) {
                if (![item isKindOfClass:[NSDictionary class]]) continue;
                [out addObject:@{
                    @"path": item[@"path"] ?: @"",
                    @"name": item[@"name"] ?: @"",
                }];
            }
            NSData *json = [NSJSONSerialization dataWithJSONObject:out options:NSJSONWritingPrettyPrinted error:nil];
            NSString *text = json ? [[NSString alloc] initWithData:json encoding:NSUTF8StringEncoding] : @"[]";
            completion([NSString stringWithFormat:@"在 %@ 中搜索「%@」共命中 %lu 个文件：\n%@",
                        repo, query, (unsigned long)out.count, text], nil);
        });
    }];
}

@end
