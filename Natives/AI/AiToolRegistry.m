//
//  AiToolRegistry.m
//  Amethyst
//

#import "AiToolRegistry.h"
#import "AiToolBootstrapper.h"

@interface AiToolRegistry ()
@property (nonatomic, strong) NSMutableDictionary<NSString *, id<AiTool>> *tools;
@end

@implementation AiToolRegistry

+ (instancetype)sharedRegistry {
    static AiToolRegistry *instance = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        instance = [[AiToolRegistry alloc] init];
    });
    return instance;
}

- (instancetype)init {
    self = [super init];
    if (self) {
        _tools = [NSMutableDictionary dictionary];
        // 关键修复（AI 不知道自己能用工具）：此前 [AiToolBootstrapper registerBuiltinTools]
        // 从未被任何地方调用，工具列表始终为空，openAIToolSchemas 返回空数组，
        // 模型收不到任何工具定义，表现为 AI 完全不知道能调用工具。这里在单例 init 时自动注册。
        [AiToolBootstrapper registerBuiltinToolsIntoRegistry:self];

        // 启动自检：把注册结果落盘到 Documents/AI/ai_tools_dump.txt，
        // 用于定位「源码里有、运行时却没有」的工具缺失问题。
        [self dumpToolRegistrationDiagnostics];
    }
    return self;
}

#pragma mark - 注册自检

/// 把已注册工具清单 + 各阶段到场情况 + 3e 工具类链接探测写入 Documents/AI/ai_tools_dump.txt
- (void)dumpToolRegistrationDiagnostics {
    NSMutableString *out = [NSMutableString string];
    NSArray<NSString *> *names = [self.tools.allKeys sortedArrayUsingSelector:@selector(compare:)];

    [out appendFormat:@"=== AiToolRegistry 自检 %@ ===\n", [NSDate date]];
    [out appendFormat:@"已注册工具数：%lu\n", (unsigned long)names.count];
    [out appendString:@"\n--- 工具名列表（名称 / 权限）---\n"];
    for (NSString *n in names) {
        id<AiTool> t = self.tools[n];
        [out appendFormat:@"  %@  (permission=%ld)\n", n, (long)t.permission];
    }

    // 分阶段到场检查
    NSDictionary<NSString *, NSArray<NSString *> *> *stages = @{
        @"3a 基础": @[@"list_instances", @"list_game_versions", @"read_latest_log",
                      @"read_crash_report", @"match_known_errors", @"list_files",
                      @"read_file", @"grep_files", @"write_file", @"edit_file",
                      @"delete_file", @"ask"],
        @"3b 资源": @[@"search_mods", @"search_resourcepacks", @"search_shaders",
                      @"search_datapacks", @"search_modpacks", @"search_worlds",
                      @"install_mod", @"install_resourcepack", @"install_shader",
                      @"install_datapack", @"install_game_version", @"install_loader"],
        @"enhance": @[@"read_logs", @"check_downloads", @"list_settings", @"get_setting",
                      @"set_setting", @"todo_create", @"todo_list", @"todo_update",
                      @"todo_delete", @"sleep", @"create_instance"],
        @"3c 联网": @[@"fetch_url"],
        @"3d 推送": @[@"github_set_token", @"github_push"],
        @"3e 目录": @[@"list_roots", @"folder_request_access", @"folder_list_authorized",
                      @"folder_revoke_access"],
        @"3e 源码": @[@"github_tree", @"github_read_files", @"github_search_code"],
    };
    [out appendString:@"\n--- 分阶段到场检查 ---\n"];
    for (NSString *stage in @[@"3a 基础", @"3b 资源", @"enhance", @"3c 联网", @"3d 推送", @"3e 目录", @"3e 源码"]) {
        NSArray *expect = stages[stage];
        NSMutableArray *missing = [NSMutableArray array];
        for (NSString *n in expect) {
            if (self.tools[n] == nil) [missing addObject:n];
        }
        if (missing.count == 0) {
            [out appendFormat:@"  [OK]   %@（%lu 个全部在场）\n", stage, (unsigned long)expect.count];
        } else {
            [out appendFormat:@"  [缺失] %@ → 缺 %@\n", stage, [missing componentsJoinedByString:@", "]];
        }
    }

    // 类存在性探测：确认 3e 相关类是否真的被链接进二进制
    [out appendString:@"\n--- 工具类链接探测（NSClassFromString）---\n"];
    NSArray<NSString *> *classes = @[@"AiFileTools", @"AiFolderAccessTool", @"AiGitHubTreeTool",
                                     @"AiGitHubTool", @"AiWebFetchTool", @"AiInstancesTool",
                                     @"AiAssetSearchTool", @"AiAssetInstallTool"];
    for (NSString *cn in classes) {
        Class c = NSClassFromString(cn);
        [out appendFormat:@"  %-24s %@\n", cn.UTF8String, c ? @"存在" : @"不存在"];
    }

    // 关键构建信息
    [out appendString:@"\n--- 构建信息 ---\n"];
    NSDictionary *info = NSBundle.mainBundle.infoDictionary;
    [out appendFormat:@"  CFBundleIdentifier: %@\n", info[@"CFBundleIdentifier"] ?: @"?"];
    [out appendFormat:@"  CFBundleShortVersionString: %@\n", info[@"CFBundleShortVersionString"] ?: @"?"];
    [out appendFormat:@"  CFBundleExecutable: %@\n", info[@"CFBundleExecutable"] ?: @"?"];

    // 落盘
    NSString *docs = NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES).firstObject;
    NSString *aiDir = [docs stringByAppendingPathComponent:@"AI"];
    [[NSFileManager defaultManager] createDirectoryAtPath:aiDir
                              withIntermediateDirectories:YES
                                               attributes:nil
                                                    error:nil];
    NSString *path = [aiDir stringByAppendingPathComponent:@"ai_tools_dump.txt"];
    [out writeToFile:path atomically:YES encoding:NSUTF8StringEncoding error:nil];

    NSLog(@"[AiToolRegistry] 工具自检完成：共 %lu 个 → %@", (unsigned long)names.count, path);
    NSLog(@"[AiToolRegistry] 工具清单：%@", [names componentsJoinedByString:@", "]);
}

