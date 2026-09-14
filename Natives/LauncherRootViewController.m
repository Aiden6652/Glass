#import "LauncherRootViewController.h"
#import "LauncherMenuViewController.h"
#import "LauncherNewsViewController.h"
#import "LauncherRightPanelViewController.h"
#import "DownloadViewController.h"
#import "VersionManagerViewController.h"
#import "ProfileSettingsViewController.h"
#import "LauncherPreferencesViewController.h"
#import "LauncherNavigationController.h"
#import "LauncherPreferences.h"
#import "BackgroundManager.h"
#import "PLProfiles.h"
#import "utils.h"
#import "ModsManagerViewController.h"
#import "ShadersManagerViewController.h"
#import "ModpackImportViewController.h"
#import "LauncherPrefGameDirViewController.h"
#import "CustomControlsViewController.h"
// ZeroTier/Terracotta 联机暂时移除（排查启动崩溃）
// #import "MultiplayerViewController.h"
// #import "TerracottaViewController.h"
// #import "TerracottaManager.h"
// #import "TerracottaBridge.h"
#import "AccountListViewController.h"
#import "AI/AIViewController.h"
#import "AI/AiSessionStore.h"
#import "GlassTheme.h"
#import "GlassEffectView.h"

// ===== Glass 主题动效 =====
// 页面切换与启动动效的全部参数集中在 GlassTheme 中，本文件只负责施加动画。
// 设计要点（踩坑记录）：
//   1. 一律用 CGAffineTransform 而非 frame —— frame 与 Auto Layout 冲突会打架。
//   2. 退场 VC 的 transform/alpha 必须在 completion 中复位，否则该 VC 被复用时会带残留状态。
//   3. 新 VC 的约束必须在动画开始前已激活，否则 bounds 为 0，浮入距离算成 0。

// 布局常量（iPad 基准值；iPhone 上通过 LauncherRootLayoutWidth 适配后会变窄）
static const CGFloat kSidebarWidthPad = 70.0;      // iPad 左侧边栏宽度
static const CGFloat kSidebarWidthPhone = 56.0;    // iPhone 左侧边栏宽度（仅图标）
static const CGFloat kRightPanelWidthPad = 220.0;  // iPad 右侧面板宽度
static const CGFloat kRightPanelWidthPhone = 168.0; // iPhone 右侧面板宽度（保证按钮文字可读）

/// 检测物理设备是否为 iPhone（不受 debug.debug_ipad_ui 的 idiom hook 影响）。
/// UIKit+hook.m 会把 idiom 强制改成 Pad，导致 trait.userInterfaceIdiom 不可靠。
/// 这里用 UIDevice.model 检测真实设备类型。
static BOOL LauncherRootIsPhysicalPhone(void) {
    NSString *model = [[UIDevice currentDevice].model lowercaseString];
    return [model containsString:@"iphone"];
}

/// 根据物理设备类型决定侧栏宽度（与 LauncherCardLayoutViewController 保持一致）
static CGFloat LauncherRootLayoutSidebarWidth(UITraitCollection *trait) {
    if (LauncherRootIsPhysicalPhone()) return kSidebarWidthPhone;
    return kSidebarWidthPad;
}

/// 根据物理设备类型决定右侧面板宽度
static CGFloat LauncherRootLayoutRightPanelWidth(UITraitCollection *trait) {
    if (LauncherRootIsPhysicalPhone()) return kRightPanelWidthPhone;
    return kRightPanelWidthPad;
}

@interface LauncherRootViewController ()

@property(nonatomic, strong) UIView *sidebarContainer;
@property(nonatomic, strong) UIView *contentContainer;
@property(nonatomic, strong) UIView *rightPanelContainer;

@property(nonatomic, strong) NSLayoutConstraint *contentLeadingConstraint;
@property(nonatomic, strong) NSLayoutConstraint *contentTrailingConstraint;
@property(nonatomic, strong) NSLayoutConstraint *sidebarWidthConstraint;
@property(nonatomic, strong) NSLayoutConstraint *rightPanelWidthConstraint;
// 关键修复（UI 累积异常）：setContentViewController: 之前每次切换都激活 4 个新约束
// （leading/trailing/top/bottom 到 contentContainer），但旧 VC 的约束未显式 deactivate。
// 在 tmpRootVC 保留场景下，缓存复用的子 VC 反复激活约束，layout 解算时 leading/trailing
// 约束叠加导致 contentContainer 内容区左右变宽。现持有当前约束并先 deactivate 再激活。
@property(nonatomic, strong) NSArray<NSLayoutConstraint *> *currentContentConstraints;

@property(nonatomic, assign) BOOL isShowingProfileEditor;
@property(nonatomic, strong) ProfileSettingsViewController *profileEditorVC;

/// Glass 启动动效只播放一次（避免每次切回前台/重新布局都重播）
@property(nonatomic, assign) BOOL hasPlayedLaunchAnimation;

@end

@implementation LauncherRootViewController

#pragma mark - Lifecycle

- (void)viewDidLoad {
    [super viewDidLoad];

    self.view.backgroundColor = [UIColor clearColor];

    // 初始化版本列表（必须在其他视图控制器之前）
    [self initializeVersionLists];

    // 创建三个容器视图
    [self setupContainers];

    // 添加子视图控制器
    [self setupChildViewControllers];

    // 应用背景
    [[BackgroundManager sharedManager] applyBackgroundToView:self.view];

    // 监听外观变更（字体颜色 / 卡片颜色），与 Card 布局保持一致
    [[NSNotificationCenter defaultCenter] addObserver:self
                                             selector:@selector(applyCustomAppearance)
                                                 name:@"LauncherAppearanceChanged"
                                               object:nil];

    // 监听玻璃质感档位变更：用户在设置里调档后立即重绘左右侧栏的玻璃层
    [[NSNotificationCenter defaultCenter] addObserver:self
                                             selector:@selector(glassStyleChanged:)
                                                 name:@"LauncherGlassStyleChanged"
                                               object:nil];

    [self applyCustomAppearance];
    // 首帧应用一次玻璃档位（此时容器已建好，可安全插入渲染层）
    [self applyGlassStyleToContainers];
}

- (BOOL)prefersStatusBarHidden {
    return YES;
}

