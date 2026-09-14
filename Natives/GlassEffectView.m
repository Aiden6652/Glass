//
//  GlassEffectView.m
//  Amethyst
//
//  Glass 液态玻璃渲染组件实现。详见 GlassEffectView.h 的设计说明。
//

#import "GlassEffectView.h"

/// 渲染层命名：用于反复刷新时精确移除，不误伤调用方自己的图层
static NSString * const kGlassBlurLayerName   = @"glass.effect.blur";
static NSString * const kGlassSpecularName    = @"glass.effect.specular";
static NSString * const kGlassSheenName       = @"glass.effect.sheen";
static NSString * const kGlassInnerGlowName   = @"glass.effect.innerglow";
static NSString * const kGlassFresnelName     = @"glass.effect.fresnel";
static NSString * const kGlassTintName        = @"glass.effect.tint";
static NSString * const kGlassBackdropName    = @"glass.effect.backdrop";

/// 折射采样的放大倍数。液态玻璃会把背景"压缩"，所以对模糊后的背景做轻微放大，
/// 视觉上就像透过一块厚玻璃看东西。数值越大折射越夸张，1.06 是接近 iOS 26 的观感。
static const CGFloat kGlassRefractionScale = 1.06;

#pragma mark - 私有实例变量
// 用类扩展承载私有 ivar，而不是写在 @implementation 的花括号里——
// 后者与头文件中 @property 隐式合成的 ivar 会产生
// "inconsistent number of instance variables specified" 编译错误。
@interface GlassEffectView () {
    UIVisualEffectView *_blurView;
    CAGradientLayer    *_tintLayer;
    UIImageView        *_backdropView;
    BOOL                _didSetup;
    CGSize              _lastBackdropSize;
}
@end

@implementation GlassEffectView

#pragma mark - 构造

+ (instancetype)glassViewWithStyle:(GlassStyle)style cornerRadius:(CGFloat)radius {
    GlassEffectView *v = [[GlassEffectView alloc] initWithFrame:CGRectZero];
    v.style = style;
    v.cornerRadius = radius;
    return v;
}

- (instancetype)initWithFrame:(CGRect)frame {
    self = [super initWithFrame:frame];
    if (self) {
        [self commonInit];
    }
    return self;
}

- (instancetype)initWithCoder:(NSCoder *)coder {
    self = [super initWithCoder:coder];
    if (self) {
        [self commonInit];
    }
    return self;
}

- (void)commonInit {
    _style = [GlassTheme glassStyle];  // 默认跟随用户设置
    _cornerRadius = [GlassTheme containerCornerRadius];
    _roundedCorners = (UIRectCornerTopLeft | UIRectCornerTopRight |
                       UIRectCornerBottomLeft | UIRectCornerBottomRight);
    _showBorder = YES;
    _showOuterShadow = NO;
    self.backgroundColor = [UIColor clearColor];
    self.userInteractionEnabled = NO;   // 纯装饰层，不拦截触摸
    self.clipsToBounds = NO;
}

- (void)didMoveToWindow {
    [super didMoveToWindow];
    if (!_didSetup) {
        _didSetup = YES;
        [self rebuildLayers];
    }
    // 折射快照必须在窗口绘制完成之后才截得到内容。
    // 首次挂载时视图还没上屏，立刻截图会得到空白，所以延后一帧再采。
    if (self.window) {
        dispatch_async(dispatch_get_main_queue(), ^{
            [self refreshBackdropImage];
        });
    }
}

- (void)layoutSubviews {
    [super layoutSubviews];
    [self layoutGlassSublayers];

    // 尺寸变化（旋转 / 分屏）后原来的折射快照已失效，需要按新尺寸重采。
    // 节流处理：连续 layout 时只保留最后一次，避免旋转过程中反复截图导致卡顿。
    if (_backdropView && !CGSizeEqualToSize(_lastBackdropSize, self.bounds.size)) {
        _lastBackdropSize = self.bounds.size;
        __weak typeof(self) weakSelf = self;
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.05 * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{
            [weakSelf refreshBackdropImage];
        });
    }
}

#pragma mark - 属性

- (void)setStyle:(GlassStyle)style {
    if (_style == style) return;
    _style = style;
    [self rebuildLayers];
}

