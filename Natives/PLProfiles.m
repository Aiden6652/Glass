//
//  PLProfiles.m
//  Amethyst
//
//  Profile manager with JSON-safe save
//

#import "LauncherPreferences.h"
#import "PLProfiles.h"
#import "utils.h"

static PLProfiles* current;

@interface PLProfiles()
@end

@implementation PLProfiles

+ (id)defaultProfiles {
    return @{
        @"profiles": @{
            @"(Default)": @{
                @"name": @"(Default)",
                @"lastVersionId": @"latest-release"
            }
        },
        @"selectedProfile": @"(Default)"
    }.mutableCopy;
}

+ (PLProfiles *)current {
    if (!current) {
        [self updateCurrent];
    }
    return current;
}

+ (void)updateCurrent {
    current = [[PLProfiles alloc] initWithCurrentInstance];
}

+ (id)profile:(NSMutableDictionary *)profile resolveKey:(id)key {
    id rawValue = profile[key];
    // 兼容 javaVersion 字段：Mojang 规范是 NSDictionary（{component, majorVersion}），
    // 但部分代码（如 ForgeDirectInstaller）也写入 NSDictionary。PLProfiles 期望返回 NSString。
    if ([rawValue isKindOfClass:[NSDictionary class]]) {
        // javaVersion: 返回 majorVersion 的字符串值；缺失则落入下方 valueDefaults
        id major = rawValue[@"majorVersion"];
        if (major) return [major description];
        // 落入下方 valueDefaults 逻辑，避免返回 nil 破坏调用方
    } else if ([rawValue isKindOfClass:[NSString class]] && [(NSString *)rawValue length] > 0) {
        return rawValue;
    }

    NSDictionary *valueDefaults = @{
        @"javaVersion": @"0",
        @"gameDir": @"."
    };
    if (valueDefaults[key]) {
        return valueDefaults[key];
    }

    NSDictionary *prefDefaults = @{
        @"defaultTouchCtrl": @"control.default_ctrl",
        @"defaultGamepadCtrl": @"control.default_gamepad_ctrl",
        @"javaArgs": @"java.java_args",
        @"renderer": @"video.renderer",
        // MC 26.2+ Graphics API（OpenGL/Vulkan 游戏内切换），缺省为 "default"
        // 该字段仅在 MC 26.2+ 生效，旧版本会被 MC 忽略，无副作用。
        @"graphicsApi": @"video.graphics_api"
    };
    return getPrefObject(prefDefaults[key]);
}

+ (id)resolveKeyForCurrentProfile:(id)key {
    return [self profile:self.current.selectedProfile resolveKey:key];
}

- (id)initWithCurrentInstance {
    self = [super init];
    self.profilePath = [@(getenv("POJAV_GAME_DIR")) stringByAppendingPathComponent:@"launcher_profiles.json"];
    self.profileDict = parseJSONFromFile(self.profilePath);
    if (self.profileDict[@"NSErrorObject"]) {
        self.profileDict = PLProfiles.defaultProfiles;
        [self save];
    }
    // 自愈补丁：自动补齐缺失的版本 profile（解决 Forge 等加载器安装收尾崩溃后版本不显示）
    [self autoAddMissingVersionProfiles];

    return self;
}

/// 自愈补丁：扫描 versions/ 目录，为有版本 json 但没有 profile 的版本自动补上 profile。
/// 解决 Forge 等加载器版本安装时收尾崩溃（JVM 退出带崩 app）导致 launcher_profiles.json
/// 未写入的问题——只要版本 json 已落盘，重开启动器即可自动出现在版本列表，无需手动补。
- (void)autoAddMissingVersionProfiles {
    NSString *gameDir = @(getenv("POJAV_GAME_DIR"));
    NSString *versionsDir = [gameDir stringByAppendingPathComponent:@"versions"];
    NSFileManager *fm = [NSFileManager defaultManager];
    if (![fm fileExistsAtPath:versionsDir]) {
        return;
    }

    NSArray *entries = [fm contentsOfDirectoryAtPath:versionsDir error:nil];
    NSMutableDictionary *profiles = [self profiles];  // 经 getter 保证为可变字典
    BOOL changed = NO;

    for (NSString *entry in entries) {
        NSString *versionPath = [versionsDir stringByAppendingPathComponent:entry];
        BOOL isDir = NO;
        if (![fm fileExistsAtPath:versionPath isDirectory:&isDir] || !isDir) {
            continue;
        }
        // 目录里必须有对应的版本 json 才算有效版本
        NSString *jsonPath = [versionPath stringByAppendingPathComponent:[entry stringByAppendingPathExtension:@"json"]];
        if (![fm fileExistsAtPath:jsonPath]) {
            continue;
        }

        // 已有对应 profile 则跳过
        BOOL exists = NO;
        for (NSString *name in profiles) {
            if ([[profiles[name][@"lastVersionId"] description] isEqualToString:entry]) {
                exists = YES;
                break;
            }
        }
        if (exists) {
            continue;
        }

        // 自动补 profile（显示名美化：1.20.1-forge-47.1.39 → Forge 1.20.1）
        NSString *displayName = entry;
        if ([entry containsString:@"-forge-"]) {
            NSString *mcVer = [entry componentsSeparatedByString:@"-forge-"].firstObject;
            displayName = [NSString stringWithFormat:@"Forge %@", mcVer];
        }
        profiles[displayName] = [@{
            @"name": displayName,
            @"lastVersionId": entry,
            @"gameDir": @"."
        } mutableCopy];
        NSLog(@"[PLProfiles] Self-healing: auto-added profile \"%@\" for version %@", displayName, entry);
        changed = YES;
    }

    if (changed) {
        [self save];
    }
}

