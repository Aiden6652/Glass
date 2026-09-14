//
//  AiFolderAccessTool.m
//  Amethyst
//
//  实现见头文件。要点：
//  - iOS 沙盒下 App 无法直接访问自身容器以外的路径，唯一正途是 UIDocumentPickerViewController
//    （forOpeningContentTypes / forOpeningContentTypes:asCopy:NO）+ startAccessingSecurityScopedResource。
//  - 授权凭证用书签（bookmark）持久化到 NSUserDefaults，跨启动有效。
//    注意：iOS 没有 NSURLBookmarkCreationWithSecurityScope（macOS 专属，iOS SDK 中 unavailable），
//    创建/解析书签时 options 传 0 即可，系统会自动附带 security scope。
//  - 所有 UI 操作派发到主线程；选取器必须从一个可见的 VC present。
//  - 选取器统一用 initWithDocumentTypes:@[@"public.folder"] inMode:UIDocumentPickerModeOpen
//    （不依赖 iOS 14+ 的 UniformTypeIdentifiers 框架，兼容性更好）。
//

#import "AiFolderAccessTool.h"
#import <UIKit/UIKit.h>

/// 书签数组在 NSUserDefaults 中的键（数组元素为 NSData）
static NSString * const kAiAuthorizedFolderBookmarksKey = @"ai.authorized_folder_bookmarks";
static NSString * const kAiToolDomain = @"AiTool";

@interface AiFolderAccessTool () <UIDocumentPickerDelegate>
@property (nonatomic, copy) NSString *internalName;
/// 正在等待选取结果的回调（选取器为异步 UI，需暂存）
@property (nonatomic, copy, nullable) void (^pendingPickCompletion)(NSString * _Nullable result, NSError * _Nullable error);
@end

@implementation AiFolderAccessTool

- (instancetype)initWithName:(NSString *)name {
    self = [super init];
    if (self) {
        _internalName = name ?: @"";
    }
    return self;
}

- (NSString *)name { return self.internalName; }

- (AiToolPermission)permission {
    if ([self.internalName isEqualToString:@"folder_list_authorized"]) {
        return AiToolPermissionReadOnly;
    }
    if ([self.internalName isEqualToString:@"folder_revoke_access"]) {
        return AiToolPermissionControlledWrite;
    }
    // folder_request_access：需要弹出系统 UI 让用户主动选取，标为 ExternalNetwork
    // （Ask/YOLO 直接放行，其它模式询问；选取动作本身天然需要用户参与，安全无虞）
    return AiToolPermissionExternalNetwork;
}

- (NSString *)summary {
    if ([self.internalName isEqualToString:@"folder_request_access"]) {
        return @"请求用户授权一个 App 容器之外的目录，使其可被文件工具读写。"
               "\n参数："
               "\n  - reason（string，可选）：向用户说明为什么需要该目录，会显示在提示中。"
               "\n行为：弹出系统「文件」目录选择器，用户选定后该目录永久加入 AI 可访问列表"
               "（直到用 folder_revoke_access 撤销或用户删除书签）。"
               "\n返回：授权成功返回目录的绝对路径；用户取消返回错误。"
               "\n用法：当用户要求 AI 访问容器外目录（如「我的 iPhone/某个App/xxx」「iCloud 里的东西」）"
               "而现有根目录无法覆盖时调用；不要滥用，一次只请求一个目录。";
    }
    if ([self.internalName isEqualToString:@"folder_list_authorized"]) {
        return @"列出所有已由用户授权的容器外目录。"
               "\n参数：无。"
               "\n返回 JSON 数组，每项含 path（当前绝对路径）、name（目录名）、valid（书签是否仍然有效）。"
               "\n注意：容器内路径无需授权即已可访问，本工具只反映容器外的额外授权。";
    }
    if ([self.internalName isEqualToString:@"folder_revoke_access"]) {
        return @"撤销某个已授权的容器外目录，撤销后文件工具将无法再访问其内容。"
               "\n参数："
               "\n  - path（string，必填）：要撤销的目录路径（可用 folder_list_authorized 查询）。"
               "\n返回：「已撤销 <path>」或错误。";
    }
    return @"容器外目录授权工具";
}

#pragma mark - 书签存储