- (void)setCornerRadius:(CGFloat)cornerRadius {
    if (fabs(_cornerRadius - cornerRadius) < 0.01) return;
    _cornerRadius = cornerRadius;
    [self layoutGlassSublayers];
}

- (void)setRoundedCorners:(UIRectCorner)roundedCorners {
    _roundedCorners = roundedCorners;
    [self layoutGlassSublayers];
}

- (void)setShowOuterShadow:(BOOL)showOuterShadow {
    _showOuterShadow = showOuterShadow;
    [self applyOuterShadow];
}

- (void)setShowBorder:(BOOL)showBorder {
    _showBorder = showBorder;
    [self layoutGlassSublayers];
}

#pragma mark - 图层构建

/// 按当前档位重建全部渲染层。
/// 档位越低，叠加的层数越少——这既是视觉上的"玻璃感"强弱，也是性能上的调节旋钮。
- (void)rebuildLayers {
    // 具体档位数值统一由 GlassTheme 提供，保证设置页调档与渲染表现严格一致
    NSInteger layers = [GlassTheme glassLayerCountForStyle:self.style];

    // 清空旧层（只删自己命名的层，保留调用方可能添加的内容）
    NSMutableArray<CALayer *> *toRemove = [NSMutableArray array];
    for (CALayer *sub in self.layer.sublayers) {
        if ([sub.name hasPrefix:@"glass.effect."]) [toRemove addObject:sub];
    }
    for (CALayer *l in toRemove) [l removeFromSuperlayer];
    if (_blurView) { [_blurView removeFromSuperview]; _blurView = nil; }
    _tintLayer = nil;
    _backdropView = nil;

    if (layers <= 0) {
        self.backgroundColor = [UIColor clearColor];
        [self applyOuterShadow];
        return;
    }

    // ① 折射层：以自身 frame 截取屏幕内容做模糊+放大，模拟厚玻璃的折射。
    //    只在"强"和"液态玻璃"档启用——它是整套方案里最贵的一层。
    if ([GlassTheme glassUsesRefractionForStyle:self.style]) {
        _backdropView = [[UIImageView alloc] initWithFrame:self.bounds];
        _backdropView.contentMode = UIViewContentModeScaleAspectFill;
        _backdropView.userInteractionEnabled = NO;
        _backdropView.layer.name = kGlassBackdropName;
        _backdropView.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
        [self addSubview:_backdropView];
    }

    // ② 模糊层：所有非关闭档位都有，是"磨砂"的基础
    if (layers >= 2) {
        UIBlurEffectStyle blurStyle = [GlassTheme blurEffectStyle];
        UIBlurEffect *effect = [UIBlurEffect effectWithStyle:blurStyle];
        _blurView = [[UIVisualEffectView alloc] initWithEffect:effect];
        _blurView.frame = self.bounds;
        _blurView.userInteractionEnabled = NO;
        _blurView.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
        [self insertSubview:_blurView atIndex:0];
    }

    // ③ 有色玻璃：仅液态玻璃档叠加极淡的冷色调，模拟 iOS 26 的 tinted glass
    if ([GlassTheme glassUsesTintForStyle:self.style]) {
        _tintLayer = [CAGradientLayer layer];
        _tintLayer.name = kGlassTintName;
        _tintLayer.colors = @[
            (id)[GlassTheme glassTintTopColor].CGColor,
            (id)[GlassTheme glassTintBottomColor].CGColor
        ];
        _tintLayer.startPoint = CGPointMake(0.5, 0.0);
        _tintLayer.endPoint   = CGPointMake(0.5, 1.0);
        [self.layer addSublayer:_tintLayer];
    }

    // ④ 镜面高光：右上斜向亮带（模拟主光源）+ 顶部弧形高光
    if (layers >= 3) {
        CAGradientLayer *specular = [CAGradientLayer layer];
        specular.name = kGlassSpecularName;
        specular.colors = @[
            (id)[UIColor clearColor].CGColor,
            (id)[GlassTheme glassSpecularColor].CGColor,
            (id)[UIColor clearColor].CGColor
        ];
        specular.locations = @[@0.0, @0.5, @1.0];
        // 斜向：左上 → 右下，让高光沿玻璃对角铺开
        specular.startPoint = CGPointMake(0.0, 0.0);
        specular.endPoint   = CGPointMake(1.0, 1.0);
        [self.layer addSublayer:specular];
    }
    if (layers >= 4) {
        CAGradientLayer *sheen = [CAGradientLayer layer];
        sheen.name = kGlassSheenName;
        sheen.colors = @[
            (id)[GlassTheme glassTopSheenColor].CGColor,
            (id)[UIColor clearColor].CGColor
        ];
        sheen.locations = @[@0.0, @0.42];
        sheen.startPoint = CGPointMake(0.5, 0.0);
        sheen.endPoint   = CGPointMake(0.5, 1.0);
        [self.layer addSublayer:sheen];
    }

    // ⑤ 内发光：模拟玻璃厚度带来的边缘泛光。
    //    这里刻意不用 radial 渐变——radial 是"中心亮、边缘暗"，与我们要的
    //    "边缘亮、中心透"正好相反。改用一条沿对角线铺开的线性亮带，
    //    配合模糊层的半透明质感，观感上更接近厚玻璃边缘的聚光。
    if (layers >= 5) {
        CAGradientLayer *inner = [CAGradientLayer layer];
        inner.name = kGlassInnerGlowName;
        inner.colors = @[
            (id)[GlassTheme glassInnerGlowColor].CGColor,
            (id)[UIColor clearColor].CGColor,
            (id)[GlassTheme glassInnerGlowColor].CGColor
        ];
        // 两端亮、中间透 → 左右两侧形成对称的贴边泛光
        inner.locations = @[@0.0, @0.5, @1.0];
        inner.startPoint = CGPointMake(0.0, 0.5);
        inner.endPoint   = CGPointMake(1.0, 0.5);
        [self.layer addSublayer:inner];
    }

    [self applyOuterShadow];
    [self layoutGlassSublayers];
    [self refreshBackdropImage];
}