- (void)initializeVersionLists {
    // 初始化本地版本列表
    if (!localVersionList) {
        localVersionList = [NSMutableArray new];
    }
    [localVersionList removeAllObjects];
    
    NSFileManager *fileManager = [NSFileManager defaultManager];
    NSString *versionPath = [NSString stringWithFormat:@"%s/versions/", getenv("POJAV_GAME_DIR")];
    NSArray *list = [fileManager contentsOfDirectoryAtPath:versionPath error:nil];
    for (NSString *versionId in list) {
        NSString *localPath = [NSString stringWithFormat:@"%s/versions/%@", getenv("POJAV_GAME_DIR"), versionId];
        BOOL isDirectory;
        if ([fileManager fileExistsAtPath:localPath isDirectory:&isDirectory] && isDirectory) {
            [localVersionList addObject:@{
                @"id": versionId,
                @"type": @"custom"
            }];
        }
    }
    
    // 初始化远程版本列表
    if (!remoteVersionList) {
        remoteVersionList = [NSMutableArray new];
    }
    [remoteVersionList removeAllObjects];
    [remoteVersionList addObjectsFromArray:@[
        @{@"id": @"latest-release", @"type": @"release"},
        @{@"id": @"latest-snapshot", @"type": @"snapshot"}
    ]];
    
    // 异步获取远程版本列表
    [self fetchRemoteVersionList];
}

- (void)fetchRemoteVersionList {
    NSString *downloadSource = getPrefObject(@"general.download_source");
    NSString *versionManifestURL;
    
    if ([downloadSource isEqualToString:@"bmclapi"]) {
        versionManifestURL = @"https://bmclapi2.bangbang93.com/mc/game/version_manifest_v2.json";
    } else {
        versionManifestURL = @"https://piston-meta.mojang.com/mc/game/version_manifest_v2.json";
    }
    
    NSURL *url = [NSURL URLWithString:versionManifestURL];
    NSURLSessionDataTask *task = [[NSURLSession sharedSession] dataTaskWithURL:url completionHandler:^(NSData *data, NSURLResponse *response, NSError *error) {
        if (data && !error) {
            NSError *jsonError;
            NSDictionary *json = [NSJSONSerialization JSONObjectWithData:data options:0 error:&jsonError];
            if (json && json[@"versions"]) {
                dispatch_async(dispatch_get_main_queue(), ^{
                    [remoteVersionList addObjectsFromArray:json[@"versions"]];
                    setPrefObject(@"internal.latest_version", json[@"latest"]);
                    NSDebugLog(@"[LauncherRootVC] Loaded %d remote versions", remoteVersionList.count);
                });
            }
        } else {
            NSDebugLog(@"[LauncherRootVC] Failed to fetch version list: %@", error.localizedDescription);
        }
    }];
    [task resume];
}

- (void)viewWillAppear:(BOOL)animated {
    [super viewWillAppear:animated];
    [[BackgroundManager sharedManager] resumeVideo];
}

- (void)viewWillDisappear:(BOOL)animated {
    [super viewWillDisappear:animated];
    [[BackgroundManager sharedManager] pauseVideo];
}

#pragma mark - Glass 启动动效

/// 首次显示时，三栏容器错峰从下方浮入，形成"拼装"观感。
/// 只播放一次（hasPlayedLaunchAnimation 守卫）；后续从设置页返回、切前台都不重播，
/// 避免用户每次切页都被动效打扰。
- (void)viewDidAppear:(BOOL)animated {
    [super viewDidAppear:animated];

    if (self.hasPlayedLaunchAnimation) return;
    self.hasPlayedLaunchAnimation = YES;

    UIView *sidebar = self.sidebarContainer;
    UIView *content = self.contentContainer;
    UIView *right   = self.rightPanelContainer;
    if (!sidebar || !content || !right) return;

    // 关键：延到下一个 runloop 再播。
    // viewDidAppear 时机下 Auto Layout 可能尚未完成本轮布局，此时 bounds 还是 0，
    // 若按 bounds 计算浮入距离会得到 0，表现为"没有动效"。dispatch_async 可确保读到最终 bounds。
    dispatch_async(dispatch_get_main_queue(), ^{
        CGFloat dist      = [GlassTheme launchSlideDistance];
        CGFloat stagger   = [GlassTheme launchStaggerDelay];
        NSTimeInterval dur = [GlassTheme launchDuration];
        CGFloat damping   = [GlassTheme launchDamping];

        // 初始态：三栏位于下方且透明。中间主内容区位移略大，错峰时层次更明显。
        sidebar.transform = CGAffineTransformMakeTranslation(0, dist);
        content.transform = CGAffineTransformMakeTranslation(0, dist * 1.15);
        right.transform   = CGAffineTransformMakeTranslation(0, dist);
        sidebar.alpha = 0.0;
        content.alpha = 0.0;
        right.alpha   = 0.0;

        void (^animateIn)(UIView *, NSTimeInterval) = ^(UIView *v, NSTimeInterval delay) {
            [UIView animateWithDuration:dur
                                  delay:delay
                 usingSpringWithDamping:damping
                  initialSpringVelocity:0.4
                                options:UIViewAnimationOptionCurveEaseOut | UIViewAnimationOptionAllowUserInteraction
                             animations:^{
                v.transform = CGAffineTransformIdentity;
                v.alpha = 1.0;
            } completion:nil];
        };

        // 错峰：左 → 中 → 右
        animateIn(sidebar, 0.0);
        animateIn(content, stagger);
        animateIn(right,   stagger * 2);
    });
}

- (void)traitCollectionDidChange:(UITraitCollection *)previousTraitCollection {
    [super traitCollectionDidChange:previousTraitCollection];
    // iPhone 与 iPad 切换、或分屏调整大小时，更新侧栏与右侧面板宽度
    CGFloat sidebarWidth = LauncherRootLayoutSidebarWidth(self.traitCollection);
    CGFloat rightPanelWidth = LauncherRootLayoutRightPanelWidth(self.traitCollection);
    if (self.sidebarWidthConstraint.constant != sidebarWidth) {
        self.sidebarWidthConstraint.constant = sidebarWidth;
    }
    if (self.rightPanelWidthConstraint.constant != rightPanelWidth) {
        self.rightPanelWidthConstraint.constant = rightPanelWidth;
    }
    // 通知子 VC 重新布局
    for (UIViewController *child in self.childViewControllers) {
        [child.view setNeedsLayout];
    }

    // Glass：明暗模式切换时刷新玻璃描边颜色（CGColor 不随动态颜色自动更新）
    if (@available(iOS 13.0, *)) {
        if (previousTraitCollection.userInterfaceStyle != self.traitCollection.userInterfaceStyle) {
            [self refreshGlassEdgeColors];
        }
    }
}