/// 读取全部书签数据（NSData 数组）
+ (NSArray<NSData *> *)bookmarkDataList {
    NSArray *raw = [[NSUserDefaults standardUserDefaults] arrayForKey:kAiAuthorizedFolderBookmarksKey];
    if (![raw isKindOfClass:[NSArray class]]) return @[];
    NSMutableArray<NSData *> *out = [NSMutableArray array];
    for (id item in raw) {
        if ([item isKindOfClass:[NSData class]]) [out addObject:(NSData *)item];
    }
    return out;
}

+ (void)setBookmarkDataList:(NSArray<NSData *> *)list {
    [[NSUserDefaults standardUserDefaults] setObject:(list ?: @[]) forKey:kAiAuthorizedFolderBookmarksKey];
    [[NSUserDefaults standardUserDefaults] synchronize];
}

/// 解析书签 →（url, stale）
/// 注意：iOS 上 NSURLBookmarkResolutionWithSecurityScope 被标记为 macOS 专属（在 iOS SDK 中
/// 显式 unavailable），但创建书签时传 0、解析时传 0 即可正常工作——系统会自动附带
/// security scope（iOS 的 UIDocumentPicker 返回的 URL 本身就是 security-scoped）。
/// 这是 Apple 文档与头文件长期不一致的一处坑，实测 iOS 14~17 均可用。
+ (nullable NSURL *)resolveBookmark:(NSData *)data isStale:(BOOL *)isStale {
    if (data.length == 0) return nil;
    BOOL stale = NO;
    NSURL *url = [NSURL URLByResolvingBookmarkData:data
                                           options:0
                                     relativeToURL:nil
                               bookmarkDataIsStale:&stale
                                             error:nil];
    if (isStale) *isStale = stale;
    return url;
}

/// 迁移陈旧书签（系统移动目录后会标记 stale，重新生成）
+ (void)refreshStaleBookmarks {
    NSArray<NSData *> *list = [self bookmarkDataList];
    NSMutableArray<NSData *> *rebuilt = [NSMutableArray array];
    BOOL changed = NO;
    for (NSData *data in list) {
        BOOL stale = NO;
        NSURL *url = [self resolveBookmark:data isStale:&stale];
        if (!url) { changed = YES; continue; } // 失效丢弃
        if (stale) {
            NSData *fresh = [self bookmarkDataForURL:url];
            if (fresh) { [rebuilt addObject:fresh]; changed = YES; continue; }
        }
        [rebuilt addObject:data];
    }
    if (changed) [self setBookmarkDataList:rebuilt];
}

/// 生成书签数据。iOS 无 security-scope 选项（macOS 专属，iOS SDK 中 unavailable），
/// 传 0 即可：前提是调用前已经 startAccessingSecurityScopedResource 成功。
+ (nullable NSData *)bookmarkDataForURL:(NSURL *)url {
    if (!url) return nil;
    return [url bookmarkDataWithOptions:0
         includingResourceValuesForKeys:nil
                          relativeToURL:nil
                                  error:nil];
}

+ (NSArray<NSString *> *)authorizedRootPaths {
    [self refreshStaleBookmarks];
    NSMutableArray<NSString *> *paths = [NSMutableArray array];
    for (NSData *data in [self bookmarkDataList]) {
        NSURL *url = [self resolveBookmark:data isStale:NULL];
        if (!url) continue;
        // startAccessingSecurityScopedResource 自 iOS 8 起可用，直接调用
        BOOL accessed = [url startAccessingSecurityScopedResource];
        (void)accessed;
        NSString *path = url.path;
        if (path.length > 0) {
            const char *c = [path UTF8String];
            char *real = c ? realpath(c, NULL) : NULL;
            if (real) {
                [paths addObject:@(real)];
                free(real);
            } else {
                [paths addObject:path.stringByStandardizingPath];
            }
        }
        // 注意：这里不能 stop，因为 AiFileTools 需要持续访问；授权资源在 App 生命周期内保持。
        (void)accessed;
    }
    return paths;
}

#pragma mark - 执行分发

