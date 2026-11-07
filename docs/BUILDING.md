# 编译

工具：Flutter 3.41.4 / Dart 3.11.1、Go 1.24.7。Android 需要 JDK 21、SDK 36 和 NDK 28.2.13676358；Windows 需要 Visual Studio 2022 C++ 桌面开发工具链。安装器使用 Inno Setup 6.7.3。

在项目根目录执行：

```powershell
$env:PUB_HOSTED_URL = 'https://pub.flutter-io.cn'
flutter pub get --enforce-lockfile
# Android 无签名构建检查
.\tool\build-android.ps1 -BuildConfig config/build.community.json -Unsigned
# Windows 完整运行目录
.\tool\build-windows.ps1 -BuildConfig config/build.community.json
# Windows 安装器
.\tool\build-windows-installer.ps1
```

缺少原生库时脚本会自动从源码构建。Android 可安装的正式包需要自己的签名，格式参考 `keystore.properties.example`。

测试和构建均使用 `pubspec.lock` 中记录的包源、版本及校验值。构建脚本不会自动升级依赖；更新依赖时先明确修改并验证锁文件，再提交源码。

## GitHub 自动构建

提交到 `main` 或创建面向 `main` 的 PR 会运行 `CI`，先完成源码检查及 Flutter、原生组件测试，再构建 Android ARM64、Windows x64 和 Windows ARM64。该流程使用公开配置，安卓构建检查不需要签名密钥。Windows ARM64 使用独立的 Flutter 3.47.9 及固定引擎校验，详情见 [ARM64 构建](WINDOWS-ARM64-BUILD.md)。

正式安装包在仓库的 **Actions → Build signed release → Run workflow** 中选择 `main` 后生成。推送与 `pubspec.yaml` 版本匹配的 `v` 标签也会触发，例如版本 `2.2.0+220` 对应 `v2.2.0+220`。工作流读取 GitHub 的 `release` environment：

| 类型 | 名称 |
| --- | --- |
| Secrets | `ANDROID_KEYSTORE_BASE64`、`ANDROID_KEYSTORE_PASSWORD`、`ANDROID_KEY_ALIAS`、`ANDROID_KEY_PASSWORD`、`ASTERLINK_CONTROL_URL`、`UMENG_APPKEY` |
| Variables | `ASTERLINK_APPLICATION_ID`（正式版为 `com.asterlink.app`）、`ASTERLINK_GITHUB_REPO`、`UMENG_CHANNEL` |

已有用户覆盖安装需要继续使用原签名密钥。私有配置和签名只放在 environment 中，不能提交到源码。

使用私有口令解析、百度取链及解析配置时，额外设置 Secret `ASTERLINK_CLIENT_DEFINES_JSON`。其 JSON 对象以 `baidu-api.defines.json`、`cloud-command.defines.json`、`parser-hub.defines.json` 为键，值为对应本机 `.local/` 文件的 JSON 对象。准备脚本只接受这些文件及已知客户端字段，写入临时构建目录后沿用本机构建的配置校验；不包含后端源码或管理凭据。

构建成功后，在运行详情底部的 **Artifacts** 下载 `release-android`（签名 APK）、`release-windows`（x64 安装器、便携 ZIP）和 `release-windows-arm64`（ARM64 安装器、便携 ZIP），保留 14 天。工作流只生成并上传构建附件，公开 Release 另行发布。

新增 ED2K 需要更新 Gopeed 原生组件。升级已有工作目录时，Android 构建加 `-RebuildNative`（正式入口同样支持该参数），避免沿用旧 AAR；Windows 构建会重建所选架构 helper。源码与验证说明见 [ED2K 下载](ED2K-DOWNLOAD.md)。

## macOS 测试包

macOS 构建需要 Mac 和 Xcode。仓库的 **Actions → Build macOS test app → Run workflow**
可选择 `arm64`（苹果芯片）或 `x64`（Intel），并使用原有客户端配置。工作流在对应
架构的 Mac 上编译，检查下载器、解析脚本运行库和播放器架构，并验证启动和视频播放。
成功后下载 `macos-arm64-test` 或 `macos-x64-test` 附件中的 DMG。

