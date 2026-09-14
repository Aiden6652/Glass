//
//  AiFolderAccessTool.h
//  Amethyst
//
//  Air AI Agent 容器外目录授权工具：
//  借助系统 UIDocumentPickerViewController 让用户显式挑选一个容器外目录
//  （iCloud Drive、本机「我的 iPhone」、其它 App 的 Documents 等），
//  再用 security-scoped bookmark 持久化授权，供文件工具（list_files/read_file/…）读写。
//
//  provisioned tools:
//    - folder_request_access  弹出系统目录选择器，请用户授权一个目录（ExternalNetwork 级别）
//    - folder_list_authorized 列出已授权的目录（ReadOnly）
//    - folder_revoke_access   撤销某个已授权目录（ControlledWrite）
//

#import <Foundation/Foundation.h>
#import "AiTool.h"

NS_ASSUME_NONNULL_BEGIN

@interface AiFolderAccessTool : NSObject <AiTool>

- (instancetype)initWithName:(NSString *)name;

/// 供 AiFileTools 越界检查复用：返回所有已授权目录的**已解析绝对路径**。
/// 未授权任何目录时返回空数组（永不返回 nil）。
+ (NSArray<NSString *> *)authorizedRootPaths;

@end

NS_ASSUME_NONNULL_END