/// 外投影：单独的 shadowPath，避免触发离屏渲染
- (void)applyOuterShadow {
    if (!_showOuterShadow || self.style == GlassStyleOff) {
        self.layer.shadowOpacity = 0.0;
        // 必须用 NULL 而不是 nil：shadowPath 是 CGPathRef（C 指针），
        // ARC 下 nil 属于 id 类型，需要桥接转换才能赋值，否则编译报错。
        self.layer.shadowPath = NULL;
        return;
    }
    self.layer.shadowColor   = [GlassTheme glassShadowColor].CGColor;
    self.layer.shadowOpacity = (float)[GlassTheme glassShadowOpacity];
    self.layer.shadowRadius  = [GlassTheme glassShadowRadius];
    self.layer.shadowOffset  = CGSizeMake(0, [GlassTheme glassShadowOffsetY]);
    self.layer.shadowPath    = [self glassPath].CGPath;
}

/// 当前形状路径（支持部分圆角）
- (UIBezierPath *)glassPath {
    if (self.roundedCorners == (UIRectCornerTopLeft | UIRectCornerTopRight |
                                UIRectCornerBottomLeft | UIRectCornerBottomRight)) {
        return [UIBezierPath bezierPathWithRoundedRect:self.bounds
                                          cornerRadius:self.cornerRadius];
    }
    return [UIBezierPath bezierPathWithRoundedRect:self.bounds
                                 byRoundingCorners:self.roundedCorners
                                       cornerRadii:CGSizeMake(self.cornerRadius, self.cornerRadius)];
}

