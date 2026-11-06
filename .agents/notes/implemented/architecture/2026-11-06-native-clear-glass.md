# Agent Note: 原生清透玻璃与内容穿过控件层

Status: implemented

## Problem

用户提供 Liquid Glass 设置截图，指出已有界面丢失透明玻璃效果，并要求 iOS 使用官方 API。旧材质在暗色/浅色上叠加 88%/84% 实色且模糊半径为 18；聊天导航、消息和输入区纵向排布，玻璃后面只有背景，无法透出滚动内容。

## Decision

支持 iOS 26 API 的构建和设备通过 Flutter platform view 使用 UIKit `UIGlassEffect(style: .clear)`，alpha 保持 1，由系统决定材质；控件内容、点击与语义仍由 Flutter 持有。只读通道查询原生能力，Xcode/系统不支持时回退 Flutter，减少透明度和高对比度使用不透明底色。UIKit 装饰视图不接收手势，不创建第二份可访问性控件。

Flutter 路径降低底色覆盖与模糊强度，加方向性边缘高光和外部阴影。聊天详情使用 Scaffold 的同帧测量传递覆盖区域高度，滚动内容绘制在玻璃后，首尾 padding 保护静止阅读与点击；输入内部不再添加实色填充。列表的电脑与操作并入标题区，操作组和智能体按钮复用玻璃组件，紧凑布局归属[整体界面重做](2026-11-06-liquid-glass-mobile-ui.md)。保持原有连接、权限、草稿、返回与通知控制。

## 记录归属

检索活跃玻璃、导航、无障碍记录后，[整体界面重做](2026-11-06-liquid-glass-mobile-ui.md)部分重叠，继续持有三标签导航与业务分离；本篇取代其“全部材质由 Flutter 绘制”的选择并补足背景合成。用户参考图仅留本机，不作为产品素材或测试资产。没有需要删除或归档的笔记。[有界更新与悬浮提示](../bug-fix/2026-11-06-bounded-chat-updates.md)持有同轮修复的订阅与错误层级。

## Alternatives considered

- 单纯把透明度调低能少改代码，但纵向布局让控件背后没有内容，因此必须同时改叠放方式。
- 全部平台继续使用 Flutter 可以统一实现，但支持版本的 iOS 有系统折射和材质行为，用户明确希望使用官方 API，因此优先原生能力。
- 把整个 App 改为 SwiftUI 可直接使用全部原生控件，但会重写现有 Android 和 Flutter 页面；仅原生化装饰层，保留现有业务与交互。
- 在背景添加照片可让玻璃明显，但照片并非本产品内容，不能证明聊天滚动下的真实透光；采用实际页面和合成彩色背景验证。

## Testing

像素测试对比玻璃下红蓝背景，要求通道差异大于 85，实色降级差异小于 3，避免“只有 BackdropFilter 就算透明”的错误验收。两张长聊天滚动基线检查内容与导航/输入区的实际重叠，并保留浅深色、中英文、窄屏、2 倍字体和键盘回归。Flutter 全量 354 项通过、2 项原生入口依既有条件跳过，静态分析无问题。80 项构建脚本测试与 iOS source membership 静态校验通过；原生能力与无障碍信号有通道回归，RunnerTests 包含官方 effect 类型、alpha 与交互隔离测试，但没有在 Windows 执行 XCTest。

官方依据：[UIGlassEffect](https://developer.apple.com/documentation/uikit/uiglasseffect)从 iOS 26 起可用；[Flutter iOS platform views](https://docs.flutter.dev/platform-integration/ios/platform-views)使用混合合成，需在目标设备核验材质对 Flutter 内容的采样。

2026-11-07 00:39（UTC+8）已同签名覆盖安装 Lenovo L71091。APK SHA256 为 `b9454aafbe2ed72af27038258736b8ba92c388ce363ae9f8b2f85e8b8305b1d8`，设备包哈希一致；367 个源码/配置文件构建前后未变，10 个关键数据库/凭据/通知文件安装期间未变，启动返回 ok。真机滚动与键盘截图确认正文穿过玻璃后方；没有输入或发送测试内容。6 次滚动的 125 个有效 SurfaceFlinger 呈现间隔中位数 8.35 ms、95 分位 16.70 ms，仅为 debug 样本，不代表发布版构建/栅格耗时。当前进程日志未出现崩溃、布局溢出或原生库加载错误。证据仅在 `.local/clear-glass-delivery/`，不提交真实会话截图。

提交 `5c164dd` 的 [GitHub Actions 42253618038](https://github.com/mc373906408/codex-mobile-bridge-app/actions/runs/42253618038)最终结论为 success：普通版和 cloud 版 iOS 无签名 Xcode 编译、Swift storage/preview、Windows/macOS host FFI，以及 Windows Android APK/AAB 构建校验均已通过。手动定向 FFI job 和发布 job 按触发条件跳过，不代表未执行普通流水线中的真实 FFI 检查。可下载[用于用户签名的普通 iOS 包](https://github.com/mc373906408/codex-mobile-bridge-app/actions/runs/42253618038/artifacts/13523638960)、[cloud iOS 构建](https://github.com/mc373906408/codex-mobile-bridge-app/actions/runs/42253618038/artifacts/13524025005)和[Android 构建](https://github.com/mc373906408/codex-mobile-bridge-app/actions/runs/42253618038/artifacts/13526097035)。iOS 签名安装及 iPhone 材质/输入验收尚未执行；CI 编译成功不能替代这项验证。

## Consequences

玻璃现在采样实际滚动内容，iOS 支持版本使用系统材质，其余平台保留共用回退。代价是 UiKitView 引入混合合成，平台视图与 Flutter 文本必须在真机核验背景采样和输入；Windows 本机不能代替 Xcode 编译或 iPhone 验收。Flutter 模糊与高光不等同于系统光学效果。降低遮盖使背景对文字的影响增加，静止 padding 和无障碍回退不可省略。
