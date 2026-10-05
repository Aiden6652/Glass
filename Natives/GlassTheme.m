//
//  GlassTheme.m
//  Amethyst
//
//  Glass 启动器视觉主题常量实现。
//
//  全部颜色走 [UIColor colorWithDynamicProvider:]，由系统在明暗模式切换时
//  自动解析，无需手动监听 traitCollection 变化，也不会残留旧颜色。
//
//  液态玻璃档位（GlassStyle）相关的表现参数也集中在这里，
//  使「设置页选什么」与「GlassEffectView 渲染成什么样」共用同一份数值来源。
//

#import "GlassTheme.h"
#import "LauncherPreferences.h"
#import "utils.h"   // localize()

@implementation GlassTheme

#pragma mark - 通用尺寸

+ (CGFloat)containerCornerRadius { return 22.0; }

+ (CGFloat)menuButtonSize { return 56.0; }

+ (CGFloat)menuButtonCornerRadius { return 16.0; }

+ (CGFloat)borderWidth {
    // 三倍屏（Plus/Pro Max 类）用细线更精致，普通屏用 1pt
    return (UIScreen.mainScreen.scale >= 3.0) ? 0.5 : 1.0;
}

#pragma mark - 明暗判定

+ (BOOL)isDarkAppearance {
    if (@available(iOS 13.0, *)) {
        return UITraitCollection.currentTraitCollection.userInterfaceStyle == UIUserInterfaceStyleDark;
    }
    return YES; // iOS 13 以下不涉及动态颜色，默认按深色处理
}

#pragma mark - 动态颜色

+ (UIColor *)glassBorderColor {
    return [UIColor colorWithDynamicProvider:^UIColor *(UITraitCollection *tc) {
        if (tc.userInterfaceStyle == UIUserInterfaceStyleDark) {
            // 深色玻璃：极淡的白色描边模拟玻璃边缘受光
            return [UIColor colorWithWhite:1.0 alpha:0.10];
        }
        // 浅色玻璃：稍强的白色描边，与浅背景拉开层次
        return [UIColor colorWithWhite:1.0 alpha:0.65];
    }];
}

+ (UIColor *)glassPanelTintColor {
    return [UIColor colorWithDynamicProvider:^UIColor *(UITraitCollection *tc) {
        if (tc.userInterfaceStyle == UIUserInterfaceStyleDark) {
            return [UIColor colorWithWhite:1.0 alpha:0.04];
        }
        return [UIColor colorWithWhite:1.0 alpha:0.30];
    }];
}

+ (UIColor *)glassShadowColor {
    return [UIColor blackColor];
}

+ (CGFloat)glassShadowOpacity {
    GlassStyle style = [self glassStyle];
    if (style == GlassStyleOff) return 0.0;
    // 液态玻璃是"浮"在背景上的，需要更实的投影来建立层次
    CGFloat base = [self isDarkAppearance] ? 0.45 : 0.12;
    if (style == GlassStyleLiquid) base += 0.08;
    else if (style == GlassStyleStrong) base += 0.04;
    return base;
}

+ (CGFloat)glassShadowRadius {
    GlassStyle style = [self glassStyle];
    if (style == GlassStyleLiquid) return 32.0;
    if (style == GlassStyleStrong)   return 26.0;
    return 24.0;
}

+ (CGFloat)glassShadowOffsetY {
    GlassStyle style = [self glassStyle];
    if (style == GlassStyleLiquid) return 12.0;
    return 8.0;
}

+ (UIColor *)menuSelectionHighlightColor {
    return [UIColor colorWithDynamicProvider:^UIColor *(UITraitCollection *tc) {
        if (tc.userInterfaceStyle == UIUserInterfaceStyleDark) {
            return [UIColor colorWithWhite:1.0 alpha:0.14];
        }
        return [UIColor colorWithWhite:0.0 alpha:0.06];
    }];
}