/// 同步所有子层的 frame / 圆角 / 描边路径
- (void)layoutGlassSublayers {
    if (self.bounds.size.width <= 0 || self.bounds.size.height <= 0) return;

    UIBezierPath *path = [self glassPath];
    CGPathRef cgPath = path.CGPath;

    // 关闭隐式动画：旋转/尺寸变化时玻璃层必须跟手，不能"追着跑"
    [CATransaction begin];
    [CATransaction setDisableActions:YES];

    _backdropView.frame = self.bounds;

    if (_blurView) {
        _blurView.frame = self.bounds;
        // mask 复用：只在路径真正变化时重建，避免每次 layout 都新建一个 CAShapeLayer
        CAShapeLayer *mask = (CAShapeLayer *)_blurView.layer.mask;
        if (![mask isKindOfClass:[CAShapeLayer class]]) {
            mask = [CAShapeLayer layer];
            mask.fillColor = [UIColor blackColor].CGColor;
            _blurView.layer.mask = mask;
        }
        mask.path = cgPath;
        mask.frame = self.bounds;
    }

    for (CALayer *sub in self.layer.sublayers) {
        if ([sub.name isEqualToString:kGlassSpecularName] ||
            [sub.name isEqualToString:kGlassTintName]) {
            sub.frame = self.bounds;
            sub.cornerRadius = self.cornerRadius;
            sub.masksToBounds = YES;
            continue;
        }
        if ([sub.name isEqualToString:kGlassSheenName] ||
            [sub.name isEqualToString:kGlassInnerGlowName]) {
            sub.frame = self.bounds;
            sub.cornerRadius = self.cornerRadius;
            sub.masksToBounds = YES;
            continue;
        }
        if ([sub.name isEqualToString:kGlassFresnelName]) {
            CAShapeLayer *f = (CAShapeLayer *)sub;
            f.frame = self.bounds;
            f.path = cgPath;
            continue;
        }
    }

    // 菲涅尔描边：按需增删
    CAShapeLayer *fresnel = nil;
    for (CALayer *sub in self.layer.sublayers) {
        if ([sub.name isEqualToString:kGlassFresnelName]) { fresnel = (CAShapeLayer *)sub; break; }
    }
    if (_showBorder && self.style != GlassStyleOff) {
        if (!fresnel) {
            fresnel = [CAShapeLayer layer];
            fresnel.name = kGlassFresnelName;
            fresnel.fillColor = [UIColor clearColor].CGColor;
            [self.layer addSublayer:fresnel];
        }
        fresnel.strokeColor = [GlassTheme glassBorderColor].CGColor;
        fresnel.lineWidth   = [GlassTheme borderWidth] * [GlassTheme glassBorderWidthScaleForStyle:self.style];
        fresnel.path = cgPath;
        fresnel.frame = self.bounds;
        fresnel.contentsScale = UIScreen.mainScreen.scale;
    } else if (fresnel) {
        [fresnel removeFromSuperlayer];
    }

    // 注意：CGPathRef 是 C 指针，不能与 nil（id 类型）写在同一个三元表达式里，
    // 否则 "incompatible operand types" 编译失败。必须显式判空。
    self.layer.shadowPath = _showOuterShadow ? cgPath : NULL;

    [CATransaction commit];
}

#pragma mark - 折射

/// 截取自身在屏幕上的区域，做高斯模糊 + 放大，作为折射底层。
/// 说明：真正的液态玻璃是实时采样并折射背景，iOS 14 没有公开 API 能做到，
/// 这里用"快照 + 放大"逼近——因为它同时也是被模糊层盖住的，观感非常接近。
- (void)refreshBackdropImage {
    if (!_backdropView || !self.window) return;

    UIView *host = self.superview ?: self;
    CGRect inWindow = [self convertRect:self.bounds toView:self.window];
    if (inWindow.size.width < 1 || inWindow.size.height < 1) return;

    // 向外扩一圈再截，避免放大后边缘露白
    CGFloat pad = MAX(inWindow.size.width, inWindow.size.height) * (kGlassRefractionScale - 1.0) / 2.0 + 2.0;
    CGRect captureRect = CGRectInset(inWindow, -pad, -pad);

    UIGraphicsBeginImageContextWithOptions(captureRect.size, NO, 0.0);
    CGContextRef ctx = UIGraphicsGetCurrentContext();
    if (ctx) {
        CGContextTranslateCTM(ctx, -captureRect.origin.x, -captureRect.origin.y);
        [self.window drawViewHierarchyInRect:self.window.bounds afterScreenUpdates:NO];
    }
    UIImage *snapshot = UIGraphicsGetImageFromCurrentImageContext();
    UIGraphicsEndImageContext();
    if (!snapshot) return;

    // 高斯模糊：CoreImage 较重，这里用小半径 CIGaussianBlur，只做一次并在旋转后重做
    UIImage *blurred = [self blurredImage:snapshot radius:[GlassTheme glassRefractionBlurRadius]];
    _backdropView.image = blurred;
    _backdropView.transform = CGAffineTransformMakeScale(kGlassRefractionScale, kGlassRefractionScale);
    (void)host;
}

