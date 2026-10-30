# 安装轻传

## Mac

从 [GitHub Releases](../../../releases) 下载适用于 Apple 芯片的 macOS ZIP。解压后，将“轻传.app”放入应用程序目录，再打开。支持 macOS 13 或更新版本。下载版运行不需要 Xcode、Python 或 Node.js。macOS 可能提示安全检查，请按系统和 [Apple 官方说明](https://support.apple.com/102445)处理。

更新前先退出旧版；保留旧应用备份后替换。不要删除 `~/Library/Application Support/BridgeDrop` 或钥匙串中的原有配对。应用含同一 bundle ID 的副本重复启动时，会优先打开已运行的副本。

## iPhone

本项目目前提供 iOS 源码和 Xcode 工程，没有 App Store、TestFlight 或可直接安装的 IPA。使用完整 Xcode，选择 `BridgeDrop-iOS`，在 Signing & Capabilities 设置你自己的 Team，选择 iPhone 后构建安装。具体开发工具及测试见 [BUILDING.md](BUILDING.md)。开发签名与日常 Apple 账户是否相同没有配对要求。

界面默认使用英文，可在 Settings → Language 选择简体中文。两端安装新版后，Mac 打开“配对”（Pair）显示邀请。iPhone 系统相机若提供轻传链接入口，可点击进入；否则在轻传内使用“导入邀请码 → 扫描另一台设备”，或粘贴邀请文本。核对设备信息，勾选确认并点击“确认导入并配对”，才保存配对并连接。邀请码只能交给轻传处理，不要提交到搜索框、浏览器或在线二维码工具。

iPhone 首次打开或从后台返回时，已有配对可点击“开启 / 恢复已有配对连接”。传输期间请保持应用在前台；活动任务会暂时关闭自动锁屏。手动锁屏或切换应用仍可能暂停，返回后可继续。收到文字后手动点击复制，不会自动覆盖剪贴板。

## 网络

同一可互访局域网优先，无需相同 Apple 账户。Bonjour 不可用时，可以在设置中填写另一台设备的局域网 IP 和默认端口 47185。这个端口提供加密 TCP，不是网页服务；手动地址不能绕过访客网络的设备隔离。

不同网络需要自己部署和配置 HTTPS 中继；项目没有预置公共服务器。参见 [中继说明](../relay/README.md)。

## 验证范围

1.2.0 已通过 macOS 构建、核心与发送器测试、配对回归、本地 TCP 和本地中继联测，并使用 iOS SDK 编译了模拟器和设备架构版本。独立 iOS 模拟器可以安装、启动并接受测试应用链接；配对确认页尚未完成目视验收。

iOS 26.2 系统相机、实际 Mac ↔ iPhone 文件/文字传输及复杂真实网络仍待真机验收。只有源码构建通过不代表已经安装到你的 iPhone。正式分发并拥有域名后再评估 Universal Links。
