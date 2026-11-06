# macOS 测试版

首个测试版面向 Apple Silicon（ARM64）。应用、下载组件和解析脚本运行时要求 macOS 11 或更高版本；最终最低系统要求还需在对应系统实机验证。

使用现有 Flutter 界面、media_kit 播放器和 Gopeed 下载核心。支持外部 `.app` 播放器选择、独立视频窗口、访达文件定位、拖入文件、截图复制及局域网互传。Mac 的系统音量和亮度由系统控制。

## 功能适配

备份和日志导出使用系统保存窗口；种子、字幕、背景图片使用文件选择器。云盘页面支持拖入文件上传，解析与账号页面采用桌面布局，收藏支持拖拽排序。已保存文件优先在同卷建立硬链接；卷或文件提供方拒绝硬链接时，检查空间后回退复制并保留原下载数据。

网页登录与网页搜索使用持久 WK 数据存储，保证登录 Cookie 能被读取；添加账号时只清理当前网盘及已知认证域的 Cookie。投屏支持手动输入电视 IP 或设备描述地址。

下载保护页面读取实际防休眠状态，按 Mac 行为提示最小化继续传输。Mac 不使用 Android 的保活通知、电池权限、APK 安装流程，也不使用 Windows 托盘或 `.exe` 播放器路径。下载和设备互传期间仍需保持应用运行，完全退出应用会停止传输。

当前只构建 Apple Silicon 测试包。Mac 原生摄像头扫码、访达文件关联和苹果原生崩溃采集尚未接入；设备连接可用连接码或手动地址。系统音量与屏幕亮度继续由 macOS 控制。

GitHub 工作流编译客户端，检查启动首帧，并运行 Dart 回归与原生 Go 存储、续传测试。系统文件窗口、网页授权、外部播放器及独立视频窗口仍需在 Mac 实机上验证。

## 构建

必须在 Mac 上安装 Flutter 3.41.4、Xcode、CocoaPods、Go 1.24.7、Python 3 和 PowerShell 7：

```powershell
./tool/build-macos.ps1 -BuildConfig config/build.community.json
```

现有官方客户端配置通过忽略提交的 `.local/build-config.json` 和对应 defines 文件提供；省略 `-BuildConfig` 会优先使用该配置。GitHub 的 macOS 工作流在手动官方构建时从 `release` 环境读取现有客户端配置，PR 检查使用公共配置。

```sh
python tool/macos-smoke.py --app build/macos/Build/Products/Release/文析助手.app
python tool/package-macos.py --app build/macos/Build/Products/Release/文析助手.app
```

安装包为 `.local/macos-release-assets/asterlink-版本号-macos-arm64-test.dmg` 和 ZIP，附 SHA-256。工作流检查原生架构、签名结构、下载助手、启动首帧以及相关回归测试。

## 安装测试

打开 DMG，将“文析助手”拖入 Applications。测试包只使用本地临时签名，没有 Developer ID 签名或苹果公证。首次启动若被 macOS 阻止，在“系统设置 → 隐私与安全性”中允许打开该测试应用。

测试包不进入正式自动更新选择。应用未启用 App Sandbox，以支持用户指定下载目录、下载子进程及局域网连接；此构建不适用于 Mac App Store。正式分发前需要 Developer ID 签名、公证及实机验证。
