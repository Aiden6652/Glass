//
//  AiFileTools.m
//  Amethyst
//

#import "AiFileTools.h"
#import "LauncherPreferences.h"

static NSString * const kAiToolDomain = @"AiTool";

@interface AiFileTools ()
@property (nonatomic, copy) NSString *internalName;
@end

@implementation AiFileTools

- (instancetype)initWithName:(NSString *)name {
    self = [super init];
    if (self) {
        _internalName = name ?: @"";
    }
    return self;
}

- (NSString *)name {
    return self.internalName;
}

- (AiToolPermission)permission {
    if ([self.internalName isEqualToString:@"write_file"] || [self.internalName isEqualToString:@"edit_file"]) {
        return AiToolPermissionControlledWrite;
    }
    if ([self.internalName isEqualToString:@"delete_file"]) {
        return AiToolPermissionDangerousWrite;
    }
    return AiToolPermissionReadOnly;
}

- (NSString *)summary {
    if ([self.internalName isEqualToString:@"list_roots"]) {
        return @"列出 AI 文件工具当前可访问的根目录（容器根 + 用户已授权的外部目录）。"
               "\n参数：无。"
               "\n返回 JSON 数组，每项含 path（根路径）、kind（container/authorized）、name（显示名）。"
               "\n用途：当不确定能访问哪些位置、或用户问「你能看到哪些文件夹」时调用；"
               "若用户希望 AI 访问容器外的目录（如其它 App 的文件夹、iCloud、本地存储），"
               "提示用户用 folder_request_access 授权。";
    }
    if ([self.internalName isEqualToString:@"list_files"]) {
        return @"列出指定目录下的文件/子目录（不递归）。"
               "\n参数：path（string，可选，默认当前实例根目录）。"
               "\n返回 JSON 数组，每项含 name（名称）、type（file/dir）、size（字节）、modifiedUnixTS（修改时间戳），按名称排序。"
               "\n可访问范围：整个 App 容器（Documents/Library/tmp，含启动器目录、instances、存档、模组、配置）"
               "以及用户已授权的外部目录；可用 list_roots 查询，容器外目录需先 folder_request_access 授权。";
    }
    if ([self.internalName isEqualToString:@"read_file"]) {
        return @"读取文本文件内容。"
               "\n参数：path（string，必填）、maxChars（number，可选，默认 8000，超长截断）。"
               "\n返回文件文本内容；二进制文件返回「二进制文件不可读」。"
               "\n可访问范围：App 容器全路径 + 已授权外部目录（见 list_roots）。";
    }
    if ([self.internalName isEqualToString:@"grep_files"]) {
        return @"在文件中用正则表达式搜索匹配行。"
               "\n参数：path（string，可选，默认当前实例根目录）、pattern（string，必填，正则表达式）、"
               "recursive（boolean，可选，默认 NO）、maxResults（number，可选，默认 50）。"
               "\n返回 JSON 数组 {path, lineNumber, line}。"
               "\n可访问范围：App 容器全路径 + 已授权外部目录（见 list_roots）。";
    }
    if ([self.internalName isEqualToString:@"write_file"]) {
        return @"写文本文件（原子写入，自动创建父目录）。"
               "\n参数：path（string，必填）、content（string，必填）。"
               "\n返回「已写入（N 字符）」。覆盖已存在内容。"
               "\n可访问范围：App 容器全路径 + 已授权外部目录；写入容器外目录前需 folder_request_access 授权。"
               "\n注意：不要写入 /System、越权目录或破坏性路径。";
    }
    if ([self.internalName isEqualToString:@"edit_file"]) {
        return @"精确替换文件中的一段文本。"
               "\n参数：path（string，必填）、oldText（string，必填）、newText（string，必填）。"
               "\n仅当 oldText 在文件中恰好出现 1 次时才替换，否则返回错误（出现 N 次）。";
    }
    if ([self.internalName isEqualToString:@"delete_file"]) {
        return @"删除文件（危险操作）。"
               "\n参数：path（string，必填）。"
               "\n出于安全考虑，仅允许删除文本类文件（.txt/.log/.json/.properties/.toml/.md/.cfg/.yml/.yaml/.xml/.xaml/.lang 等），不删除目录。"
               "\n返回「已删除」。";
    }
    return @"文件操作工具";
}

