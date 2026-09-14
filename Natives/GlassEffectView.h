//
//  GlassEffectView.h
//  Amethyst
//
//  Glass 液态玻璃（Liquid Glass）渲染组件。
//
//  背景：iOS 26 的 UIGlassEffect 能直接得到"液态玻璃"，但 Glass 最低支持 iOS 14，
//  不能直接使用。本组件用「多层合成」把液态玻璃的视觉要素在 iOS 14+ 上复刻出来：
//
//    1. 折射层——用一条从屏幕外采样背景的快照做高斯模糊 + 放大，模拟玻璃把
//       背景"压缩折射"的效果（这是液态玻璃与普通毛玻璃最大的视觉差别）
//    2. 模糊层——UIVisualEffectView，提供基础磨砂
//    3. 镜面高光——顶部弧形亮带 + 左上角斜向高光，模拟玻璃的镜面反射
//    4. 菲涅尔描边——边缘亮、内部透，模拟玻璃厚度
//    5. 内发光 + 外投影——让玻璃"浮"在背景之上
//    6. 有色玻璃——可选色调，模拟 iOS 26 的 tinted glass
//
//  支持两种使用方式：
//    A. 主动：创建 GlassEffectView 作为子视图（用于给任意 UIView 加玻璃背景）
//    B. 被动：类方法 applyGlassToView:style: 一键给已有视图套玻璃（不改层级结构）
//
//  所有档位（GlassStyle）影响的是"玻璃有多像玻璃"，而不是开关玻璃——
//  GlassStyleOff 会退化为完全平面，让用户在性能吃紧时彻底关掉。
//

#import <UIKit/UIKit.h>
#import "GlassTheme.h"

NS_ASSUME_NONNULL_BEGIN

@interface GlassEffectView : UIView

/// 玻璃档位。默认取偏好 general.glass_style，未设置时为 Liquid。
@property (nonatomic, assign) GlassStyle style;

/// 圆角。设置后会同步到模糊层、高光层与外投影的裁剪路径。
@property (nonatomic, assign) CGFloat cornerRadius;

/// 只保留部分圆角（例如左侧栏只圆左边两角）。默认四个角全圆。
@property (nonatomic, assign) UIRectCorner roundedCorners;

/// 外投影。默认关闭（由调用方按需开启，避免叠加过多阴影显得脏）。
/// 开启时会同时开启 masksToBounds=NO，注意此时子视图不会被裁剪。
@property (nonatomic, assign) BOOL showOuterShadow;

/// 菲涅尔描边（玻璃边缘的亮线），默认开启。
@property (nonatomic, assign) BOOL showBorder;

/// 便捷构造：指定档位与圆角
+ (instancetype)glassViewWithStyle:(GlassStyle)style cornerRadius:(CGFloat)radius;

/// 一键给已有视图套上玻璃观感（不改动其 subviews 结构，只在最底层插入渲染层）。
/// 会移除该视图上此前由本类插入的渲染层，因此可反复调用以刷新档位。
+ (void)applyGlassToView:(UIView *)view style:(GlassStyle)style cornerRadius:(CGFloat)radius;

/// 同上，但保留指定的圆角方向（用于左右侧栏）。
+ (void)applyGlassToView:(UIView *)view
                   style:(GlassStyle)style
            cornerRadius:(CGFloat)radius
          roundedCorners:(UIRectCorner)corners;

/// 移除本类给视图插入的全部玻璃渲染层。
+ (void)removeGlassFromView:(UIView *)view;

/// 明暗模式切换后刷新所有玻璃层的 CGColor（动态 UIColor 的 CGColor 不会自动跟随）。
- (void)refreshColors;

/// 全局：刷新某个视图及其所有子视图中已应用的玻璃层配色。
+ (void)refreshGlassInViewHierarchy:(UIView *)rootView;

@end

NS_ASSUME_NONNULL_END
