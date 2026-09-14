#import "SkinCacheManager.h"
#import "utils.h"
#import "authenticator/BaseAuthenticator.h"

/// 皮肤缓存子目录名（位于 Documents 下）
static NSString * const kSkinCacheDirName = @"skin_cache";
/// 两次联网刷新之间的最小间隔（秒）。1 小时，避免每次切号都打 Mojang 接口。
static const NSTimeInterval kSkinRefreshThrottle = 3600.0;
/// 单个网络请求超时（秒）。移动网络下 12s 足够，失败即回退缓存。
static const NSTimeInterval kSkinRequestTimeout = 12.0;

@implementation SkinCacheManager

+ (instancetype)sharedManager {
    static SkinCacheManager *sharedInstance = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        sharedInstance = [[SkinCacheManager alloc] init];
    });
    return sharedInstance;
}

#pragma mark - 路径

/// 缓存根目录：Documents/skin_cache/（不存在则创建）
- (NSString *)cacheDirectory {
    NSArray *paths = NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES);
    NSString *docs = paths.firstObject;
    NSString *dir = [docs stringByAppendingPathComponent:kSkinCacheDirName];
    if (![[NSFileManager defaultManager] fileExistsAtPath:dir]) {
        [[NSFileManager defaultManager] createDirectoryAtPath:dir
                                  withIntermediateDirectories:YES
                                                   attributes:nil
                                                        error:nil];
    }
    return dir;
}

/// accountId 可能含 '/'、':' 等非法字符（第三方 UUID 一般安全，但仍做防护）
- (NSString *)safeName:(NSString *)accountId {
    if (accountId.length == 0) return @"unknown";
    NSCharacterSet *invalid = [NSCharacterSet characterSetWithCharactersInString:@"/\\:*?\"<>|"];
    NSArray *parts = [accountId componentsSeparatedByCharactersInSet:invalid];
    NSString *cleaned = [parts componentsJoinedByString:@"_"];
    return cleaned.length > 0 ? cleaned : @"unknown";
}

- (NSString *)metaPathForAccount:(NSString *)accountId {
    return [[self cacheDirectory] stringByAppendingPathComponent:
            [NSString stringWithFormat:@"%@_meta.json", [self safeName:accountId]]];
}

- (NSString *)headPathForAccount:(NSString *)accountId {
    return [[self cacheDirectory] stringByAppendingPathComponent:
            [NSString stringWithFormat:@"%@_head.png", [self safeName:accountId]]];
}

- (NSString *)skinPathForAccount:(NSString *)accountId {
    return [[self cacheDirectory] stringByAppendingPathComponent:
            [NSString stringWithFormat:@"%@_skin.png", [self safeName:accountId]]];
}

#pragma mark - 读取缓存

+ (nullable UIImage *)cachedHeadImageForAccount:(NSString *)accountId {
    if (accountId.length == 0) return nil;
    SkinCacheManager *mgr = [SkinCacheManager sharedManager];
    NSString *path = [mgr headPathForAccount:accountId];
    if (![[NSFileManager defaultManager] fileExistsAtPath:path]) return nil;
    UIImage *img = [UIImage imageWithContentsOfFile:path];
    return img;
}

+ (nullable NSDictionary *)cachedMetaForAccount:(NSString *)accountId {
    if (accountId.length == 0) return nil;
    SkinCacheManager *mgr = [SkinCacheManager sharedManager];
    NSString *path = [mgr metaPathForAccount:accountId];
    if (![[NSFileManager defaultManager] fileExistsAtPath:path]) return nil;
    NSMutableDictionary *dict = parseJSONFromFile(path);
    if (dict[@"NSErrorObject"] != nil) return nil;
    return dict;
}

+ (BOOL)hasCachedSkinForAccount:(NSString *)accountId {
    if (accountId.length == 0) return NO;
    SkinCacheManager *mgr = [SkinCacheManager sharedManager];
    return [[NSFileManager defaultManager] fileExistsAtPath:[mgr headPathForAccount:accountId]];
}