+ (UIColor *)menuSelectionGlowColor {
    return [UIColor colorWithDynamicProvider:^UIColor *(UITraitCollection *tc) {
        if (tc.userInterfaceStyle == UIUserInterfaceStyleDark) {
            return [UIColor colorWithWhite:1.0 alpha:0.22];
        }
        return [UIColor colorWithWhite:0.0 alpha:0.10];
    }];
}

+ (UIColor *)menuButtonGlassFillColor {
    return [UIColor colorWithDynamicProvider:^UIColor *(UITraitCollection *tc) {
        if (tc.userInterfaceStyle == UIUserInterfaceStyleDark) {
            // 深色：极淡白色填充，模拟暗色玻璃
            return [UIColor colorWithWhite:1.0 alpha:0.06];
        }
        // 浅色：白色半透明填充，模拟磨砂玻璃
        return [UIColor colorWithWhite:1.0 alpha:0.45];
    }];
}

+ (UIColor *)menuButtonBorderColor {
    return [UIColor colorWithDynamicProvider:^UIColor *(UITraitCollection *tc) {
        if (tc.userInterfaceStyle == UIUserInterfaceStyleDark) {
            return [UIColor colorWithWhite:1.0 alpha:0.14];
        }
        return [UIColor colorWithWhite:1.0 alpha:0.85];
    }];
}

+ (UIColor *)menuButtonTopSheenColor {
    return [UIColor colorWithDynamicProvider:^UIColor *(UITraitCollection *tc) {
        if (tc.userInterfaceStyle == UIUserInterfaceStyleDark) {
            return [UIColor colorWithWhite:1.0 alpha:0.16];
        }
        return [UIColor colorWithWhite:1.0 alpha:0.70];
    }];
}

+ (UIBlurEffectStyle)blurEffectStyle {
    // UIBlurEffectStyleSystem* 系列为 iOS 13 引入。
    // 这里用编译期可用性判断而非 @available 运行时判断：后者在方法体内无法为
    // 返回值提供有效的可用性保护，会触发 "does not guard availability here" 警告。
#if __IPHONE_OS_VERSION_MAX_ALLOWED >= 130000
    if ([NSProcessInfo.processInfo isOperatingSystemAtLeastVersion:(NSOperatingSystemVersion){13, 0, 0}]) {
        // 液态玻璃要让背景尽可能透出来，用更薄的材质；
        // 标准档用 Thin，强档用更实的 Material 以体现"厚度"。
        GlassStyle style = [self glassStyle];
        BOOL dark = [self isDarkAppearance];
        if (style == GlassStyleLiquid) {
            return dark ? UIBlurEffectStyleSystemUltraThinMaterialDark
                        : UIBlurEffectStyleSystemUltraThinMaterialLight;
        }
        if (style == GlassStyleStrong) {
            return dark ? UIBlurEffectStyleSystemMaterialDark
                        : UIBlurEffectStyleSystemMaterialLight;
        }
        return dark ? UIBlurEffectStyleSystemThinMaterialDark
                    : UIBlurEffectStyleSystemThinMaterialLight;
    }
#endif
    return UIBlurEffectStyleDark;
}

#pragma mark - 字号

+ (UIFont *)menuTitleFont {
    return [UIFont systemFontOfSize:11 weight:UIFontWeightMedium];
}

#pragma mark - 动效参数

+ (NSTimeInterval)transitionDuration { return 0.45; }

+ (CGFloat)transitionDamping { return 0.85; }

+ (CGFloat)transitionVelocity { return 0.5; }

+ (CGFloat)transitionOldPageOffsetY { return 30.0; }

+ (CGFloat)launchSlideDistance { return 70.0; }

+ (NSTimeInterval)launchStaggerDelay { return 0.08; }

+ (NSTimeInterval)launchDuration { return 0.55; }

+ (CGFloat)launchDamping { return 0.88; }

#pragma mark - AI 对话 & 卡片（Glass 扩展）