- (void)viewDidLayoutSubviews {
    [super viewDidLayoutSubviews];
    // 修复：移除原先对 nav 栈所有 VC 一刀切注入负 additionalSafeAreaInsets.top 的逻辑。
    // 该负 inset 会导致两个严重问题：
    //   1. 设置页等使用 safeAreaLayoutGuide.topAnchor 布局的 VC，其内容被推到导航栏之上（"飞到顶上"），
    //      外观调整等选项无法正常滚动和操作。
    //   2. Java 管理等 push 进来的子页面，前一个页面的内容因为负 inset 透出在当前页面下方，
    //      形成"前一页面没有及时消失"的视觉残留。
    // "大白条"问题已通过 makeViewControllerTransparent（将 VC view 背景设为 clearColor）
    // + applyEffectToNavigationBar（导航栏毛玻璃）解决，不再需要此 hack。
    //
    // 关键修复（UI 累积异常）：之前仅清理 NEGATIVE .top 的 additionalSafeAreaInsets，
    // 未覆盖 .left/.right/.bottom 与正值累积。在 tmpRootVC 保留场景下，若其他路径
    // 累加 left/right inset，此方法无法兜底，导致 contentContainer 内容区左右变宽。
    // 现清理所有方向的非零 inset。

    // Glass：侧栏/右面板尺寸变化（旋转、分屏、iPhone/iPad 切换）后重算玻璃描边路径。
    // 必须放在下方 `if (!contentVC) return;` 之前 —— 否则无内容页时描边不会更新。
    [self refreshGlassEdgePaths];

    UIViewController *contentVC = _contentViewController;
    if (!contentVC) return;
    if ([contentVC isKindOfClass:[UINavigationController class]]) {
        UINavigationController *nav = (UINavigationController *)contentVC;
        for (UIViewController *vc in nav.viewControllers) {
            UIEdgeInsets insets = vc.additionalSafeAreaInsets;
            if (insets.top != 0 || insets.left != 0 || insets.right != 0 || insets.bottom != 0) {
                vc.additionalSafeAreaInsets = UIEdgeInsetsZero;
            }
        }
    } else {
        UIEdgeInsets insets = contentVC.additionalSafeAreaInsets;
        if (insets.top != 0 || insets.left != 0 || insets.right != 0 || insets.bottom != 0) {
            contentVC.additionalSafeAreaInsets = UIEdgeInsetsZero;
        }
    }
}

#pragma mark - Setup

- (void)setupContainers {
    CGFloat corner = [GlassTheme containerCornerRadius];

    // 左侧边栏容器 - 半透明，仅保留外侧（左上/左下）圆角，避免与中间容器相邻处形成凹槽
    // 注意：masksToBounds 必须保持 YES —— 它负责裁剪毛玻璃层与内容，改为 NO 会导致
    // 子视图溢出圆角形成直角凸出。玻璃边缘改用独立子层实现（applyGlassEdgeToView:），
    // 不占用 layer.border（border 会沿 maskedCorners 之外的角也画出来）。
    self.sidebarContainer = [[UIView alloc] init];
    self.sidebarContainer.translatesAutoresizingMaskIntoConstraints = NO;
    self.sidebarContainer.layer.cornerRadius = corner;
    self.sidebarContainer.layer.maskedCorners = kCALayerMinXMinYCorner | kCALayerMinXMaxYCorner;
    self.sidebarContainer.layer.masksToBounds = YES;
    [[BackgroundManager sharedManager] applyEffectToView:self.sidebarContainer];
    [self applyGlassEdgeToView:self.sidebarContainer];

    // 中间内容容器 - 完全透明，四角直角（内部塞入 nav controller + table view，圆角会裁剪内容且无视觉收益）
    self.contentContainer = [[UIView alloc] init];
    self.contentContainer.translatesAutoresizingMaskIntoConstraints = NO;
    self.contentContainer.backgroundColor = [UIColor clearColor];
    [self.view addSubview:self.contentContainer];

    // 右侧面板容器 - 半透明，仅保留外侧（右上/右下）圆角
    self.rightPanelContainer = [[UIView alloc] init];
    self.rightPanelContainer.translatesAutoresizingMaskIntoConstraints = NO;
    self.rightPanelContainer.layer.cornerRadius = corner;
    self.rightPanelContainer.layer.maskedCorners = kCALayerMaxXMinYCorner | kCALayerMaxXMaxYCorner;
    self.rightPanelContainer.layer.masksToBounds = YES;
    [[BackgroundManager sharedManager] applyEffectToView:self.rightPanelContainer];
    [self applyGlassEdgeToView:self.rightPanelContainer];
    
    // 设置约束
    // 使用可变宽度约束，便于 traitCollection 变化时更新（iPhone/iPad 适配）
    self.sidebarWidthConstraint = [self.sidebarContainer.widthAnchor constraintEqualToConstant:LauncherRootLayoutSidebarWidth(self.traitCollection)];
    self.rightPanelWidthConstraint = [self.rightPanelContainer.widthAnchor constraintEqualToConstant:LauncherRootLayoutRightPanelWidth(self.traitCollection)];

    [NSLayoutConstraint activateConstraints:@[
        // 左侧边栏
        [self.sidebarContainer.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor],
        [self.sidebarContainer.topAnchor constraintEqualToAnchor:self.view.topAnchor],
        [self.sidebarContainer.bottomAnchor constraintEqualToAnchor:self.view.bottomAnchor],
        self.sidebarWidthConstraint,

        // 右侧面板
        [self.rightPanelContainer.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor],
        [self.rightPanelContainer.topAnchor constraintEqualToAnchor:self.view.topAnchor],
        [self.rightPanelContainer.bottomAnchor constraintEqualToAnchor:self.view.bottomAnchor],
        self.rightPanelWidthConstraint,

        // 中间内容区——填满侧栏与右面板之间的空间
        [self.contentContainer.leadingAnchor constraintEqualToAnchor:self.sidebarContainer.trailingAnchor],
        [self.contentContainer.trailingAnchor constraintEqualToAnchor:self.rightPanelContainer.leadingAnchor],
        [self.contentContainer.topAnchor constraintEqualToAnchor:self.view.topAnchor],
        [self.contentContainer.bottomAnchor constraintEqualToAnchor:self.view.bottomAnchor]
    ]];
}