- (UIImage *)blurredImage:(UIImage *)image radius:(CGFloat)radius {
    if (radius <= 0.01) return image;
    CIImage *input = [[CIImage alloc] initWithImage:image];
    CIFilter *filter = [CIFilter filterWithName:@"CIGaussianBlur"];
    if (!filter) return image;
    [filter setValue:input forKey:kCIInputImageKey];
    [filter setValue:@(radius) forKey:kCIInputRadiusKey];
    CIImage *output = filter.outputImage;
    if (!output) return image;

    static CIContext *ctx = nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        ctx = [CIContext contextWithOptions:@{kCIContextUseSoftwareRenderer: @NO}];
    });
    CGImageRef cg = [ctx createCGImage:output fromRect:input.extent];
    if (!cg) return image;
    UIImage *result = [UIImage imageWithCGImage:cg scale:image.scale orientation:image.imageOrientation];
    CGImageRelease(cg);
    return result;
}

#pragma mark - 配色刷新

- (void)refreshColors {
    for (CALayer *sub in self.layer.sublayers) {
        if (![sub.name hasPrefix:@"glass.effect."]) continue;

        if ([sub.name isEqualToString:kGlassFresnelName]) {
            ((CAShapeLayer *)sub).strokeColor = [GlassTheme glassBorderColor].CGColor;
        } else if ([sub.name isEqualToString:kGlassSpecularName]) {
            ((CAGradientLayer *)sub).colors = @[
                (id)[UIColor clearColor].CGColor,
                (id)[GlassTheme glassSpecularColor].CGColor,
                (id)[UIColor clearColor].CGColor
            ];
        } else if ([sub.name isEqualToString:kGlassSheenName]) {
            ((CAGradientLayer *)sub).colors = @[
                (id)[GlassTheme glassTopSheenColor].CGColor,
                (id)[UIColor clearColor].CGColor
            ];
        } else if ([sub.name isEqualToString:kGlassInnerGlowName]) {
            // 必须与 rebuildLayers 中的三色结构保持一致，否则明暗切换后渐变会跳变
            ((CAGradientLayer *)sub).colors = @[
                (id)[GlassTheme glassInnerGlowColor].CGColor,
                (id)[UIColor clearColor].CGColor,
                (id)[GlassTheme glassInnerGlowColor].CGColor
            ];
        } else if ([sub.name isEqualToString:kGlassTintName]) {
            ((CAGradientLayer *)sub).colors = @[
                (id)[GlassTheme glassTintTopColor].CGColor,
                (id)[GlassTheme glassTintBottomColor].CGColor
            ];
        }
    }
    [self applyOuterShadow];
    [self refreshBackdropImage];
}

+ (void)refreshGlassInViewHierarchy:(UIView *)rootView {
    if (!rootView) return;
    if ([rootView isKindOfClass:[GlassEffectView class]]) {
        [(GlassEffectView *)rootView refreshColors];
    }
    for (UIView *sub in rootView.subviews) {
        [self refreshGlassInViewHierarchy:sub];
    }
}

#pragma mark - 一键应用

+ (void)applyGlassToView:(UIView *)view style:(GlassStyle)style cornerRadius:(CGFloat)radius {
    [self applyGlassToView:view style:style cornerRadius:radius
            roundedCorners:(UIRectCornerTopLeft | UIRectCornerTopRight |
                            UIRectCornerBottomLeft | UIRectCornerBottomRight)];
}

+ (void)applyGlassToView:(UIView *)view
                   style:(GlassStyle)style
            cornerRadius:(CGFloat)radius
          roundedCorners:(UIRectCorner)corners {
    if (!view) return;
    [self removeGlassFromView:view];
    if (style == GlassStyleOff) return;

    GlassEffectView *glass = [[GlassEffectView alloc] initWithFrame:view.bounds];
    glass.style = style;
    glass.cornerRadius = radius;
    glass.roundedCorners = corners;
    glass.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    // 插到最底层，绝不遮挡调用方已有的内容
    [view insertSubview:glass atIndex:0];
}

+ (void)removeGlassFromView:(UIView *)view {
    if (!view) return;
    for (UIView *sub in [view.subviews copy]) {
        if ([sub isKindOfClass:[GlassEffectView class]]) {
            [sub removeFromSuperview];
        }
    }
}

@end
