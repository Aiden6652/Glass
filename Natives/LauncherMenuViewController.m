#import "LauncherMenuViewController.h"
#import "LauncherPreferencesViewController.h"
#import "LauncherPreferences.h"
#import "VersionManagerViewController.h"
#import "ProfileSettingsViewController.h"
#import "PLProfiles.h"
#import "BackgroundManager.h"
#import "GlassTheme.h"
#import "utils.h"

@interface LauncherMenuViewController ()

@property(nonatomic, strong) UIView *sidebarView;
@property(nonatomic, strong) UIStackView *menuStackView;
@property(nonatomic, strong) NSArray<NSDictionary *> *menuItems;
@property(nonatomic, assign) NSInteger selectedIndex;

@end

@implementation LauncherMenuViewController

#pragma mark - Lifecycle

- (void)viewDidLoad {
    [super viewDidLoad];

    self.view.backgroundColor = [UIColor clearColor];

    // 适配自定义启动器背景：将当前视图控制器透明化，让全局背景（图片/视频）能够透出显示。
    // 即使本控制器在 LauncherRootViewController 中作为子 VC 添加，仍需在自身 viewDidLoad 中调用。
    [[BackgroundManager sharedManager] makeViewControllerTransparent:self];

    // 监听背景 UI 效果变化通知：当用户在背景设置中切换毛玻璃/半透明或调整透明度时，
    // 重新调用 makeViewControllerTransparent 以应用最新的视觉效果，保证背景始终正确透出。
    [[NSNotificationCenter defaultCenter] addObserver:self
                                             selector:@selector(reapplyBackgroundEffect)
                                                 name:@"BackgroundUIEffectChanged"
                                               object:nil];

    // 监听外观变更（字体颜色变化时刷新菜单按钮颜色）
    [[NSNotificationCenter defaultCenter] addObserver:self
                                             selector:@selector(applyCustomAppearance)
                                                 name:@"LauncherAppearanceChanged"
                                               object:nil];

    // 监听玻璃质感档位变更：档位会改变按钮叠加的图层数量，需整组重建
    [[NSNotificationCenter defaultCenter] addObserver:self
                                             selector:@selector(rebuildMenuButtonsForGlassStyle)
                                                 name:@"LauncherGlassStyleChanged"
                                               object:nil];

    // 菜单项配置
    // 联机相关入口暂不显示（需进一步完善）
    // case 3 为"联机"（陶瓦联机 Terracotta，与 HMCL/FCL/ZL2 互通）
    // case 4 为"ZeroTier 联机"（独立入口，与陶瓦联机并列，便于用户直接进入 ZeroTier 界面）
    // case 5 为"设置"
    // 键位调整界面已移到设置页面中
    self.menuItems = @[
        @{@"icon": @"house.fill", @"title": @" ", @"index": @0},
        @{@"icon": @"arrow.down.circle.fill", @"title": @" ", @"index": @1},
        @{@"icon": @"sparkles", @"title": @" ", @"index": @2},
        @{@"icon": @"puzzlepiece.fill", @"title": @" ", @"index": @3},
        // 暂时移除两个联机图标，恢复时取消下方两行注释并将设置项 index 改回 @6
        // @{@"icon": @"antenna.radiowaves.left.and.right", @"title": @" ", @"index": @4},
        // @{@"icon": @"network", @"title": @" ", @"index": @5},
        @{@"icon": @"gearshape.fill", @"title": @" ", @"index": @4}
    ];
    
    self.selectedIndex = 0;
    
    [self setupSidebar];
}

#pragma mark - UI Setup