- (void)setupChildViewControllers {
    // 左侧边栏 - 功能菜单
    LauncherMenuViewController *sidebarVC = [[LauncherMenuViewController alloc] init];
    [self addChildViewController:sidebarVC];
    sidebarVC.view.translatesAutoresizingMaskIntoConstraints = NO;
    [self.sidebarContainer addSubview:sidebarVC.view];
    [NSLayoutConstraint activateConstraints:@[
        [sidebarVC.view.leadingAnchor constraintEqualToAnchor:self.sidebarContainer.leadingAnchor],
        [sidebarVC.view.trailingAnchor constraintEqualToAnchor:self.sidebarContainer.trailingAnchor],
        [sidebarVC.view.topAnchor constraintEqualToAnchor:self.sidebarContainer.topAnchor],
        [sidebarVC.view.bottomAnchor constraintEqualToAnchor:self.sidebarContainer.bottomAnchor]
    ]];
    [sidebarVC didMoveToParentViewController:self];
    _sidebarViewController = sidebarVC;
    
    // 中间内容 - 默认显示新闻页
    LauncherNewsViewController *newsVC = [[LauncherNewsViewController alloc] init];
    [self setContentViewController:newsVC animated:NO];
    
    // 右侧面板 - 账户和启动
    LauncherRightPanelViewController *rightPanelVC = [[LauncherRightPanelViewController alloc] init];
    [self addChildViewController:rightPanelVC];
    rightPanelVC.view.translatesAutoresizingMaskIntoConstraints = NO;
    [self.rightPanelContainer addSubview:rightPanelVC.view];
    [NSLayoutConstraint activateConstraints:@[
        [rightPanelVC.view.leadingAnchor constraintEqualToAnchor:self.rightPanelContainer.leadingAnchor],
        [rightPanelVC.view.trailingAnchor constraintEqualToAnchor:self.rightPanelContainer.trailingAnchor],
        [rightPanelVC.view.topAnchor constraintEqualToAnchor:self.rightPanelContainer.topAnchor],
        [rightPanelVC.view.bottomAnchor constraintEqualToAnchor:self.rightPanelContainer.bottomAnchor]
    ]];
    [rightPanelVC didMoveToParentViewController:self];
    _rightPanelViewController = rightPanelVC;
    
    // 注册通知监听
    [[NSNotificationCenter defaultCenter] addObserver:self
                                             selector:@selector(showHomePage)
                                                 name:@"ShowHomePage"
                                               object:nil];
    [[NSNotificationCenter defaultCenter] addObserver:self
                                             selector:@selector(showDownloadPage)
                                                 name:@"ShowDownloadPage"
                                               object:nil];
    [[NSNotificationCenter defaultCenter] addObserver:self
                                             selector:@selector(showVersionManager)
                                                 name:@"ShowVersionManager"
                                               object:nil];
    [[NSNotificationCenter defaultCenter] addObserver:self
                                             selector:@selector(showProfileEditor:)
                                                 name:@"ShowProfileEditor"
                                               object:nil];
    [[NSNotificationCenter defaultCenter] addObserver:self
                                             selector:@selector(showSettings)
                                                 name:@"ShowSettings"
                                               object:nil];
    // 监听显示 AI 助手页面
    [[NSNotificationCenter defaultCenter] addObserver:self
                                             selector:@selector(showAIPage)
                                                 name:@"ShowAIPage"
                                               object:nil];
    // ZeroTier/Terracotta 联机暂时移除（排查启动崩溃）
    // [[NSNotificationCenter defaultCenter] addObserver:self
    //                                          selector:@selector(showMultiplayer)
    //                                              name:@"ShowMultiplayer"
    //                                            object:nil];
    // [[NSNotificationCenter defaultCenter] addObserver:self
    //                                          selector:@selector(showZeroTier)
    //                                              name:@"ShowZeroTier"
    //                                            object:nil];
    // 首页快捷瓷砖触发：切到对应内容区子页面（不再 FormSheet 弹窗）
    [[NSNotificationCenter defaultCenter] addObserver:self
                                             selector:@selector(showModsManager)
                                                 name:@"ShowModsManager"
                                               object:nil];
    [[NSNotificationCenter defaultCenter] addObserver:self
                                             selector:@selector(showShadersManager)
                                                 name:@"ShowShadersManager"
                                               object:nil];
    [[NSNotificationCenter defaultCenter] addObserver:self
                                             selector:@selector(showModpackImport)
                                                 name:@"ShowModpackImport"
                                               object:nil];
    [[NSNotificationCenter defaultCenter] addObserver:self
                                             selector:@selector(showGameDirectory)
                                                 name:@"ShowGameDirectory"
                                               object:nil];
    // FCL 风格：账户管理在中间内容区显示（不再 FormSheet 弹窗）
    [[NSNotificationCenter defaultCenter] addObserver:self
                                             selector:@selector(showAccountManager)
                                                 name:@"ShowAccountManager"
                                               object:nil];
    [[NSNotificationCenter defaultCenter] addObserver:self
                                             selector:@selector(backgroundChanged)
                                                 name:@"BackgroundChanged"
                                               object:nil];
    [[NSNotificationCenter defaultCenter] addObserver:self
                                             selector:@selector(uiEffectChanged:)
                                                 name:@"BackgroundUIEffectChanged"
                                               object:nil];
    // 监听版本切换，重新加载编辑器
    [[NSNotificationCenter defaultCenter] addObserver:self
                                             selector:@selector(reloadProfileEditorIfNeeded)
                                                 name:@"SelectedProfileChanged"
                                               object:nil];
    // 监听游戏目录切换，重新加载版本列表
    [[NSNotificationCenter defaultCenter] addObserver:self
                                             selector:@selector(reloadVersionLists)
                                                 name:@"ReloadProfileList"
                                               object:nil];
    // 监听查找版本请求
    [[NSNotificationCenter defaultCenter] addObserver:self
                                             selector:@selector(findVersionInRemoteList:)
                                                 name:@"FindVersionInRemoteList"
                                               object:nil];
}

- (void)findVersionInRemoteList:(NSNotification *)notification {
    NSDictionary *userInfo = notification.userInfo;
    NSString *versionId = userInfo[@"versionId"];
    void (^callback)(NSDictionary *) = userInfo[@"callback"];
    
    if (!versionId || !callback) {
        return;
    }
    
    // 在远程版本列表中查找
    NSDictionary *versionObject = nil;
    for (NSDictionary *version in remoteVersionList) {
        if ([version[@"id"] isEqualToString:versionId]) {
            versionObject = version;
            break;
        }
    }
    
    // 如果在远程列表中找不到，检查是否是本地版本
    if (!versionObject) {
        for (NSDictionary *version in localVersionList) {
            if ([version[@"id"] isEqualToString:versionId]) {
                versionObject = version;
                break;
            }
        }
    }
    
    callback(versionObject);
}