#pragma mark - 沙盒路径安全

/// 当前实例根目录（POJAV_GAME_DIR 或其回退）
+ (NSString *)currentGameRoot {
    const char *root = getenv("POJAV_GAME_DIR");
    if (root && strlen(root) > 0) return @(root);
    const char *home = getenv("POJAV_HOME");
    if (home && strlen(home) > 0) {
        NSString *name = getPrefObject(@"general.game_directory");
        if (name.length == 0) name = @"default";
        return [NSString stringWithFormat:@"%s/instances/%@", home, name];
    }
    return [NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES) firstObject];
}

/// 文件工具合法根目录集合（自 3e 阶段起为「多根」）：
///  1. App 容器根（NSHomeDirectory()）——覆盖 Documents / Library / tmp / SystemData，
///     即启动器目录、instances/*、存档、模组、偏好设置、缓存、日志等全部可写区域；
///  2. 用户经 UIDocumentPickerViewController 显式授权的容器外目录
///     （存于 AiFolderAccessTool 的授权书签列表，路径已 realpath 归一化）。
/// 经 realpath 归一化以匹配 POJAV_GAME_DIR 符号链接解析后的真实前缀，避免误判越界。
/// 3e 调整：从「仅启动器目录」放宽为「整个 App 容器 + 用户授权目录」。
+ (NSArray<NSString *> *)sandboxRoots {
    NSMutableArray<NSString *> *roots = [NSMutableArray array];

    void (^addRoot)(NSString *) = ^(NSString *candidate) {
        if (candidate.length == 0) return;
        NSString *normalized = nil;
        const char *c = [candidate UTF8String];
        if (c) {
            char *real = realpath(c, NULL);
            if (real) {
                normalized = @(real);
                free(real);
            }
        }
        if (!normalized) normalized = [candidate stringByStandardizingPath];
        if (normalized.length > 0 && ![roots containsObject:normalized]) {
            [roots addObject:normalized];
        }
    };

    // 1) App 容器根
    addRoot(NSHomeDirectory());

    // 2) 用户授权的外部目录（弱依赖：类不存在时安全降级）
    Class accessClass = NSClassFromString(@"AiFolderAccessTool");
    if (accessClass && [accessClass respondsToSelector:@selector(authorizedRootPaths)]) {
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Warc-performSelector-leaks"
        id authorized = [accessClass performSelector:@selector(authorizedRootPaths)];
#pragma clang diagnostic pop
        if ([authorized isKindOfClass:[NSArray class]]) {
            for (id p in (NSArray *)authorized) {
                if ([p isKindOfClass:[NSString class]]) addRoot((NSString *)p);
            }
        }
    }

    return roots;
}

/// 兼容旧标识：返回容器根（主根）。
+ (NSString *)sandboxRoot {
    NSArray<NSString *> *roots = [self sandboxRoots];
    return roots.firstObject ?: NSHomeDirectory();
}

+ (nullable NSString *)resolveSafely:(NSString *)path {
    if (path.length == 0) return nil;
    NSArray<NSString *> *stdRoots = [self sandboxRoots];
    NSString *primaryRoot = stdRoots.firstObject ?: NSHomeDirectory();

    BOOL usedGameDir = ([path rangeOfString:@"$GAMEDIR"].location != NSNotFound);
    NSString *worked = path;
    if (usedGameDir) {
        NSString *gameRoot = [self currentGameRoot];
        worked = [worked stringByReplacingOccurrencesOfString:@"$GAMEDIR" withString:(gameRoot.length ? gameRoot : primaryRoot)];
    }

    NSString *joined;
    if (usedGameDir) {
        joined = worked; // 已被替换为物理绝对路径
    } else if ([worked hasPrefix:@"/"]) {
        // 绝对物理路径原样使用，是否越界由下方基于根集合的检查统一裁决。
        joined = worked;
    } else if ([worked hasPrefix:@"~/"]) {
        // 支持 ~/Documents 这类写法，映射到容器根
        joined = [primaryRoot stringByAppendingPathComponent:[worked substringFromIndex:2]];
    } else {
        // 相对路径：相对当前实例根
        joined = [[self currentGameRoot] stringByAppendingPathComponent:worked];
    }

    // 标准化（去 ./ ..、解析符号链接），随后做越界检查（命中任一合法根即放行）
    NSString *std = [joined stringByResolvingSymlinksInPath];
    for (NSString *root in stdRoots) {
        NSString *stdRoot = [root stringByResolvingSymlinksInPath];
        NSString *prefix = [stdRoot hasSuffix:@"/"] ? stdRoot : [stdRoot stringByAppendingString:@"/"];
        if ([std isEqualToString:stdRoot] || [std hasPrefix:prefix]) {
            return std; // 命中合法根
        }
    }
    return nil; // 越界
}

