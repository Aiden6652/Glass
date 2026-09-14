# Glass 完整源码包说明

基于 Aiden6652/Air @ ae2d067 全量修改后的完整仓库源码。

## 本包内容

完整仓库源码（可直接推送 GitHub 触发 Actions 构建 ipa），已应用全部 Glass 改造：

1. **全量改名**
   - bundle id：`com.air-devs.air` → `com.glass.launcher`（Info.plist / Makefile / 三份 entitlements / CI workflow / 后台下载 session id / os_log / URL scheme 前缀）
   - 可执行名：`AngelAuraAmethyst` → `Glass`（CMakeLists / Makefile / main.m / JavaApp 两处 System.load / .gitignore / CI artifact）
   - 显示名：Glass

2. **AI 模块**
   - 新增 `AI/AiListToolsTool`（list_tools 工具，AI 可自查可用工具）
   - AiAgent：工具清单注入 system prompt + 解析 ` ```tool_call ` 文本调用（不支持 function calling 的模型也能用工具）
   - AiToolRegistry：启动自检落盘 `Documents/AI/ai_tools_dump.txt`；未知工具错误附上可用工具清单
   - AI 会话页 Glass 化（输入栏浮入动效、气泡玻璃描边）

3. **皮肤缓存**
   - 新增 `SkinCacheManager`：启动联网刷新皮肤落盘 `Documents/skin_cache/`，失败回退本地缓存；本地离线账户跳过；1 小时节流

4. **Glass UI**
   - `GlassTheme`（统一主题）、主界面三栏浮入动效、玻璃描边、菜单按钮玻璃质感

## 排除项（重要）

- **`.git/`**：未包含。推送时建议直接在原 Air 仓库上覆盖（子模块 gitlink 保留），或新开仓库后执行 `git submodule add` 重建。
- **`ThirdParty/ZalithLauncher2/`**：1.3GB 纯参考代码（Android 启动器），不参与 iOS 构建，已排除。仓库里它是 git submodule（commit eba819bc）。CI 的 `git submodule update --init --recursive` 会自动拉取。
- 其余 4 个子模块（AFNetworking / DBNumberedSlider / ZeroTierFramework / fishhook，均已对齐到仓库记录的 commit）**已包含**在 `Natives/external/` 内。

## 推送提醒

- 若推到**原 Air 仓库**：直接覆盖文件即可，子模块不受影响。
- 若**新建 Glass 仓库**：不要用网页拖拽上传（子模块 gitlink 会丢失，CI 构建会挂）。用 git 命令行推送，或在网页建仓后本地 `git submodule add` 补齐。
- 改了 bundle id = 新沙盒容器。旧 App 数据（accounts/instances/controlmap/AI/java_runtimes）需手动迁移：Filza 把旧容器 Documents/ 拷到新容器，或等导出/导入功能。

## 构建

与原仓库一致：GitHub Actions → development workflow，产出
`com.glass.launcher-*-ios.ipa`（无 JIT）与 `-trollstore.tipa`（带 JIT）。
