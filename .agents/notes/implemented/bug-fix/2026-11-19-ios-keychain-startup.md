# Agent Note: iOS Keychain 故障不阻断首页启动

Status: implemented

## Problem

首页初始化把可选的本地设备别名读取和数据库、设备目录、界面偏好放在同一个错误处理块中。iOS Keychain 返回 `Unexpected security result code` 时，别名读取失败会留下全局红色错误横幅。云账户索引也保存在 Keychain，失败时云登录控件被禁用，但首页没有显示原因。

## Decision

本地设备别名只用于展示。读取失败时继续加载设备与首页，用服务器原名显示，并在用户重命名时允许重新读取；不得覆盖或清除无法读取的已有别名。云账号和令牌属于安全凭据，读取失败仍须阻止登录和配对，不降级写入普通偏好。首页允许进入云服务页查看状态，同时明确显示存储错误。

iOS Keychain 的 OSStatus `-34018` 表示当前应用签名没有可用的 Keychain entitlement，使用签名配置提示；该插件的其他 `Unexpected security result code` 错误归类为安全存储不可用。模拟器用例必须使用 Flutter 默认签名构建，显式 `--no-codesign` 的包会返回 `-34018`。未知平台异常继续使用通用设备功能错误，并且错误文案不暴露原生诊断或凭据。

## 记录审计

- [本地设备名称](../feature/2026-11-07-local-computer-names.md)：部分重叠，继续持有别名的身份键、重命名和删除规则；本篇只规定启动时的失败隔离。
- [云目录错误](2026-11-14-cloud-directory-error-context.md)：部分重叠，继续持有云来源错误的呈现语境；本篇增加安全存储失败的首页诊断。
- [云登录通知](2026-11-05-cloud-notifications-on-login.md)：无关，继续持有登录成功后的通知默认行为；本篇不改变通知流程。
- 已检索活跃的 Keychain、启动、别名与云目录笔记，没有完全重复或需要归档的记录。

## Alternatives considered

- 让任何 Keychain 错误中断整个首页初始化，会把只影响显示名称的故障扩大到直连设备和应用导航。
- 允许云登录在凭据存储失败时继续，会造成无法安全恢复登录状态的账号流程，因此仍阻止登录并显示具体故障原因。
- 把所有 iOS 平台异常归结为权限提示，无法区分缺少签名 entitlement 与其他 Keychain 状态，因此只对已知 OSStatus 单独分类。

## Testing

Widget 回归以模拟的 `-34018` 同时触发别名与云账户读取失败，验证首页和直连入口保持可用、全局错误横幅消失、云存储错误可见，并可打开云服务页查看错误。错误文案测试覆盖缺失 entitlement、其他 Keychain OSStatus 及中文、英文展示。Flutter analyze 无问题，完整套件 542 项通过、5 项条件跳过。全新 iPhone 18 Pro iOS 27.2 模拟器上的默认 Flutter 构建首页无错误横幅；`integration_test/native_startup_test.dart` 实际写入、读取和删除 Keychain 测试凭据通过。全程只使用 iOS 模拟器，没有访问或操作实体手机。

## Consequences

可选展示数据的 Keychain 问题不会掩盖首页功能，账号凭据仍有 fail-closed 边界。云账号仍需要能够读写安全存储才可登录。模拟器的调试构建必须保留 Xcode 的模拟器签名处理；禁止用 `--no-codesign` 的产物判断 Keychain 是否可用。真实 iOS 设备的发布包仍须带正确 provisioning profile 和 Keychain entitlement，本轮没有验证实体设备或发布签名。