#pragma mark - 执行分发

- (void)execute:(NSDictionary<NSString *, id> *)params
     completion:(void (^)(NSString * _Nullable result, NSError * _Nullable error))completion {
    if (!completion) return;

    if ([self.internalName isEqualToString:@"list_roots"])  { [self performListRoots:params completion:completion]; return; }
    if ([self.internalName isEqualToString:@"list_files"]) { [self performListFiles:params completion:completion]; return; }    if ([self.internalName isEqualToString:@"read_file"])   { [self performReadFile:params completion:completion]; return; }
    if ([self.internalName isEqualToString:@"grep_files"])  { [self performGrepFiles:params completion:completion]; return; }
    if ([self.internalName isEqualToString:@"write_file"])  { [self performWriteFile:params completion:completion]; return; }
    if ([self.internalName isEqualToString:@"edit_file"])   { [self performEditFile:params completion:completion]; return; }
    if ([self.internalName isEqualToString:@"delete_file"]) { [self performDeleteFile:params completion:completion]; return; }

    NSError *err = [NSError errorWithDomain:kAiToolDomain code:404
                                   userInfo:@{NSLocalizedDescriptionKey: [NSString stringWithFormat:@"未知工具 %@", self.internalName]}];
    completion(nil, err);
}

- (NSError *)errorWithCode:(NSInteger)code message:(NSString *)message {
    return [NSError errorWithDomain:kAiToolDomain code:code
                           userInfo:@{NSLocalizedDescriptionKey: message}];
}

#pragma mark - list_roots

- (void)performListRoots:(NSDictionary *)params completion:(void(^)(NSString *, NSError *))completion {
    NSMutableArray *out = [NSMutableArray array];
    NSArray<NSString *> *roots = [[self class] sandboxRoots];
    NSString *container = NSHomeDirectory();
    NSString *containerStd = [container stringByResolvingSymlinksInPath];
    for (NSString *root in roots) {
        BOOL isContainer = [[root stringByResolvingSymlinksInPath] isEqualToString:containerStd];
        [out addObject:@{
            @"path": root,
            @"kind": isContainer ? @"container" : @"authorized",
            @"name": isContainer ? @"App 容器（Documents/Library/tmp）" : root.lastPathComponent,
        }];
    }
    NSData *data = [NSJSONSerialization dataWithJSONObject:out options:NSJSONWritingPrettyPrinted error:nil];
    NSString *json = data ? [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding] : @"[]";
    completion(json, nil);
}

#pragma mark - list_files

- (void)performListFiles:(NSDictionary *)params completion:(void(^)(NSString *, NSError *))completion {
    NSString *path = [params[@"path"] isKindOfClass:[NSString class]] ? params[@"path"] : nil;
    if (path.length == 0) path = [[self class] currentGameRoot];
    NSString *resolved = [[self class] resolveSafely:path];
    if (!resolved) { completion(nil, [self errorWithCode:403 message:@"路径越界或无效"]); return; }

    NSArray *items = [[NSFileManager defaultManager] contentsOfDirectoryAtPath:resolved error:nil];
    if (!items) { completion(nil, [self errorWithCode:404 message:@"目录不存在"]); return; }

    NSMutableArray *entries = [NSMutableArray array];
    for (NSString *name in items) {
        if ([name hasPrefix:@"."]) continue;
        NSString *full = [resolved stringByAppendingPathComponent:name];
        BOOL isDir = NO;
        if (![[NSFileManager defaultManager] fileExistsAtPath:full isDirectory:&isDir]) continue;
        NSDictionary *attrs = [[NSFileManager defaultManager] attributesOfItemAtPath:full error:nil];
        long long size = isDir ? 0 : [attrs[NSFileSize] longLongValue];
        double ts = [attrs[NSFileModificationDate] timeIntervalSince1970];
        [entries addObject:@{
            @"name": name,
            @"type": isDir ? @"dir" : @"file",
            @"size": @(size),
            @"modifiedUnixTS": @(ts),
        }];
    }
    [entries sortUsingComparator:^NSComparisonResult(NSDictionary *a, NSDictionary *b) {
        return [a[@"name"] localizedCaseInsensitiveCompare:b[@"name"]];
    }];
    completion([self jsonStringFromObject:entries], nil);
}

