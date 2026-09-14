//
//  AiWebFetchTool.m
//  Amethyst
//
//  fetch_url 工具实现：通用网页/API 抓取（HTTP GET）。
//  设计原则：
//  - 只允许 http/https，防止 file:// 等本地读取绕过文件工具的安全边界。
//  - 默认请求 https 网页、GitHub API、raw.githubusercontent.com、普通文本均可用。
//  - 返回内容会被截断（默认 8000 字符，可通过 maxChars 调整），防止上下文爆炸。
//  - 权限 ReadOnly：纯只读 GET、无副作用，任何安全模式免确认直接执行。
//

#import "AiWebFetchTool.h"

@implementation AiWebFetchTool

- (NSString *)name {
    return @"fetch_url";
}

- (AiToolPermission)permission {
    return AiToolPermissionReadOnly;
}

- (NSString *)summary {
    return @"对任意 http/https URL 发起 GET 请求并返回网页/API 的文本内容。"
           "\n可用于：查看 GitHub 仓库/文件/Release、搜索 GitHub（用 api.github.com/search/...）、读取 Modrinth/CurseForge 之外任意网站、在线文档、JSON API 等。"
           "\n参数："
           "\n  - url（string，必填）：完整 URL。示例：https://api.github.com/repos/owner/repo、https://raw.githubusercontent.com/owner/repo/main/README.md、https://api.github.com/search/repositories?q=minecraft&per_page=5。"
           "\n  - maxChars（integer，可选）：返回内容最大字符数，默认 8000，最大 30000，超出部分截断。"
           "\n  - token（string，可选）：显式传入的 Bearer Token。不传时自动使用本机已保存的 GitHub Token（github_set_token 存的那个），可避免 GitHub API 限流。"
           "\n返回：HTML 页面自动剥离标签转为纯文本；JSON/纯文本原样返回。"
           "\n边界：仅 GET 只读，不会下载文件到本地；请求失败返回错误说明。"
           "\n用法：AI 应自行构造目标 URL（GitHub 等公开网站均可直接访问），拿到内容后结合用户意图继续推进，不要把原始 JSON 大段粘贴给用户，应先总结提炼。";
}

#pragma mark - 执行

- (void)execute:(NSDictionary<NSString *, id> *)params
     completion:(void (^)(NSString * _Nullable result, NSError * _Nullable error))completion {
    if (!completion) return;

    NSString *urlString = nil;
    id urlValue = params[@"url"];
    if ([urlValue isKindOfClass:[NSString class]]) {
        urlString = (NSString *)urlValue;
    }
    if (urlString.length == 0) {
        NSError *err = [NSError errorWithDomain:@"AiTool" code:400
                                       userInfo:@{NSLocalizedDescriptionKey: @"fetch_url 缺少必填参数 url"}];
        completion(nil, err);
        return;
    }

    NSInteger maxChars = 8000;
    id maxValue = params[@"maxChars"];
    if ([maxValue respondsToSelector:@selector(integerValue)]) {
        NSInteger v = [maxValue integerValue];
        if (v > 0) maxChars = MIN(v, 30000);
    }

    NSURL *url = [NSURL URLWithString:urlString];
    if (!url || !url.scheme) {
        NSError *err = [NSError errorWithDomain:@"AiTool" code:400
                                       userInfo:@{NSLocalizedDescriptionKey: [NSString stringWithFormat:@"无效 URL：%@", urlString]}];
        completion(nil, err);
        return;
    }
    NSString *scheme = [url.scheme lowercaseString];
    if (![scheme isEqualToString:@"http"] && ![scheme isEqualToString:@"https"]) {
        NSError *err = [NSError errorWithDomain:@"AiTool" code:400
                                       userInfo:@{NSLocalizedDescriptionKey: @"仅支持 http/https URL"}];
        completion(nil, err);
        return;
    }

    NSMutableURLRequest *request = [NSMutableURLRequest requestWithURL:url];
    request.HTTPMethod = @"GET";
    request.timeoutInterval = 20.0;
    [request setValue:@"Air/1.0 (iOS; MC Launcher)" forHTTPHeaderField:@"User-Agent"];
    [request setValue:@"application/json, text/plain, text/html, */*;q=0.8" forHTTPHeaderField:@"Accept"];

    // GitHub/私有 API 认证：优先用参数 token，否则自动读取 github_set_token 保存的本机 token。
    // 带上 token 可避免 GitHub API 匿名限流（60 次/小时 → 最高 5000 次/小时）。
    NSString *authToken = nil;
    id tokenParam = params[@"token"];
    if ([tokenParam isKindOfClass:[NSString class]] && [(NSString *)tokenParam length] > 0) {
        authToken = (NSString *)tokenParam;
    } else {
        authToken = [[NSUserDefaults standardUserDefaults] stringForKey:@"ai.github_token"];
    }
    if (authToken.length > 0) {
        // 若调用方显式给了 token 参数，说明该 token 属于目标站点（可能是 GitHub 也可能不是），
        // 统一按 Bearer 附加；对 GitHub 与常见 API 均适用。
        [request setValue:[NSString stringWithFormat:@"Bearer %@", authToken] forHTTPHeaderField:@"Authorization"];
    }

    NSURLSession *session = [NSURLSession sharedSession];
    NSURLSessionDataTask *task = [session dataTaskWithRequest:request
                                            completionHandler:^(NSData *data, NSURLResponse *response, NSError *error) {
        // 结果统一回到主线程回调
        dispatch_async(dispatch_get_main_queue(), ^{
            if (error) {
                NSError *err = [NSError errorWithDomain:@"AiTool" code:-1
                                               userInfo:@{NSLocalizedDescriptionKey: [NSString stringWithFormat:@"网络请求失败：%@", error.localizedDescription ?: @"未知错误"]}];
                completion(nil, err);
                return;
            }
            NSHTTPURLResponse *http = (NSHTTPURLResponse *)response;
            NSInteger statusCode = (http && [http respondsToSelector:@selector(statusCode)]) ? http.statusCode : 200;
            if (statusCode >= 400) {
                NSError *err = [NSError errorWithDomain:@"AiTool" code:(int)statusCode
                                               userInfo:@{NSLocalizedDescriptionKey: [NSString stringWithFormat:@"HTTP %ld：目标站点返回错误（可能页面不存在、需登录或访问被拒）", (long)statusCode]}];
                completion(nil, err);
                return;
            }

            if (!data) {
                NSError *err = [NSError errorWithDomain:@"AiTool" code:-1
                                               userInfo:@{NSLocalizedDescriptionKey: @"响应为空"}];
                completion(nil, err);
                return;
            }

            // 尝试 UTF-8 解码；失败则按 Latin-1
            NSString *text = [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding];
            if (!text) {
                text = [[NSString alloc] initWithData:data encoding:NSISOLatin1StringEncoding];
            }
            if (!text) {
                NSError *err = [NSError errorWithDomain:@"AiTool" code:-1
                                               userInfo:@{NSLocalizedDescriptionKey: @"无法解码响应内容"}];
                completion(nil, err);
                return;
            }

            // 简单 HTML 转纯文本
            if ([text rangeOfString:@"<html" options:NSCaseInsensitiveSearch].location != NSNotFound ||
                [text rangeOfString:@"<!doctype html" options:NSCaseInsensitiveSearch].location != NSNotFound ||
                [http.MIMEType isEqualToString:@"text/html"]) {
                text = [AiWebFetchTool plainTextFromHTML:text];
            }

            if (text.length > maxChars) {
                text = [text substringToIndex:maxChars];
            }
            completion(text, nil);
        });
    }];
    [task resume];
}

