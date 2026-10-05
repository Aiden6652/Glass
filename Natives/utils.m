#import <SafariServices/SafariServices.h>

#include "jni.h"
#include <dlfcn.h>
#include <mach/mach.h>
#include <math.h>
#include <os/lock.h>
#include <stdio.h>
#include <stdlib.h>
#include <unistd.h>
#include <dirent.h>
#include <string.h>
#include <setjmp.h>
#include <signal.h>
#include <sys/sysctl.h>

#include "utils.h"

CFTypeRef SecTaskCopyValueForEntitlement(void* task, NSString* entitlement, CFErrorRef  _Nullable *error);
void* SecTaskCreateFromSelf(CFAllocatorRef allocator);

BOOL getEntitlementValue(NSString *key) {
    void *secTask = SecTaskCreateFromSelf(NULL);
    CFTypeRef value = SecTaskCopyValueForEntitlement(SecTaskCreateFromSelf(NULL), key, nil);
    CFRelease(secTask);
    if (value == nil) {
        return NO;
    }
    CFRelease(value);
    return ![(__bridge id)value isKindOfClass:NSNumber.class] || [(__bridge id)value boolValue];
}

BOOL isJITEnabled(BOOL checkCSFlags) {
    if (!checkCSFlags && (getEntitlementValue(@"dynamic-codesigning") || isJailbroken)) {
        return YES;
    }

    int flags;
    csops(getpid(), 0, &flags, sizeof(flags));
    return (flags & CS_DEBUGGED) != 0;
}

void openLink(UIViewController* sender, NSURL* link) {
    if (NSClassFromString(@"SFSafariViewController") == nil) {
        NSData *data = [link.absoluteString dataUsingEncoding:NSUTF8StringEncoding];
        CIFilter *filter = [CIFilter filterWithName:@"CIQRCodeGenerator"];
        [filter setValue:data forKey:@"inputMessage"];
        UIImage *image = [UIImage imageWithCIImage:filter.outputImage scale:1.0 orientation:UIImageOrientationUp];
        UIGraphicsBeginImageContextWithOptions(CGSizeMake(300, 300), NO, 0.0);
        CGRect frame = CGRectMake(0, 0, 300, 300);
        [image drawInRect:frame];
        UIImageView *imageView = [[UIImageView alloc] initWithFrame:frame];
        imageView.image = UIGraphicsGetImageFromCurrentImageContext();
        UIGraphicsEndImageContext();

        UIAlertController* alert = [UIAlertController alertControllerWithTitle:nil
            message:link.absoluteString
            preferredStyle:UIAlertControllerStyleAlert];

        UIViewController *vc = UIViewController.new;
        vc.view = imageView;
        [alert setValue:vc forKey:@"contentViewController"];

        UIAlertAction* doneAction = [UIAlertAction actionWithTitle:localize(@"Done", nil) style:UIAlertActionStyleCancel handler:nil];
        [alert addAction:doneAction];
        [sender presentViewController:alert animated:YES completion:nil];
    } else {
        SFSafariViewController *vc = [[SFSafariViewController alloc] initWithURL:link];
        [sender presentViewController:vc animated:YES completion:nil];
    }
}

NSMutableDictionary* parseJSONFromFile(NSString *path) {
    NSError *error;

    NSString *content = [NSString stringWithContentsOfFile:path encoding:NSUTF8StringEncoding error:&error];
    if (content == nil) {
        NSLog(@"[ParseJSON] Error: could not read %@: %@", path, error.localizedDescription);
        return @{@"NSErrorObject": error}.mutableCopy;
    }

    NSData* data = [content dataUsingEncoding:NSUTF8StringEncoding];
    NSMutableDictionary *dict = [NSJSONSerialization JSONObjectWithData:data options:NSJSONReadingMutableContainers error:&error];
    if (error) {
        NSLog(@"[ParseJSON] Error: could not parse JSON: %@", error.localizedDescription);
        return @{@"NSErrorObject": error}.mutableCopy;
    }
    return dict;
}

NSError* saveJSONToFile(NSDictionary *dict, NSString *path) {
    // TODO: handle rename
    NSError *error;
    NSData *jsonData = [NSJSONSerialization dataWithJSONObject:dict options:NSJSONWritingPrettyPrinted error:&error];
    if (jsonData == nil) {
        return error;
    }
    BOOL success = [jsonData writeToFile:path options:NSDataWritingAtomic error:&error];
    if (!success) {
        return error;
    }
    return nil;
}

// ★ [I18N] 启动器界面语言覆盖：持久化键。
// 刻意与系统的 AppleLanguages 分开——那是全局键，会牵动 App 内所有 bundle 的语言
// 选择，也不适合作为「跟随系统 / 指定语言」这种应用内偏好的保存位置。
NSString * const AmeLauncherLanguageDefaultsKey = @"ame_launcher_language";

#pragma mark - ★ [I18N] 语言解析核心（单一事实源）

// ★ [I18N] 语言解析缓存：'生效语言' 结果缓存 + 代数号（写入覆盖时自增使其失效）。
static NSInteger sAmeLanguageGeneration = 0;
static NSInteger sAmeEffectiveCodeGeneration = -1;
static NSString *sAmeEffectiveCodeCache = nil;
// 已加载的 <code>.lproj 包缓存（NSNull 表示"查过、没有"）。
static NSMutableDictionary<NSString *, id> *sAmeLangBundleCache = nil;
static NSString *sAmeResolvedLanguageCode = nil;
static NSBundle *sAmeResolvedLanguageBundle = nil;

// ★ [I18N] 启动器真正支持的语言（curated 白名单）。
// 依据：对 Natives/resources/*.lproj/Localizable.strings 的键集合盘点（见
// D:\CTF\_I18N_FIX.md「覆盖度表」）：只有 zh-Hans / zh-Hant / zh-CN / en / ja / km
// 这 6 个的翻译覆盖率 ≥95%；其余 48 个（de/ar/fr/ru…）覆盖率 ≤12%（上游 Pojav
// 遗留的旧键集合），选它们等于大面积回退英文 ⇒ 是"选了没用的壳子"，一律不列。
// zh-CN 与 zh-Hans 同为简体且被变体映射到 zh-Hans，不单独作为一项。
NSArray<NSString *> *AmeLauncherSupportedLanguageCodes(void) {
    static NSArray<NSString *> *codes;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        codes = @[@"zh-Hans", @"zh-Hant", @"en", @"ja", @"km"];
    });
    return codes;
}