#pragma mark - read_file

- (void)performReadFile:(NSDictionary *)params completion:(void(^)(NSString *, NSError *))completion {
    NSString *path = [params[@"path"] isKindOfClass:[NSString class]] ? params[@"path"] : nil;
    if (path.length == 0) { completion(nil, [self errorWithCode:400 message:@"参数 path 必填"]); return; }
    NSString *resolved = [[self class] resolveSafely:path];
    if (!resolved) { completion(nil, [self errorWithCode:403 message:@"路径越界或无效"]); return; }

    NSUInteger maxChars = 8000;
    NSNumber *maxNum = params[@"maxChars"];
    if ([maxNum isKindOfClass:[NSNumber class]]) {
        NSInteger v = maxNum.integerValue;
        if (v > 0) maxChars = (NSUInteger)v;
    }

    NSData *data = [NSData dataWithContentsOfFile:resolved];
    if (!data) { completion(nil, [self errorWithCode:404 message:@"文件不存在或不可读"]); return; }

    // 二进制检测：包含 NUL 字节，或无法按 UTF-8 解码
    BOOL hasNull = [data rangeOfData:[NSData dataWithBytes:"\0" length:1] options:0 range:NSMakeRange(0, data.length)].location != NSNotFound;
    if (hasNull) { completion(@"二进制文件不可读", nil); return; }
    NSString *content = [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding];
    if (!content) {
        content = [[NSString alloc] initWithData:data encoding:NSISOLatin1StringEncoding];
    }
    if (!content) { completion(@"二进制文件不可读", nil); return; }
    if (content.length > maxChars) {
        content = [NSString stringWithFormat:@"（内容过长已截断，显示开头 %lu 字符）\n%@", (unsigned long)maxChars,
                   [content substringToIndex:maxChars]];
    }
    completion(content, nil);
}

#pragma mark - grep_files

