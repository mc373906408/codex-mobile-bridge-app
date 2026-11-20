# 手机交付

用户于 2026-11-20 明确要求：这台 Mac 不构建 Android，不进行安卓手机验收。不要在本机生成 APK、AAB 或执行安卓覆盖安装，也不要默认改用远程或 CI 构建。详见[本机不做 Android 构建](.agents/notes/implemented/process/2026-11-20-no-android-builds-on-this-mac.md)。

以下规则只适用于用户明确要求、且在其他获准环境中进行的 Android 交付：

- 修改完成必要验证后，覆盖安装到已确认的测试手机，并检查安装包哈希与启动结果。
- 当前测试手机是 Lenovo L71091（Android 13、ARM64），App 包名为 `dev.waken.bridge_mobile`。每次安装前重新核对设备与现有签名，不假定旧 ADB 地址仍有效。
- 正常更新沿用兼容签名，保留账号、连接、草稿和通知同意；不要卸载、清库或代用户重新登录。
- 手机不在线或安装受阻时，完成其他可执行工作，明确报告实际阻碍与尚未安装的状态，不宣称部署完成。
- 执行依据与验证边界见[后续修改同步手机](.agents/notes/implemented/process/2026-11-05-verified-changes-to-phone.md)。