#pragma mark - 文本工具清单（prompt 驱动回退方案）

/// 生成给模型看的纯文本工具清单（名称 + 完整说明）。
/// 用于「模型不支持原生 tool_calls」或「工具 schema 未送达」时，
/// 改由 system prompt 告知能力，模型以文本形式发起调用。
- (NSString *)textToolCatalog {
    NSArray<NSString *> *names = [self.tools.allKeys sortedArrayUsingSelector:@selector(compare:)];
    NSMutableString *out = [NSMutableString string];
    for (NSString *name in names) {
        id<AiTool> tool = self.tools[name];
        NSString *summary = tool.summary ?: @"";
        [out appendFormat:@"### %@\n%@\n\n", name, summary];
    }
    return out;
}

/// 已注册工具名列表（升序）
- (NSArray<NSString *> *)allToolNames {
    return [self.tools.allKeys sortedArrayUsingSelector:@selector(compare:)];
}

- (void)registerTool:(id<AiTool>)tool {
    if (!tool || tool.name.length == 0) return;
    self.tools[tool.name] = tool;
}

- (id<AiTool> _Nullable)toolForName:(NSString *)name {
    if (name.length == 0) return nil;
    return self.tools[name];
}

/// OpenAI 风格 schema：description 直接用 summary；parameters 用宽松 object 描述，
/// 让模型可自由传参（宁可宽松，参数说明已写入 summary）。
- (NSArray<NSDictionary *> *)openAIToolSchemas {
    NSMutableArray<NSDictionary *> *schemas = [NSMutableArray array];
    NSArray<NSString *> *sortedNames = [self.tools.allKeys sortedArrayUsingSelector:@selector(compare:)];
    for (NSString *name in sortedNames) {
        id<AiTool> tool = self.tools[name];
        [schemas addObject:@{
            @"type": @"function",
            @"function": @{
                @"name": tool.name,
                @"description": tool.summary ?: @"",
                @"parameters": @{
                    @"type": @"object",
                    @"properties": @{},
                    @"required": @[],
                },
            },
        }];
    }
    return schemas;
}

#pragma mark - 参数规范化