- (void)execute:(NSDictionary<NSString *, id> *)params
     completion:(void (^)(NSString * _Nullable, NSError * _Nullable))completion {
    if (!completion) return;
    if ([self.internalName isEqualToString:@"folder_request_access"]) {
        [self performRequestAccess:params completion:completion];
        return;
    }
    if ([self.internalName isEqualToString:@"folder_list_authorized"]) {
        [self performListAuthorized:params completion:completion];
        return;
    }
    if ([self.internalName isEqualToString:@"folder_revoke_access"]) {
        [self performRevokeAccess:params completion:completion];
        return;
    }
    completion(nil, [self errorWithCode:404 message:[NSString stringWithFormat:@"未知工具 %@", self.internalName]]);
}

- (NSError *)errorWithCode:(NSInteger)code message:(NSString *)message {
    return [NSError errorWithDomain:kAiToolDomain code:code
                           userInfo:@{NSLocalizedDescriptionKey: message}];
}

#pragma mark - folder_request_access

- (void)performRequestAccess:(NSDictionary *)params
                  completion:(void (^)(NSString * _Nullable, NSError * _Nullable))completion {
    // 防止重入：已有等待中的选取
    if (self.pendingPickCompletion) {
        completion(nil, [self errorWithCode:409 message:@"已有一次目录授权请求正在进行，请先完成或取消"]);
        return;
    }
    self.pendingPickCompletion = completion;

    dispatch_async(dispatch_get_main_queue(), ^{
        UIViewController *presentingVC = [AiFolderAccessTool topmostPresentableViewController];
        if (!presentingVC) {
            [self finishPendingWithResult:nil error:[self errorWithCode:-1 message:@"当前没有可用界面，无法弹出目录选择器"]];
            return;
        }

        UIDocumentPickerViewController *picker = nil;
        // 不依赖 UniformTypeIdentifiers（iOS 14+ 才有的框架），
        // 统一用旧版 NSString 类型标识 "public.folder"（UTI），任何 iOS 版本都有效。
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
        picker = [[UIDocumentPickerViewController alloc] initWithDocumentTypes:@[@"public.folder"]
                                                                       inMode:UIDocumentPickerModeOpen];
#pragma clang diagnostic pop
        picker.delegate = self;
        picker.allowsMultipleSelection = NO;
        picker.modalPresentationStyle = UIModalPresentationFormSheet;

        id reason = params[@"reason"];
        if ([reason isKindOfClass:[NSString class]] && [(NSString *)reason length] > 0) {
            // UIDocumentPickerViewController 无可设置的标题属性，仅记录日志便于排查
            NSLog(@"[AiFolderAccessTool] 目录授权原因：%@", reason);
        }

        [presentingVC presentViewController:picker animated:YES completion:nil];
    });
}

- (void)finishPendingWithResult:(NSString *)result error:(NSError *)error {
    void (^cb)(NSString *, NSError *) = self.pendingPickCompletion;
    self.pendingPickCompletion = nil;
    if (cb) cb(result, error);
}

#pragma mark - UIDocumentPickerDelegate

- (void)documentPicker:(UIDocumentPickerViewController *)controller
 didPickDocumentsAtURLs:(NSArray<NSURL *> *)urls {
    NSURL *url = urls.firstObject;
    if (!url) {
        [self finishPendingWithResult:nil error:[self errorWithCode:-1 message:@"未选择任何目录"]];
        return;
    }

    BOOL accessed = [url startAccessingSecurityScopedResource];

    NSData *bookmark = [AiFolderAccessTool bookmarkDataForURL:url];
    if (!bookmark) {
        if (accessed) [url stopAccessingSecurityScopedResource];
        [self finishPendingWithResult:nil error:[self errorWithCode:-1 message:@"无法为该目录生成授权凭证，请重试或换一个目录"]];
        return;
    }

    // 去重后写入
    NSMutableArray<NSData *> *list = [[AiFolderAccessTool bookmarkDataList] mutableCopy];
    NSString *newPath = url.path.stringByStandardizingPath;
    BOOL existed = NO;
    for (NSData *existing in [list copy]) {
        NSURL *u = [AiFolderAccessTool resolveBookmark:existing isStale:NULL];
        if (u && [u.path.stringByStandardizingPath isEqualToString:newPath]) { existed = YES; break; }
    }
    if (!existed) [list addObject:bookmark];
    [AiFolderAccessTool setBookmarkDataList:list];

    // 保持安全作用域访问开启（AiFileTools 后续读取需要）；授权资源在 App 生命周期内保持。
    (void)accessed;

    NSString *p = url.path;
    const char *c = p ? [p UTF8String] : NULL;
    char *real = c ? realpath(c, NULL) : NULL;
    NSString *finalPath = real ? @(real) : p;
    if (real) free(real);

    NSString *result = [NSString stringWithFormat:@"已授权目录：%@%@",
                        finalPath ?: @"(未知路径)",
                        existed ? @"（此前已授权，已刷新书签）" : @""];
    [self finishPendingWithResult:result error:nil];
}