#pragma mark - HTML 剥离

/// 简单把 HTML 转成可读纯文本：去掉 script/style/标签，解码常见实体
+ (NSString *)plainTextFromHTML:(NSString *)html {
    if (html.length == 0) return @"";

    NSString *s = html;
    // 去掉 script/style 块
    NSRegularExpression *scriptRe = [NSRegularExpression regularExpressionWithPattern:@"(?is)<(script|style)[^>]*>.*?</\\1>" options:0 error:nil];
    s = [scriptRe stringByReplacingMatchesInString:s options:0 range:NSMakeRange(0, s.length) withTemplate:@" "];
    // 去掉注释
    NSRegularExpression *commentRe = [NSRegularExpression regularExpressionWithPattern:@"(?s)<!--.*?-->" options:0 error:nil];
    s = [commentRe stringByReplacingMatchesInString:s options:0 range:NSMakeRange(0, s.length) withTemplate:@" "];
    // 标签 → 换行/空格
    NSRegularExpression *tagRe = [NSRegularExpression regularExpressionWithPattern:@"(?i)</(p|div|li|tr|h1|h2|h3|h4|h5|h6|br|section|article|blockquote)>" options:0 error:nil];
    s = [tagRe stringByReplacingMatchesInString:s options:0 range:NSMakeRange(0, s.length) withTemplate:@"\n"];
    NSRegularExpression *tagRe2 = [NSRegularExpression regularExpressionWithPattern:@"<[^>]+>" options:0 error:nil];
    s = [tagRe2 stringByReplacingMatchesInString:s options:0 range:NSMakeRange(0, s.length) withTemplate:@" "];

    // 解码常见实体
    NSDictionary *entities = @{
        @"&amp;": @"&", @"&lt;": @"<", @"&gt;": @">",
        @"&quot;": @"\"", @"&#39;": @"'", @"&apos;": @"'",
        @"&nbsp;": @" ", @"&mdash;": @"—", @"&ndash;": @"–",
        @"&hellip;": @"…", @"&copy;": @"©", @"&reg;": @"®",
    };
    for (NSString *key in entities) {
        s = [s stringByReplacingOccurrencesOfString:key withString:entities[key]];
    }

    // 压缩空白：每行 trim，去掉多余空行
    NSArray *lines = [s componentsSeparatedByString:@"\n"];
    NSMutableArray *outLines = [NSMutableArray array];
    for (NSString *rawLine in lines) {
        NSString *line = [rawLine stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]];
        if (line.length > 0) {
            [outLines addObject:line];
        }
    }
    return [outLines componentsJoinedByString:@"\n"];
}

@end