// ★ [I18N] 系统语言代码 → 我们实际使用的 .lproj 代码（含变体映射）。
// 处理 zh-Hans-CN / zh-Hant-TW / en-GB / ja-JP / km-KH 这类带脚本或地区后缀的代码，
// 以及 iOS 常见的"裸语言"（zh / en / ja）。匹配不到返回 nil（调用方回退 en）。
NSString *AmeLauncherMatchLanguageCode(NSString *systemCode) {
    if (systemCode.length == 0) return nil;

    NSArray<NSString *> *supported = AmeLauncherSupportedLanguageCodes();
    NSString *lower = systemCode.lowercaseString;
    NSArray<NSString *> *parts = [lower componentsSeparatedByString:@"-"];
    NSString *lang = parts.count ? parts.firstObject : lower;
    NSString *script = nil;   // 4 字母脚本子标签：hans / hant / latn…
    NSString *region = nil;   // 2 字母或 3 位数字地区：cn / tw / us…
    for (NSUInteger i = 1; i < parts.count; i++) {
        NSString *p = parts[i];
        if (p.length == 0) continue;
        BOOL hasDigit = [p rangeOfCharacterFromSet:[NSCharacterSet decimalDigitCharacterSet]].location != NSNotFound;
        if (p.length == 4 && !hasDigit) {
            script = p;
        } else if ((p.length == 2 && !hasDigit) || p.length == 3) {
            region = p;
        }
    }

    // 1) 精确命中我们的代码（zh-Hans / zh-Hant / en / ja / km，大小写不敏感）
    for (NSString *code in supported) {
        if ([code.lowercaseString isEqualToString:lower]) return code;
    }
    // 2) 中文：按脚本 / 地区判定简繁，其余一律简体
    if ([lang isEqualToString:@"zh"]) {
        if ([script isEqualToString:@"hant"]) return @"zh-Hant";
        if ([script isEqualToString:@"hans"]) return @"zh-Hans";
        static NSSet *tradRegions;
        static dispatch_once_t onceTrad;
        dispatch_once(&onceTrad, ^{
            tradRegions = [NSSet setWithArray:@[@"tw", @"hk", @"mo"]];
        });
        if (region && [tradRegions containsObject:region]) return @"zh-Hant";
        return @"zh-Hans";   // zh / zh-CN / zh-SG / zh-MY …
    }
    // 3) 其它语言：语言码直接对应（en-US→en, ja-JP→ja, km-KH→km, …）
    for (NSString *code in supported) {
        if ([code.lowercaseString isEqualToString:lang]) return code;
    }
    // 4) 兜底：交给 Apple 的匹配器在"我们支持的语言"里挑（处理未覆盖的变体）
    NSArray<NSString *> *best = [NSBundle preferredLocalizationsFromArray:supported
                                                          forPreferences:@[systemCode]];
    if (best.count > 0 && [supported containsObject:best.firstObject]) {
        return best.firstObject;
    }
    return nil;
}

// ★ [I18N] 当前"实际生效"的界面语言代码。
// 语义：用户明确选择的语言 → 系统偏好语言最佳匹配 → 开发语言 en。
// 设置页显示与实际渲染都用它 ⇒ 显示与内容永远一致，不再"系统是英文却显示中文"。
NSString *AmeLauncherEffectiveLanguageCode(void) {
    if (sAmeEffectiveCodeCache.length > 0 && sAmeEffectiveCodeGeneration == sAmeLanguageGeneration) {
        return sAmeEffectiveCodeCache;
    }
    NSString *result = nil;
    NSString *override = AmeLauncherPreferredLanguageOverride();
    if (override.length > 0) {
        result = override;
    } else {
        for (NSString *pref in [NSLocale preferredLanguages]) {
            NSString *m = AmeLauncherMatchLanguageCode(pref);
            if (m.length > 0) { result = m; break; }
        }
    }
    if (result.length == 0) result = @"en";
    sAmeEffectiveCodeCache = result;
    sAmeEffectiveCodeGeneration = sAmeLanguageGeneration;
    return result;
}

// ★ [I18N] 读取用户选择；空串 / nil / 已不支持的旧值一律视为「跟随系统」。
// "已不支持"（旧版可能存过 de/ar 等空壳语言）会被当作未选择并顺手清理，
// 避免出现"切了却大面积英文"的破碎界面（幂等迁移）。
NSString *AmeLauncherPreferredLanguageOverride(void) {
    NSString *code = [[NSUserDefaults standardUserDefaults] stringForKey:AmeLauncherLanguageDefaultsKey];
    if (code.length == 0) return nil;
    if (![AmeLauncherSupportedLanguageCodes() containsObject:code]) {
        [[NSUserDefaults standardUserDefaults] removeObjectForKey:AmeLauncherLanguageDefaultsKey];
        return nil;
    }
    return code;
}

// ★ [I18N] 写入/清除覆盖。code 为 nil 或空串时清除（回到跟随系统）。
void AmeLauncherSetPreferredLanguageOverride(NSString *code) {
    NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];
    if (code.length > 0) {
        [defaults setObject:code forKey:AmeLauncherLanguageDefaultsKey];
    } else {
        [defaults removeObjectForKey:AmeLauncherLanguageDefaultsKey];
    }
    [defaults synchronize];
    sAmeLanguageGeneration++;   // ★ [I18N] 使缓存的"生效语言"失效，下次 localize 重新解析
}

// ★ [I18N] 语言代码 → 人读显示名（用系统当前语言本地化）。取不到时回退返回代码本身。
// 例：系统中文时 zh-Hans → 「简体中文」；系统英文时 → 「Chinese, Simplified」。
NSString *AmeLauncherDisplayNameForLanguageCode(NSString *code) {
    if (code.length == 0) return @"";
    NSString *name = [[NSLocale currentLocale] localizedStringForLanguageCode:code];
    return name.length > 0 ? name : code;
}

// ★ [I18N] 语言选单要列出的语言（= 真正支持的白名单，按显示名排序）。
// 保留旧函数名以兼容调用方；语义从"枚举包内所有 .lproj"收窄为白名单：
// 只列 AmeLauncherSupportedLanguageCodes()，绝不把空壳语言摆进选单。
NSArray<NSString *> *AmeLauncherAvailableLanguageCodes(void) {
    NSArray<NSString *> *codes = AmeLauncherSupportedLanguageCodes();
    return [codes sortedArrayUsingComparator:^NSComparisonResult(NSString *a, NSString *b) {
        return [AmeLauncherDisplayNameForLanguageCode(a) localizedCaseInsensitiveCompare:
                AmeLauncherDisplayNameForLanguageCode(b)];
    }];
}

#pragma mark - ★ [I18N] 翻译覆盖率（选单标"部分翻译"用）

// ★ [I18N] 解析 <code>.lproj/Localizable.strings 为 键→值（仅用于覆盖率统计；
// 运行时取词仍走 bundle）。解析失败返回 nil ⇒ 上层按 100% 处理，统计绝不砸界面。
static NSDictionary<NSString *, NSString *> *AmeLauncherParseStrings(NSString *code) {
    if (code.length == 0) return nil;
    NSString *dir = [code stringByAppendingPathExtension:@"lproj"];
    NSString *path = [[[NSBundle mainBundle].resourcePath stringByAppendingPathComponent:dir]
                      stringByAppendingPathComponent:@"Localizable.strings"];
    NSString *text = [NSString stringWithContentsOfFile:path encoding:NSUTF8StringEncoding error:NULL];
    if (text.length == 0) return nil;
    NSMutableDictionary<NSString *, NSString *> *map = [NSMutableDictionary dictionary];
    for (NSString *raw in [text componentsSeparatedByString:@"\n"]) {
        NSString *line = [raw stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]];
        if (![line hasPrefix:@"\""]) continue;   // 跳过注释与空行
        NSRange kOpen = [line rangeOfString:@"\""];
        if (kOpen.location == NSNotFound) continue;
        NSRange kClose = [line rangeOfString:@"\"" options:0
                                       range:NSMakeRange(kOpen.location + 1, line.length - kOpen.location - 1)];
        if (kClose.location == NSNotFound) continue;
        NSString *key = [line substringWithRange:NSMakeRange(kOpen.location + 1, kClose.location - kOpen.location - 1)];
        NSRange eq = [line rangeOfString:@"=" options:0 range:NSMakeRange(kClose.location, line.length - kClose.location)];
        if (eq.location == NSNotFound) continue;
        NSRange vOpen = [line rangeOfString:@"\"" options:0 range:NSMakeRange(eq.location, line.length - eq.location)];
        if (vOpen.location == NSNotFound) continue;
        NSRange vClose = [line rangeOfString:@"\"" options:NSBackwardsSearch
                                       range:NSMakeRange(vOpen.location + 1, line.length - vOpen.location - 1)];
        if (vClose.location == NSNotFound) continue;
        NSString *val = [line substringWithRange:NSMakeRange(vOpen.location + 1, vClose.location - vOpen.location - 1)];
        if (key.length > 0) map[key] = val;
    }
    return map.count ? map : nil;
}