+ (UIColor *)containerBackgroundColor {
    return [UIColor colorWithDynamicProvider:^UIColor *(UITraitCollection *tc) {
        if (tc.userInterfaceStyle == UIUserInterfaceStyleDark) {
            return [UIColor colorWithWhite:1.0 alpha:0.04];
        }
        return [UIColor colorWithWhite:0.0 alpha:0.03];
    }];
}

+ (UIColor *)glassCardColor {
    return [UIColor colorWithDynamicProvider:^UIColor *(UITraitCollection *tc) {
        if (tc.userInterfaceStyle == UIUserInterfaceStyleDark) {
            return [UIColor colorWithWhite:1.0 alpha:0.08];
        }
        return [UIColor colorWithWhite:1.0 alpha:0.55];
    }];
}

+ (UIColor *)userBubbleColor {
    // 用户气泡用 accent 淡底，明暗模式下都保持可读
    UIColor *accent = [UIColor colorWithRed:0.20 green:0.55 blue:0.95 alpha:1.0];
    return [UIColor colorWithDynamicProvider:^UIColor *(UITraitCollection *tc) {
        if (tc.userInterfaceStyle == UIUserInterfaceStyleDark) {
            return [accent colorWithAlphaComponent:0.22];
        }
        return [accent colorWithAlphaComponent:0.14];
    }];
}

+ (UIColor *)assistantBubbleColor {
    return [UIColor colorWithDynamicProvider:^UIColor *(UITraitCollection *tc) {
        if (tc.userInterfaceStyle == UIUserInterfaceStyleDark) {
            return [UIColor colorWithWhite:1.0 alpha:0.08];
        }
        return [UIColor colorWithWhite:1.0 alpha:0.60];
    }];
}

#pragma mark - 偏好读取

+ (GlassTransitionStyle)currentTransitionStyle {
    // 走启动器既有的偏好读取函数（getPrefObject 定义于 LauncherPreferences.h）。
    // 未设置时返回 SlideUp，保证默认即 Glass 标志性的"从下方浮入"。
    id raw = getPrefObject(@"general.transition_style");
    if ([raw isKindOfClass:[NSString class]] && [(NSString *)raw length] > 0) {
        NSString *s = (NSString *)raw;
        if ([s isEqualToString:@"cross-dissolve"]) return GlassTransitionStyleCrossDissolve;
        if ([s isEqualToString:@"scale-fade"])     return GlassTransitionStyleScaleFade;
        if ([s isEqualToString:@"slide-up"])       return GlassTransitionStyleSlideUp;
    }
    return GlassTransitionStyleSlideUp;
}

#pragma mark - 玻璃质感档位

+ (NSInteger)glassStyleCount { return 4; }

+ (GlassStyle)glassStyle {
    id raw = getPrefObject(@"general.glass_style");
    if ([raw isKindOfClass:[NSString class]] && [(NSString *)raw length] > 0) {
        NSString *s = (NSString *)raw;
        if ([s isEqualToString:@"off"])      return GlassStyleOff;
        if ([s isEqualToString:@"standard"]) return GlassStyleStandard;
        if ([s isEqualToString:@"strong"])   return GlassStyleStrong;
        if ([s isEqualToString:@"liquid"])   return GlassStyleLiquid;
    }
    // 默认即液态玻璃：这是 Glass 这一版的主打观感
    return GlassStyleLiquid;
}

+ (NSString *)prefValueForGlassStyle:(GlassStyle)style {
    switch (style) {
        case GlassStyleOff:      return @"off";
        case GlassStyleStandard: return @"standard";
        case GlassStyleStrong:   return @"strong";
        case GlassStyleLiquid:   return @"liquid";
    }
    return @"liquid";
}