- (void)performGrepFiles:(NSDictionary *)params completion:(void(^)(NSString *, NSError *))completion {
    NSString *path = [params[@"path"] isKindOfClass:[NSString class]] ? params[@"path"] : nil;
    if (path.length == 0) path = [[self class] currentGameRoot];
    NSString *pattern = [params[@"pattern"] isKindOfClass:[NSString class]] ? params[@"pattern"] : nil;
    if (pattern.length == 0) { completion(nil, [self errorWithCode:400 message:@"参数 pattern（正则）必填"]); return; }
    NSString *resolved = [[self class] resolveSafely:path];
    if (!resolved) { completion(nil, [self errorWithCode:403 message:@"路径越界或无效"]); return; }

    BOOL recursive = NO;
    NSNumber *recNum = params[@"recursive"];
    if ([recNum isKindOfClass:[NSNumber class]]) recursive = recNum.boolValue;

    NSUInteger maxResults = 50;
    NSNumber *maxNum = params[@"maxResults"];
    if ([maxNum isKindOfClass:[NSNumber class]] && maxNum.integerValue >= 0) maxResults = (NSUInteger)maxNum.integerValue;
    if (maxResults == 0) maxResults = 50;

    NSError *regexError = nil;
    NSRegularExpression *regex = [NSRegularExpression regularExpressionWithPattern:pattern options:0 error:&regexError];
    if (!regex) {
        completion(nil, [self errorWithCode:400 message:[NSString stringWithFormat:@"正则表达式无效：%@", regexError.localizedDescription]]);
        return;
    }

    NSMutableArray *results = [NSMutableArray array];
    NSMutableArray *pendingDirs = [NSMutableArray arrayWithObject:resolved];
    NSFileManager *fm = [NSFileManager defaultManager];

    while (pendingDirs.count > 0 && results.count < maxResults) {
        NSString *dir = [pendingDirs lastObject];
        [pendingDirs removeLastObject];
        NSArray *items = [fm contentsOfDirectoryAtPath:dir error:nil];
        for (NSString *name in items) {
            if ([name hasPrefix:@"."]) continue;
            if (results.count >= maxResults) break;
            NSString *full = [dir stringByAppendingPathComponent:name];
            BOOL isDir = NO;
            if (![fm fileExistsAtPath:full isDirectory:&isDir]) continue;
            if (isDir) {
                if (recursive) [pendingDirs addObject:full];
                continue;
            }
            NSData *data = [fm contentsAtPath:full];
            if (!data) continue;
            NSString *text = [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding];
            if (!text) continue;
            NSArray<NSString *> *lines = [text componentsSeparatedByCharactersInSet:[NSCharacterSet newlineCharacterSet]];
            NSUInteger lineNumber = 1;
            for (NSString *line in lines) {
                if (results.count >= maxResults) break;
                if ([regex numberOfMatchesInString:line options:0 range:NSMakeRange(0, line.length)] > 0) {
                    [results addObject:@{
                        @"path": name,
                        @"lineNumber": @(lineNumber),
                        @"line": line,
                    }];
                }
                lineNumber++;
            }
        }
    }
    completion([self jsonStringFromObject:results], nil);
}

#pragma mark - write_file

- (void)performWriteFile:(NSDictionary *)params completion:(void(^)(NSString *, NSError *))completion {
    NSString *path = [params[@"path"] isKindOfClass:[NSString class]] ? params[@"path"] : nil;
    NSString *content = [params[@"content"] isKindOfClass:[NSString class]] ? params[@"content"] : @"";
    if (path.length == 0) { completion(nil, [self errorWithCode:400 message:@"参数 path 必填"]); return; }
    if (![params[@"content"] isKindOfClass:[NSString class]]) {
        completion(nil, [self errorWithCode:400 message:@"参数 content 必填"]); return;
    }
    NSString *resolved = [[self class] resolveSafely:path];
    if (!resolved) { completion(nil, [self errorWithCode:403 message:@"路径越界或无效"]); return; }

    NSString *parentDir = [resolved stringByDeletingLastPathComponent];
    NSError *dirError = nil;
    [[NSFileManager defaultManager] createDirectoryAtPath:parentDir withIntermediateDirectories:YES attributes:nil error:&dirError];
    if (dirError) { completion(nil, [self errorWithCode:500 message:[NSString stringWithFormat:@"创建目录失败：%@", dirError.localizedDescription]]); return; }

    NSData *data = [content dataUsingEncoding:NSUTF8StringEncoding];
    NSError *writeError = nil;
    BOOL ok = [data writeToURL:[NSURL fileURLWithPath:resolved] options:NSDataWritingAtomic error:&writeError];
    if (!ok) {
        completion(nil, [self errorWithCode:500 message:[NSString stringWithFormat:@"写入失败：%@", writeError.localizedDescription]]);
        return;
    }
    completion([NSString stringWithFormat:@"已写入（%lu 字符）", (unsigned long)content.length], nil);
}

#pragma mark - edit_file