- (void)setupSidebar {
    self.sidebarView = [[UIView alloc] init];
    self.sidebarView.translatesAutoresizingMaskIntoConstraints = NO;
    self.sidebarView.backgroundColor = [UIColor clearColor];
    [self.view addSubview:self.sidebarView];

    [NSLayoutConstraint activateConstraints:@[
        [self.sidebarView.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor],
        [self.sidebarView.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor],
        [self.sidebarView.topAnchor constraintEqualToAnchor:self.view.topAnchor],
        [self.sidebarView.bottomAnchor constraintEqualToAnchor:self.view.bottomAnchor]
    ]];

    // 创建垂直均分的 UIStackView，替代固定偏移布局。
    // 之前用 startY=60 + 固定间距 15，5 个按钮总高 370pt，在 iPhone 横屏（卡片高度不足）
    // 时第 5 个按钮（设置）被卡片 masksToBounds 裁剪，且按钮只锚定 top 无 bottom 约束，
    // 下方留出大块空白加剧"下面空隙大"的观感。
    // 改用 UIStackView EqualSpacing 让按钮在可用空间内垂直均匀分布，上下留白相同，
    // 无论卡片高度如何都能完整显示所有按钮，且消除固定 startY 导致的下方空白。
    self.menuStackView = [[UIStackView alloc] init];
    self.menuStackView.translatesAutoresizingMaskIntoConstraints = NO;
    self.menuStackView.axis = UILayoutConstraintAxisVertical;
    self.menuStackView.distribution = UIStackViewDistributionEqualSpacing;
    self.menuStackView.alignment = UIStackViewAlignmentCenter;
    self.menuStackView.spacing = 8;
    [self.sidebarView addSubview:self.menuStackView];

    CGFloat buttonSize = [GlassTheme menuButtonSize];
    for (NSInteger i = 0; i < self.menuItems.count; i++) {
        NSDictionary *item = self.menuItems[i];
        UIButton *btn = [self createMenuButtonWithItem:item index:i];
        [self.menuStackView addArrangedSubview:btn];
        [NSLayoutConstraint activateConstraints:@[
            [btn.widthAnchor constraintEqualToConstant:buttonSize],
            [btn.heightAnchor constraintEqualToConstant:buttonSize]
        ]];
    }

    [NSLayoutConstraint activateConstraints:@[
        [self.menuStackView.leadingAnchor constraintEqualToAnchor:self.sidebarView.leadingAnchor],
        [self.menuStackView.trailingAnchor constraintEqualToAnchor:self.sidebarView.trailingAnchor],
        [self.menuStackView.topAnchor constraintEqualToAnchor:self.sidebarView.topAnchor constant:8],
        [self.menuStackView.bottomAnchor constraintEqualToAnchor:self.sidebarView.bottomAnchor constant:-8],
        [self.menuStackView.centerXAnchor constraintEqualToAnchor:self.sidebarView.centerXAnchor]
    ]];
}

- (UIButton *)createMenuButtonWithItem:(NSDictionary *)item index:(NSInteger)index {
    UIButton *btn = [UIButton buttonWithType:UIButtonTypeSystem];
    btn.translatesAutoresizingMaskIntoConstraints = NO;
    btn.tag = index;

    // 设置图标
    UIImage *icon = [UIImage systemImageNamed:item[@"icon"]];
    [btn setImage:icon forState:UIControlStateNormal];

    // 设置颜色 - 选中项高亮
    // 支持自定义字体颜色：用户在设置中配置 general.text_color 后，
    // 未选中项使用自定义颜色，选中项保持高亮蓝色
    UIColor *normalColor = [self menuNormalColor];
    UIColor *accent = accentColor();
    if (index == self.selectedIndex) {
        btn.tintColor = accent;
    } else {
        btn.tintColor = normalColor;
    }

    // 设置标题（在图标下方）
    btn.titleLabel.font = [GlassTheme menuTitleFont];
    [btn setTitle:item[@"title"] forState:UIControlStateNormal];
    [btn setTitleColor:(index == self.selectedIndex) ? accent : normalColor forState:UIControlStateNormal];
    
    // 垂直布局：图标在上，文字在下
    btn.contentHorizontalAlignment = UIControlContentHorizontalAlignmentCenter;
    btn.contentVerticalAlignment = UIControlContentVerticalAlignmentCenter;
    btn.titleEdgeInsets = UIEdgeInsetsMake(30, -30, 0, 0);
    btn.imageEdgeInsets = UIEdgeInsetsMake(-10, 0, 0, 0);
    
    [btn addTarget:self action:@selector(menuButtonTapped:) forControlEvents:UIControlEventTouchUpInside];

    // ===== Glass 玻璃质感 =====
    // 实现说明：不用 UIVisualEffectView —— 它会插在按钮与图标之间，既影响点击区域，
    // 又要额外处理圆角裁剪，收益不如实现成本。这里改用「半透明填充 + 描边 + 顶部渐变高光」
    // 多层叠加模拟玻璃：视觉上接近毛玻璃，且完全不影响按钮原有的图标/文字布局与点击。
    //
    // 液态玻璃档位（Strong / Liquid）额外叠加一层「斜向镜面高光」与「边缘内发光」，
    // 让按钮也有玻璃厚度感；标准档保持原来的单层顶部高光。
    GlassStyle glassStyle = [GlassTheme glassStyle];
    if (glassStyle == GlassStyleOff) {
        // 关闭档：按钮完全平面化，只留选中态的颜色区分
        btn.layer.cornerRadius = [GlassTheme menuButtonCornerRadius];
        btn.layer.masksToBounds = NO;
        btn.layer.borderWidth = 0.0;
        btn.backgroundColor = [UIColor clearColor];
    } else {
        [self applyGlassLayersToButton:btn selected:(index == self.selectedIndex)];
    }

    // 选中态直接应用一次，保证首帧即正确
    [self applyGlassSelectionStyleToButton:btn selected:(index == self.selectedIndex)];

    return btn;
}

