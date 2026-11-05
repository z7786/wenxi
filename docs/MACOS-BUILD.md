# macOS 测试版

首个测试版面向 Apple Silicon（ARM64）。应用、下载组件和解析脚本运行时要求 macOS 11 或更高版本；最终最低系统要求还需在对应系统实机验证。

使用现有 Flutter 界面、media_kit 播放器和 Gopeed 下载核心。支持外部 `.app` 播放器选择、独立视频窗口、访达文件定位、拖入文件、截图复制及局域网互传。Mac 的系统音量和亮度由系统控制。

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