- (void)reloadVersionLists {
    // 重新加载版本列表
    [self initializeVersionLists];
    // 通知右侧面板刷新版本显示
    [[NSNotificationCenter defaultCenter] postNotificationName:@"SelectedProfileChanged" object:nil];
}

- (void)showHomePage {
    LauncherNewsViewController *newsVC = [[LauncherNewsViewController alloc] init];
    [self setContentViewController:newsVC animated:YES];
}

- (void)showDownloadPage {
    // 在中间内容区显示下载页面，包在 NavigationController 中以便子流程（版本选择/安装器）push 显示
    DownloadViewController *downloadVC = [[DownloadViewController alloc] init];
    UINavigationController *nav = [[UINavigationController alloc] initWithRootViewController:downloadVC];
    nav.navigationBar.prefersLargeTitles = NO;
    [self setContentViewController:nav animated:YES];
}

- (void)showVersionManager {
    // 在中间内容区显示版本管理页面，包在 NavigationController 中以便子流程（模组/光影/游戏目录管理）push
    VersionManagerViewController *vc = [[VersionManagerViewController alloc] init];
    UINavigationController *nav = [[UINavigationController alloc] initWithRootViewController:vc];
    nav.navigationBar.prefersLargeTitles = NO;
    [self setContentViewController:nav animated:YES];
}

- (void)showProfileEditor:(NSNotification *)notification {
    // 在中间内容区显示版本编辑器页面（使用 ProfileSettingsViewController）
    NSString *profileName = notification.object;

    ProfileSettingsViewController *vc = [[ProfileSettingsViewController alloc] init];
    vc.profileName = profileName;

    // 包装在导航控制器中
    UINavigationController *navVC = [[UINavigationController alloc] initWithRootViewController:vc];
    navVC.navigationBar.prefersLargeTitles = NO;

    self.profileEditorVC = vc;
    self.isShowingProfileEditor = YES;
    [self setContentViewController:navVC animated:YES];
}

- (void)reloadProfileEditorIfNeeded {
    // 如果当前正在显示编辑器页面，重新加载
    if (self.isShowingProfileEditor) {
        NSString *currentProfile = PLProfiles.current.selectedProfileName;
        if (currentProfile) {
            [[NSNotificationCenter defaultCenter] postNotificationName:@"ShowProfileEditor" object:currentProfile];
        }
    }
}

- (void)showSettings {
    // 在中间内容区显示设置页面
    LauncherPreferencesViewController *vc = [[LauncherPreferencesViewController alloc] init];
    // 包装在导航控制器中，使其子页面能够正常导航
    UINavigationController *navVC = [[UINavigationController alloc] initWithRootViewController:vc];
    navVC.navigationBar.prefersLargeTitles = YES;
    [self setContentViewController:navVC animated:YES];
}

- (void)showAIPage {
    // 从 AiSessionStore 取最近会话，没有则让 AIViewController 新建一个
    AiSession *session = [[AiSessionStore sharedStore] lastActiveSession];
    AIViewController *vc = [[AIViewController alloc] initWithSession:session];
    UINavigationController *navVC = [[UINavigationController alloc] initWithRootViewController:vc];
    navVC.navigationBar.prefersLargeTitles = NO;
    [self setContentViewController:navVC animated:YES];
}

// ZeroTier/Terracotta 联机暂时移除（排查启动崩溃）
// - (void)showMultiplayer { ... TerracottaViewController ... }
// - (void)showZeroTier { ... MultiplayerViewController ... TerracottaManager ... }
- (void)showMultiplayer {
    [self showMultiplayerDisabledAlert];
}
- (void)showZeroTier {
    [self showMultiplayerDisabledAlert];
}
- (void)showMultiplayerDisabledAlert {
    UIAlertController *alert = [UIAlertController
        alertControllerWithTitle:localize(@"i18n_str_320", nil)
                          message:localize(@"i18n_str_321", nil)
                   preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:localize(@"i18n_str_322", nil) style:UIAlertActionStyleDefault handler:nil]];
    [self presentViewController:alert animated:YES completion:nil];
}

#pragma mark - 首页快捷入口 (替换原 FormSheet 弹窗)

- (void)showModsManager {
    // 切到版本管理页并直接 push 模组管理
    // 修复"前一界面未消失"竞态：先构建完整 nav 栈再 setContentViewController，
    // 这样 setContentViewController 内的 for 循环能一次性透明化栈中所有 VC，
    // 避免 animated:YES 的 crossDissolve 进行中再 animated:NO push 导致新 VC 未透明化。
    VersionManagerViewController *vm = [[VersionManagerViewController alloc] init];
    UINavigationController *nav = [[UINavigationController alloc] initWithRootViewController:vm];
    nav.navigationBar.prefersLargeTitles = NO;
    ModsManagerViewController *m = [[ModsManagerViewController alloc] init];
    [nav pushViewController:m animated:NO];
    [self setContentViewController:nav animated:YES];
}

- (void)showShadersManager {
    VersionManagerViewController *vm = [[VersionManagerViewController alloc] init];
    UINavigationController *nav = [[UINavigationController alloc] initWithRootViewController:vm];
    nav.navigationBar.prefersLargeTitles = NO;
    ShadersManagerViewController *s = [[ShadersManagerViewController alloc] init];
    s.initialMode = ShadersManagerModeLocal;
    [nav pushViewController:s animated:NO];
    [self setContentViewController:nav animated:YES];
}

- (void)showGameDirectory {
    VersionManagerViewController *vm = [[VersionManagerViewController alloc] init];
    UINavigationController *nav = [[UINavigationController alloc] initWithRootViewController:vm];
    nav.navigationBar.prefersLargeTitles = NO;
    LauncherPrefGameDirViewController *g = [[LauncherPrefGameDirViewController alloc] init];
    [nav pushViewController:g animated:NO];
    [self setContentViewController:nav animated:YES];
}

- (void)showModpackImport {
    // 切到下载页并直接 push 整合包导入界面
    DownloadViewController *d = [[DownloadViewController alloc] init];
    UINavigationController *nav = [[UINavigationController alloc] initWithRootViewController:d];
    nav.navigationBar.prefersLargeTitles = NO;
    ModpackImportViewController *m = [[ModpackImportViewController alloc] init];
    [nav pushViewController:m animated:NO];
    [self setContentViewController:nav animated:YES];
}

