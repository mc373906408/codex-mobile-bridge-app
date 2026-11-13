# Agent Note: 已认证聊天沿用网关返回的会话能力

Status: implemented

## Problem

手机已通过网关认证并能加载聊天列表，但打开聊天时，Rust 适配器因网关没有返回编码账号的 `draftAccountIdentity`，清空发送、审批、重连等能力，并显示“暂时无法验证账号身份”。该字段用于隔离草稿及旧操作，不是网关登录凭据。用户明确要求移除聊天内部这层额外拦截。

## Decision

共享入口为 `rust/src/adapters/mod.rs::finish_snapshot`，由 Codex、Claude、DeepSeek 和 ZCode 适配器复用；`Engine::snapshot` 继续要求当前网关认证有效。

聊天快照在网关授权身份有效时沿用网关返回的会话能力。`draftAccountIdentity` 是可选的作用域细分字段；缺失时仍以网关授权身份及完整会话身份生成草稿和操作作用域。字段有效时沿用现有作用域算法，保留已保存草稿。网关授权身份缺失时继续关闭操作能力；发送前继续重新读取快照、核对控制令牌，并通过认证、Origin、CSRF 和原生归属校验的网关接口执行。

可选编码账号标识从缺失变为有效、有效值变化、网关授权身份或完整会话身份变化时，作用域及控制令牌变化，旧操作不能沿用。缺失字段不产生账号身份错误，也不覆盖网关实际返回的连接提示。

## 记录审计

检索活跃笔记中的账号身份、账号指纹、`draftAccountIdentity` 和草稿隔离：[架构省察](../architecture/2026-11-04-app-architecture-and-scope-audit.md)与[原生 Web 功能接入](../architecture/2026-11-10-native-web-parity.md)部分重叠，继续持有网关认证、实例隔离、写入前核验和未知写入记录；本篇持有可选编码账号标识不再关闭聊天能力的决定，双方互链。[云聊天恢复提案](../../proposed/bug-fix/2026-11-05-cloud-chat-recovery-and-notice-scope.md)部分重叠，持有恢复期间提示的清理规则，本篇解决缺失可选字段导致新提示及能力清空的问题，双方互链。[云状态边界](2026-11-04-cloud-state-boundaries-and-legacy-removal.md)和[云登录通知](2026-11-05-cloud-notifications-on-login.md)判定为无关，分别持有其他云认证及通知边界。没有完全吸收记录或需要删除、归档的过时提案。手机交付沿用[同签名覆盖更新](../process/2026-11-05-verified-changes-to-phone.md)，双方互链。

## Alternatives considered

- 只隐藏提示可以减少打扰，但仍会清空能力、阻止输入和发送，不能解决用户遇到的拦截。
- 必须等编码账号标识出现才能打开操作，可以细分编码账号草稿，但将可选元数据变成额外认证条件，与网关已授权并返回会话能力的事实及本次用户要求冲突。

## Testing

新增用例先在旧实现稳定复现两处失败，再随修复通过。合成 HTTP 回归覆盖没有编码账号标识的 Codex、Claude、DeepSeek 和 ZCode 聊天，核对草稿作用域、Cookie、Origin、CSRF 及同一操作只提交一次；缺失网关授权身份仍关闭能力，标识变化仍使作用域和控制令牌失效。

`python -X utf8 scripts/test_rust.py` 完成 83 项 Rust 回归，1 项专用 P2P 实验夹具按原有要求跳过。Flutter 静态检查无问题，全量组件回归 402 项通过、4 项原生夹具按原有前提跳过。Rust 格式和 Git 空白检查通过。

Android ARM64 调试包构建成功，12 个 ELF 原生库的 16 KiB 页面对齐及 APK 对齐检查通过；547 个源码、依赖及生成文件的构建前后哈希一致。交付文件 `.local/deliveries/2026-11-11-authenticated-chat/app-debug-a58b723ea5df.apk` 的 SHA-256 为 `a58b723ea5df5a8efbd735ca76dacc03eeeb902a4081ec1d6a0915577144cf99`，单独核对交付副本后与构建报告一致。签名与最近交付的 APK 一致，服务端秘密排除检查通过。构建证据保存在 `.tmp/authenticated-chat-20261111/build-result.json` 与 `build/reports/android/app-debug.apk.json`。

2026-11-11 10:38（UTC+8）已在 Lenovo L71091（Android 13、ARM64）完成同签名覆盖安装；安装前重新拉取手机原 APK 核对签名。手机安装包 SHA-256 与上述产物一致，53 个持久化文件在安装后首次启动前哈希全部一致，原始安装时间保持。Activity 启动返回 `ok`，进程正常，启动日志未发现崩溃或原生库加载错误。安装证据见 `.tmp/authenticated-chat-20261111/installation-result.json`。无线调试随后换到用户提供的新端口，再次核对同一硬件设备、安装包哈希和运行进程通过，结果见同目录 `final-device-check.json`。

实机首次首页显示“暂无在线云设备”。后续检查时手机前台切换到其他应用，已停止界面操作；尚未完成真实聊天页打开及发送验证，不能将启动成功或合成 HTTP 测试视为真实聊天链路通过。界面证据仅保留本 App 首页，未保留其他应用截图或界面导出。

## Consequences

已认证聊天不再因缺少可选编码账号标识而被客户端额外关闭，草稿和操作仍按完整网关及会话作用域保存；网关实际返回的连接提示保留。网关未提供编码账号标识时，客户端无法仅凭该缺失字段区分同一会话内部的编码账号变化，授权及原生归属由网关即时核验。标识随后出现会切换作用域，旧草稿保留在原作用域，不自动迁移。若后续网关提供稳定的账号或配置版本，应优先复用该字段细分作用域，不重新引入聊天认证门槛。真机安装与启动已验证，真实聊天链路仍需在网关在线且 App 保持前台时核验。