// ★ [I18N-ORDER] 某语言的"人工翻译率"（0.0~1.0）。以【英文】为基准键集：
// 值存在且与英文逐字不同 ⇒ 计为已翻译。
// ✗ 旧版以 zh-Hans 为基准、并对所有 zh* 直接返回 1.0；而 zh-Hans.lproj 当时是"英文占位
//   文件"，于是这个基准本身是错的，且永远报 100%，把"渲染成英文"的缺陷整个掩盖掉。
double AmeLauncherLanguageTranslatedRatio(NSString *code) {
    if (code.length == 0) return 1.0;
    if ([code isEqualToString:@"en"]) return 1.0;   // 英文即基准
    static NSDictionary<NSString *, NSString *> *en;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        en = AmeLauncherParseStrings(@"en");
    });
    NSDictionary<NSString *, NSString *> *tgt = AmeLauncherParseStrings(code);
    if (en.count == 0 || tgt.count == 0) return 1.0;   // 统计失败：不标百分比
    NSUInteger total = 0, localized = 0;
    for (NSString *k in en) {
        NSString *tv = tgt[k];
        if (tv.length == 0) continue;                    // 缺键 = 未翻译
        total++;
        if ([tv isEqualToString:en[k]]) continue;        // 与英文逐字相同 = 占位/未译
        localized++;
    }
    if (total == 0) return 1.0;
    return (double)localized / (double)total;
}

// ★ [I18N] 取词：在指定 <code>.lproj> 包里查 key；命中失败返回 nil。
static NSString *AmeLocalizedValue(NSBundle *bundle, NSString *key) {
    if (bundle == nil || key.length == 0) return nil;
    NSString *value = [bundle localizedStringForKey:key value:nil table:nil];
    if (value.length > 0 && ![value isEqualToString:key]) return value;
    return nil;
}

// ★ [I18N] <code>.lproj 包查询（带缓存）；找不到返回 nil。
static NSBundle *AmeBundleForLanguageCode(NSString *code) {
    if (code.length == 0) return nil;
    if (sAmeLangBundleCache == nil) sAmeLangBundleCache = [NSMutableDictionary dictionary];
    id cached = sAmeLangBundleCache[code];
    if (cached == (id)[NSNull null]) return nil;
    if ([cached isKindOfClass:[NSBundle class]]) return cached;
    NSString *path = [[NSBundle mainBundle] pathForResource:code ofType:@"lproj"];
    NSBundle *bundle = path.length ? [NSBundle bundleWithPath:path] : nil;
    sAmeLangBundleCache[code] = bundle ?: (id)[NSNull null];
    return bundle;
}

// ★ [I18N-ORDER] 启动最早期(任何 UI 构建之前)调用一次:解析并缓存"生效语言"、预热
// <code>.lproj 包缓存,并打印【自证日志】——生效语言 / 实际使用的 .lproj / 该语言的
// 真实翻译覆盖率 / Bundle.main 首选本地化 / 系统首选语言。
// 目的:让"设置显示中文、界面却渲染英文"这类【显示与渲染分叉】在日志里一眼可见
// (根因即:生效语言=zh-Hans,而 zh-Hans.lproj 曾是英文占位文件)。
void AmeLauncherPrimeLanguage(void) {
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        NSString *code = AmeLauncherEffectiveLanguageCode();   // 解析 + 缓存(单一事实源)
        NSBundle *bundle = AmeBundleForLanguageCode(code);     // 预热 bundle 缓存
        BOOL hasOverride = (AmeLauncherPreferredLanguageOverride().length > 0);
        double coverage = AmeLauncherLanguageTranslatedRatio(code);
        NSLog(@"[i18n][I18N-ORDER] effective=%@ followSystem=%@ bundle=%@ coverage=%.2f bundlePref=%@ systemPref=%@",
              code,
              hasOverride ? @"NO" : @"YES",
              bundle.bundlePath ?: @"(nil)",
              coverage,
              [[NSBundle mainBundle] preferredLocalizations].firstObject ?: @"(nil)",
              [NSLocale preferredLanguages].firstObject ?: @"(nil)");
        if (bundle == nil) {
            NSLog(@"[i18n][I18N-ORDER] ★ 警告:生效语言 %@ 没有对应 .lproj ⇒ 界面会整体回退英文", code);
        }
    });
}

// ★ [I18N] 统一取词入口（全启动器 2093 处调用都经此）。
// 单一事实源 = AmeLauncherEffectiveLanguageCode()（用户选择 → 系统最佳匹配 → en）：
// 不再依赖 NSLocalizedString 的"系统 bundle 解析"，因此改语言后只要重跑一次文案
// 就真的换过来；设置页显示的语言与这里实际渲染的语言永远一致。
// 回退链：当前语言 → en → 系统 UIKit 内建（"OK"/"Cancel" 等）→ key 本身。
NSString* localize(NSString* key, NSString* comment) {
    if (key.length == 0) return key ?: @"";
    NSString *code = AmeLauncherEffectiveLanguageCode();
    if (![code isEqualToString:sAmeResolvedLanguageCode] || sAmeResolvedLanguageBundle == nil) {
        sAmeResolvedLanguageCode = code;
        sAmeResolvedLanguageBundle = AmeBundleForLanguageCode(code);
    }
    NSString *value = AmeLocalizedValue(sAmeResolvedLanguageBundle, key);
    if (value) return value;
    if (![code isEqualToString:@"en"]) {
        value = AmeLocalizedValue(AmeBundleForLanguageCode(@"en"), key);
        if (value) return value;
    }
    value = AmeLocalizedValue([NSBundle bundleWithIdentifier:@"com.apple.UIKit"], key);
    if (value) return value;
    return key;
}

// 该错误是否意味着设备根本连不上网。值得穷举：原来只认
// NSURLErrorDataNotAllowed（应用被关蜂窝数据这一种窄形态），而最常见的离线
// 形态——飞行模式、无 Wi-Fi——是 NSURLErrorNotConnectedToInternet。
BOOL isConnectivityError(NSError *error) {
    if (![error.domain isEqualToString:NSURLErrorDomain]) return NO;
    switch (error.code) {
        case NSURLErrorNotConnectedToInternet:   // 飞行模式、无 Wi-Fi、无信号
        case NSURLErrorDataNotAllowed:           // 应用被关蜂窝数据
        case NSURLErrorNetworkConnectionLost:    // 请求中途掉线
        case NSURLErrorCannotConnectToHost:
        case NSURLErrorCannotFindHost:
        case NSURLErrorDNSLookupFailed:          // captive portal 与坏 DNS
        case NSURLErrorTimedOut:
        case NSURLErrorInternationalRoamingOff:
        case NSURLErrorCallIsActive:
        case NSURLErrorResourceUnavailable:
            return YES;
        default:
            return NO;
    }
}

void customNSLog(const char *file, int lineNumber, const char *functionName, NSString *format, ...)
{
    va_list ap; 
    va_start (ap, format);
    NSString *body = [[NSString alloc] initWithFormat:format arguments:ap];
    printf("%s", [body UTF8String]);
    if (![format hasSuffix:@"\n"]) {
        printf("\n");
    }
    va_end (ap);
}

CGFloat MathUtils_dist(CGFloat x1, CGFloat y1, CGFloat x2, CGFloat y2) {
    const CGFloat x = (x2 - x1);
    const CGFloat y = (y2 - y1);
    return (CGFloat) hypot(x, y);
}