/// 应用 Glass 选中态：选中时叠加半透明高光 + 柔和外发光，未选中时回到常态玻璃底。
/// 注意：高光层（glassSheen）始终保留，仅调整按钮自身的 backgroundColor / border / shadow，
/// 避免反复增删子层导致图层堆积。
- (void)applyGlassSelectionStyleToButton:(UIButton *)btn selected:(BOOL)selected {
    if (!btn) return;
    BOOL glassOff = ([GlassTheme glassStyle] == GlassStyleOff);

    if (selected) {
        btn.backgroundColor = [GlassTheme menuSelectionHighlightColor];
        btn.layer.borderColor = accentColor().CGColor;
        btn.layer.shadowColor = [GlassTheme menuSelectionGlowColor].CGColor;
        btn.layer.shadowOpacity = 1.0;
        btn.layer.shadowRadius = glassOff ? 0.0 : 12.0;
        btn.layer.shadowOffset = CGSizeZero;
    } else {
        btn.backgroundColor = glassOff ? [UIColor clearColor]
                                      : [GlassTheme menuButtonGlassFillColor];
        btn.layer.borderColor = glassOff ? [UIColor clearColor].CGColor
                                         : [GlassTheme menuButtonBorderColor].CGColor;
        btn.layer.shadowOpacity = 0.0;
        btn.layer.shadowRadius = 0.0;
    }
}

#pragma mark - Actions

- (void)menuButtonTapped:(UIButton *)sender {
    NSInteger index = sender.tag;

    // FCL 风格：选中菜单项时添加弹跳动画（ScaleX/ScaleY 弹跳，OvershootInterpolator 效果）
    [UIView animateWithDuration:0.3
                          delay:0
         usingSpringWithDamping:0.5
          initialSpringVelocity:0.8
                        options:UIViewAnimationOptionAllowUserInteraction
                     animations:^{
        sender.transform = CGAffineTransformMakeScale(1.2, 1.2);
    } completion:^(BOOL finished) {
        [UIView animateWithDuration:0.2
                              delay:0
                            options:UIViewAnimationOptionCurveEaseOut
                         animations:^{
            sender.transform = CGAffineTransformIdentity;
        } completion:nil];
    }];

    // 更新选中状态
    self.selectedIndex = index;
    [self updateButtonColors];

    // 回调
    NSString *title = self.menuItems[index][@"title"];
    if (self.onMenuItemSelected) {
        self.onMenuItemSelected(index, title);
    }

    // 处理导航
    [self handleMenuSelection:index];
}

- (void)updateButtonColors {
    UIColor *normalColor = [self menuNormalColor];
    UIColor *accent = accentColor();
    // 按钮现在在 menuStackView.arrangedSubviews 中（UIStackView 重构后）
    for (UIView *view in self.menuStackView.arrangedSubviews) {
        if ([view isKindOfClass:[UIButton class]]) {
            UIButton *btn = (UIButton *)view;
            NSInteger index = btn.tag;
            BOOL selected = (index == self.selectedIndex);

            if (selected) {
                btn.tintColor = accent;
                [btn setTitleColor:accent forState:UIControlStateNormal];
            } else {
                btn.tintColor = normalColor;
                [btn setTitleColor:normalColor forState:UIControlStateNormal];
            }
            // Glass 选中态（玻璃高光 + 光晕）统一由此方法施加
            [self applyGlassSelectionStyleToButton:btn selected:selected];
        }
    }
}

// 字体颜色变更时刷新所有菜单按钮
- (void)applyCustomAppearance {
    [self updateButtonColors];
}

/// 重新应用背景效果：当 BackgroundUIEffectChanged 通知到达时调用，
/// 通过 BackgroundManager 重新设置当前视图控制器的透明度/毛玻璃效果，
/// 确保全局背景能够正常透出。
- (void)reapplyBackgroundEffect {
    [[BackgroundManager sharedManager] makeViewControllerTransparent:self];
}

#pragma mark - 玻璃外观刷新