- (void)documentPickerWasCancelled:(UIDocumentPickerViewController *)controller {
    [self finishPendingWithResult:nil error:[self errorWithCode:-1 message:@"用户取消了目录授权"]];
}

#pragma mark - folder_list_authorized

- (void)performListAuthorized:(NSDictionary *)params
                   completion:(void (^)(NSString * _Nullable, NSError * _Nullable))completion {
    [AiFolderAccessTool refreshStaleBookmarks];
    NSMutableArray *out = [NSMutableArray array];
    for (NSData *data in [AiFolderAccessTool bookmarkDataList]) {
        BOOL stale = NO;
        NSURL *url = [AiFolderAccessTool resolveBookmark:data isStale:&stale];
        if (!url) continue;
        NSString *p = url.path ?: @"";
        const char *c = p.length ? [p UTF8String] : NULL;
        char *real = c ? realpath(c, NULL) : NULL;
        NSString *finalPath = real ? @(real) : p;
        if (real) free(real);
        [out addObject:@{
            @"path": finalPath ?: @"",
            @"name": url.lastPathComponent ?: @"",
            @"valid": @(!stale),
        }];
    }
    NSData *json = [NSJSONSerialization dataWithJSONObject:out options:NSJSONWritingPrettyPrinted error:nil];
    completion(json ? [[NSString alloc] initWithData:json encoding:NSUTF8StringEncoding] : @"[]", nil);
}

#pragma mark - folder_revoke_access

- (void)performRevokeAccess:(NSDictionary *)params
                 completion:(void (^)(NSString * _Nullable, NSError * _Nullable))completion {
    NSString *target = [params[@"path"] isKindOfClass:[NSString class]] ? params[@"path"] : nil;
    if (target.length == 0) {
        completion(nil, [self errorWithCode:400 message:@"folder_revoke_access 缺少必填参数 path"]);
        return;
    }
    NSString *targetStd = target.stringByStandardizingPath;

    NSMutableArray<NSData *> *kept = [NSMutableArray array];
    BOOL removed = NO;
    for (NSData *data in [AiFolderAccessTool bookmarkDataList]) {
        NSURL *url = [AiFolderAccessTool resolveBookmark:data isStale:NULL];
        NSString *p = url.path.stringByStandardizingPath;
        if (p && ([p isEqualToString:targetStd] || [p hasSuffix:targetStd])) {
            removed = YES;
            continue;
        }
        [kept addObject:data];
    }
    if (!removed) {
        completion(nil, [self errorWithCode:404 message:[NSString stringWithFormat:@"未找到已授权目录：%@", target]]);
        return;
    }
    [AiFolderAccessTool setBookmarkDataList:kept];
    completion([NSString stringWithFormat:@"已撤销 %@", target], nil);
}

#pragma mark - 顶层 VC

+ (UIViewController * _Nullable)topmostPresentableViewController {
    UIWindow *keyWindow = nil;
    if (@available(iOS 13.0, *)) {
        for (UIWindowScene *scene in [UIApplication sharedApplication].connectedScenes) {
            if (scene.activationState == UISceneActivationStateForegroundActive) {
                keyWindow = scene.windows.firstObject;
                break;
            }
        }
    }
    if (!keyWindow) keyWindow = [[UIApplication sharedApplication] windows].firstObject;
    if (!keyWindow) keyWindow = [UIApplication sharedApplication].keyWindow;
    UIViewController *top = keyWindow.rootViewController;
    while (top.presentedViewController) top = top.presentedViewController;
    return top;
}

@end