//Ported from https://www.arduino.cc/reference/en/language/functions/math/map/
CGFloat MathUtils_map(CGFloat x, CGFloat in_min, CGFloat in_max, CGFloat out_min, CGFloat out_max) {
    return (x - in_min) * (out_max - out_min) / (in_max - in_min) + out_min;
}

CGFloat dpToPx(CGFloat dp) {
    CGFloat screenScale = [[UIScreen mainScreen] scale];
    return dp * screenScale;
}

CGFloat pxToDp(CGFloat px) {
    CGFloat screenScale = [[UIScreen mainScreen] scale];
    return px / screenScale;
}

void setButtonPointerInteraction(UIButton *button) {
    button.pointerInteractionEnabled = YES;
    button.pointerStyleProvider = ^ UIPointerStyle* (UIButton* button, UIPointerEffect* proposedEffect, UIPointerShape* proposedShape) {
        UITargetedPreview *preview = [[UITargetedPreview alloc] initWithView:button];
        return [NSClassFromString(@"UIPointerStyle") styleWithEffect:[NSClassFromString(@"UIPointerHighlightEffect") effectWithPreview:preview] shape:proposedShape];
    };
}

__attribute__((noinline,optnone,naked))
void* JIT26CreateRegionLegacy(size_t len) {
    asm("brk #0x69 \n"
        "ret");
}
// ★ [POCKETJ-JIT] Universal JIT 协议第 0 号调用:显式请求调试器脱离。
//   参考:EricoEC/PocketJLauncher · Vendor/StikJIT/Resources/universal.js(commands[0])
//   与 Vendor/StikJIT/INTEGRATION.md「Implement the universal protocol」给出的签名:
//     void JIT26Detach(void) { mov x16, #0; brk #0xf00d; ret }
//   x16=0 ⇒ universal.js 的 JIT26Detach() ⇒ 向 debugserver 发 "D" 并结束脚本循环。
//   ⚠ 调用时机(INTEGRATION.md 强制):必须先对【所有】初始 RX 区完成
//     JIT26PrepareRegion、建好可写别名,再调本函数;脚本一旦脱离,后加入的 RX 区
//     就无法再被服务。本仓库现有启动流程靠 universal.js 的 detachAfterFirstBr
//     在 dyld 补丁阶段的 JIT26PrepareRegion / JIT26PrepareRegionForPatching 之后
//     隐式脱离,故这里只补齐协议原语,不在启动路径上另加调用点 —— 擅自提前脱离会让
//     后续 brk 落在"无人服务"的窗口里,从而整体降级(★ [JIT-NOCRASH] 起,各调用
//     点已走 Safe 包装,不再硬崩,但 JIT 功能会因此退化)。详见
//     Natives/pocketj_jit/PORTING_NOTES.md。
__attribute__((noinline,optnone,naked))
void JIT26Detach(void) {
    asm("mov x16, #0 \n"
        "brk #0xf00d \n"
        "ret");
}
__attribute__((noinline,optnone,naked))
void* JIT26PrepareRegion(void *addr, size_t len) {
    asm("mov x16, #1 \n"
        "brk #0xf00d \n"
        "ret");
}
__attribute__((noinline,optnone,naked))
void BreakSendJITScript(char* script, size_t len) {
   asm("mov x16, #2 \n"
       "brk #0xf00d \n"
       "ret");
}
__attribute__((noinline,optnone,naked))
void JIT26SetDetachAfterFirstBr(BOOL value) {
   asm("mov x16, #3 \n"
       "brk #0xf00d \n"
       "ret");
}
__attribute__((noinline,optnone,naked))
void JIT26PrepareRegionForPatching(void *addr, size_t size) {
   asm("mov x16, #4 \n"
       "brk #0xf00d \n"
       "ret");
}
void JIT26SendJITScript(NSString* script) {
    NSCAssert(script, @"Script must not be nil");
    BreakSendJITScript((char*)script.UTF8String, script.length);
}

// ★ [JIT-NOCRASH] ============================================================
// JIT26 brk 协议的统一 SIGTRAP 安全网
//
// universal 协议的每一步都靠 `brk` 与调试器握手（legacy 建区为 brk #0x69；其余
// 全部为 brk #0xf00d）。**调试器未就岗时执行 brk ⇒ SIGTRAP ⇒ 进程直接死**，
// 连"优雅放弃"的机会都没有（议题 #133「开启 JIT 后闪退」）。这里在调用窗口内
// 布一层 SIGTRAP handler + sigsetjmp/siglongjmp：无人应答时把"必死崩溃"转成
// "函数返回失败/降级"，由调用方跳过该步；调试器在岗时 brk 由调试器例外端口/
// ptrace 现场服务（Mach 例外优先于信号转换），本 handler 根本不会触发，成功
// 路径与裸调用逐字节一致 —— 安全网只在"无人应答"时兜底，不干扰正常 JIT。
//
// 嵌套/可重入（硬约束 5）：裸协议函数全是叶子（naked asm，只 brk+ret，不再调用
// 别人），单次窗口不会自嵌套；但调用方可能嵌套（外层窗口未退出时又走进另一个
// [JIT-NOCRASH] 包装）。旧的单缓冲 g_jit26TrapEnv 一旦被内层 sigsetjmp 覆盖，
// 外层的 siglongjmp 目标即失效 —— 故这里改成【按深度索引的 sigjmp_buf 槽位
// 栈】：第 0 层复用 g_jit26TrapEnv（保留旧名），更深层用 g_jit26TrapNestEnv[]；
// handler 永远跳到最内层活动窗口，最内层在跳回后把 depth 回退到自己的槽位，
// 外层窗口继续存活。g_jit26TrapArmed 保留为"是否有窗口在等 brk 应答"的兼容标志。
// ============================================================================
#define JIT26_TRAP_MAX_DEPTH 8

static sigjmp_buf g_jit26TrapEnv;                            // 第 0 层窗口缓冲（复用旧名）
static sigjmp_buf g_jit26TrapNestEnv[JIT26_TRAP_MAX_DEPTH];  // 更深层窗口槽位
static volatile sig_atomic_t g_jit26TrapDepth = 0;           // 活动窗口层数（0=未布网）
static volatile sig_atomic_t g_jit26TrapArmed = 0;           // 兼容标志：>0 即有窗口在等 brk

// 取 depth 对应的窗口缓冲。返回值恒非 NULL（depth 已被 push/pop 约束在 [0,MAX)）。
static sigjmp_buf *JIT26TrapSlotForDepth(int depth) {
    if (depth <= 0) return &g_jit26TrapEnv;
    if (depth < JIT26_TRAP_MAX_DEPTH) return &g_jit26TrapNestEnv[depth];
    return &g_jit26TrapNestEnv[JIT26_TRAP_MAX_DEPTH - 1];
}

static void JIT26TrapCatch(int sig) {
    if (!g_jit26TrapArmed || g_jit26TrapDepth <= 0) {
        // 不属于本安全网的 SIGTRAP：恢复默认语义原样致死，不吞异常
        signal(sig, SIG_DFL);
        raise(sig);
        return;
    }
    // 跳到最内层活动窗口；depth 与 sigaction 由该窗口自己回退。
    sigjmp_buf *env = JIT26TrapSlotForDepth((int)g_jit26TrapDepth - 1);
    siglongjmp(*env, 1);
}

