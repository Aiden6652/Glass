//
//  GlassLiquidEffect.m
//  Amethyst
//
//  见 GlassLiquidEffect.h 的设计说明。
//
//  实现要点：
//    1. 只 swizzle UIVisualEffectView 的两个入口：
//         - initWithEffect:
//         - setEffect:            （上游有些地方先建空 view 再赋 effect）
//       收到信标 ⇒ installGlassBackdropInto:，并把 effect 换成 nil。
//    2. GlassEffectView 作为子视图插到 index 0（最底），不遮挡宿主内容；
//       但 UIVisualEffectView 的 contentView 会盖住最底子视图，因此这里改为插到
//       vev.contentView 之下不可行 —— 实测把 GlassEffectView 加在 vev 自身 subviews
//       的 index 0，随后把 contentView 提到最上，即可同时保证"玻璃在下、内容在上"。
//    3. 宿主圆角：若调用方给 UIVisualEffectView 设了 cornerRadius，跟随之；否则用
//       GlassTheme 的容器圆角。这样胶囊/卡片/面板各自形状正确。
//    4. 明暗切换：监听 GlassTheme 的刷新入口（上游 BackgroundManager 会调用
//       refreshGlassInViewHierarchy），GlassEffectView 自己会重刷配色，无需额外处理。
//

#import "GlassLiquidEffect.h"
#import "GlassEffectView.h"
#import "GlassTheme.h"
#import <objc/runtime.h>

/// 关联键：记录已装到某个 UIVisualEffectView 上的 GlassEffectView
static const void *kGlassLiquidBackdropKey = &kGlassLiquidBackdropKey;

@implementation GlassLiquidEffect

- (BOOL)isGlassLiquidBeacon { return YES; }

+ (instancetype)effectWithStrong:(BOOL)strong {
    GlassLiquidEffect *e = [[GlassLiquidEffect alloc] init];
    e.strong = strong;
    e.preferredCornerRadius = [GlassTheme containerCornerRadius];
    return e;
}

#pragma mark - 安装