/// 明暗模式切换时刷新所有玻璃按钮的 CGColor。
/// 成因：UIColor 是动态颜色，但 layer.borderColor / shadowColor / 渐变层 colors 都是
/// CGColor，不参与动态颜色解析，必须在外观变化时手动重取，否则会残留旧模式的颜色。
- (void)traitCollectionDidChange:(UITraitCollection *)previousTraitCollection {
    [super traitCollectionDidChange:previousTraitCollection];

    if (@available(iOS 13.0, *)) {
        if (previousTraitCollection.userInterfaceStyle == self.traitCollection.userInterfaceStyle) {
            return; // 外观没变，无需刷新
        }
    }
    [self refreshGlassButtonAppearance];
}

/// 档位变化后重建全部菜单按钮的玻璃层。
/// 之所以重建而非改属性：档位决定的是"叠加几层"，层数变了必须重新插入。
/// 重建时保留当前的选中项，选中态不会被重置。
- (void)rebuildMenuButtonsForGlassStyle {
    for (UIView *view in self.menuStackView.arrangedSubviews) {
        if (![view isKindOfClass:[UIButton class]]) continue;
        UIButton *btn = (UIButton *)view;

        // 清掉旧的玻璃层（只删本类命名的层，图标/标题是 subview 不受影响）
        NSMutableArray<CALayer *> *stale = [NSMutableArray array];
        for (CALayer *sub in btn.layer.sublayers) {
            if ([sub.name isEqualToString:@"glassSheen"] ||
                [sub.name isEqualToString:@"glassSpecular"]) {
                [stale addObject:sub];
            }
        }
        for (CALayer *l in stale) [l removeFromSuperlayer];

        BOOL selected = (btn.tag == self.selectedIndex);
        [self applyGlassLayersToButton:btn selected:selected];
    }
    [self refreshGlassButtonAppearance];
}

/// 按当前档位给单个按钮铺玻璃层（与 makeMenuButton 中的逻辑保持同一份数值来源）。
/// 抽出来是为了让"首建"和"换档重建"共用一套实现，避免两处走样。
- (void)applyGlassLayersToButton:(UIButton *)btn selected:(BOOL)selected {
    if (!btn) return;
    GlassStyle style = [GlassTheme glassStyle];
    CGFloat radius = [GlassTheme menuButtonCornerRadius];
    CGRect frame = CGRectMake(0, 0, [GlassTheme menuButtonSize], [GlassTheme menuButtonSize]);

    btn.layer.cornerRadius = radius;
    btn.layer.borderWidth = (style == GlassStyleOff)
        ? 0.0
        : [GlassTheme borderWidth] * [GlassTheme glassBorderWidthScaleForStyle:style];

    if (style == GlassStyleOff) {
        btn.backgroundColor = [UIColor clearColor];
        btn.layer.borderColor = [UIColor clearColor].CGColor;
        return;
    }

    // 顶部受光
    CAGradientLayer *sheen = [CAGradientLayer layer];
    sheen.name = @"glassSheen";
    sheen.colors = @[(id)[GlassTheme glassTopSheenColor].CGColor, (id)[UIColor clearColor].CGColor];
    sheen.locations = @[@0.0, @0.55];
    sheen.startPoint = CGPointMake(0.5, 0.0);
    sheen.endPoint   = CGPointMake(0.5, 1.0);
    sheen.cornerRadius = radius;
    sheen.masksToBounds = YES;
    sheen.frame = frame;
    [btn.layer insertSublayer:sheen atIndex:0];

    // 斜向镜面高光（高档位）
    if ([GlassTheme glassLayerCountForStyle:style] >= 3) {
        CAGradientLayer *specular = [CAGradientLayer layer];
        specular.name = @"glassSpecular";
        specular.colors = @[(id)[GlassTheme glassSpecularColor].CGColor, (id)[UIColor clearColor].CGColor];
        specular.locations = @[@0.0, @0.85];
        specular.startPoint = CGPointMake(0.0, 0.0);
        specular.endPoint   = CGPointMake(1.0, 1.0);
        specular.cornerRadius = radius;
        specular.masksToBounds = YES;
        specular.frame = frame;
        [btn.layer insertSublayer:specular atIndex:0];
    }
}