// 进入窗口：安装 handler、登记本层槽位。返回本层索引；<0 = 深度超限无法布网，
// 调用方【必须】据此直接降级，绝不能再调用裸 brk 函数。
static int JIT26TrapWindowPush(struct sigaction *oldsa, sigjmp_buf **outEnv) {
    struct sigaction sa;
    memset(&sa, 0, sizeof(sa));
    sa.sa_handler = JIT26TrapCatch;
    sigemptyset(&sa.sa_mask);
    sa.sa_flags = SA_NODEFER;
    if (oldsa) memset(oldsa, 0, sizeof(*oldsa));   // sigaction 万一失败也不回装垃圾
    sigaction(SIGTRAP, &sa, oldsa);

    int idx = (int)g_jit26TrapDepth;
    if (idx < 0 || idx >= JIT26_TRAP_MAX_DEPTH) {
        sigaction(SIGTRAP, oldsa, NULL);   // 回滚，保持环境原样
        if (outEnv) *outEnv = NULL;
        return -1;
    }
    if (outEnv) *outEnv = JIT26TrapSlotForDepth(idx);
    g_jit26TrapDepth = idx + 1;
    g_jit26TrapArmed = 1;
    return idx;
}

// 退出窗口：把 depth 回退到本层（处理"从 handler 跳回时更内层已被解开"的情形），
// 恢复原 SIGTRAP 处置。idx<0（未曾布网成功）时不动 depth。
static void JIT26TrapWindowPop(int idx, struct sigaction *oldsa) {
    if (idx >= 0 && g_jit26TrapDepth > idx) {
        g_jit26TrapDepth = idx;
    }
    if (g_jit26TrapDepth <= 0) {
        g_jit26TrapArmed = 0;
    }
    sigaction(SIGTRAP, oldsa, NULL);
}

// 布网失败（深度超限）时的统一降级日志。
static void JIT26LogWindowOverflow(const char *op) {
    NSLog(@"[JIT26] [JIT-NOCRASH] %s: trap-window depth overflow (%d) -- skipping raw brk (degrade)",
          op, (int)JIT26_TRAP_MAX_DEPTH);
}

// ★ [SHADER-SIGBUS] ============================================================
// 已 PrepareRegion 的 JIT 区登记表（纯旁路：只记录，不改变任何行为）。
//
// 为什么需要：SIGBUS 那一类崩溃的归属判定卡在"地址落在匿名 JIT 区"还是
// "落在真实 dylib 镜像"上（上一轮只有 `pc − region_base == dylib 偏移` 这一
// 条算式，两种解释都成立）。这张表让崩溃取证能直接标注每一帧的类别。
// 容量 32 已远超实际（启动期 PrepareRegion 调用不超过十余次）；满了就丢弃
// 最早的记录并计数，绝不分配内存（崩溃路径只读，写入点也在 JIT 握手路径上）。
// ============================================================================
#define JIT26_REGION_MAX 32
static struct { void *addr; size_t len; } g_jit26PreparedRegions[JIT26_REGION_MAX];
static volatile sig_atomic_t g_jit26PreparedCount = 0;   // 已登记条数（<= MAX）
static volatile sig_atomic_t g_jit26PreparedDropped = 0; // 溢出丢弃计数

void JIT26RecordPreparedRegion(void *addr, size_t len) {
    if (addr == NULL || len == 0) return;
    int n = (int)g_jit26PreparedCount;
    if (n < 0) n = 0;
    if (n >= JIT26_REGION_MAX) {
        g_jit26PreparedDropped = (sig_atomic_t)(g_jit26PreparedDropped + 1);
        return;
    }
    g_jit26PreparedRegions[n].addr = addr;
    g_jit26PreparedRegions[n].len  = len;
    g_jit26PreparedCount = (sig_atomic_t)(n + 1);
}

BOOL JIT26AddressInPreparedRegion(const void *p) {
    uintptr_t a = (uintptr_t)p;
    int n = (int)g_jit26PreparedCount;
    if (n > JIT26_REGION_MAX) n = JIT26_REGION_MAX;
    for (int i = 0; i < n; i++) {
        uintptr_t base = (uintptr_t)g_jit26PreparedRegions[i].addr;
        uintptr_t end  = base + g_jit26PreparedRegions[i].len;
        if (a >= base && a < end) return YES;
    }
    return NO;
}

// brk #0x69（legacy 建区）安全网：无人应答返回 NULL；调试器在岗返回裸函数值。
void* JIT26CreateRegionLegacySafe(size_t len) {
    struct sigaction oldsa;
    sigjmp_buf *env = NULL;
    int idx = JIT26TrapWindowPush(&oldsa, &env);
    if (idx < 0) {
        JIT26LogWindowOverflow("JIT26CreateRegionLegacySafe");
        return NULL;
    }
    void *result = NULL;
    if (sigsetjmp(*env, 1) == 0) {
        result = JIT26CreateRegionLegacy(len);
    } else {
        NSLog(@"[JIT26] [JIT-NOCRASH] brk #0x69 NOT serviced (no debugger) -- degraded, returning NULL");
        result = NULL;
    }
    JIT26TrapWindowPop(idx, &oldsa);
    return result;
}

// ★ [POCKETJ-JIT] brk #0xf00d cmd=0（显式请求调试器脱离）安全网：与
//   JIT26CreateRegionLegacySafe 同款。调试器已脱离时 brk 无人应答，捕获后返回
//   NO 而不使进程致死；调试器在岗时 brk 由调试器例外端口服务，行为与裸函数一致。
BOOL JIT26DetachSafe(void) {
    struct sigaction oldsa;
    sigjmp_buf *env = NULL;
    int idx = JIT26TrapWindowPush(&oldsa, &env);
    if (idx < 0) {
        JIT26LogWindowOverflow("JIT26DetachSafe");
        return NO;
    }
    BOOL serviced = YES;
    if (sigsetjmp(*env, 1) == 0) {
        JIT26Detach();
    } else {
        NSLog(@"[JIT26] [JIT-NOCRASH] brk #0xf00d(cmd=0 detach) NOT serviced -- degraded");
        serviced = NO;
    }
    JIT26TrapWindowPop(idx, &oldsa);
    return serviced;
}

// ★ [JIT-NOCRASH] brk #0xf00d cmd=1（准备可写别名）安全网。裸函数返回值无调用方
//   使用，这里只报"是否被调试器服务"；降级返回 NO。
BOOL JIT26PrepareRegionSafe(void *addr, size_t len) {
    struct sigaction oldsa;
    sigjmp_buf *env = NULL;
    int idx = JIT26TrapWindowPush(&oldsa, &env);
    if (idx < 0) {
        JIT26LogWindowOverflow("JIT26PrepareRegionSafe");
        return NO;
    }
    BOOL serviced = YES;
    if (sigsetjmp(*env, 1) == 0) {
        (void)JIT26PrepareRegion(addr, len);
        // ★ [SHADER-SIGBUS] 登记本区（只记录），供崩溃取证区分"匿名 JIT 区"与"真实 dylib"。
        JIT26RecordPreparedRegion(addr, len);
        NSDebugLog(@"[JIT26] [JIT-NOCRASH] PrepareRegion serviced (addr=%p len=%lu)", addr, (unsigned long)len);
    } else {
        NSLog(@"[JIT26] [JIT-NOCRASH] brk #0xf00d(cmd=1 PrepareRegion) NOT serviced -- degraded");
        serviced = NO;
    }
    JIT26TrapWindowPop(idx, &oldsa);
    return serviced;
}

// ★ [JIT-NOCRASH] brk #0xf00d cmd=4（小区域、保留内容）安全网；降级返回 NO。
BOOL JIT26PrepareRegionForPatchingSafe(void *addr, size_t len) {
    struct sigaction oldsa;
    sigjmp_buf *env = NULL;
    int idx = JIT26TrapWindowPush(&oldsa, &env);
    if (idx < 0) {
        JIT26LogWindowOverflow("JIT26PrepareRegionForPatchingSafe");
        return NO;
    }
    BOOL serviced = YES;
    if (sigsetjmp(*env, 1) == 0) {
        JIT26PrepareRegionForPatching(addr, len);
        // ★ [SHADER-SIGBUS] 同 PrepareRegionSafe：登记本区供崩溃取证。
        JIT26RecordPreparedRegion(addr, len);
        NSDebugLog(@"[JIT26] [JIT-NOCRASH] PrepareRegionForPatching serviced (addr=%p len=%lu)", addr, (unsigned long)len);
    } else {
        NSLog(@"[JIT26] [JIT-NOCRASH] brk #0xf00d(cmd=4 PrepareRegionForPatching) NOT serviced -- degraded");
        serviced = NO;
    }
    JIT26TrapWindowPop(idx, &oldsa);
    return serviced;
}

