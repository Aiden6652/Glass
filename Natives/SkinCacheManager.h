#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>

NS_ASSUME_NONNULL_BEGIN

/// 皮肤（头像）本地缓存管理器（单例）。
///
/// 设计目标：
///   - 每次启动 / 每次刷新账户时，先尝试联网从 Mojang（或第三方认证服务器 / 微软 Xbox 头像）
///     拉取最新皮肤，并保存到本地缓存；
///   - 若联网失败（Mojang 服务器不可达 / 断网 / 超时），直接回退使用本地已缓存的皮肤图片，
///     保证头像始终可见，不会掉成占位图；
///   - 仅对有正版（微软）账户执行"存皮肤"流程；本地离线账户没有正版皮肤，直接跳过，
///     继续走原有的第三方头像 URL 逻辑。
///
/// 缓存目录：Documents/skin_cache/
///   <accountId>_meta.json   皮肤元信息（skinURL / model / 更新时间）
///   <accountId>_head.png    已下载的头像图（120x120，用于列表/右栏显示）
///   <accountId>_skin.png    原始皮肤图（64x64 或 64x32，备用）
@interface SkinCacheManager : NSObject

+ (instancetype)sharedManager;

/// 启动时调用：为当前选中账户刷新皮肤并落盘缓存。
/// 会先判断账户是否为正版（微软）账户，非正版直接跳过。
/// 建议在后台队列调用，内部自带网络请求。
+ (void)refreshCurrentAccountSkinIfNeeded;

/// 为指定账户（authData 字典，来自 accounts/<accountId>.json）刷新皮肤缓存。
///
/// @param accountId 账户唯一标识（accountId），用于命名缓存文件
/// @param authData  账户数据字典，内部读取 profileId / accessToken / username / xuid 等字段
/// @param force     YES 时忽略"距上次刷新不足 1 小时"的节流，强制联网刷新
/// @param completion 完成回调（主线程），cached 表示本次是否使用了本地缓存（联网失败）
+ (void)refreshSkinForAccount:(NSString *)accountId
                     authData:(NSDictionary *)authData
                        force:(BOOL)force
                   completion:(void (^ _Nullable)(BOOL success, BOOL usedCache))completion;

/// 读取本地缓存的头像图片，不存在返回 nil。
/// 头像显示处（账户列表 / 右栏）应优先调用此方法，再回退到在线 URL。
+ (nullable UIImage *)cachedHeadImageForAccount:(NSString *)accountId;

/// 读取本地缓存的皮肤元信息（skinURL / model / lastUpdated），不存在返回 nil。
+ (nullable NSDictionary *)cachedMetaForAccount:(NSString *)accountId;

/// 是否已存在该账户的本地皮肤缓存（至少头像图存在）。
+ (BOOL)hasCachedSkinForAccount:(NSString *)accountId;

/// 删除指定账户的皮肤缓存（账户被删除时调用）。
+ (void)removeCacheForAccount:(NSString *)accountId;

@end

NS_ASSUME_NONNULL_END
