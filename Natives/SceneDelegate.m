#import "SceneDelegate.h"
#import "ios_uikit_bridge.h"
#import "utils.h"
#import "LauncherRootViewController.h"
#import "LauncherCardLayoutViewController.h"
#import "AmeRootTabController.h"   // ★ [ROOTTAB] 根标签栏控制器
#import "LauncherLanguageViewController.h"   // ★ [I18N] 语言切换广播/语言选单
#import "LauncherPreferences.h"
#import "BackgroundManager.h"
#import "UpdateChecker.h"
#import "SkinCacheManager.h"   // ★ [GLASS] 皮肤缓存：启动联网刷新 + 失败回退本地
// ★ [MP-RESTORE] Terracotta 联机恢复
#import "TerracottaManager.h"
#import "TerracottaBridge.h"

extern UIWindow *mainWindow;

// ★ [FG] Air Task32 的呈现面执法入口（定义在 SurfaceViewController.m）。
//   设计上可周期性重复调用且幂等：pojavWindow 为空时直接返回 NO，非游戏态零副作用。
extern BOOL Amethyst_EnforceSDL3Presentation(void);

@interface SceneDelegate ()
@end

@implementation SceneDelegate

- (void)scene:(UIScene *)scene willConnectToSession:(UISceneSession *)session options:(UISceneConnectionOptions *)connectionOptions {
    // ★ [I18N-ORDER] 装根 UI 之前再兜一次:确保"生效语言"已解析(幂等;AppDelegate 已提前调过)。
    AmeLauncherPrimeLanguage();
    UIWindowScene *windowScene = (UIWindowScene *)scene;
    
    // 强制横屏 (iOS 16+)
    if (@available(iOS 16.0, *)) {
        UIWindowSceneGeometryPreferencesIOS *geometryPreferences = [[UIWindowSceneGeometryPreferencesIOS alloc] init];
        geometryPreferences.interfaceOrientations = UIInterfaceOrientationMaskAllButUpsideDown;   // ★ [PORTRAIT]
        [windowScene requestGeometryUpdateWithPreferences:geometryPreferences errorHandler:^(NSError *error) {
            NSLog(@"[SceneDelegate] Failed to update geometry: %@", error);
        }];
    }
    
    self.window = [[UIWindow alloc] initWithWindowScene:windowScene];
    self.window.frame = windowScene.coordinateSpace.bounds;
    // 修复：使用 systemBackgroundColor 自适应浅色/深色模式。
    // 之前硬编码深灰（0.08）在浅色模式下导致"中间一片黑"。
    // systemBackgroundColor 在浅色模式为白、深色模式为黑，自动适配。
    // BackgroundManager.applyBackgroundToWindow 会根据用户是否设置自定义壁纸覆盖此颜色。
    if (@available(iOS 13.0, *)) {
        self.window.backgroundColor = [UIColor systemBackgroundColor];
    } else {
        self.window.backgroundColor = [UIColor colorWithWhite:0.08 alpha:1.0];
    }
    mainWindow = self.window;

    // ★ [I18N] 根 UI 由统一入口安装（语言切换时会整体重建，见 handleLauncherLanguageChanged:）。
    // 之前这里内联按布局创建主页容器；抽成方法后，重建走同一逻辑，避免两处漂移。
    [self ameInstallLauncherRootUIWithSettingsLanguagePage:NO];

    // 外观模式（浅色/深色/跟随系统）：读 general.ui_theme 偏好。
    //   light  -> UIUserInterfaceStyleLight
    //   dark   -> UIUserInterfaceStyleDark（默认，保持与原行为一致）
    //   auto   -> UIUserInterfaceStyleUnspecified（跟随系统）
    // iOS 13+ 支持 overrideUserInterfaceStyle。仅设置 window 级别，不触碰账号/偏好。
    if (@available(iOS 13.0, *)) {
        NSString *theme = getPrefObject(@"general.ui_theme");
        if ([theme isEqualToString:@"light"]) {
            self.window.overrideUserInterfaceStyle = UIUserInterfaceStyleLight;
        } else if ([theme isEqualToString:@"auto"]) {
            self.window.overrideUserInterfaceStyle = UIUserInterfaceStyleUnspecified;
        } else {
            self.window.overrideUserInterfaceStyle = UIUserInterfaceStyleDark;
        }
    }

    [self.window makeKeyAndVisible];

    // 立即应用背景（移除原来的 0.1s 延迟）：
    // 延迟会在启动时露出窗口底色形成"黑条"或"黑闪"。BackgroundManager 在其 init
    // 中已 loadSavedBackground/loadUISettings，单例首次访问即完成初始化，无需延迟。
    [[BackgroundManager sharedManager] applyBackgroundToWindow:self.window];

    [self showTranslationNoticeIfNeeded];

    // ★ [GLASS] 启动时刷新皮肤缓存：正版/第三方账户联网拉最新皮肤落盘，失败回退本地缓存，
    //   本地离线账户内部直接跳过。放到下一个 runloop，避免阻塞启动首帧。
    dispatch_async(dispatch_get_main_queue(), ^{
        [SkinCacheManager refreshCurrentAccountSkinIfNeeded];
    });

    // 启动时自动检查启动器更新（参照 ZL2 LauncherUpgradeViewModel.checkOnAppStart）。
    // 仅当确实存在新版本时才弹窗；请求失败、已是最新、处于限频窗口内一律静默。
    // 延后一拍执行，等 rootViewController 完成首轮布局后再 present。
    dispatch_async(dispatch_get_main_queue(), ^{
        [UpdateChecker performStartupCheckFromPresenter:self.window.rootViewController];
    });

    // ★ [MP-RESTORE] 联机恢复 —— lazy init：启动路径上**不**创建 TerracottaManager /
    //   不触发 terracotta_ios_start / 不起 ZeroTier 节点（避免把当年"启动崩溃"风险带回）。
    //   TerracottaManager 是 dispatch_once 单例，首次进入联机页 [shared] 时才 init；
    //   这里只探测 libterracotta 是否已链接，供日志诊断。
    if ([TerracottaBridge isAvailable]) {
        NSLog(@"[SceneDelegate] libterracotta linked, multiplayer available (lazy init)");
    } else {
        NSLog(@"[SceneDelegate] libterracotta not linked, multiplayer disabled");
    }

    // 监听主题切换通知（设置页"外观模式"切换时实时应用，无需重启）
    [[NSNotificationCenter defaultCenter] addObserver:self
                                             selector:@selector(applyUITheme:)
                                                 name:@"UIThemeChanged"
                                               object:nil];

    // ★ [I18N] 语言切换：重建整棵启动器 UI，让所有页面重跑 localize（真正即时生效）。
    [[NSNotificationCenter defaultCenter] addObserver:self
                                             selector:@selector(handleLauncherLanguageChanged:)
                                                 name:AmeLauncherLanguageChangedNotification
                                               object:nil];
}