// ★ [JIT-NOCRASH] brk #0xf00d cmd=2（下发 UniversalJIT26 script）安全网；降级返回 NO。
BOOL JIT26SendJITScriptSafe(NSString *script) {
    if (script == nil) {
        NSLog(@"[JIT26] [JIT-NOCRASH] SendJITScript skipped: script is nil");
        return NO;
    }
    struct sigaction oldsa;
    sigjmp_buf *env = NULL;
    int idx = JIT26TrapWindowPush(&oldsa, &env);
    if (idx < 0) {
        JIT26LogWindowOverflow("JIT26SendJITScriptSafe");
        return NO;
    }
    BOOL serviced = YES;
    if (sigsetjmp(*env, 1) == 0) {
        JIT26SendJITScript(script);
        NSDebugLog(@"[JIT26] [JIT-NOCRASH] SendJITScript serviced");
    } else {
        NSLog(@"[JIT26] [JIT-NOCRASH] brk #0xf00d(cmd=2 SendJITScript) NOT serviced -- degraded");
        serviced = NO;
    }
    JIT26TrapWindowPop(idx, &oldsa);
    return serviced;
}

// ★ [JIT-NOCRASH] brk #0xf00d cmd=3（首次 brk 后是否自动脱离）安全网；降级返回 NO。
BOOL JIT26SetDetachAfterFirstBrSafe(BOOL value) {
    struct sigaction oldsa;
    sigjmp_buf *env = NULL;
    int idx = JIT26TrapWindowPush(&oldsa, &env);
    if (idx < 0) {
        JIT26LogWindowOverflow("JIT26SetDetachAfterFirstBrSafe");
        return NO;
    }
    BOOL serviced = YES;
    if (sigsetjmp(*env, 1) == 0) {
        JIT26SetDetachAfterFirstBr(value);
        NSDebugLog(@"[JIT26] [JIT-NOCRASH] SetDetachAfterFirstBr(%d) serviced", (int)value);
    } else {
        NSLog(@"[JIT26] [JIT-NOCRASH] brk #0xf00d(cmd=3 SetDetachAfterFirstBr) NOT serviced -- degraded");
        serviced = NO;
    }
    JIT26TrapWindowPop(idx, &oldsa);
    return serviced;
}

// ============================================================================
// ★ [POCKETJ-JIT] PocketJ 内置 JIT 前置门禁
//   (EricoEC/PocketJLauncher · Vendor/StikJIT/INTEGRATION.md
//    「Built-in StikJIT: Gate every entry point」)
//
//   内置 StikJIT 需要同时满足:iOS ≥ 17.4 · 宿主进程 get-task-allow ·
//   可读配对文件。注意 get-task-allow 属于宿主进程,必须在宿主侧检查。
//
//   ⚠ 本仓库暂未接入 Helper 扩展(进程不能自附加调试器 —— 见 PocketJ
//     Natives/stikdebug/StikDebugEngine.m 顶部同款注释),因此这里【只检测、
//     只记日志/供 UI 展示】,不做任何 vAttach 动作。等 Helper 扩展落地后,
//     这三个门禁就是启动 Helper 前的 guard。
// ============================================================================

BOOL AMEJITDeviceSupportsBuiltInStikJIT(void) {
    if (@available(iOS 17.4, *)) {
        return YES;
    }
    return NO;
}

// 宿主进程是否带 get-task-allow。使用 Security 框架 SPI(SecTask*),
// 原型见本文件顶部的 extern 声明;与 INTEGRATION.md 的 ObjC 示例同构,
// 但按文档写法释放正确(不复用本文件既有 getEntitlementValue —— 它有一处
// 释放后使用)。
BOOL AMEJITHasGetTaskAllow(void) {
    void *task = SecTaskCreateFromSelf(NULL);
    if (task == NULL) {
        return NO;
    }
    CFTypeRef value = SecTaskCopyValueForEntitlement(task, @"get-task-allow", NULL);
    BOOL result = (value == kCFBooleanTrue);
    if (value != NULL) {
        CFRelease(value);
    }
    CFRelease(task);
    return result;
}

// 配对文件推荐位置(INTEGRATION.md「Store and import the pairing file」):
//   Documents/StikJIT/pairingFile.plist
// Info.plist 已置 UIFileSharingEnabled=true,用户可经 Finder/AFC 拷入。
// ★ [JIT-PAIRING] 配对文件在实战里会放在不同位置(用户按不同教程导入的):
//   以前只认 Documents/StikJIT/pairingFile.plist 一条 ⇒ 明明装了也报 pairing=NO
//   (用户实测:日志说"没装",但他确实装了)。故改为【多候选】逐个查,并记住命中的那条。
static NSString *gAmeJITPairingFoundPath = nil;

NSArray<NSString *> *AMEJITPairingFileCandidates(void) {
    NSMutableArray<NSString *> *out = [NSMutableArray array];
    NSURL *documents = [NSFileManager.defaultManager
        URLForDirectory:NSDocumentDirectory inDomain:NSUserDomainMask
       appropriateForURL:nil create:YES error:nil];
    NSURL *support = [NSFileManager.defaultManager
        URLForDirectory:NSApplicationSupportDirectory inDomain:NSUserDomainMask
       appropriateForURL:nil create:YES error:nil];
    if (documents) {
        NSArray<NSString *> *subs = @[@"StikJIT", @"StikDebug", @"pairing", @""];
        NSArray<NSString *> *names = @[@"pairingFile.plist", @"pairingFile",
                                       @"mobiledevicepairing.plist", @"pairing_record.plist"];
        for (NSString *sub in subs) {
            NSURL *dir = sub.length ? [documents URLByAppendingPathComponent:sub isDirectory:YES] : documents;
            for (NSString *n in names) {
                [out addObject:[[dir URLByAppendingPathComponent:n] path]];
            }
        }
    }
    if (support) {
        for (NSString *sub in @[@"StikJIT", @"StikDebug", @""]) {
            NSURL *dir = sub.length ? [support URLByAppendingPathComponent:sub isDirectory:YES] : support;
            [out addObject:[[dir URLByAppendingPathComponent:@"pairingFile.plist"] path]];
        }
    }
    return out;
}

/// 返回【实际存在】的配对文件路径;都没有则返回推荐路径(供日志展示“应该放哪”)。
NSString *AMEJITPairingFilePath(void) {
    if (gAmeJITPairingFoundPath && [NSFileManager.defaultManager fileExistsAtPath:gAmeJITPairingFoundPath]) {
        return gAmeJITPairingFoundPath;
    }
    for (NSString *p in AMEJITPairingFileCandidates()) {
        if ([NSFileManager.defaultManager fileExistsAtPath:p]) {
            gAmeJITPairingFoundPath = p;
            return p;
        }
    }
    return AMEJITPairingFileCandidates().firstObject;
}

BOOL AMEJITHasPairingFile(void) {
    for (NSString *p in AMEJITPairingFileCandidates()) {
        if ([NSFileManager.defaultManager fileExistsAtPath:p]) {
            gAmeJITPairingFoundPath = p;
            return YES;
        }
    }
    return NO;
}

