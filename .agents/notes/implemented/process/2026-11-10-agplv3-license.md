# Agent Note: App 改用 AGPLv3

Status: implemented

## Problem

项目所有者要求 App 与 Server 统一采用 AGPL。App 根许可证、Rust Flutter 插件许可证和文档仍标注 MIT，原生包元数据未明确自有代码许可；应用的开源许可页只显式注册字体和 EasyTier，不能完整显示当前项目的授权。

## Decision

App 自有代码采用 `AGPL-3.0-only`，即 GNU Affero General Public License 第 3 版。根 [LICENSE](../../../../LICENSE)与 `rust_builder/LICENSE` 保存 [GNU 官方完整文本](https://www.gnu.org/licenses/agpl-3.0.txt)；[NOTICE](../../../../NOTICE)保留 `Copyright (c) 2026 waken`，明确第 3 版、免责说明与源码地址。两个自有 Rust crate 的 Cargo 元数据以及 iOS/macOS Podspec 使用同一 SPDX 标识。

`ios/Podfile.lock` 同步自有插件的规格校验值，依赖版本不变。CocoaPods 1.17.0 使用落盘规格文件的 SHA1；复现旧 JSON 的 `e20a707c28bb53f610ec4451eb0e00f0ff7a2d61` 后，仅更换 `license.type` 得到 `16afce00b2741963738aed2dd550987d66664afb`，避免 `pod install --deployment` 因规格元数据变化而拒绝锁文件。

根 LICENSE、NOTICE 作为 Flutter 资源随安装包提供，`registerAppLicenses()` 在现有开源许可页注册 Bridge Mobile 完整文本，继续注册 IBM Plex 和 EasyTier。`third_party/bridge-p2p`、Cargokit、字体及其他第三方材料保留原有许可；P2P 文档区分第三方快照与本仓库自有原生模块，不改写快照或重新生成 FFI。对应源码分发继续使用现有源码归档流程。

## 记录归属

已按 MIT、GPL、AGPL、license、许可证和开源检索活跃笔记，未发现自有代码许可的独立决定。[EasyTier 直连](../architecture/2026-11-06-easytier-p2p.md)部分重叠，保留 LGPL、上游 MIT 源码及对应源码归档的边界，双方互链。[后续修改同步手机](2026-11-05-verified-changes-to-phone.md)部分重叠，仍持有同签名覆盖安装及数据保留要求，双方互链。其他访问权限说明与版权无关；没有需归档或拒绝的既有 App 许可提案。

## Alternatives considered

- 保留 MIT 简化集成和商业采用，但不符合所有者最终要求的统一 AGPL 许可。
- GPLv3 适用于分发 copyleft，网络交互要求少于 AGPL；所有者明确选用 AGPL，因此不维持 GPLv3。
- AGPL-3.0-or-later 可允许接收者选择未来许可证版本，但本次仅授予第 3 版，不增加未请求的未来版本授权。
- 仅替换根 LICENSE 最少影响工程，却会遗漏原生插件元数据与安装包内的许可展示；因此同步已有入口并随包带入原文。

## Testing

根及插件 LICENSE 与 GNU 官方 AGPLv3 文本逐字节一致，SHA256 为 `0d96a4ff68ad6d4b6f1f30f713b18d5184912ba8dd389f86aa7710db079abcb0`。自有包元数据及资源声明检查通过，第三方目录和字体文件无变更。Dart 格式、Flutter 全量静态分析及 `test/widget_test.dart` 的六项测试通过，笔记三项门禁通过。

`python scripts/build_android.py --format apk --debug --abi arm64-v8a` 构建成功；10 个 ELF 库的打包与页对齐检查通过。实际 APK 中 LICENSE、NOTICE、EasyTier 和字体许可与源码逐字节一致。产物 `build/app/outputs/flutter-apk/app-debug.apk` 的 SHA256 为 `398bd35d94742a218520dede72f648c6820154acf7f087227700f55ac584f371`，构建报告位于 `build/reports/android/app-debug.apk.json`。更新 iOS 校验值后重新执行 `scripts/verify_build_snapshot.py` 通过，锁定依赖和生成代码未被升级；本轮没有在 macOS 上执行 iOS 构建。

2026-11-10 核查 ADB 5037、5038 均无在线设备，mDNS 也未发现手机；因此没有执行签名比对、覆盖安装或真机启动检查。任务启动的空 ADB 服务已停止，保留 APK 供设备恢复连接后安装。

同日后续原生业务交付已使用恢复在线的 Lenovo L71091 完成同签名覆盖安装，包 `ff14e3212eed27be0f10f9c757567997aab91f825cdf7234806c8f59dbe22a1d` 包含本篇许可资源。设备包哈希、启动和安装前数据保留通过，证据见[Web 功能验收](../../../../docs/web-parity.md)。

## Consequences

源码、包元数据与用户可见的授权一致，第三方版权继续独立保留。后续分发应提供适用的对应源码和重建材料；安装包增加两份小型文本资源。更换许可证不撤销历史 MIT 版本的既有授权，也不替代依赖组合或商店分发条件审查。首次许可构建时手机离线，后续包含许可资源的业务包已完成同签名真机交付。