/// FCL 风格：账户管理在中间内容区显示（不再 FormSheet 弹窗）
- (void)showAccountManager {
    AccountListViewController *vc = [[AccountListViewController alloc] initWithStyle:UITableViewStyleInsetGrouped];
    // 账户选择后通知右侧面板刷新（使用已有的 UpdateAccountInfo 通知）
    vc.whenItemSelected = ^void() {
        [[NSNotificationCenter defaultCenter] postNotificationName:@"UpdateAccountInfo" object:nil];
    };
    // 账户删除后也通知右侧面板刷新
    vc.whenDelete = ^void(NSString *name) {
        [[NSNotificationCenter defaultCenter] postNotificationName:@"UpdateAccountInfo" object:nil];
    };
    UINavigationController *nav = [[UINavigationController alloc] initWithRootViewController:vc];
    nav.navigationBar.prefersLargeTitles = NO;
    [self setContentViewController:nav animated:YES];
}

- (void)backgroundChanged {
    // 重新应用背景
    [[BackgroundManager sharedManager] applyBackgroundToView:self.view];
    // 背景变化可能导致外观（明暗）变化，玻璃描边颜色需同步刷新
    [self refreshGlassEdgeColors];
    // 液态玻璃的折射层是采样背景得到的，背景换了必须重采，否则玻璃里还是旧画面
    [self applyGlassStyleToContainers];
    if (self.view.window) {
        [GlassEffectView refreshGlassInViewHierarchy:self.view.window];
    }
}

#pragma mark - Glass 玻璃边缘

/// 按当前档位给左右侧栏套上液态玻璃渲染层。
/// 档位为「关闭」时只清理玻璃层，保留 BackgroundManager 原本的毛玻璃/半透明表现，
/// 做到"关掉玻璃不等于关掉背景效果"，用户不会觉得设置失灵。
- (void)applyGlassStyleToContainers {
    GlassStyle style = [GlassTheme glassStyle];
    CGFloat radius = [GlassTheme containerCornerRadius];

    for (UIView *container in @[self.sidebarContainer, self.rightPanelContainer]) {
        if (!container) continue;

        [GlassEffectView removeGlassFromView:container];

        if (style == GlassStyleOff) {
            // 关闭档：恢复为纯色描边（旧行为），不叠加任何额外图层
            [self refreshGlassEdgeVisibility:YES inContainer:container];
            continue;
        }

        BOOL isSidebar = (container == self.sidebarContainer);
        UIRectCorner corners = isSidebar
            ? (UIRectCornerTopLeft | UIRectCornerBottomLeft)
            : (UIRectCornerTopRight | UIRectCornerBottomRight);

        [GlassEffectView applyGlassToView:container
                                    style:style
                             cornerRadius:radius
                           roundedCorners:corners];

        // GlassEffectView 自带更精细的菲涅尔描边，此时旧的 glassEdge 描边会与之重叠成"双线"，
        // 因此高档位下隐藏旧描边，避免边缘发毛。
        [self refreshGlassEdgeVisibility:NO inContainer:container];
    }
}

/// 显隐旧版 glassEdge 描边层
- (void)refreshGlassEdgeVisibility:(BOOL)visible inContainer:(UIView *)container {
    for (CALayer *sub in container.layer.sublayers) {
        if ([sub isKindOfClass:[CAShapeLayer class]] && [sub.name isEqualToString:@"glassEdge"]) {
            sub.hidden = !visible;
        }
    }
}

- (void)glassStyleChanged:(NSNotification *)notification {
    // 档位存在偏好里，重绘时直接读，无需解析通知的 object
    [self applyGlassStyleToContainers];
    // 内容区（导航栏、卡片等）也同步刷新，避免出现"侧栏变了、中间没变"的割裂感
    [[NSNotificationCenter defaultCenter] postNotificationName:@"LauncherAppearanceApplied" object:nil];
    if (self.view.window) {
        [GlassEffectView refreshGlassInViewHierarchy:self.view.window];
    }
}

/// 为容器添加"玻璃边缘"描边。
/// 实现要点：不用 layer.border —— 因为 sidebar/rightPanel 只保留单侧圆角（maskedCorners），
/// layer.border 会在另外两个直角处也画出实线，视觉上像"缺了圆角的方框"。
/// 改用 CAShapeLayer + UIBezierPath(roundedRect:byRoundingCorners:)，只画保留圆角的那一侧。
/// 描边颜色是动态颜色，需在明暗切换时刷新（refreshGlassEdgeColors）。
- (void)applyGlassEdgeToView:(UIView *)view {
    if (!view) return;

    CAShapeLayer *edge = [CAShapeLayer layer];
    edge.name = @"glassEdge";
    edge.fillColor = [UIColor clearColor].CGColor;
    edge.strokeColor = [GlassTheme glassBorderColor].CGColor;
    edge.lineWidth = [GlassTheme borderWidth];
    edge.contentsScale = UIScreen.mainScreen.scale;

    // 描边要画在容器边界内，否则会被 masksToBounds 裁掉一半
    edge.frame = view.bounds;

    BOOL isSidebar = (view == self.sidebarContainer);
    UIRectCorner corners = isSidebar
        ? (UIRectCornerTopLeft | UIRectCornerBottomLeft)
        : (UIRectCornerTopRight | UIRectCornerBottomRight);
    CGFloat radius = [GlassTheme containerCornerRadius];

    edge.path = [UIBezierPath bezierPathWithRoundedRect:view.bounds
                                      byRoundingCorners:corners
                                            cornerRadii:CGSizeMake(radius, radius)].CGPath;

    [view.layer addSublayer:edge];
}

/// 明暗模式变化时刷新玻璃描边颜色（动态颜色 CGColor 不会自动跟随，需手动重取）
- (void)refreshGlassEdgeColors {
    CGColorRef color = [GlassTheme glassBorderColor].CGColor;
    for (UIView *container in @[self.sidebarContainer, self.rightPanelContainer]) {
        if (!container) continue;
        for (CALayer *sub in container.layer.sublayers) {
            if ([sub isKindOfClass:[CAShapeLayer class]] && [sub.name isEqualToString:@"glassEdge"]) {
                ((CAShapeLayer *)sub).strokeColor = color;
            }
        }
    }
}