/// ★ [JIT-PAIRING] 单独探测“使能工具是否已装”——用 URL scheme 探,与配对文件无关。
///   避免把“没找到配对文件”误读成“工具没装”。
BOOL AMEJITEnablerAppInstalled(void) {
    NSArray<NSString *> *schemes = @[@"stikdebug", @"stikjit", @"sidestore", @"stosdebug"];
    for (NSString *sc in schemes) {
        NSURL *u = [NSURL URLWithString:[sc stringByAppendingString:@"://"]];
        if (u && [[UIApplication sharedApplication] canOpenURL:u]) {
            return YES;
        }
    }
    return NO;
}

// 在一次 JIT 获取动作前把门禁状态打到日志(只读,无副作用)。
void AMEJITLogPocketJReadiness(NSString *context) {
    BOOL hasPairing = AMEJITHasPairingFile();
    NSLog(@"[JIT] [POCKETJ-JIT] readiness(%@): ios17_4=%@ get-task-allow=%@ "
          @"enabler-app-installed=%@ pairing-file=%@ found=%@ (推荐位置=%@)",
          context ?: @"?",
          AMEJITDeviceSupportsBuiltInStikJIT() ? @"YES" : @"NO",
          AMEJITHasGetTaskAllow() ? @"YES" : @"NO",
          AMEJITEnablerAppInstalled() ? @"YES" : @"NO",
          hasPairing ? @"YES" : @"NO",
          hasPairing ? (AMEJITPairingFilePath() ?: @"(?)") : @"(未找到,已试多路径)",
          AMEJITPairingFileCandidates().firstObject ?: @"(nil)");
}

#ifndef P_TRACED
#define P_TRACED 0x00000800 /* process is being traced by a debugger (ptrace) */
#endif

// 向内核查询当前进程是否存在活的 ptrace 关系。P_TRACED 在调试器附加的
// 整个生命周期内置位、脱离瞬间清零，是"调试器还在"的准确信号。
BOOL JIT26DebuggerAttachedViaPtrace(void) {
    struct kinfo_proc info;
    size_t size = sizeof(info);
    int mib[4] = {CTL_KERN, KERN_PROC, KERN_PROC_PID, getpid()};
    memset(&info, 0, sizeof(info));
    if (sysctl(mib, 4, &info, &size, NULL, 0) != 0) {
        return NO;
    }
    return (info.kp_proc.p_flag & P_TRACED) != 0;
}

// 检测通过 Mach 异常端口持有本任务的调试器。lldb/debugserver 以
// ptrace(PT_ATTACH) 拿到任务端口后 PT_DETACH 但保留端口——此后 P_TRACED
// 为 0 而调试器完全存活、持续服务 EXC_BREAKPOINT（JIT26 的 brk #0x69 /
// brk #0xf00d 正是这样被服务的）。任务级 BREAKPOINT/SOFTWARE 非空
// handler 即"JIT26 调试器就位"的可靠信号。
BOOL JIT26DebuggerViaExceptionPorts(void) {
    exception_mask_t masks[EXC_TYPES_COUNT];
    exception_handler_t handlers[EXC_TYPES_COUNT];
    exception_behavior_t behaviors[EXC_TYPES_COUNT];
    thread_state_flavor_t flavors[EXC_TYPES_COUNT];
    mach_msg_type_number_t count = EXC_TYPES_COUNT;
    kern_return_t kr = task_get_exception_ports(mach_task_self(),
                                                EXC_MASK_BREAKPOINT | EXC_MASK_SOFTWARE,
                                                masks, &count, handlers, behaviors, flavors);
    if (kr != KERN_SUCCESS) {
        return NO;
    }
    for (mach_msg_type_number_t i = 0; i < count; i++) {
        if (handlers[i] != MACH_PORT_NULL) {
            return YES;
        }
    }
    return NO;
}

BOOL JIT26IsLikelyDebuggerKeepAttached(void) {
    // 调试器 spawn 的进程 ppid != 1（launchd 为 1）。
    if (getppid() != 1) {
        return YES;
    }
    // StikJIT/SideJIT 对已运行进程按 pid 附加，ppid 恒为 1；且启用工具可能
    // 退出导致进程被重挂到 launchd（ppid 回 1）而 CS_DEBUGGED 残留——单看
    // ppid 会把完全可用的会话误判为"无调试器"。回退到活的 ptrace 标志：
    // 附加期间恒置位，脱离即清零，既不错过附加流，也不漏掉真脱离。
    if (JIT26DebuggerAttachedViaPtrace()) {
        return YES;
    }
    // lldb/debugserver PT_DETACH 后 P_TRACED 回 0，但仍通过任务级异常端口
    // 服务 EXC_BREAKPOINT。把活的任务级 BREAKPOINT/SOFTWARE handler 视为
    // "调试器在岗"——它正是必须服务 brk #0x69 的实体。
    return JIT26DebuggerViaExceptionPorts();
}

// JIT 等待轮询的有界版本：最长 timeout 秒（超时返回 NO，调用方走超时
// 重试弹窗），每 10s 一条心跳日志，挂起间隙（迭代间隔 >2s）不计入超时预算。
BOOL ame169_waitForJITCondition(BOOL (^condition)(void), NSTimeInterval timeout, NSString *label) {
    NSDate *start = [NSDate date];
    NSDate *ame179_lastIter = [NSDate date];
    BOOL ame181_foreground = (UIApplication.sharedApplication.applicationState == UIApplicationStateActive);
    int ame181_csFlags = 0;
    csops(getpid(), 0, &ame181_csFlags, sizeof(ame181_csFlags));
    NSLog(@"[JIT] %@ wait begin: startForeground=%d traced=%d exn=%d csdbg=%d",
          label ?: @"JIT", ame181_foreground, JIT26DebuggerAttachedViaPtrace(),
          JIT26DebuggerViaExceptionPorts(), (ame181_csFlags & CS_DEBUGGED) != 0);
    for (;;) {
        if (condition()) {
            NSTimeInterval ame181_waited = -[start timeIntervalSinceNow];
            NSLog(@"[JIT] %@ condition satisfied after %.1fs (traced=%d exn=%d)",
                  label ?: @"JIT", ame181_waited, JIT26DebuggerAttachedViaPtrace(),
                  JIT26DebuggerViaExceptionPorts());
            return YES;
        }
        BOOL ame181_nowForeground = (UIApplication.sharedApplication.applicationState == UIApplicationStateActive);
        if (ame181_nowForeground != ame181_foreground) {
            NSLog(@"[JIT] %@ app %s while waiting (traced=%d exn=%d)",
                  label ?: @"JIT", ame181_nowForeground ? "returned to FOREGROUND" : "went to BACKGROUND",
                  JIT26DebuggerAttachedViaPtrace(), JIT26DebuggerViaExceptionPorts());
            ame181_foreground = ame181_nowForeground;
        }
        // 挂起间隙豁免：stikjit:// 把 App 切后台后 iOS 可能挂起进程，墙钟
        // 空转会烧穿等待预算；迭代间隔 >2s（正常节拍 0.2s）视为挂起，前推
        // start 补回预算。
        NSTimeInterval ame179_gap = -[ame179_lastIter timeIntervalSinceNow];
        if (ame179_gap > 2.0) {
            NSLog(@"[JIT] %@: suspension gap of %.0fs excluded from timeout budget",
                  label ?: @"JIT", ame179_gap);
            start = [start dateByAddingTimeInterval:ame179_gap];
        }
        ame179_lastIter = [NSDate date];
        NSTimeInterval waited = -[start timeIntervalSinceNow];
        if (waited >= timeout) {
            NSLog(@"[JIT] %@ wait TIMED OUT after %.0fs (traced=%d exn=%d)",
                  label ?: @"JIT", waited, JIT26DebuggerAttachedViaPtrace(), JIT26DebuggerViaExceptionPorts());
            return NO;
        }
        if (fmod(waited, 10.0) < 0.2) {
            NSLog(@"[JIT] %@: still waiting after %.0fs (traced=%d exn=%d)",
                  label ?: @"JIT", waited, JIT26DebuggerAttachedViaPtrace(), JIT26DebuggerViaExceptionPorts());
        }
        usleep(1000 * 200);
    }
}