/// 把一个键规范化成小写 camelCase（例如 "game-version"→"gameVersion"、"InstanceName"→"instanceName"）。
- (NSString *)normalizedKeyCamel:(NSString *)key {
    if (key.length == 0) return key;

    NSUInteger length = key.length;
    // 记录每个"词"的起始下标（词与词之间由分隔符或大小写驼峰边界隔开）
    NSMutableIndexSet *wordStarts = [NSMutableIndexSet indexSet];
    [wordStarts addIndex:0];
    for (NSUInteger i = 1; i < length; i++) {
        unichar c = [key characterAtIndex:i];
        if (c == '_' || c == '-' || c == '.' || c == ' ' || c == '/') {
            continue; // 分隔符本身不成为词头
        }
        unichar prev = [key characterAtIndex:i - 1];
        BOOL prevIsSep = (prev == '_' || prev == '-' || prev == '.' || prev == ' ' || prev == '/');
        BOOL prevIsLower = (prev >= 'a' && prev <= 'z') || (prev >= '0' && prev <= '9');
        BOOL isUpper = (c >= 'A' && c <= 'Z');
        if (prevIsSep) {
            [wordStarts addIndex:i];
        } else if (isUpper && prevIsLower) {
            // 驼峰边界：小写/数字后紧跟大写（兼顾 PascalCase 与 camelCase）
            [wordStarts addIndex:i];
        }
    }

    NSMutableString *result = [NSMutableString string];
    NSMutableString *currentWord = [NSMutableString string];
    __block BOOL isFirstWord = YES;

    void (^flush)(void) = ^{
        if (currentWord.length == 0) return;
        if (isFirstWord) {
            // 首词整体保持小写
            [result appendString:currentWord];
            isFirstWord = NO;
        } else {
            // 后续词首字母大写、其余小写
            NSString *word = currentWord;
            NSString *capitalized = [word stringByReplacingCharactersInRange:NSMakeRange(0, 1)
                                                                  withString:[[word substringToIndex:1] uppercaseString]];
            [result appendString:capitalized];
        }
        [currentWord setString:@""];
    };

    for (NSUInteger i = 0; i < length; i++) {
        unichar c = [key characterAtIndex:i];
        if (c == '_' || c == '-' || c == '.' || c == ' ' || c == '/') {
            flush();
            continue;
        }
        if (i > 0 && [wordStarts containsIndex:i]) {
            flush();
        }
        // 统一转小写
        unichar lower = (c >= 'A' && c <= 'Z') ? (unichar)(c - 'A' + 'a') : c;
        [currentWord appendString:[NSString stringWithFormat:@"%C", lower]];
    }
    flush();
    return result;
}

/// 判断 value 是否"为空"（丢弃的键包括 nil、NSNull、空字符串）
- (BOOL)isEmptyValue:(id)value {
    if (value == nil || [value isKindOfClass:[NSNull class]]) return YES;
    if ([value isKindOfClass:[NSString class]]) {
        return [(NSString *)value length] == 0;
    }
    return NO;
}

- (NSDictionary * _Nonnull)normalizedParams:(NSDictionary * _Nonnull)params {
    if (![params isKindOfClass:[NSDictionary class]]) return @{};
    NSMutableDictionary *normalized = [NSMutableDictionary dictionary];
    [params enumerateKeysAndObjectsUsingBlock:^(id rawKey, id value, BOOL *stop) {
        NSString *key = [rawKey isKindOfClass:[NSString class]] ? (NSString *)rawKey : [rawKey description];
        NSString *camelKey = [self normalizedKeyCamel:key];
        if (camelKey.length == 0) return;
        if ([self isEmptyValue:value]) return; // 丢弃 value 为空 的键
        normalized[camelKey] = value;
    }];
    return normalized;
}

#pragma mark - 执行

- (void)executeToolNamed:(NSString *)name
                  params:(NSDictionary *)params
              completion:(void (^)(NSString * _Nullable result, NSError * _Nullable error))completion {
    id<AiTool> tool = [self toolForName:name];
    if (!tool) {
        if (completion) {
            dispatch_async(dispatch_get_main_queue(), ^{
                // 未知工具时把当前可用工具名一并返回，便于模型自我纠正
                NSArray *avail = [self allToolNames];
                NSString *hint = [NSString stringWithFormat:@"未知工具 %@。当前可用工具（%lu 个）：%@",
                                  name ?: @"", (unsigned long)avail.count,
                                  [avail componentsJoinedByString:@", "]];
                NSError *err = [NSError errorWithDomain:@"AiTool" code:404
                                               userInfo:@{NSLocalizedDescriptionKey: hint}];
                completion(nil, err);
            });
        }
        return;
    }

    // 先规范化参数再透传给工具 execute
    NSDictionary *normalized = [self normalizedParams:params];
    [tool execute:normalized completion:^(NSString * _Nullable result, NSError * _Nullable error) {
        // 统一把结果回调到主线程
        dispatch_async(dispatch_get_main_queue(), ^{
            if (completion) {
                completion(result, error);
            }
        });
    }];
}

@end