#pragma mark - ★ [I18N] 启动器根 UI 安装 / 语言切换重建

// ★ [UI-LAYOUT] 布局按设备自动判定（用户切换入口已移除；旧 general.ui_layout=card 已由
//   PLPreferences 在启动最早期【主动迁移】为 vs，见 [UI-LAYOUT-MIGRATE]）：
//   iPhone ⇒ 标准（LauncherRootViewController）；iPad ⇒ 卡片（LauncherCardLayoutViewController）。
//
//   为什么不再读 general.ui_layout：该键曾是设置页「UI 布局」的取值（vs/card）。用户可把
//   iPhone 也设成 card ⇒ iPhone 跑 iPad 的卡片布局 ⇒ 主页错乱（群主报的那个 bug）。旧值
//   即使仍留在 plist 里也不再影响根 VC 选择 ⇒ 存量 iPhone 不会卡在错乱态。
//
//   设备判定必须用【物理机型】(UIDevice.model)，不能用 idiom / traitCollection：
//   UIKit+hook.m 的 init_hookUIKitConstructor 会把 UIDevice/Screen 的 active idiom 强制
//   改写成 Pad 或 Phone（见 debug.debug_ipad_ui），那时 realUIIdiom、trait.userInterfaceIdiom
//   都不可靠。LauncherRootViewController / LauncherCardLayoutViewController 内部也各自用
//   同一套 UIDevice.model 判定（LauncherRootIsPhysicalPhone / LauncherCardLayoutIsPhysicalPhone），
//   口径一致。
// 按设备创建主页容器（willConnect 与语言切换重建共用同一逻辑）。
// ★ [UI-LAYOUT-MIGRATE] 布局统一走 ameResolveUILayout()（唯一解析函数，见 LauncherPreferences.m）。
//   它只按物理机型判定，不读遗留的 general.ui_layout —— 该键的 card 值已在启动最早期
//   被 PLPreferences 迁移（iPhone 上写回 vs），故无论库里存过什么，iPhone 一律标准布局。
- (UIViewController *)ameMakeLauncherHomeViewController {
    NSString *layout = ameResolveUILayout();
    BOOL isPad = [layout isEqualToString:@"card"];
    // ★ [UI-LAYOUT] 内部回退开关（不暴露给设置 UI，便于以后回退/装机对照）：
    //   仅 iPad 生效，值 "vs" ⇒ 临时强制标准布局；iPhone 端一律标准 ⇒ 无论配什么都不会
    //   再出现 card-on-iPhone 错乱。默认空串 = 按设备自动。
    NSString *force = getPrefObject(@"debug.debug_ui_layout_force");
    if (isPad && [force isEqualToString:@"vs"]) {
        NSLog(@"[UI-LAYOUT] iPad debug.debug_ui_layout_force=vs ⇒ standard(Root)");
        return [[LauncherRootViewController alloc] init];
    }
    if (isPad) {
        NSLog(@"[UI-LAYOUT] device=iPad ⇒ card layout (auto)");
        return [[LauncherCardLayoutViewController alloc] init];
    }
    NSLog(@"[UI-LAYOUT] device=iPhone ⇒ standard layout (auto); legacy general.ui_layout migrated -> vs");
    return [[LauncherRootViewController alloc] init];
}