- (id)profiles {
    id profiles = self.profileDict[@"profiles"];
    if (![profiles isKindOfClass:[NSDictionary class]]) {
        profiles = [NSMutableDictionary dictionary];
        self.profileDict[@"profiles"] = profiles;
    } else if (![profiles isKindOfClass:[NSMutableDictionary class]]) {
        profiles = [profiles mutableCopy];
        self.profileDict[@"profiles"] = profiles;
    }
    return profiles;
}

- (id)selectedProfile {
    return self.profiles[self.selectedProfileName];
}

- (NSString *)selectedProfileName {
    return (id)self.profileDict[@"selectedProfile"];
}

- (void)setSelectedProfileName:(NSString *)name {
    self.profileDict[@"selectedProfile"] = (id)name;
    [self save];
    
    [[NSNotificationCenter defaultCenter] postNotificationName:@"SelectedProfileChanged" object:name];
}

/// 递归清理 NSDate 等非法 JSON 类型，确保保存不崩溃
- (id)jsonSanitizedObject:(id)obj {
    if ([obj isKindOfClass:[NSDate class]]) {
        static NSDateFormatter *formatter = nil;
        static dispatch_once_t onceToken;
        dispatch_once(&onceToken, ^{
            formatter = [[NSDateFormatter alloc] init];
            formatter.locale = [NSLocale localeWithLocaleIdentifier:@"en_US_POSIX"];
            formatter.timeZone = [NSTimeZone timeZoneWithAbbreviation:@"UTC"];
            formatter.dateFormat = @"yyyy-MM-dd'T'HH:mm:ss'Z'";
        });
        return [formatter stringFromDate:obj];
    } else if ([obj isKindOfClass:[NSDictionary class]]) {
        NSMutableDictionary *clean = [NSMutableDictionary dictionaryWithCapacity:[obj count]];
        [obj enumerateKeysAndObjectsUsingBlock:^(id key, id val, BOOL *stop) {
            id safeKey = [key isKindOfClass:[NSDate class]] ? [self jsonSanitizedObject:key] : key;
            clean[safeKey] = [self jsonSanitizedObject:val];
        }];
        return clean;
    } else if ([obj isKindOfClass:[NSArray class]]) {
        NSMutableArray *clean = [NSMutableArray arrayWithCapacity:[obj count]];
        for (id item in obj) {
            [clean addObject:[self jsonSanitizedObject:item]];
        }
        return clean;
    }
    return obj;
}

- (void)save {
    id sanitized = [self jsonSanitizedObject:self.profileDict];
    if ([NSJSONSerialization isValidJSONObject:sanitized]) {
        saveJSONToFile(sanitized, self.profilePath);
    } else {
        NSLog(@"[PLProfiles] save failed: profileDict still contains invalid JSON types after sanitization");
    }
}

- (void)saveProfile:(NSMutableDictionary<NSString *, NSString *> *)profile withName:(NSString *)name {
    if (!self.profileDict[@"profiles"]) {
        self.profileDict[@"profiles"] = [NSMutableDictionary dictionary];
    }
    self.profileDict[@"profiles"][name] = profile;
    [self save];
}

#pragma mark - 服务器地址（FCL 风格：启动后自动加入服务器）

// 获取当前选中 profile 的服务器地址，留空返回 @""
- (NSString *)serverIpForCurrentProfile {
    return [self serverIpForProfile:self.selectedProfileName];
}

// 获取指定 profile 的服务器地址，缺失或为空均返回 @""
- (NSString *)serverIpForProfile:(NSString *)profileName {
    NSString *ip = self.profiles[profileName][@"serverIp"];
    return ip ?: @"";
}

// 设置指定 profile 的服务器地址，nil 转为 @""
- (void)setServerIp:(NSString *)serverIp forProfile:(NSString *)profileName {
    NSMutableDictionary *profile = [self.profiles[profileName] mutableCopy];
    if (!profile) {
        profile = [NSMutableDictionary dictionary];
    }
    profile[@"serverIp"] = serverIp ?: @"";
    self.profiles[profileName] = profile;
    [self save];
}

@end