+ (void)removeCacheForAccount:(NSString *)accountId {
    if (accountId.length == 0) return;
    SkinCacheManager *mgr = [SkinCacheManager sharedManager];
    NSFileManager *fm = [NSFileManager defaultManager];
    for (NSString *p in @[[mgr headPathForAccount:accountId],
                          [mgr skinPathForAccount:accountId],
                          [mgr metaPathForAccount:accountId]]) {
        if ([fm fileExistsAtPath:p]) {
            [fm removeItemAtPath:p error:nil];
        }
    }
}

#pragma mark - 账户类型判定

/// 是否为正版（微软）账户。
/// 判定依据与 LauncherRightPanelViewController / AccountListViewController 保持一致的约定：
///   - xboxGamertag 存在       → 微软账户
///   - expiresAt > 0 且无 clientToken → 微软账户
///   - 有 clientToken          → 第三方（LittleSkin / 自建 yggdrasil），走 yggdrasil 接口
///   - expiresAt == 0          → 本地离线账户，无正版皮肤，跳过
+ (BOOL)isPremiumMicrosoftAccount:(NSDictionary *)authData {
    if (authData == nil) return NO;
    // 本地离线账户：expiresAt 为 0（BaseAuthenticator loadSavedName 的判定方式）
    if ([authData[@"expiresAt"] longValue] == 0) return NO;
    // 第三方账户：有 clientToken
    if (authData[@"clientToken"] != nil) return NO;
    // 其余归为微软（含 Demo.* 演示账户，其 profileId 为全 0，后续会因拿不到皮肤而回退）
    return YES;
}

/// 是否为第三方（yggdrasil）账户
+ (BOOL)isThirdPartyAccount:(NSDictionary *)authData {
    if (authData == nil) return NO;
    return authData[@"clientToken"] != nil;
}

#pragma mark - 对外入口

+ (void)refreshCurrentAccountSkinIfNeeded {
    // 放到后台队列，避免阻塞启动流程
    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
        BaseAuthenticator *currentAuth = [BaseAuthenticator current];
        if (currentAuth == nil || currentAuth.authData == nil) return;

        NSDictionary *authData = currentAuth.authData;
        NSString *accountId = authData[@"accountId"];
        if (accountId.length == 0) {
            // 旧格式账户兜底：用 username 当 key（此时尚未迁移）
            accountId = authData[@"username"];
        }
        if (accountId.length == 0) return;

        // 本地离线账户：没有正版皮肤，直接跳过（不做任何网络请求、不留缓存）
        if (![self isPremiumMicrosoftAccount:authData] && ![self isThirdPartyAccount:authData]) {
            NSLog(@"[SkinCache] 本地离线账户，跳过皮肤刷新: %@", accountId);
            return;
        }

        [self refreshSkinForAccount:accountId
                           authData:authData
                              force:NO
                         completion:^(BOOL success, BOOL usedCache) {
            if (!success) return;
            // 通知 UI 刷新头像（右栏 updateAccountInfo 会优先读本地缓存）
            dispatch_async(dispatch_get_main_queue(), ^{
                [[NSNotificationCenter defaultCenter] postNotificationName:@"UpdateAccountInfo" object:nil];
            });
        }];
    });
}

+ (void)refreshSkinForAccount:(NSString *)accountId
                     authData:(NSDictionary *)authData
                        force:(BOOL)force
                   completion:(void (^)(BOOL, BOOL))completion {
    if (accountId.length == 0 || authData == nil) {
        if (completion) completion(NO, NO);
        return;
    }

    SkinCacheManager *mgr = [SkinCacheManager sharedManager];

    // 节流：距上次成功刷新不足 1 小时且本地已有缓存，直接返回（force=YES 时跳过节流）
    if (!force && [SkinCacheManager hasCachedSkinForAccount:accountId]) {
        NSDictionary *meta = [SkinCacheManager cachedMetaForAccount:accountId];
        NSTimeInterval last = [meta[@"lastUpdated"] doubleValue];
        if (last > 0 && ([[NSDate date] timeIntervalSince1970] - last) < kSkinRefreshThrottle) {
            if (completion) completion(YES, YES);
            return;
        }
    }

    // 判断走哪条链路
    if ([SkinCacheManager isThirdPartyAccount:authData]) {
        // 第三方账户：走 yggdrasil sessionserver 拿 textures
        [mgr fetchThirdPartySkinForAccount:accountId authData:authData completion:completion];
    } else if ([SkinCacheManager isPremiumMicrosoftAccount:authData]) {
        // 微软正版账户：走 Mojang session server
        [mgr fetchMicrosoftSkinForAccount:accountId authData:authData completion:completion];
    } else {
        // 本地离线账户：跳过，不写缓存
        if (completion) completion(NO, NO);
    }
}