// 安装 / 重建启动器根 UI。pushLanguagePage=YES 时（语言切换后）自动回到「设置 > 语言」
// 页面，并在新语言下给出确认提示。
// ★ 为什么整体重建：全启动器 2093 处 localize() 文案，大量在 viewDidLoad / cellForRow
//   里取好；只 reloadData 无法刷新 viewDidLoad 的静态文案。换成全新实例即可让它们
//   重新取词 —— 等价于"重启一次界面"，但不动进程、不动运行中的游戏
//   （SurfaceViewController 不在这棵树里，且切语言只可能发生在启动器设置页）。
- (void)ameInstallLauncherRootUIWithSettingsLanguagePage:(BOOL)pushLanguagePage {
    UIViewController *home = [self ameMakeLauncherHomeViewController];
    AmeRootTabController *tabs = [AmeRootTabController tabControllerWithHomeViewController:home];
    self.window.rootViewController = tabs;
    [[BackgroundManager sharedManager] applyBackgroundToWindow:self.window];

    if (!pushLanguagePage) return;

    const NSUInteger settingsIndex = 4;   // 与 AmeRootTabController 的标签顺序保持一致
    if (settingsIndex >= tabs.viewControllers.count) return;
    tabs.selectedIndex = settingsIndex;
    UIViewController *settingsVC = tabs.viewControllers[settingsIndex];
    if (![settingsVC isKindOfClass:[UINavigationController class]]) return;
    UINavigationController *nav = (UINavigationController *)settingsVC;

    LauncherLanguageViewController *lang = [[LauncherLanguageViewController alloc] init];
    [nav pushViewController:lang animated:NO];

    // 语言已切换的确认提示（用新语言显示），明确告诉用户"已经真的换了"。
    dispatch_async(dispatch_get_main_queue(), ^{
        UIAlertController *alert = [UIAlertController
            alertControllerWithTitle:localize(@"preference.lang.switched.title", @"语言已切换")
                             message:localize(@"preference.lang.switched.message",
                                 @"界面已按所选语言重新加载。")
                      preferredStyle:UIAlertControllerStyleAlert];
        [alert addAction:[UIAlertAction actionWithTitle:localize(@"OK", nil)
                                                  style:UIAlertActionStyleDefault
                                                handler:nil]];
        [lang presentViewController:alert animated:YES completion:nil];
    });
}

- (void)handleLauncherLanguageChanged:(NSNotification *)notification {
    // ★ [I18N] 重建根 UI ⇒ 底栏 / 主页 / 卡片 / 胶囊 / 设置页等全部重新取词。
    [self ameInstallLauncherRootUIWithSettingsLanguagePage:YES];
}

- (void)showTranslationNoticeIfNeeded {
    // 仅当系统语言为英文时提示：部分内容为机翻，可能不够准确，欢迎提交翻译 PR。
    // 用户选择"不再提醒"后通过偏好持久化，下次不再弹出。
    // ★ [I18N] 用"实际生效语言"判断（与界面渲染同一事实源），不再直接读 preferredLanguages。
    if (![AmeLauncherEffectiveLanguageCode() hasPrefix:@"en"]) {
        return;
    }
    if (getPrefBool(@"general.translation_notice_dismissed")) {
        return;
    }

    UIViewController *presenter = self.window.rootViewController;
    if (presenter == nil) {
        return;
    }

    UIAlertController *alert = [UIAlertController alertControllerWithTitle:localize(@"i18n_str_2000", nil)
                                                                   message:localize(@"i18n_str_2001", nil)
                                                            preferredStyle:UIAlertControllerStyleAlert];

    UIAlertAction *gotItAction = [UIAlertAction actionWithTitle:localize(@"i18n_str_2002", nil)
                                                          style:UIAlertActionStyleDefault
                                                        handler:nil];
    [alert addAction:gotItAction];

    UIAlertAction *dontAskAction = [UIAlertAction actionWithTitle:localize(@"i18n_str_2003", nil)
                                                            style:UIAlertActionStyleCancel
                                                          handler:^(UIAlertAction *action) {
        setPrefBool(@"general.translation_notice_dismissed", YES);
    }];
    [alert addAction:dontAskAction];

    [presenter presentViewController:alert animated:YES completion:nil];
}