/// 重新取用当前外观下的玻璃颜色，刷新描边、底色与渐变高光
- (void)refreshGlassButtonAppearance {
    UIColor *fill   = [GlassTheme menuButtonGlassFillColor];
    UIColor *border = [GlassTheme menuButtonBorderColor];
    UIColor *sheen  = [GlassTheme glassTopSheenColor];
    UIColor *spec   = [GlassTheme glassSpecularColor];

    for (UIView *view in self.menuStackView.arrangedSubviews) {
        if (![view isKindOfClass:[UIButton class]]) continue;
        UIButton *btn = (UIButton *)view;

        btn.layer.borderColor = border.CGColor;

        // 渐变层颜色重取（关闭隐式动画避免闪色）
        for (CALayer *sub in btn.layer.sublayers) {
            if (![sub isKindOfClass:[CAGradientLayer class]]) continue;

            [CATransaction begin];
            [CATransaction setDisableActions:YES];
            if ([sub.name isEqualToString:@"glassSheen"]) {
                ((CAGradientLayer *)sub).colors = @[(id)sheen.CGColor, (id)[UIColor clearColor].CGColor];
            } else if ([sub.name isEqualToString:@"glassSpecular"]) {
                ((CAGradientLayer *)sub).colors = @[(id)spec.CGColor, (id)[UIColor clearColor].CGColor];
            }
            [CATransaction commit];
        }
        (void)fill;
    }
    // 底色与选中态一并重算（选中项描边用的是 accentColor，也需重新取）
    [self updateButtonColors];
}

- (void)dealloc {
    [[NSNotificationCenter defaultCenter] removeObserver:self];
}

// 未选中菜单项的颜色：优先使用用户自定义的 general.text_color，否则默认 systemGray
- (UIColor *)menuNormalColor {
    NSString *hex = getPrefObject(@"general.text_color");
    if (hex.length > 0) {
        UIColor *custom = [self colorFromHexString:hex];
        if (custom) return custom;
    }
    return [UIColor systemGrayColor];
}

- (UIColor *)colorFromHexString:(NSString *)hexString {
    NSString *hex = [hexString stringByReplacingOccurrencesOfString:@"#" withString:@""];
    if (hex.length != 6 && hex.length != 8) return nil;
    unsigned int r, g, b, a = 255;
    if (hex.length == 6) {
        [[NSScanner scannerWithString:hex] scanHexInt:&r];
        b = r & 0xFF;
        g = (r >> 8) & 0xFF;
        r = (r >> 16) & 0xFF;
    } else {
        [[NSScanner scannerWithString:hex] scanHexInt:&r];
        a = r & 0xFF;
        b = (r >> 8) & 0xFF;
        g = (r >> 16) & 0xFF;
        r = (r >> 24) & 0xFF;
    }
    return [UIColor colorWithRed:r/255.0 green:g/255.0 blue:b/255.0 alpha:a/255.0];
}

- (void)handleMenuSelection:(NSInteger)index {
    switch (index) {
        case 0: // 主页
            // 通知父控制器切换到新闻页
            [[NSNotificationCenter defaultCenter] postNotificationName:@"ShowHomePage" object:nil];
            break;

        case 1: // 下载
            [[NSNotificationCenter defaultCenter] postNotificationName:@"ShowDownloadPage" object:nil];
            break;

        case 2: // AI 助手
            [[NSNotificationCenter defaultCenter] postNotificationName:@"ShowAIPage" object:nil];
            break;

        case 3: // 版本管理（合并了原"当前版本设置"功能）
            [self showVersionManager];
            break;

        case 4: // 设置（联机入口暂时移除，恢复时顺延 index）
            [self showSettings];
            break;
    }
}

- (void)showVersionManager {
    // 发送通知让 LauncherRootViewController 在中间内容区显示
    [[NSNotificationCenter defaultCenter] postNotificationName:@"ShowVersionManager" object:nil];
}

- (void)showMultiplayer {
    // 发送通知让 LauncherRootViewController 显示陶瓦联机界面
    [[NSNotificationCenter defaultCenter] postNotificationName:@"ShowMultiplayer" object:nil];
}

- (void)showZeroTier {
    // 发送通知让 LauncherRootViewController 显示 ZeroTier 联机界面
    // ZeroTier 与陶瓦联机为并列的两套联机方案，独立菜单入口避免用户先进入陶瓦再切换。
    [[NSNotificationCenter defaultCenter] postNotificationName:@"ShowZeroTier" object:nil];
}

- (void)showSettings {
    // 发送通知让 LauncherRootViewController 在中间内容区显示
    [[NSNotificationCenter defaultCenter] postNotificationName:@"ShowSettings" object:nil];
}

#pragma mark - Data Updates

- (void)updateAccountInfo {
    // 账户信息在右侧面板显示，这里不需要处理
}

#pragma mark - Orientation

- (BOOL)shouldAutorotate {
    return YES;
}

- (UIInterfaceOrientationMask)supportedInterfaceOrientations {
    return UIInterfaceOrientationMaskLandscape;
}

@end