#pragma mark - 微软（正版）链路

- (void)fetchMicrosoftSkinForAccount:(NSString *)accountId
                            authData:(NSDictionary *)authData
                          completion:(void (^)(BOOL, BOOL))completion {
    NSString *accessToken = authData[@"accessToken"];
    NSString *profileId = authData[@"profileId"];

    BOOL isDemo = [authData[@"username"] hasPrefix:@"Demo."] ||
                  [profileId isEqualToString:@"00000000-0000-0000-0000-000000000000"];

    // 无 token / 演示账户 / 无 UUID → 无法从 Mojang 取皮肤，回退本地缓存
    if (isDemo || accessToken.length == 0 || profileId.length == 0 ||
        [accessToken isEqualToString:@"offline"]) {
        NSLog(@"[SkinCache] 正版皮肤不可用（demo/offline/缺字段），回退本地缓存: %@", accountId);
        if (completion) completion([SkinCacheManager hasCachedSkinForAccount:accountId], YES);
        return;
    }

    // Mojang 新版 session server 接口（1.19+）：
    //   GET https://sessionserver.mojang.com/session/minecraft/profile/<uuid>
    //   返回 properties[].value 为 base64 编码的 textures JSON
    NSString *uuid = [profileId stringByReplacingOccurrencesOfString:@"-" withString:@""];
    NSString *urlStr = [NSString stringWithFormat:
                        @"https://sessionserver.mojang.com/session/minecraft/profile/%@", uuid];

    NSLog(@"[SkinCache] 开始联网刷新正版皮肤: %@", accountId);
    NSDictionary *result = [self GETJSON:urlStr token:accessToken];
    if (result == nil) {
        // 联网失败 → 用本地缓存
        NSLog(@"[SkinCache] Mojang 请求失败，回退本地缓存: %@", accountId);
        if (completion) completion([SkinCacheManager hasCachedSkinForAccount:accountId], YES);
        return;
    }

    NSString *skinURL = [self extractSkinURLFromProfileResponse:result];
    if (skinURL.length == 0) {
        NSLog(@"[SkinCache] 响应中未找到 SKIN 纹理，回退本地缓存: %@", accountId);
        if (completion) completion([SkinCacheManager hasCachedSkinForAccount:accountId], YES);
        return;
    }

    [self downloadAndStoreSkin:skinURL accountId:accountId completion:completion];
}

#pragma mark - 第三方（yggdrasil）链路

- (void)fetchThirdPartySkinForAccount:(NSString *)accountId
                             authData:(NSDictionary *)authData
                           completion:(void (^)(BOOL, BOOL))completion {
    NSString *serverURL = authData[@"authserver"] ?: @"https://authserver.ely.by";
    if (![serverURL hasSuffix:@"/"]) {
        serverURL = [serverURL stringByAppendingString:@"/"];
    }
    NSString *profileId = authData[@"profileId"];
    if (profileId.length == 0) {
        if (completion) completion([SkinCacheManager hasCachedSkinForAccount:accountId], YES);
        return;
    }

    // yggdrasil 统一 sessionserver 路径
    NSString *urlStr = [NSString stringWithFormat:
                        @"%@sessionserver/session/minecraft/profile/%@", serverURL, profileId];

    NSLog(@"[SkinCache] 开始联网刷新第三方皮肤: %@", accountId);
    NSDictionary *result = [self GETJSON:urlStr token:nil];
    if (result == nil) {
        NSLog(@"[SkinCache] 第三方 session 请求失败，回退本地缓存: %@", accountId);
        if (completion) completion([SkinCacheManager hasCachedSkinForAccount:accountId], YES);
        return;
    }

    NSString *skinURL = [self extractSkinURLFromProfileResponse:result];
    if (skinURL.length == 0) {
        NSLog(@"[SkinCache] 第三方响应无 SKIN 纹理，回退本地缓存: %@", accountId);
        if (completion) completion([SkinCacheManager hasCachedSkinForAccount:accountId], YES);
        return;
    }

    [self downloadAndStoreSkin:skinURL accountId:accountId completion:completion];
}