本机 Mac 使用 PowerShell 执行 `./tool/build-macos.ps1 -Architecture x64`，苹果芯片改为
`-Architecture arm64`；随后执行 `python tool/package-macos.py --app build/macos/Build/Products/Release/文析助手.app --architecture x64`。
输出位于 `.local/macos-release-assets/`。测试包使用临时签名，未配置 Developer ID 签名与苹果公证。

## 本机正式版

正式配置放在 `.local/build-config.json`，原签名配置放在 `.local/keystore.properties`。使用原包名与原签名才能覆盖已有安卓正式版。

```powershell
.\tool\build-official.ps1 -Platform all -Force
```

该入口固定读取本机正式配置，不会回退公开模板。配置与签名、账号备份和日志不上传 GitHub。

百度视频播放接口已内置，登录账号即可请求个人视频和分享视频的播放链接，无需配置中转取链服务。个人视频优先使用实测的 `mediainfo` DLNA 参数，地址不可用时尝试 `VideoURL` 参数；登录后的分享视频使用 App/DLNA 免转存取链。未登录的公益分享继续使用所选公益解析通道。播放地址过期后会重新取链，实际速度取决于百度接口、账号和网络。

百度账号视频下载沿用在线播放取链：个人视频使用 `mediainfo` DLNA / `VideoURL`，分享视频使用 App/DLNA 免转存路线，播放器的下载按钮重新获取当前视频的临时地址。返回普通媒体直链时由 Gopeed 下载，返回 HLS 时沿用现有分片下载；HLS 不使用原文件大小或校验值。视频取链失败会报告错误，不转到普通文件接口。明确选择公益解析的分享下载仍使用该公益通道。

百度账号非视频文件下载优先请求中转直链接口，失败后由 App 内置的预览接口直接向百度取链。中转取链或直链分段检查失败就切换，不耗尽下载准备阶段的重试次数；内置预览保留正常重试，使用当前账号和同一安装标识。未配置中转接口时直接使用内置预览。

中转配置：复制 `config/baidu-api.example.json` 到 `.local/baidu-api.defines.json`，填写 `ASTERLINK_BAIDU_RELAY_API_URL`（独立中转根地址，末尾保留 `/`）、服务端 RSA 公钥模数（十六进制）和客户端访问码。`ASTERLINK_BAIDU_API_URL` 保留旧 App 的原服务根地址，线上原预览入口和密钥继续保留。构建脚本自动加载该文件；直接使用 Flutter 编译时加上 `--dart-define-from-file=.local/baidu-api.defines.json`。服务端私钥、工作节点密钥和新取链的私有实现不随 App 发布。

阿里视频播放使用 OpenList OAuth 授权及阿里官方开放平台取链，登录现有阿里账号后按需自动授权，无需配置应用私钥。构建后客户端需能访问 `api.oplist.org` 与阿里开放接口；授权范围、分享转存、原画回退及验证记录见 [阿里开放平台播放](ALIYUN-OPEN-PLAYBACK.md)。

## 输出位置

| 产物 | 路径 |
| --- | --- |
| Android APK | `build/app/outputs/flutter-apk/app-release.apk` |
| Windows 运行目录 | `build/windows/x64/runner/Release/` |
| Windows 安装器 | `build/windows/installer/` |

便携使用时保留完整运行目录，不能只复制 EXE。

Android、Windows x64 / ARM64 内置播放恢复为仓库原有的 media_kit 1.2.6、
media_kit_video 2.0.1 和 libmpv。继续使用 `vendor_plugins/` 中的本地补丁、
固定原生依赖及 Windows ARM64 媒体准备脚本；当前构建不使用 MDK / FVP。
播放器界面、网盘取链、BT、边下边播和投屏沿用现有逻辑。系统音量同步、
切后台/切集先暂停、播放进度保存和后台释放播放器的优化继续保留。

Windows 原生播放回归可先运行 `tool/prepare-player-test.ps1`，再执行
`flutter test test/native_playback_test.dart --concurrency=1`。这些测试使用本地
libmpv 和测试媒体，采用空音频/视频输出；它们不能替代安卓真机硬解、功耗
和长时间播放验证。

更新链接的配置与安装行为见 [App 内更新](IN-APP-UPDATE.md)。
