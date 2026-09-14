//
//  AiGitHubTools.m
//  Amethyst
//
//  github_set_token / github_push 实现。
//  - Token 存 NSUserDefaults 键 @"ai.github_token"，不入会话记录。
//  - github_push 使用 GitHub Git Data API：读 HEAD → 建 blobs → 建 tree → 建 commit → 更新 ref。
//  - 支持一次推送多个文件（files 数组），一次 commit，不依赖本地 git。
//

#import "AiGitHubTools.h"

static NSString * const kAiGitHubTokenKey = @"ai.github_token";
static NSString * const kAiGitHubAPIDomain = @"https://api.github.com";

@interface AiGitHubTool ()
@property (nonatomic, copy) NSString *internalName;
@end

@implementation AiGitHubTool

- (instancetype)initWithName:(NSString *)name {
    self = [super init];
    if (self) {
        _internalName = [name copy] ?: @"";
    }
    return self;
}

- (NSString *)name {
    return self.internalName;
}

- (AiToolPermission)permission {
    return AiToolPermissionExternalNetwork;
}

- (NSString *)summary {
    if ([self.internalName isEqualToString:@"github_set_token"]) {
        return @"保存用户的 GitHub Personal Access Token（PAT），供 github_push 工具认证使用。"
               "\n参数："
               "\n  - token（string，必填）：GitHub PAT，需具备 repo 写权限（推荐 fine-grained token 且只授权目标仓库的 Contents 读写）。"
               "\n返回：保存结果提示。Token 仅存本机 NSUserDefaults，不出现在对话记录里。"
               "\n用法：用户首次要求推送代码时，AI 应先询问用户 token 并调用本工具保存；此后 github_push 自动使用。";
    }
    // github_push
    return @"把文件内容以一次 commit 推送到 GitHub 仓库指定分支（走 GitHub API，无需本地 git）。"
           "\n参数："
           "\n  - repo（string，必填）：仓库全名 owner/name，如 Aiden6652/Air。"
           "\n  - branch（string，可选）：目标分支，默认 main。"
           "\n  - message（string，必填）：commit 说明。"
           "\n  - files（array，必填）：文件列表，每项 {\"path\":\"Natives/AI/AiWebFetchTool.m\",\"content\":\"文件完整内容\"}。"
           "\n返回：提交结果，包含 commit sha 与网页链接。"
           "\n边界：改动的文件会直接提交到远端分支；如需改本地先读文件再决定。删除文件可把 content 置空并传 delete=true。";
}

#pragma mark - 网络 JSON 请求