- (void)performEditFile:(NSDictionary *)params completion:(void(^)(NSString *, NSError *))completion {
    NSString *path = [params[@"path"] isKindOfClass:[NSString class]] ? params[@"path"] : nil;
    NSString *oldText = [params[@"oldText"] isKindOfClass:[NSString class]] ? params[@"oldText"] : nil;
    NSString *newText = [params[@"newText"] isKindOfClass:[NSString class]] ? params[@"newText"] : @"";
    if (path.length == 0) { completion(nil, [self errorWithCode:400 message:@"参数 path 必填"]); return; }
    if (oldText.length == 0) { completion(nil, [self errorWithCode:400 message:@"参数 oldText 必填"]); return; }
    if (![params[@"newText"] isKindOfClass:[NSString class]]) { completion(nil, [self errorWithCode:400 message:@"参数 newText 必填"]); return; }
    NSString *resolved = [[self class] resolveSafely:path];
    if (!resolved) { completion(nil, [self errorWithCode:403 message:@"路径越界或无效"]); return; }

    NSError *readError = nil;
    NSString *content = [NSString stringWithContentsOfFile:resolved encoding:NSUTF8StringEncoding error:&readError];
    if (!content) { completion(nil, [self errorWithCode:404 message:@"读取文件失败或无此文件"]); return; }

    // 统计 oldText 出现次数
    NSUInteger occurrences = 0;
    NSRange searchRange = NSMakeRange(0, content.length);
    while (searchRange.location < content.length) {
        NSRange found = [content rangeOfString:oldText options:0 range:searchRange];
        if (found.location == NSNotFound) break;
        occurrences++;
        NSUInteger next = found.location + found.length;
        searchRange.location = next;
        searchRange.length = content.length - next;
    }
    if (occurrences != 1) {
        completion(nil, [self errorWithCode:422 message:[NSString stringWithFormat:@"oldText 不唯一或未找到（出现 %lu 次）", (unsigned long)occurrences]]);
        return;
    }

    NSString *newContent = [content stringByReplacingOccurrencesOfString:oldText withString:newText
                                                                 options:0 range:NSMakeRange(0, content.length)];
    NSData *data = [newContent dataUsingEncoding:NSUTF8StringEncoding];
    NSError *writeError = nil;
    if (![data writeToURL:[NSURL fileURLWithPath:resolved] options:NSDataWritingAtomic error:&writeError]) {
        completion(nil, [self errorWithCode:500 message:[NSString stringWithFormat:@"写回失败：%@", writeError.localizedDescription]]);
        return;
    }
    completion(@"已修改", nil);
}

#pragma mark - delete_file

/// 允许删除的文件扩展名白名单（文本类）
+ (NSSet<NSString *> *)deletableExtensions {
    static NSSet *set = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        set = [NSSet setWithArray:@[@"txt", @"log", @"json", @"properties", @"toml", @"md", @"cfg",
                                     @"yml", @"yaml", @"xml", @"xaml", @"lang", @"ini", @"export",
                                     @"conf", @"gradle", @"fnf", @"more"]];
    });
    return set;
}

- (void)performDeleteFile:(NSDictionary *)params completion:(void(^)(NSString *, NSError *))completion {
    NSString *path = [params[@"path"] isKindOfClass:[NSString class]] ? params[@"path"] : nil;
    if (path.length == 0) { completion(nil, [self errorWithCode:400 message:@"参数 path 必填"]); return; }
    NSString *resolved = [[self class] resolveSafely:path];
    if (!resolved) { completion(nil, [self errorWithCode:403 message:@"路径越界或无效"]); return; }

    NSFileManager *fm = [NSFileManager defaultManager];
    BOOL isDir = NO;
    if (![fm fileExistsAtPath:resolved isDirectory:&isDir]) {
        completion(nil, [self errorWithCode:404 message:@"文件不存在"]); return;
    }
    if (isDir) {
        completion(nil, [self errorWithCode:403 message:@"出于安全考虑仅允许删除文件，不允许删除目录"]); return;
    }
    NSString *ext = [[resolved pathExtension] lowercaseString];
    if (![[[self class] deletableExtensions] containsObject:ext]) {
        completion(nil, [self errorWithCode:403 message:[NSString stringWithFormat:@"出于安全考虑仅允许删除文本类文件（不支持 .%@）", ext]]);
        return;
    }
    NSError *removeError = nil;
    if (![fm removeItemAtPath:resolved error:&removeError]) {
        completion(nil, [self errorWithCode:500 message:[NSString stringWithFormat:@"删除失败：%@", removeError.localizedDescription]]);
        return;
    }
    completion(@"已删除", nil);
}

#pragma mark - 工具

- (NSString *)jsonStringFromObject:(id)object {
    if (![NSJSONSerialization isValidJSONObject:object]) return @"[]";
    NSData *data = [NSJSONSerialization dataWithJSONObject:object options:0 error:nil];
    if (!data) return @"[]";
    return [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding];
}

@end