/// 容器尺寸变化后重算玻璃描边路径（旋转 / 分屏 / 设备切换）
- (void)refreshGlassEdgePaths {
    for (UIView *container in @[self.sidebarContainer, self.rightPanelContainer]) {
        if (!container || container.bounds.size.width <= 0 || container.bounds.size.height <= 0) continue;

        BOOL isSidebar = (container == self.sidebarContainer);
        UIRectCorner corners = isSidebar
            ? (UIRectCornerTopLeft | UIRectCornerBottomLeft)
            : (UIRectCornerTopRight | UIRectCornerBottomRight);
        CGFloat radius = [GlassTheme containerCornerRadius];

        for (CALayer *sub in container.layer.sublayers) {
            if ([sub isKindOfClass:[CAShapeLayer class]] && [sub.name isEqualToString:@"glassEdge"]) {
                CAShapeLayer *edge = (CAShapeLayer *)sub;
                // 关闭隐式动画，避免旋转时描边"追着跑"
                [CATransaction begin];
                [CATransaction setDisableActions:YES];
                edge.frame = container.bounds;
                edge.path = [UIBezierPath bezierPathWithRoundedRect:container.bounds
                                                  byRoundingCorners:corners
                                                        cornerRadii:CGSizeMake(radius, radius)].CGPath;
                [CATransaction commit];
            }
        }
    }
}

- (void)uiEffectChanged:(NSNotification *)notification {
    // 重新应用毛玻璃/半透明效果到容器视图
    [[BackgroundManager sharedManager] applyEffectToView:self.sidebarContainer];
    [[BackgroundManager sharedManager] applyEffectToView:self.rightPanelContainer];
    // 半透明/毛玻璃切换会改变底层画面，液态玻璃的折射层需重新采样
    if (self.view.window) {
        [GlassEffectView refreshGlassInViewHierarchy:self.view.window];
    }
}

- (void)dealloc {
    [[NSNotificationCenter defaultCenter] removeObserver:self];
}

#pragma mark - Custom Appearance（字体颜色 / 卡片颜色，与 Card 布局一致）

- (void)applyCustomAppearance {
    // 应用自定义卡片颜色（半透明覆盖 BackgroundManager 的毛玻璃，而非完全替换）
    NSString *cardColor = getPrefObject(@"general.card_color");
    if (cardColor.length > 0) {
        UIColor *color = [self colorFromHexString:cardColor];
        if (color) {
            // 使用半透明颜色覆盖毛玻璃，alpha 提升到 0.85 增强可见度。
            // 之前 0.7 太淡，浅色背景几乎看不出效果。
            // 保留毛玻璃（backgroundColor 叠加在 UIVisualEffectView 之上），
            // 既显示卡片色调又透出背景图。
            CGFloat r, g, b, a;
            if ([color getRed:&r green:&g blue:&b alpha:&a]) {
                UIColor *semiColor = [UIColor colorWithRed:r green:g blue:b alpha:MIN(a, 0.85)];
                [self applySemiTransparentColor:semiColor toContainer:self.sidebarContainer];
                [self applySemiTransparentColor:semiColor toContainer:self.rightPanelContainer];
            }
        }
    } else {
        // 未设置自定义颜色时，恢复毛玻璃效果
        [self restoreEffectToContainer:self.sidebarContainer];
        [self restoreEffectToContainer:self.rightPanelContainer];
    }
    // 通知右侧面板、菜单等子 VC 同步刷新外观（text_color / card_color 联动）
    [[NSNotificationCenter defaultCenter] postNotificationName:@"LauncherAppearanceApplied" object:nil];
}

- (void)applySemiTransparentColor:(UIColor *)color toContainer:(UIView *)container {
    // 保留 BackgroundManager 的毛玻璃 UIVisualEffectView，在其上叠加半透明纯色
    // 这样既显示用户自定义的卡片颜色，又能透出背景图
    container.backgroundColor = color;
}

- (void)restoreEffectToContainer:(UIView *)container {
    container.backgroundColor = [UIColor clearColor];
    // 检查是否已有毛玻璃，没有则重新应用
    BOOL hasBlur = NO;
    for (UIView *sub in container.subviews) {
        if ([sub isKindOfClass:[UIVisualEffectView class]]) {
            hasBlur = YES;
            break;
        }
    }
    if (!hasBlur) {
        [[BackgroundManager sharedManager] applyEffectToView:container];
    }
}

- (UIColor *)colorFromHexString:(NSString *)hexString {
    NSString *hex = [hexString stringByReplacingOccurrencesOfString:@"#" withString:@""];
    if (hex.length != 6 && hex.length != 8) return nil;
    unsigned int rgb = 0;
    if (![[NSScanner scannerWithString:hex] scanHexInt:&rgb]) return nil;
    unsigned int r, g, b, a;
    if (hex.length == 6) {
        // RRGGBB
        r = (rgb >> 16) & 0xFF;
        g = (rgb >> 8) & 0xFF;
        b = rgb & 0xFF;
        a = 255;
    } else {
        // AARRGGBB
        a = (rgb >> 24) & 0xFF;
        r = (rgb >> 16) & 0xFF;
        g = (rgb >> 8) & 0xFF;
        b = rgb & 0xFF;
    }
    return [UIColor colorWithRed:r/255.0 green:g/255.0 blue:b/255.0 alpha:a/255.0];
}

#pragma mark - Content Switching