#pragma mark - 通用网络/解析

/// 同步 GET 并解析为 JSON 字典；失败返回 nil（含超时/非 200/解析失败）
- (NSDictionary *)GETJSON:(NSString *)urlStr token:(NSString *)token {
    NSURL *url = [NSURL URLWithString:urlStr];
    if (url == nil) return nil;

    NSMutableURLRequest *req = [NSMutableURLRequest requestWithURL:url];
    req.timeoutInterval = kSkinRequestTimeout;
    req.HTTPMethod = @"GET";
    [req setValue:@"application/json" forHTTPHeaderField:@"Accept"];
    if (token.length > 0 && ![token isEqualToString:@"offline"]) {
        [req setValue:[NSString stringWithFormat:@"Bearer %@", token]
   forHTTPHeaderField:@"Authorization"];
    }

    __block NSDictionary *result = nil;
    dispatch_semaphore_t sema = dispatch_semaphore_create(0);

    NSURLSessionDataTask *task =
        [[NSURLSession sharedSession] dataTaskWithRequest:req
                                       completionHandler:^(NSData *data, NSURLResponse *response, NSError *error) {
        if (error == nil && data.length > 0) {
            NSInteger code = [(NSHTTPURLResponse *)response statusCode];
            if (code == 200) {
                id obj = [NSJSONSerialization JSONObjectWithData:data options:kNilOptions error:nil];
                if ([obj isKindOfClass:[NSDictionary class]]) {
                    result = (NSDictionary *)obj;
                }
            }
        }
        dispatch_semaphore_signal(sema);
    }];
    [task resume];
    dispatch_semaphore_wait(sema, dispatch_time(DISPATCH_TIME_NOW,
                                                (int64_t)((kSkinRequestTimeout + 3) * NSEC_PER_SEC)));
    return result;
}

/// 从 profile 响应里取出 SKIN 纹理 URL（base64 value → JSON → textures.SKIN.url）
- (NSString *)extractSkinURLFromProfileResponse:(NSDictionary *)response {
    id properties = response[@"properties"];
    if (![properties isKindOfClass:[NSArray class]]) return nil;

    for (NSDictionary *property in (NSArray *)properties) {
        if (![property isKindOfClass:[NSDictionary class]]) continue;
        if (![property[@"name"] isEqualToString:@"textures"]) continue;

        NSString *base64Value = property[@"value"];
        if (base64Value.length == 0) continue;

        NSData *decoded = [[NSData alloc] initWithBase64EncodedString:base64Value options:0];
        if (decoded == nil) continue;

        NSDictionary *texturesDict = [NSJSONSerialization JSONObjectWithData:decoded options:kNilOptions error:nil];
        NSString *skinURL = texturesDict[@"textures"][@"SKIN"][@"url"];
        if ([skinURL isKindOfClass:[NSString class]] && skinURL.length > 0) {
            return skinURL;
        }
    }
    return nil;
}