// JIT 等待成功后的自愈式主队列派发：后台被楔死的主线程上 dispatch_async
// 的续接块可能永不执行。三道防线：①常规派发；②前台激活重派；③后台看门狗
//（120s 窗口，仅前台未达时重派并钉死锚点）。delivered 只在主队列读写，
// 多重派发不会导致块双跑。
void ame185_dispatchToMainSelfHealing(dispatch_block_t block, NSString *label) {
    if (!block) return;
    __block volatile BOOL delivered = NO;
    __block id ame185_obs = nil;
    void (^ame185_cleanup)(void) = ^{
        if (ame185_obs) {
            [[NSNotificationCenter defaultCenter] removeObserver:ame185_obs];
            ame185_obs = nil;
        }
    };
    dispatch_block_t attempt = ^{
        if (delivered) return;
        delivered = YES;
        ame185_cleanup();
        block();
    };
    dispatch_async(dispatch_get_main_queue(), attempt);
    ame185_obs = [[NSNotificationCenter defaultCenter]
        addObserverForName:UIApplicationDidBecomeActiveNotification
                    object:nil queue:[NSOperationQueue mainQueue]
                 usingBlock:^(NSNotification *ame185_note) {
        if (delivered) { ame185_cleanup(); return; }
        NSLog(@"[JIT] self-healing dispatch: refire on foreground (label=%@)", label);
        dispatch_async(dispatch_get_main_queue(), attempt);
    }];
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_DEFAULT, 0), ^{
        for (int ame185_i = 0; ame185_i < 60; ame185_i++) {
            if (delivered) { ame185_cleanup(); return; }
            usleep(2 * 1000 * 1000);
            if (delivered) { ame185_cleanup(); return; }
            if ([UIApplication sharedApplication].applicationState == UIApplicationStateActive) {
                NSLog(@"[JIT] self-healing dispatch: watchdog redispatch #%d (label=%@)", ame185_i + 1, label);
                dispatch_async(dispatch_get_main_queue(), attempt);
            }
        }
        if (!delivered) {
            NSLog(@"[JIT] self-healing dispatch: NOT delivered after 120s -- main queue wedged (label=%@)", label);
        }
        ame185_cleanup();
    });
}

BOOL DeviceCanCreateRXMap(void) {
    // This is only guaranteed to be accurate when JIT is already enabled. Obviously this is only useful for vphone and similar internal environments where JIT is always enabled.
    uint32_t *map = mmap(NULL, getpagesize(), PROT_READ | PROT_WRITE, MAP_ANONYMOUS | MAP_SHARED, -1, 0);
    if (map == MAP_FAILED) {
        NSLog(@"DeviceCanCreateRXMap: mmap failed: %s", strerror(errno));
        return NO;
    }
    *map = 0xFFFFFFFF;
    int ret = mprotect(map, getpagesize(), PROT_READ | PROT_EXEC) | mprotect(map, getpagesize(), PROT_READ | PROT_EXEC);
    munmap(map, getpagesize());
    return ret == 0;
}

static BOOL DeviceLikelyHasTXMFromChipID(void) {
    NSUInteger (*MGGetSInt64Answer)(NSString *) = dlsym(RTLD_DEFAULT, "MGGetSInt64Answer");
    if (MGGetSInt64Answer == NULL) {
        // Failing closed would select the legacy mapping path on the exact
        // systems where Apple made Preboot unreadable. Prefer the TXM-safe
        // path on recent systems when MobileGestalt is unavailable.
        if (@available(iOS 19.0, *)) return YES;
        return NO;
    }

    switch (MGGetSInt64Answer(@"ChipID")) {
        case 0x8020: // A12
        case 0x8027: // A12X/Z
            return NO;
        case 0x8030: // A13
        case 0x8101: // A14
        case 0x8103: // M1
            if (@available(iOS 27.0, *)) return YES;
            return NO;
        default:
            if (@available(iOS 19.0, *)) return YES;
            return NO;
    }
}

BOOL DeviceHasTXM(void) {
    // Try the direct active-Preboot path before falling back to legacy
    // directory enumeration.
    static const char *modernTXMPath =
        "/System/Volumes/Preboot/boot/usr/standalone/firmware/FUD/"
        "Ap,TrustedExecutionMonitor.img4";
    if (access(modernTXMPath, F_OK) == 0) return YES;

    DIR *d = opendir("/private/preboot");
    if (!d) {
        // /private/preboot is no longer readable on iOS 26.6 and iOS 27.
        // Fall back to a conservative hardware/OS heuristic.
        return DeviceLikelyHasTXMFromChipID();
    }

    struct dirent *dir;
    BOOL hasTXM = NO;
    while ((dir = readdir(d)) != NULL) {
        if(strlen(dir->d_name) == 96) {
            char txmPath[PATH_MAX] = {0};
            int length = snprintf(txmPath, sizeof(txmPath),
                "/private/preboot/%s/usr/standalone/firmware/FUD/"
                "Ap,TrustedExecutionMonitor.img4", dir->d_name);
            if (length > 0 && (size_t)length < sizeof(txmPath) &&
                    access(txmPath, F_OK) == 0) {
                hasTXM = YES;
                break;
            }
        }
    }
    closedir(d);
    return hasTXM;
}

JITFlags DeviceGetJITFlags(BOOL refresh) {
    static os_unfair_lock cacheLock = OS_UNFAIR_LOCK_INIT;
    static JITFlags cachedFlags = 0;
    static BOOL cacheInitialized = NO;

    os_unfair_lock_lock(&cacheLock);
    if (refresh || !cacheInitialized) {
        JITFlags flags = 0;
        const char *s = getenv("JIT_FLAGS");
        if (s) {
            if (s[0] == '0' && tolower(s[1]) == 'b') {
                flags = strtoul(s + 2, NULL, 2);
            } else {
                flags = strtoul(s, NULL, 0);
            }
            NSLog(@"[JIT] Using overridden JIT flags: 0x%X", flags);
        } else {
            if (@available(iOS 26.0, *)) {
                flags |= JIT_FLAG_IS_IOS_26;
                if (!DeviceCanCreateRXMap()) {
                    flags |= JIT_FLAG_FORCE_MIRRORED;
                }
            }
            if (DeviceHasTXM()) {
                flags |= JIT_FLAG_HAS_TXM;
            }
        }

        cachedFlags = flags;
        cacheInitialized = YES;
    }
    JITFlags result = cachedFlags;
    os_unfair_lock_unlock(&cacheLock);
    return result;
}

BOOL DeviceHasJITFlags(JITFlags flags) {
    return (DeviceGetJITFlags(NO) & flags) == flags;
}

BOOL DeviceNeedsDebugJITMapping(void) {
    // This is a capability decision, not a TXM firmware-detection decision.
    // MirrorMappedCodeCache now means that the Universal JIT script has been
    // installed and HotSpot may request its RX mapping from the debugger.
    return DeviceHasJITFlags(JIT_FLAG_IS_IOS_26 | JIT_FLAG_FORCE_MIRRORED);
}

void dismissModalViewController(UIViewController *viewController) {
    [viewController.navigationController dismissViewControllerAnimated:YES completion:nil];
}
