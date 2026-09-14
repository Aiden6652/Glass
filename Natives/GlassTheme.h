//
//  GlassTheme.h
//  Amethyst
//
//  Glass 启动器视觉主题常量：集中管理毛玻璃质感相关的圆角、描边、阴影、
//  动效时长与缓动参数。所有颜色均为动态颜色（明暗双套自动切换）。
//
//  设计原则：本类只提供「数值与颜色」，不持有任何视图，不依赖现有 UI 组件，
//  因此可被任意界面安全引用，不会造成循环依赖或副作用。
//

#import <UIKit/UIKit.h>

NS_ASSUME_NONNULL_BEGIN

#pragma mark - 过渡动效样式

/// 页面切换动效样式（对应偏好键 general.transition_style）
typedef NS_ENUM(NSInteger, GlassTransitionStyle) {
    /// 从下方浮入（默认，Glass 标志性动效）
    GlassTransitionStyleSlideUp = 0,
    /// 交叉淡化（原版行为）
    GlassTransitionStyleCrossDissolve = 1,
    /// 缩放淡入（从 0.92 放大到 1.0）
    GlassTransitionStyleScaleFade = 2,
};

#pragma mark - 玻璃质感档位

/// 玻璃观感档位（对应偏好键 general.glass_style）。
/// 从"完全关闭"到"液态玻璃"逐级增强，越高级叠加的渲染层越多、越接近真实玻璃，
/// 同时在低端设备上也越费性能——这也是提供档位选择的根本原因。
typedef NS_ENUM(NSInteger, GlassStyle) {
    /// 关闭：完全平面，不叠加任何模糊/高光/折射层（性能优先）
    GlassStyleOff = 0,
    /// 标准：半透明底 + 描边 + 顶部高光，最接近旧版 Glass 观感
    GlassStyleStandard = 1,
    /// 强：在标准之上加斜向镜面高光与内发光，玻璃厚度感明显
    GlassStyleStrong = 2,
    /// 液态玻璃（默认）：再加一层背景折射采样，模拟 iOS 26 的 Liquid Glass
    GlassStyleLiquid = 3,
};


@interface GlassTheme : NSObject
/// 档位数量（设置页生成选项用）
+ (NSInteger)glassStyleCount;
/// 读取偏好：当前玻璃档位（无偏好时返回 Liquid）
+ (GlassStyle)glassStyle;

/// 档位对应的偏好存储值（general.glass_style 里存的字符串）
+ (NSString *)prefValueForGlassStyle:(GlassStyle)style;

/// 档位在设置页展示用的本地化名称
+ (NSString *)displayNameForGlassStyle:(GlassStyle)style;

#pragma mark - 档位对渲染表现的控制

/// 该档位需要叠加的渲染层数（0~5）。0 表示完全关闭。
/// GlassEffectView 依据此值决定构建哪些层，保证"设置里选什么"与"渲染成什么样"严格一致。
+ (NSInteger)glassLayerCountForStyle:(GlassStyle)style;

/// 是否启用背景折射采样层（最贵的一层，仅液态玻璃档开启）
+ (BOOL)glassUsesRefractionForStyle:(GlassStyle)style;

/// 是否叠加有色玻璃色调（仅液态玻璃档开启）
+ (BOOL)glassUsesTintForStyle:(GlassStyle)style;

/// 描边宽度倍率（越高档描边越细越精致）
+ (CGFloat)glassBorderWidthScaleForStyle:(GlassStyle)style;

/// 折射采样后的高斯模糊半径
+ (CGFloat)glassRefractionBlurRadius;

#pragma mark - 液态玻璃专用颜色

/// 斜向镜面高光色
+ (UIColor *)glassSpecularColor;

/// 顶部弧形高光色
+ (UIColor *)glassTopSheenColor;

/// 边缘内发光色
+ (UIColor *)glassInnerGlowColor;

/// 有色玻璃渐变：上端
+ (UIColor *)glassTintTopColor;

/// 有色玻璃渐变：下端
+ (UIColor *)glassTintBottomColor;


#pragma mark - 通用尺寸

/// 毛玻璃容器圆角（主面板）
+ (CGFloat)containerCornerRadius;

/// 菜单按钮尺寸
+ (CGFloat)menuButtonSize;

/// 菜单按钮圆角
+ (CGFloat)menuButtonCornerRadius;

/// 玻璃描边宽度（默认 1.0 / 三倍屏下自动减半）
+ (CGFloat)borderWidth;

#pragma mark - 动态颜色（明暗双套）

/// 玻璃边缘高光色：深色模式为白色低透明，浅色模式为白色高透明
+ (UIColor *)glassBorderColor;

/// 玻璃面板底色（叠加在毛玻璃之上，用于统一明暗观感）
+ (UIColor *)glassPanelTintColor;

/// 柔和外阴影颜色
+ (UIColor *)glassShadowColor;

/// 阴影不透明度（深色 0.35 / 浅色 0.12）
+ (CGFloat)glassShadowOpacity;

/// 阴影半径
+ (CGFloat)glassShadowRadius;

/// 阴影纵向偏移（营造"悬浮"感）
+ (CGFloat)glassShadowOffsetY;

/// 选中态高光（菜单按钮选中时的背景）
+ (UIColor *)menuSelectionHighlightColor;

/// 选中态光晕（外围发光）
+ (UIColor *)menuSelectionGlowColor;

/// 菜单按钮常态玻璃底色（未选中时的半透明填充）
+ (UIColor *)menuButtonGlassFillColor;

/// 菜单按钮玻璃描边色
+ (UIColor *)menuButtonBorderColor;

/// 菜单按钮顶部内高光色（模拟玻璃受光面）
+ (UIColor *)menuButtonTopSheenColor;

/// 毛玻璃样式（随明暗自动切换）
+ (UIBlurEffectStyle)blurEffectStyle;

#pragma mark - AI 对话 & 通用卡片

/// 内容区容器底色（AI 会话页背景等）
+ (UIColor *)containerBackgroundColor;

/// 玻璃卡片底色（列表卡片、工具卡片）
+ (UIColor *)glassCardColor;

/// 用户消息气泡底色（AI 对话）
+ (UIColor *)userBubbleColor;

/// 助手消息气泡底色（AI 对话）
+ (UIColor *)assistantBubbleColor;

#pragma mark - 字号

/// 菜单按钮文字字体
+ (UIFont *)menuTitleFont;

#pragma mark - 动效参数

/// 页面切换动效时长
+ (NSTimeInterval)transitionDuration;

/// 弹簧阻尼（0~1，越大越"稳"）
+ (CGFloat)transitionDamping;

/// 弹簧初速度
+ (CGFloat)transitionVelocity;

/// 旧页面退场的上移距离（视差感）
+ (CGFloat)transitionOldPageOffsetY;

/// 启动动效：单栏浮入距离基准
+ (CGFloat)launchSlideDistance;

/// 启动动效：三栏错峰间隔
+ (NSTimeInterval)launchStaggerDelay;

/// 启动动效：单栏动画时长
+ (NSTimeInterval)launchDuration;

/// 启动动效：弹簧阻尼
+ (CGFloat)launchDamping;

/// 读取偏好：当前过渡动效样式（无偏好时返回 SlideUp）
+ (GlassTransitionStyle)currentTransitionStyle;

/// 当前是否为深色外观
+ (BOOL)isDarkAppearance;

@end

NS_ASSUME_NONNULL_END