- (void)applyUITheme:(NSNotification *)notification {
    // 实时切换外观模式。仅修改 window.overrideUserInterfaceStyle，
    // 不触碰 PLPreferences 重置逻辑、不读写账号数据，确保切换主题不会导致账号退出。
    NSString *theme = notification.object ?: getPrefObject(@"general.ui_theme");
    if (@available(iOS 13.0, *)) {
        if ([theme isEqualToString:@"light"]) {
            self.window.overrideUserInterfaceStyle = UIUserInterfaceStyleLight;
        } else if ([theme isEqualToString:@"auto"]) {
            self.window.overrideUserInterfaceStyle = UIUserInterfaceStyleUnspecified;
        } else {
            self.window.overrideUserInterfaceStyle = UIUserInterfaceStyleDark;
        }
    }
}

- (void)sceneDidDisconnect:(UIScene *)scene {
    [[NSNotificationCenter defaultCenter] removeObserver:self name:@"UIThemeChanged" object:nil];
}

#pragma mark - ★ [FG] 前后台切换：暂停 / 恢复 / 呈现面自愈

// 取证锚点：切后台与回前台各打一次 swap 计数。若回前台后 swapOK 不再增长，
// 即证实渲染循环在后台被楔死（而不是 MC 单纯停在暂停菜单）。
static void AmeFGLogSwapStats(NSString *phase) {
    unsigned long ok = 0, fail = 0;
    ame_egl_swap_stats(&ok, &fail);
    NSLog(@"[FG-Lifecycle] %@: swapOK=%lu swapFail=%lu", phase, ok, fail);
}

- (void)sceneDidBecomeActive:(UIScene *)scene {
    // ★ [FG] 回前台自愈：切后台/多任务切换期间，SDL 自建的空 UIWindow 与视图
    //   z 序可能被系统重新抬到宿主窗口之上（Air Task32「空窗黑盖子」），
    //   宿主 CAMetalLayer 被整块盖住即表现为回前台黑屏/卡住。这里补一次执法。
    //   该函数内部全程 @try 且幂等，非游戏态（pojavWindow==nil）直接返回 NO。
    @try {
        BOOL did = Amethyst_EnforceSDL3Presentation();
        NSLog(@"[FG-Lifecycle] didBecomeActive: presentation enforcement did=%d", (int)did);
    } @catch (NSException *e) {
        NSLog(@"[FG-Lifecycle] didBecomeActive: enforcement exception: %@", e);
    }
    // 重申窗口尺寸：让 MC 重新同步 framebuffer（内部已做 0 尺寸兜底）。
    CallbackBridge_resumeGameIfNeed();
    AmeFGLogSwapStats(@"didBecomeActive");
}

- (void)sceneWillResignActive:(UIScene *)scene {
    // ★ [FG] 立刻暂停。原先只有 sceneDidEnterBackground 会暂停，但上滑回主屏 /
    //   控制中心 / 通知中心 / 来电等场景里 didEnterBackground 要么晚到要么不到，
    //   且 pauseGameIfNeed 原先被 isGrabbing 挡住（26.3+ 恒 0，实为空操作）——
    //   MC 全程不知自己已进后台，仍按前台全速渲染，回前台即卡在半截状态。
    AmeFGLogSwapStats(@"willResignActive");
    CallbackBridge_pauseGameIfNeed();
}

- (void)sceneWillEnterForeground:(UIScene *)scene {
    AmeFGLogSwapStats(@"willEnterForeground");
}

- (void)sceneDidEnterBackground:(UIScene *)scene {
    // 幂等：已经停在暂停菜单时再发一次 ESC 无副作用。
    AmeFGLogSwapStats(@"didEnterBackground");
    CallbackBridge_pauseGameIfNeed();
}

#pragma mark - Orientation Support (iOS 16+)

- (UIInterfaceOrientationMask)scene:(UIScene *)scene supportedInterfaceOrientationsForWindowScene:(UIWindowScene *)windowScene API_AVAILABLE(ios(16.0)) {
    return UIInterfaceOrientationMaskAllButUpsideDown;   // ★ [PORTRAIT] 窗口层放开
}

@end