/// 下载皮肤原图 → 落盘 → 裁剪出头部图 → 落盘 → 写元信息
- (void)downloadAndStoreSkin:(NSString *)skinURL
                   accountId:(NSString *)accountId
                  completion:(void (^)(BOOL, BOOL))completion {
    NSData *skinData = [NSData dataWithContentsOfURL:[NSURL URLWithString:skinURL]];
    UIImage *skinImage = skinData ? [UIImage imageWithData:skinData] : nil;

    if (skinImage == nil) {
        NSLog(@"[SkinCache] 皮肤图下载失败，回退本地缓存: %@", accountId);
        if (completion) completion([SkinCacheManager hasCachedSkinForAccount:accountId], YES);
        return;
    }

    // 1) 落盘原始皮肤图
    NSString *skinPath = [self skinPathForAccount:accountId];
    [skinData writeToFile:skinPath options:NSDataWritingAtomic error:nil];

    // 2) 裁剪头部并放大到 120x120（与现有 UI 的显示尺寸一致）
    UIImage *headImage = [self headImageFromSkin:skinImage size:CGSizeMake(120, 120)];
    NSData *headData = headImage ? UIImagePNGRepresentation(headImage) : nil;
    if (headData) {
        [headData writeToFile:[self headPathForAccount:accountId]
                      options:NSDataWritingAtomic
                        error:nil];
    }

    // 3) 写元信息
    NSDictionary *meta = @{
        @"accountId": accountId ?: @"",
        @"skinURL": skinURL ?: @"",
        @"model": [self modelFromSkin:skinImage] ?: @"classic",
        @"lastUpdated": @([[NSDate date] timeIntervalSince1970])
    };
    saveJSONToFile(meta, [self metaPathForAccount:accountId]);

    NSLog(@"[SkinCache] 皮肤已更新并缓存: %@", accountId);
    if (completion) completion(YES, NO);
}

/// 从皮肤原图裁剪出头部（8,8 起始 8x8 区域），并缩放到目标尺寸。
/// 兼容 64x64（1.8+ 双层皮肤）与 64x32（旧版）两种尺寸。
- (nullable UIImage *)headImageFromSkin:(UIImage *)skinImage size:(CGSize)size {
    if (skinImage == nil) return nil;
    CGImageRef cg = skinImage.CGImage;
    if (cg == NULL) return nil;

    CGFloat w = CGImageGetWidth(cg);
    CGFloat h = CGImageGetHeight(cg);

    // 皮肤图必须是 64 宽，高为 64 或 32（缩放后仍按比例换算）
    if (w <= 0 || h <= 0) return nil;
    CGFloat unit = w / 64.0;      // 每个皮肤像素对应的实际像素
    CGRect headRect = CGRectMake(8 * unit, 8 * unit, 8 * unit, 8 * unit);

    CGImageRef headCG = CGImageCreateWithImageInRect(cg, headRect);
    if (headCG == NULL) return nil;
    UIImage *head = [UIImage imageWithCGImage:headCG
                                        scale:skinImage.scale
                                  orientation:skinImage.imageOrientation];
    CGImageRelease(headCG);

    // 放大到目标尺寸（最近邻保持像素风锐利）
    UIGraphicsBeginImageContextWithOptions(size, NO, 1.0);
    CGContextRef ctx = UIGraphicsGetCurrentContext();
    CGContextSetInterpolationQuality(ctx, kCGInterpolationNone);
    [head drawInRect:CGRectMake(0, 0, size.width, size.height)];
    UIImage *scaled = UIGraphicsGetImageFromCurrentImageContext();
    UIGraphicsEndImageContext();
    return scaled;
}

/// 判断皮肤模型：slim（Alex 细手臂）还是 classic（Steve）
/// 依据皮肤图 alpha 通道：(54,20) 像素在 slim 皮肤里是透明的，classic 里是不透明的。
- (NSString *)modelFromSkin:(UIImage *)skinImage {
    CGImageRef cg = skinImage.CGImage;
    if (cg == NULL) return @"classic";

    CGFloat w = CGImageGetWidth(cg);
    if (w <= 0) return @"classic";
    CGFloat unit = w / 64.0;

    // 只取 1x1 像素做判断，避免开销
    CGRect pxRect = CGRectMake(54 * unit, 20 * unit, MAX(1.0, unit), MAX(1.0, unit));
    CGImageRef px = CGImageCreateWithImageInRect(cg, pxRect);
    if (px == NULL) return @"classic";

    CFDataRef data = CGDataProviderCopyData(CGImageGetDataProvider(px));
    NSString *model = @"classic";
    if (data != NULL && CFDataGetLength(data) >= 4) {
        const UInt8 *bytes = CFDataGetBytePtr(data);
        // 取 alpha（最后一个字节）
        UInt8 alpha = bytes[CFDataGetLength(data) - 1];
        model = (alpha == 0) ? @"slim" : @"classic";
    }
    if (data != NULL) CFRelease(data);
    CGImageRelease(px);
    return model;
}

@end