+ (NSString *)displayNameForGlassStyle:(GlassStyle)style {
    // 用既有 i18n 机制，54 个语言文件均已补齐这五个键。
    // 注意键号：203~206 已被下载错误提示占用，玻璃档位用的是 2068~2072，
    // 切勿写回 203~206，否则设置页会显示"安装失败"之类的下载错误文案。
    switch (style) {
        case GlassStyleOff:      return localize(@"i18n_str_2069", nil);
        case GlassStyleStandard: return localize(@"i18n_str_2070", nil);
        case GlassStyleStrong:   return localize(@"i18n_str_2071", nil);
        case GlassStyleLiquid:   return localize(@"i18n_str_2072", nil);
    }
    return localize(@"i18n_str_2072", nil);
}

+ (NSInteger)glassLayerCountForStyle:(GlassStyle)style {
    switch (style) {
        case GlassStyleOff:      return 0;  // 完全平面
        case GlassStyleStandard: return 2;  // 模糊 + 基础
        case GlassStyleStrong:   return 4;  // + 镜面高光 + 顶部弧形高光
        case GlassStyleLiquid:   return 5;  // + 边缘内发光（折射与色调另算）
    }
    return 5;
}

+ (BOOL)glassUsesRefractionForStyle:(GlassStyle)style {
    return style == GlassStyleLiquid;
}

+ (BOOL)glassUsesTintForStyle:(GlassStyle)style {
    return style == GlassStyleLiquid;
}

+ (CGFloat)glassBorderWidthScaleForStyle:(GlassStyle)style {
    switch (style) {
        case GlassStyleOff:      return 0.0;
        case GlassStyleStandard: return 1.0;
        case GlassStyleStrong:   return 0.8;
        case GlassStyleLiquid:   return 0.6;  // 液态玻璃描边极细，像真实玻璃的边缘反光
    }
    return 1.0;
}

+ (CGFloat)glassRefractionBlurRadius { return 6.0; }

#pragma mark - 液态玻璃专用颜色

+ (UIColor *)glassSpecularColor {
    return [UIColor colorWithDynamicProvider:^UIColor *(UITraitCollection *tc) {
        if (tc.userInterfaceStyle == UIUserInterfaceStyleDark) {
            return [UIColor colorWithWhite:1.0 alpha:0.055];
        }
        return [UIColor colorWithWhite:1.0 alpha:0.32];
    }];
}

+ (UIColor *)glassTopSheenColor {
    return [UIColor colorWithDynamicProvider:^UIColor *(UITraitCollection *tc) {
        if (tc.userInterfaceStyle == UIUserInterfaceStyleDark) {
            return [UIColor colorWithWhite:1.0 alpha:0.13];
        }
        return [UIColor colorWithWhite:1.0 alpha:0.55];
    }];
}

+ (UIColor *)glassInnerGlowColor {
    return [UIColor colorWithDynamicProvider:^UIColor *(UITraitCollection *tc) {
        if (tc.userInterfaceStyle == UIUserInterfaceStyleDark) {
            return [UIColor colorWithWhite:1.0 alpha:0.07];
        }
        return [UIColor colorWithWhite:1.0 alpha:0.38];
    }];
}

+ (UIColor *)glassTintTopColor {
    // 极淡的冷蓝，模拟厚玻璃自身的青色调
    return [UIColor colorWithDynamicProvider:^UIColor *(UITraitCollection *tc) {
        if (tc.userInterfaceStyle == UIUserInterfaceStyleDark) {
            return [UIColor colorWithRed:0.62 green:0.78 blue:1.0 alpha:0.045];
        }
        return [UIColor colorWithRed:0.80 green:0.90 blue:1.0 alpha:0.16];
    }];
}

+ (UIColor *)glassTintBottomColor {
    return [UIColor colorWithDynamicProvider:^UIColor *(UITraitCollection *tc) {
        if (tc.userInterfaceStyle == UIUserInterfaceStyleDark) {
            return [UIColor colorWithRed:0.45 green:0.60 blue:0.95 alpha:0.02];
        }
        return [UIColor colorWithRed:0.86 green:0.90 blue:1.0 alpha:0.06];
    }];
}

@end
