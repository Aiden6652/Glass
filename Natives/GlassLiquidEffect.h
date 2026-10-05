//
//  GlassLiquidEffect.h
//  Amethyst
//
//  ★ 让 iOS < 26 的设备也能用到"液态玻璃"观感。
//
//  背景：
//    iOS 26 的 UIGlassEffect 能直接得到系统级液态玻璃，但 Amethyst/Glass 最低支持
//    iOS 14。上游(Amethyst-iOS-MyRemastered)的做法是：iOS < 26 一律回退系统原生材质
//    (UIBlurEffect)，即"旧系统躺平用系统毛玻璃"。
//    Glass 的目标不同：iOS < 26 时改用 GlassEffectView（纯代码 6 层合成）复刻液态
//    玻璃，保证新旧系统观感一致。
//
//  怎么做（关键）：
//    上游所有玻璃调用都收敛到了唯一入口 AmeGlassEffect(fallbackStyle)（见
//    UIKit+GlassSurface.h），返回值是 UIVisualEffect，最终被塞进
//    [[UIVisualEffectView alloc] initWithEffect:…]。
//    自定义 UIVisualEffect 子类不能被 UIKit 正确渲染（UIKit 只认系统 effect），
//    所以这里用一个"信标 effect"——它本身不参与渲染，只作为记号；随后 swizzle
//    UIVisualEffectView 的 initWithEffect:，凡收到信标者，自动在自身内部挂一层
//    GlassEffectView，并把 effect 换成 nil（避免系统再叠一层普通模糊）。
//
//  结果：一处改造 ⇒ 全局(含 11 处直接调用 + 三个分发入口)自动生效，界面代码零改动。
//

#import <UIKit/UIKit.h>

NS_ASSUME_NONNULL_BEGIN

/// 信标 effect。仅用于在 UIVisualEffectView 内部触发 GlassEffectView 安装。
@interface GlassLiquidEffect : UIVisualEffect

/// 是否为信标（swizzle 里用它做判定，避免误伤系统 effect）
@property (nonatomic, readonly) BOOL isGlassLiquidBeacon;
/// 建设信标时希望的圆角（兜底；实际圆角优先取宿主 UIVisualEffectView 的 cornerRadius）
@property (nonatomic, assign) CGFloat preferredCornerRadius;
/// 是否"强"玻璃（决定 GlassStyle 档位）
@property (nonatomic, assign) BOOL strong;

/// 创建信标
+ (instancetype)effectWithStrong:(BOOL)strong;

/// 安装 swizzle（幂等，App 启动早期调用一次即可）
+ (void)installIfNeeded;

/// 请求给 UIVisualEffectView 装 GlassEffectView（幂等；内部会延后到主队列下一轮，
/// 等 UIKit 建好 contentView/backdrop 后再安装，避免取到 nil contentView）。
/// 暴露出来便于分发层在需要时手动触发。
+ (void)adoptVisualEffectView:(UIVisualEffectView *)vev;

/// 同步安装（已在主队列且系统层就绪时用；adoptVisualEffectView: 内部调用它）。
+ (void)installGlassBackdropInto:(UIVisualEffectView *)vev;

@end

NS_ASSUME_NONNULL_END