/// 把 GlassEffectView 挂到 UIVisualEffectView 上（幂等）。
+ (void)adoptVisualEffectView:(UIVisualEffectView *)vev {
    if (vev == nil) { return; }
    // ★ 时序守门：在 initWithEffect: 内部调用时，UIKit 可能尚未建好 contentView/backdrop
    //   子视图（构建有延迟）。此时若立即插玻璃，contentView 可能取到 nil，导致
    //   "bringSubviewToFront" 落空、玻璃盖住后续内容。统一延后到主队列下一轮，
    //   此时系统层已就绪，可安全隐藏并叠玻璃。
    //   同一 vev 多次入队 ⇒ 用关联标记去重。
    static const void *kGlassLiquidPendingKey = &kGlassLiquidPendingKey;
    if (objc_getAssociatedObject(vev, kGlassLiquidPendingKey) != nil) { return; }
    objc_setAssociatedObject(vev, kGlassLiquidPendingKey, @YES, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    __weak UIVisualEffectView *weakVev = vev;
    dispatch_async(dispatch_get_main_queue(), ^{
        UIVisualEffectView *strongVev = weakVev;
        if (strongVev == nil) { return; }
        objc_setAssociatedObject(strongVev, kGlassLiquidPendingKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        [self installGlassBackdropInto:strongVev];
    });
}

/// 真正把 GlassEffectView 装进宿主（主队列下一轮执行 ⇒ 系统层已就绪）。
+ (void)installGlassBackdropInto:(UIVisualEffectView *)vev {
    if (vev == nil || vev.effect == nil) { return; }

    // 已经装过 ⇒ 只刷新档位/圆角，不重复插入
    GlassEffectView *existing = objc_getAssociatedObject(vev, kGlassLiquidBackdropKey);
    if ([existing isKindOfClass:[GlassEffectView class]] && existing.superview == vev) {
        [self applyGeometryTo:existing in:vev];
        return;
    }

    // ★ 关键：把系统自带的模糊子视图隐藏，避免与 GlassEffectView 双重模糊。
    //   UIVisualEffectView 的内部结构：contentView + 若干私有 "_UIVisualEffectBackdropView"。
    //   我们只保留 contentView(宿主内容容器)，其余系统效果层全部 alpha=0。
    UIView *cv = vev.contentView;
    for (UIView *sub in vev.subviews) {
        if (sub != cv) {
            sub.alpha = 0.0;
        }
    }

    GlassEffectView *glass = [[GlassEffectView alloc] initWithFrame:vev.bounds];
    glass.style = [GlassTheme glassStyle];              // 跟随用户设置档位
    glass.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    // 圆角优先取调用方给宿主设的圆角；为 0 时退回主题默认
    glass.cornerRadius = (vev.layer.cornerRadius > 0.5) ? vev.layer.cornerRadius
                                                       : [GlassTheme containerCornerRadius];
    glass.roundedCorners = (UIRectCornerTopLeft | UIRectCornerTopRight |
                            UIRectCornerBottomLeft | UIRectCornerBottomRight);
    // 纯装饰层，不拦截触摸
    glass.userInteractionEnabled = NO;
    // ★ 性能守门：折射采样层(截屏 + CIGaussianBlur)非常贵。小宿主(列表行/芯片)数量多，
    //   若统统用 Liquid 档会反复截全屏导致卡顿 ⇒ 小于 200pt 的宿主降到 Standard(无折射层)。
    if (vev.bounds.size.width < 200.0 || vev.bounds.size.height < 60.0) {
        glass.style = GlassStyleStandard;
    }

    // 玻璃插到最底(index 0)，contentView 保持在其之上 ⇒ "玻璃在下、内容在上"。
    [vev insertSubview:glass atIndex:0];
    if (cv != nil && cv.superview == vev) {
        [vev bringSubviewToFront:cv];
    }

    objc_setAssociatedObject(vev, kGlassLiquidBackdropKey, glass, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    [self applyGeometryTo:glass in:vev];
}

+ (void)applyGeometryTo:(GlassEffectView *)glass in:(UIVisualEffectView *)vev {
    glass.frame = vev.bounds;
    CGFloat hostRadius = vev.layer.cornerRadius;
    glass.cornerRadius = (hostRadius > 0.5) ? hostRadius : [GlassTheme containerCornerRadius];
    glass.roundedCorners = (UIRectCornerTopLeft | UIRectCornerTopRight |
                            UIRectCornerBottomLeft | UIRectCornerBottomRight);
}

#pragma mark - Swizzle

+ (void)installIfNeeded {
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        Class cls = [UIVisualEffectView class];
        SEL initSel = @selector(initWithEffect:);
        SEL setSel  = @selector(setEffect:);

        // ① initWithEffect:
        Method initM = class_getInstanceMethod(cls, initSel);
        IMP initOrig = method_getImplementation(initM);
        IMP initNew = imp_implementationWithBlock(^id(UIVisualEffectView *self_, UIVisualEffect *eff) {
            UIVisualEffectView *(*orig)(id, SEL, UIVisualEffect *) = (void *)initOrig;
            if ([eff isKindOfClass:[GlassLiquidEffect class]]) {
                // ★ 用真实轻量 effect 初始化 ⇒ 保证 contentView 一定存在
                //   (上游 CustomControlsViewController 等直接往 contentView 加子视图)。
                //   随后 adoptVisualEffectView 会隐藏系统效果层并叠上 GlassEffectView。
                UIVisualEffectView *vev = orig(self_, initSel,
                    [UIBlurEffect effectWithStyle:UIBlurEffectStyleSystemUltraThinMaterial]);
                [GlassLiquidEffect adoptVisualEffectView:vev];
                return vev;
            }
            return orig(self_, initSel, eff);
        });
        method_setImplementation(initM, initNew);

        // ② setEffect:
        Method setM = class_getInstanceMethod(cls, setSel);
        IMP setOrig = method_getImplementation(setM);
        IMP setNew = imp_implementationWithBlock(^void(UIVisualEffectView *self_, UIVisualEffect *eff) {
            void (*orig)(id, SEL, UIVisualEffect *) = (void *)setOrig;
            if ([eff isKindOfClass:[GlassLiquidEffect class]]) {
                orig(self_, setSel, [UIBlurEffect effectWithStyle:UIBlurEffectStyleSystemUltraThinMaterial]);
                [GlassLiquidEffect adoptVisualEffectView:self_];
                return;
            }
            // ★ 调用方显式清空 effect（eff == nil）⇒ 摘掉我们装的 GlassEffectView，
            //   否则会留下一层"擦不掉的玻璃"（原样交给系统 setEffect: 处理）。
            if (eff == nil) {
                GlassEffectView *mine = objc_getAssociatedObject(self_, kGlassLiquidBackdropKey);
                if ([mine isKindOfClass:[GlassEffectView class]]) { [mine removeFromSuperview]; }
                objc_setAssociatedObject(self_, kGlassLiquidBackdropKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
            }
            orig(self_, setSel, eff);
        });
        method_setImplementation(setM, setNew);

        NSLog(@"[glass] GlassLiquidEffect 已安装 ⇒ iOS<26 走 GlassEffectView 自绘液态玻璃");
    });
}

@end