- (void)setContentViewController:(UIViewController *)viewController animated:(BOOL)animated {
    if (!viewController) return;

    // 关键修复（UI 累积异常）：同一实例直接跳过，避免对同一 VC 重复添加约束
    // 和反复调用 applyEffectToNavigationBar: 导致 hairline UIImageView 累积。
    if (viewController == _contentViewController) return;

    // 检查是否切换到非编辑器页面
    if (![viewController isKindOfClass:[UINavigationController class]] ||
        ![((UINavigationController *)viewController).topViewController isKindOfClass:[ProfileSettingsViewController class]]) {
        self.isShowingProfileEditor = NO;
        self.profileEditorVC = nil;
    }

    UIViewController *oldVC = _contentViewController;

    // 移除旧的 + 添加新的
    _contentViewController = viewController;
    [self addChildViewController:viewController];
    viewController.view.translatesAutoresizingMaskIntoConstraints = NO;

    // FCL 风格：对 UINavigationController 应用 nav bar 毛玻璃效果，并对内容 VC 透明化处理，
    // 避免顶部出现默认白色 nav bar 形成"大白条"，同时与两侧深色毛玻璃面板视觉一致。
    if ([viewController isKindOfClass:[UINavigationController class]]) {
        UINavigationController *nav = (UINavigationController *)viewController;
        nav.delegate = self;
        [[BackgroundManager sharedManager] applyEffectToNavigationBar:nav.navigationBar];
        // 透明化 topViewController，让背景透出 nav bar 毛玻璃
        [[BackgroundManager sharedManager] makeViewControllerTransparent:nav.topViewController];
        // 透明化 nav 栈中所有已存在的 VC（防止前一个页面透出残留）
        for (UIViewController *stackVC in nav.viewControllers) {
            [[BackgroundManager sharedManager] makeViewControllerTransparent:stackVC];
        }
    } else {
        // 非导航控制器包装的 VC 也透明化，确保与背景融合
        [[BackgroundManager sharedManager] makeViewControllerTransparent:viewController];
    }

    // 关键修复（UI 累积异常）：deactivate 旧约束，避免在 tmpRootVC 保留场景下
    // 缓存复用的子 VC 反复激活约束导致 contentContainer 内容区左右变宽。
    if (self.currentContentConstraints.count > 0) {
        [NSLayoutConstraint deactivateConstraints:self.currentContentConstraints];
        self.currentContentConstraints = nil;
    }

    NSArray<NSLayoutConstraint *> *newConstraints = @[
        [viewController.view.leadingAnchor constraintEqualToAnchor:self.contentContainer.leadingAnchor],
        [viewController.view.trailingAnchor constraintEqualToAnchor:self.contentContainer.trailingAnchor],
        [viewController.view.topAnchor constraintEqualToAnchor:self.contentContainer.topAnchor],
        [viewController.view.bottomAnchor constraintEqualToAnchor:self.contentContainer.bottomAnchor]
    ];

    if (animated && oldVC) {
        // ===== Glass 页面切换动效 =====
        // 样式由 GlassTheme 依偏好 general.transition_style 决定，默认 slide-up（从下方浮入）。
        // 无论哪种样式，都遵守同一套父子 VC 生命周期纪律：
        //   1) 先把新 VC 的视图挂上并激活约束（否则 bounds 为 0，浮入距离/缩放基准都算错）
        //   2) 在动画 block 内 layoutIfNeeded 强制布局，避免 UIKit snapshot 时 frame 还是 (0,0,0,0)
        //   3) completion 中收尾旧 VC 并复位其 transform/alpha，防止复用残留
        [self.contentContainer addSubview:viewController.view];
        [NSLayoutConstraint activateConstraints:newConstraints];
        [self.contentContainer layoutIfNeeded];

        [oldVC willMoveToParentViewController:nil];
        [viewController didMoveToParentViewController:self];

        GlassTransitionStyle style = [GlassTheme currentTransitionStyle];
        NSTimeInterval duration = [GlassTheme transitionDuration];
        CGFloat damping = [GlassTheme transitionDamping];
        CGFloat velocity = [GlassTheme transitionVelocity];

        // 退场页复位，保证初始状态干净（可能被上一次动效或复用残留影响）
        oldVC.view.transform = CGAffineTransformIdentity;
        oldVC.view.alpha = 1.0;

        void (^cleanup)(BOOL) = ^(BOOL finished) {
            [oldVC.view removeFromSuperview];
            [oldVC removeFromParentViewController];
            // 关键：退场页在动画中被改过 transform/alpha，必须复位，否则该 VC 复用时会带残留
            oldVC.view.transform = CGAffineTransformIdentity;
            oldVC.view.alpha = 1.0;
            // 新页面同样复位，确保后续布局不受残留 transform 影响
            viewController.view.transform = CGAffineTransformIdentity;
            viewController.view.alpha = 1.0;
        };

        if (style == GlassTransitionStyleCrossDissolve) {
            // 原版交叉淡化：仅在容器上做 transition，保证无残影
            [UIView transitionWithView:self.contentContainer
                              duration:0.3
                               options:UIViewAnimationOptionTransitionCrossDissolve
                            animations:^{
                                [oldVC.view removeFromSuperview];
                                [self.contentContainer addSubview:viewController.view];
                                [self.contentContainer layoutIfNeeded];
                            } completion:^(BOOL finished) {
                                cleanup(finished);
                            }];
        } else {
            // slide-up / scale-fade：位移或缩放淡入，旧页反向让位形成视差
            CGFloat h = self.contentContainer.bounds.size.height;
            CGFloat oldOffsetY = [GlassTheme transitionOldPageOffsetY];

            if (style == GlassTransitionStyleScaleFade) {
                viewController.view.transform = CGAffineTransformMakeScale(0.92, 0.92);
            } else {
                // 浮入基准：整屏高度之下，配合弹簧阻尼产生"浮上来"的观感
                viewController.view.transform = CGAffineTransformMakeTranslation(0, MAX(h, 120.0));
            }
            viewController.view.alpha = 0.0;

            [UIView animateWithDuration:duration
                                  delay:0
                 usingSpringWithDamping:damping
                  initialSpringVelocity:velocity
                                options:UIViewAnimationOptionCurveEaseOut | UIViewAnimationOptionAllowUserInteraction
                             animations:^{
                viewController.view.transform = CGAffineTransformIdentity;
                viewController.view.alpha = 1.0;
                // 旧页上移并淡出，形成"被顶上去"的层次感
                oldVC.view.transform = CGAffineTransformMakeTranslation(0, -oldOffsetY);
                oldVC.view.alpha = 0.0;
            } completion:^(BOOL finished) {
                cleanup(finished);
            }];
        }
    } else {
        if (oldVC) {
            [oldVC willMoveToParentViewController:nil];
            [oldVC.view removeFromSuperview];
            [oldVC removeFromParentViewController];
        }
        [self.contentContainer addSubview:viewController.view];
        [NSLayoutConstraint activateConstraints:newConstraints];
        [viewController didMoveToParentViewController:self];
    }

    self.currentContentConstraints = newConstraints;
}

#pragma mark - Orientation

- (BOOL)shouldAutorotate {
    return YES;
}

- (UIInterfaceOrientationMask)supportedInterfaceOrientations {
    return UIInterfaceOrientationMaskLandscape;
}

#pragma mark - UINavigationControllerDelegate

/// 当 nav 栈 push 或 pop 完成后，对新显示的 VC 透明化处理，
/// 确保所有 push 进来的子页面（如 Java 管理、模组管理、整合包导入等）
/// 都能透出自定义启动器背景，而非显示默认的 systemBackgroundColor（白色）。
- (void)navigationController:(UINavigationController *)navigationController
       didShowViewController:(UIViewController *)viewController
                    animated:(BOOL)animated {
    // 透明化刚显示的 VC
    [[BackgroundManager sharedManager] makeViewControllerTransparent:viewController];
    // 同时透明化栈中所有 VC（防止前一个页面透出残留，解决"前一页面未及时消失"问题）
    for (UIViewController *stackVC in navigationController.viewControllers) {
        [[BackgroundManager sharedManager] makeViewControllerTransparent:stackVC];
    }
    // 重新应用导航栏毛玻璃效果（防止 push 后 nav bar 样式被重置）
    [[BackgroundManager sharedManager] applyEffectToNavigationBar:navigationController.navigationBar];
}

@end
