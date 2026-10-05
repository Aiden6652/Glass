//
//  AiToolBootstrapper.m
//  Amethyst
//

#import "AiToolBootstrapper.h"
#import "AiToolRegistry.h"

#import "AiInstancesTool.h"
#import "AiLogReader.h"
#import "AiCrashAnalyzer.h"
#import "AiFileTools.h"
#import "AiAskTool.h"
#import "AiAssetTools.h"
#import "AiSettingsTools.h"
#import "AiTodoTool.h"
#import "AiSleepTool.h"
#import "AiDownloadProbe.h"
#import "AiInstanceCreator.h"
// ★ [GLASS] 通用联网 / GitHub / 目录授权 / 源码树 / 自省工具
#import "AiWebFetchTool.h"
#import "AiGitHubTools.h"
#import "AiFolderAccessTool.h"
#import "AiGitHubTreeTool.h"
#import "AiListToolsTool.h"

@implementation AiToolBootstrapper

+ (void)registerBuiltinToolsIntoRegistry:(AiToolRegistry *)registry {
    if (!registry) return;

    // ===== 3a 阶段内置工具 =====

    // 实例/版本工具（list_instances、list_game_versions）
    [registry registerTool:[[AiInstancesTool alloc] initWithName:@"list_instances"]];
    [registry registerTool:[[AiInstancesTool alloc] initWithName:@"list_game_versions"]];

    // 日志读取工具（read_latest_log、read_crash_report）
    [registry registerTool:[[AiLogReader alloc] initWithName:@"read_latest_log"]];
    [registry registerTool:[[AiLogReader alloc] initWithName:@"read_crash_report"]];

    // 崩溃分析工具（match_known_errors）
    [registry registerTool:[[AiCrashAnalyzer alloc] init]];

    // 文件工具（list_files、read_file、grep_files、write_file、edit_file、delete_file）
    [registry registerTool:[[AiFileTools alloc] initWithName:@"list_files"]];
    [registry registerTool:[[AiFileTools alloc] initWithName:@"read_file"]];
    [registry registerTool:[[AiFileTools alloc] initWithName:@"grep_files"]];
    [registry registerTool:[[AiFileTools alloc] initWithName:@"write_file"]];
    [registry registerTool:[[AiFileTools alloc] initWithName:@"edit_file"]];
    [registry registerTool:[[AiFileTools alloc] initWithName:@"delete_file"]];

    // 交互问答工具（ask）
    [registry registerTool:[[AiAskTool alloc] init]];

    // ===== 以下为 3b 资源工具 =====

    // Modrinth 搜索工具（ExternalNetwork）
    [registry registerTool:[[AiAssetSearchTool alloc] initWithName:@"search_mods"]];
    [registry registerTool:[[AiAssetSearchTool alloc] initWithName:@"search_resourcepacks"]];
    [registry registerTool:[[AiAssetSearchTool alloc] initWithName:@"search_shaders"]];
    [registry registerTool:[[AiAssetSearchTool alloc] initWithName:@"search_datapacks"]];
    [registry registerTool:[[AiAssetSearchTool alloc] initWithName:@"search_modpacks"]];
    [registry registerTool:[[AiAssetSearchTool alloc] initWithName:@"search_worlds"]];

    // 资源安装 / 加载器工具（ControlledWrite）
    [registry registerTool:[[AiAssetInstallTool alloc] initWithName:@"install_mod"]];
    [registry registerTool:[[AiAssetInstallTool alloc] initWithName:@"install_resourcepack"]];
    [registry registerTool:[[AiAssetInstallTool alloc] initWithName:@"install_shader"]];
    [registry registerTool:[[AiAssetInstallTool alloc] initWithName:@"install_datapack"]];
    [registry registerTool:[[AiAssetInstallTool alloc] initWithName:@"install_game_version"]];
    [registry registerTool:[[AiAssetInstallTool alloc] initWithName:@"install_loader"]];

    // ===== enhance-ai-agent 新增工具 =====

    // 日志扩展（read_latest_log/read_crash_report 支持 instance 参数）
    [registry registerTool:[[AiLogReader alloc] initWithName:@"read_logs"]];

    // 下载进度查询（ReadOnly）
    [registry registerTool:[[AiDownloadProbe alloc] initWithName:@"check_downloads"]];

    // 设置工具（list/get 为 ReadOnly；set 为 ControlledWrite）
    [registry registerTool:[[AiSettingsTools alloc] initWithName:@"list_settings"]];
    [registry registerTool:[[AiSettingsTools alloc] initWithName:@"get_setting"]];
    [registry registerTool:[[AiSettingsTools alloc] initWithName:@"set_setting"]];

    // to-do 清单工具
    [registry registerTool:[[AiTodoTool alloc] initWithName:@"todo_create"]];
    [registry registerTool:[[AiTodoTool alloc] initWithName:@"todo_list"]];
    [registry registerTool:[[AiTodoTool alloc] initWithName:@"todo_update"]];
    [registry registerTool:[[AiTodoTool alloc] initWithName:@"todo_delete"]];

    // sleep（ReadOnly，无副作用）
    [registry registerTool:[[AiSleepTool alloc] init]];

    // 新建游戏目录实例（ControlledWrite）
    [registry registerTool:[[AiInstanceCreator alloc] init]];

    // ===== ★ [GLASS] 3c 阶段：通用联网浏览工具 =====
    // fetch_url（ReadOnly，任何安全模式直接放行）：允许 AI 查看 GitHub 等任意公开网页/API
    [registry registerTool:[[AiWebFetchTool alloc] init]];

    // ===== ★ [GLASS] 3d 阶段：GitHub 代码推送工具 =====
    // github_set_token / github_push（ExternalNetwork）：允许 AI 替用户向 GitHub 推送代码
    [registry registerTool:[[AiGitHubTool alloc] initWithName:@"github_set_token"]];
    [registry registerTool:[[AiGitHubTool alloc] initWithName:@"github_push"]];

    // ===== ★ [GLASS] 3e 阶段：文件访问权限放宽 + GitHub 源码树浏览 =====

    // 文件根目录枚举（ReadOnly）：让 AI 知道当前可访问哪些根（容器 + 已授权外部目录）
    [registry registerTool:[[AiFileTools alloc] initWithName:@"list_roots"]];

    // 容器外目录授权（folder_request_access 为 ExternalNetwork，其余只读/受控写入）
    [registry registerTool:[[AiFolderAccessTool alloc] initWithName:@"folder_request_access"]];
    [registry registerTool:[[AiFolderAccessTool alloc] initWithName:@"folder_list_authorized"]];
    [registry registerTool:[[AiFolderAccessTool alloc] initWithName:@"folder_revoke_access"]];

    // GitHub 仓库源码浏览（ReadOnly）：整树列出 / 批量读文件 / 仓库内搜代码
    [registry registerTool:[[AiGitHubTreeTool alloc] initWithName:@"github_tree"]];
    [registry registerTool:[[AiGitHubTreeTool alloc] initWithName:@"github_read_files"]];
    [registry registerTool:[[AiGitHubTreeTool alloc] initWithName:@"github_search_code"]];

    // ===== ★ [GLASS] 自省工具 =====
    // list_tools（ReadOnly）：让 AI 主动查询当前运行时到底注册了哪些工具，
    // 避免「凭记忆猜工具名」导致调用不存在的工具，也便于用户排查工具缺失。
    [registry registerTool:[[AiListToolsTool alloc] initWithName:@"list_tools"]];
}

@end