+ (void)requestJSONWithMethod:(NSString *)method
                          url:(NSURL *)url
                         token:(NSString *)token
                          body:(NSDictionary * _Nullable)body
                    completion:(void (^)(NSDictionary * _Nullable json, NSInteger statusCode, NSError * _Nullable error))completion {
    NSMutableURLRequest *request = [NSMutableURLRequest requestWithURL:url];
    request.HTTPMethod = method;
    request.timeoutInterval = 30.0;
    [request setValue:@"application/vnd.github+json" forHTTPHeaderField:@"Accept"];
    [request setValue:@"Air/1.0 (iOS; MC Launcher)" forHTTPHeaderField:@"User-Agent"];
    if (token.length > 0) {
        [request setValue:[NSString stringWithFormat:@"Bearer %@", token] forHTTPHeaderField:@"Authorization"];
    }
    if (body) {
        NSError *jsonErr = nil;
        NSData *payload = [NSJSONSerialization dataWithJSONObject:body options:0 error:&jsonErr];
        if (!payload || jsonErr) {
            if (completion) completion(nil, 0, jsonErr ?: [NSError errorWithDomain:@"AiGitHub" code:-1 userInfo:@{NSLocalizedDescriptionKey:@"请求体序列化失败"}]);
            return;
        }
        request.HTTPBody = payload;
        [request setValue:@"application/json" forHTTPHeaderField:@"Content-Type"];
    }

    NSURLSessionDataTask *task = [[NSURLSession sharedSession] dataTaskWithRequest:request
                                                                completionHandler:^(NSData *data, NSURLResponse *response, NSError *error) {
        dispatch_async(dispatch_get_main_queue(), ^{
            if (error) {
                if (completion) completion(nil, 0, error);
                return;
            }
            NSHTTPURLResponse *http = (NSHTTPURLResponse *)response;
            NSInteger status = (http && [http respondsToSelector:@selector(statusCode)]) ? http.statusCode : 200;
            NSDictionary *json = nil;
            if (data.length > 0) {
                json = [NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
                if (![json isKindOfClass:[NSDictionary class]]) json = nil;
            }
            if (completion) completion(json, status, nil);
        });
    }];
    [task resume];
}

+ (NSString *)errorDescriptionForStatus:(NSInteger)status json:(NSDictionary *)json {
    if (json[@"message"]) {
        NSString *msg = json[@"message"];
        if ([msg isKindOfClass:[NSString class]] && msg.length > 0) {
            return [NSString stringWithFormat:@"GitHub API 错误 (HTTP %ld)：%@", (long)status, msg];
        }
    }
    return [NSString stringWithFormat:@"GitHub API 请求失败 (HTTP %ld)", (long)status];
}

#pragma mark - 执行

- (void)execute:(NSDictionary<NSString *, id> *)params
     completion:(void (^)(NSString * _Nullable result, NSError * _Nullable error))completion {
    if (!completion) return;

    if ([self.internalName isEqualToString:@"github_set_token"]) {
        NSString *token = nil;
        id v = params[@"token"];
        if ([v isKindOfClass:[NSString class]]) token = (NSString *)v;
        token = [token stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
        if (token.length == 0) {
            NSError *err = [NSError errorWithDomain:@"AiGitHub" code:400
                                           userInfo:@{NSLocalizedDescriptionKey: @"github_set_token 缺少必填参数 token"}];
            completion(nil, err);
            return;
        }
        [[NSUserDefaults standardUserDefaults] setObject:token forKey:kAiGitHubTokenKey];
        completion(@"GitHub Token 已保存到本机，后续 github_push 会自动使用。", nil);
        return;
    }

    // ===== github_push =====
    NSString *token = [[NSUserDefaults standardUserDefaults] stringForKey:kAiGitHubTokenKey];
    if (token.length == 0) {
        NSError *err = [NSError errorWithDomain:@"AiGitHub" code:401
                                       userInfo:@{NSLocalizedDescriptionKey: @"尚未配置 GitHub Token。请先让用户提供 PAT 并调用 github_set_token 保存。"}];
        completion(nil, err);
        return;
    }

    NSString *repo = nil;
    id repoVal = params[@"repo"];
    if ([repoVal isKindOfClass:[NSString class]]) repo = (NSString *)repoVal;
    repo = [repo stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    if (repo.length == 0 || [repo componentsSeparatedByString:@"/"].count != 2) {
        NSError *err = [NSError errorWithDomain:@"AiGitHub" code:400
                                       userInfo:@{NSLocalizedDescriptionKey: @"github_push 参数 repo 需为 owner/name 格式，如 Aiden6652/Air"}];
        completion(nil, err);
        return;
    }
    NSString *branch = @"main";
    id brVal = params[@"branch"];
    if ([brVal isKindOfClass:[NSString class]] && [(NSString *)brVal length] > 0) branch = (NSString *)brVal;

    NSString *message = nil;
    id msgVal = params[@"message"];
    if ([msgVal isKindOfClass:[NSString class]]) message = (NSString *)msgVal;
    message = [message stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    if (message.length == 0) {
        NSError *err = [NSError errorWithDomain:@"AiGitHub" code:400
                                       userInfo:@{NSLocalizedDescriptionKey: @"github_push 缺少必填参数 message（commit 说明）"}];
        completion(nil, err);
        return;
    }

    NSArray *files = nil;
    id filesVal = params[@"files"];
    if ([filesVal isKindOfClass:[NSArray class]]) files = (NSArray *)filesVal;
    if (files.count == 0) {
        NSError *err = [NSError errorWithDomain:@"AiGitHub" code:400
                                       userInfo:@{NSLocalizedDescriptionKey: @"github_push 缺少 files 数组（至少一个文件）"}];
        completion(nil, err);
        return;
    }
    NSMutableArray *cleanFiles = [NSMutableArray array];
    for (id item in files) {
        if (![item isKindOfClass:[NSDictionary class]]) continue;
        NSString *p = item[@"path"];
        id c = item[@"content"];
        if (![p isKindOfClass:[NSString class]] || p.length == 0) continue;
        NSString *contentStr = [c isKindOfClass:[NSString class]] ? (NSString *)c : @"";
        BOOL isDelete = [item[@"delete"] respondsToSelector:@selector(boolValue)] && [item[@"delete"] boolValue];
        [cleanFiles addObject:@{@"path": p, @"content": contentStr, @"delete": @(isDelete)}];
    }
    if (cleanFiles.count == 0) {
        NSError *err = [NSError errorWithDomain:@"AiGitHub" code:400
                                       userInfo:@{NSLocalizedDescriptionKey: @"files 中没有任何有效文件项（需要 path 与 content）"}];
        completion(nil, err);
        return;
    }
    files = cleanFiles;

    NSString *repoEncoded = [repo stringByAddingPercentEncodingWithAllowedCharacters:[NSCharacterSet URLPathAllowedCharacterSet]];
    NSString *branchEncoded = [branch stringByAddingPercentEncodingWithAllowedCharacters:[NSCharacterSet URLPathAllowedCharacterSet]];

    // Step 1: 读取当前 HEAD commit（引用 refs/heads/branch）
    NSURL *refURL = [NSURL URLWithString:[NSString stringWithFormat:@"%@/repos/%@/git/ref/heads/%@", kAiGitHubAPIDomain, repoEncoded, branchEncoded]];
    [AiGitHubTool requestJSONWithMethod:@"GET" url:refURL token:token body:nil completion:^(NSDictionary * _Nullable json, NSInteger status, NSError * _Nullable error) {
        if (error || status >= 400 || !json[@"object"]) {
            NSError *err = [NSError errorWithDomain:@"AiGitHub" code:(int)(error ? error.code : status)
                                           userInfo:@{NSLocalizedDescriptionKey: error ? error.localizedDescription : [AiGitHubTool errorDescriptionForStatus:status json:json]}];
            completion(nil, err);
            return;
        }
        NSString *headCommitSha = json[@"object"][@"sha"];
        if (![headCommitSha isKindOfClass:[NSString class]] || headCommitSha.length == 0) {
            completion(nil, [NSError errorWithDomain:@"AiGitHub" code:-1 userInfo:@{NSLocalizedDescriptionKey:@"无法读取分支 HEAD"}]); 
            return;
        }

        // Step 2: 读 HEAD commit 拿到 base tree sha
        NSURL *headCommitURL = [NSURL URLWithString:[NSString stringWithFormat:@"%@/repos/%@/git/commits/%@", kAiGitHubAPIDomain, repoEncoded, headCommitSha]];
        [AiGitHubTool requestJSONWithMethod:@"GET" url:headCommitURL token:token body:nil completion:^(NSDictionary * _Nullable commitJson, NSInteger cStatus, NSError * _Nullable cError) {
            if (cError || cStatus >= 400 || !commitJson[@"tree"]) {
                NSError *err = [NSError errorWithDomain:@"AiGitHub" code:(int)(cError ? cError.code : cStatus)
                                               userInfo:@{NSLocalizedDescriptionKey: cError ? cError.localizedDescription : [AiGitHubTool errorDescriptionForStatus:cStatus json:commitJson]}];
                completion(nil, err);
                return;
            }
            NSString *baseTreeSha = commitJson[@"tree"][@"sha"];

            // Step 3: 串行创建每个 blob
            [self createBlobsForFiles:files repoEncoded:repoEncoded token:token
                           completion:^(NSArray * _Nullable blobShas, NSError * _Nullable blobError) {
                if (blobError || !blobShas) {
                    completion(nil, blobError ?: [NSError errorWithDomain:@"AiGitHub" code:-1 userInfo:@{NSLocalizedDescriptionKey:@"创建 blob 失败"}]);
                    return;
                }

                // Step 4: 建 tree
                NSMutableArray *treeItems = [NSMutableArray array];
                for (NSUInteger i = 0; i < files.count; i++) {
                    NSDictionary *file = files[i];
                    BOOL isDelete = [file[@"delete"] boolValue];
                    if (isDelete) {
                        [treeItems addObject:@{@"path": file[@"path"], @"sha": NSNull.null}];
                    } else {
                        NSString *blobSha = blobShas[i];
                        [treeItems addObject:@{@"path": file[@"path"], @"mode": @"100644", @"type": @"blob", @"sha": blobSha}];
                    }
                }
                NSDictionary *treeBody = @{@"base_tree": baseTreeSha ?: @"", @"tree": treeItems};
                NSURL *treeURL = [NSURL URLWithString:[NSString stringWithFormat:@"%@/repos/%@/git/trees", kAiGitHubAPIDomain, repoEncoded]];
                [AiGitHubTool requestJSONWithMethod:@"POST" url:treeURL token:token body:treeBody completion:^(NSDictionary * _Nullable treeJson, NSInteger tStatus, NSError * _Nullable tError) {
                    if (tError || tStatus >= 400 || !treeJson[@"sha"]) {
                        NSError *err = [NSError errorWithDomain:@"AiGitHub" code:(int)(tError ? tError.code : tStatus)
                                                       userInfo:@{NSLocalizedDescriptionKey: tError ? tError.localizedDescription : [AiGitHubTool errorDescriptionForStatus:tStatus json:treeJson]}];
                        completion(nil, err);
                        return;
                    }
                    NSString *newTreeSha = treeJson[@"sha"];

                    // Step 5: 创建 commit
                    NSDictionary *commitBody = @{
                        @"message": message,
                        @"tree": newTreeSha,
                        @"parents": @[headCommitSha],
                    };
                    NSURL *commitURL = [NSURL URLWithString:[NSString stringWithFormat:@"%@/repos/%@/git/commits", kAiGitHubAPIDomain, repoEncoded]];
                    [AiGitHubTool requestJSONWithMethod:@"POST" url:commitURL token:token body:commitBody completion:^(NSDictionary * _Nullable newCommitJson, NSInteger mStatus, NSError * _Nullable mError) {
                        if (mError || mStatus >= 400 || !newCommitJson[@"sha"]) {
                            NSError *err = [NSError errorWithDomain:@"AiGitHub" code:(int)(mError ? mError.code : mStatus)
                                                           userInfo:@{NSLocalizedDescriptionKey: mError ? mError.localizedDescription : [AiGitHubTool errorDescriptionForStatus:mStatus json:newCommitJson]}];
                            completion(nil, err);
                            return;
                        }
                        NSString *newCommitSha = newCommitJson[@"sha"];

                        // Step 6: 更新分支引用
                        NSDictionary *refBody = @{@"sha": newCommitSha, @"force": @NO};
                        NSURL *updateRefURL = [NSURL URLWithString:[NSString stringWithFormat:@"%@/repos/%@/git/refs/heads/%@", kAiGitHubAPIDomain, repoEncoded, branchEncoded]];
                        [AiGitHubTool requestJSONWithMethod:@"PATCH" url:updateRefURL token:token body:refBody completion:^(NSDictionary * _Nullable refJson, NSInteger rStatus, NSError * _Nullable rError) {
                            if (rError || rStatus >= 400) {
                                NSError *err = [NSError errorWithDomain:@"AiGitHub" code:(int)(rError ? rError.code : rStatus)
                                                               userInfo:@{NSLocalizedDescriptionKey: rError ? rError.localizedDescription : [AiGitHubTool errorDescriptionForStatus:rStatus json:refJson]}];
                                completion(nil, err);
                                return;
                            }
                            NSString *htmlURL = [NSString stringWithFormat:@"https://github.com/%@/commit/%@", repo, newCommitSha];
                            NSString *result = [NSString stringWithFormat:@"推送成功 ✅\n仓库：%@\n分支：%@\ncommit：%@\n链接：%@\n文件数：%lu",
                                                repo, branch, newCommitSha, htmlURL, (unsigned long)files.count];
                            completion(result, nil);
                        }];
                    }];
                }];
            }];
        }];
    }];
}

#pragma mark - 串行创建 blob

- (void)createBlobsForFiles:(NSArray *)files
                 repoEncoded:(NSString *)repoEncoded
                       token:(NSString *)token
                 completion:(void (^)(NSArray * _Nullable blobShas, NSError * _Nullable error))completion {
    NSMutableArray *blobShas = [NSMutableArray array];
    __block NSUInteger index = 0;
    __block BOOL failed = NO;
    // 必须 __block：否则 block 内递归引用到的是未初始化的栈变量，运行即崩
    __block void (^next)(void);
    next = ^{
        if (failed) return;
        if (index >= files.count) {
            if (completion) completion(blobShas, nil);
            return;
        }
        NSUInteger current = index;
        index++;
        NSDictionary *file = files[current];
        if ([file[@"delete"] boolValue]) {
            [blobShas addObject:[NSNull null]];
            next();
            return;
        }
        NSString *content = file[@"content"] ?: @"";
        NSData *contentData = [content dataUsingEncoding:NSUTF8StringEncoding];
        NSString *base64 = contentData ? [contentData base64EncodedStringWithOptions:0] : @"";
        NSDictionary *body = @{@"content": base64 ?: @"", @"encoding": @"base64"};
        NSURL *blobURL = [NSURL URLWithString:[NSString stringWithFormat:@"%@/repos/%@/git/blobs", kAiGitHubAPIDomain, repoEncoded]];
        [AiGitHubTool requestJSONWithMethod:@"POST" url:blobURL token:token body:body completion:^(NSDictionary * _Nullable json, NSInteger status, NSError * _Nullable error) {
            if (failed) return;
            if (error || status >= 400 || !json[@"sha"]) {
                failed = YES;
                NSError *err = [NSError errorWithDomain:@"AiGitHub" code:(int)(error ? error.code : status)
                                               userInfo:@{NSLocalizedDescriptionKey: error ? error.localizedDescription : [AiGitHubTool errorDescriptionForStatus:status json:json]}];
                if (completion) completion(nil, err);
                return;
            }
            [blobShas addObject:json[@"sha"]];
            next();
        }];
    };
    next();
}

@end
