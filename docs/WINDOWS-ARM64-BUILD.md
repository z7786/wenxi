# Windows ARM64 构建

Windows ARM64 使用原生 ARM64 Flutter、Gopeed、QuickJS、WebView2 和媒体库。
`build/windows/arm64` 与 `native/bin/arm64` 保存该架构的输出；默认 Windows x64
构建及 Android 的 SDK 和媒体固定版本保持原有配置。

本次使用独立的 **Flutter 3.47.9 / Dart 3.13.7**，路径
`D:\Tools\FlutterWindowsArm64-3.47.9\flutter`。原有 `D:\Flutter` 未升级。
官方 SDK 压缩包 `flutter_windows_3.47.9-stable.zip` 的 SHA-256 为：

```text
d8e2b5977e09082c6440f89dc1aa887b94c8fbcc3b39222797046295a3f68a9e
```

Flutter 3.47.9 的命令仍按宿主架构选择 Windows 目标，但其引擎已经附带可在
Windows x64 运行的 `windows_simarm64` AOT 编译器。本工程为独立 SDK 添加
`--target-platform` 选项，调用已有的 ARM64 CMake 和 assemble 构建路径。
此适配不是官方 Flutter 交叉编译支持声明，只验证上述固定版本：

```powershell
.\tool\enable-windows-arm64-sdk.ps1 `
  -FlutterRoot 'D:\Tools\FlutterWindowsArm64-3.47.9\flutter'
```

独立 SDK 缓存必须包含同一引擎版本
`89c39edfdfae2949f6806e4a315c0c08522238b7` 的
`windows-arm64-release/windows-arm64-flutter.zip`，解压至
`bin/cache/artifacts/engine/windows-arm64-release`；
`windows-arm64/flutter-cpp-client-wrapper.zip` 解压至
`bin/cache/artifacts/engine/windows-arm64`。
文件来自 Flutter 官方存储，国内可使用 `https://storage.flutter-io.cn` 镜像。
ARM64 目录中的 `icudtl.dat` 和 `const_finder.dart.snapshot` 复用同一 SDK 的
Windows x64 缓存内容；这两项是数据/工具快照，不是分发的 x64 原生库。

Visual Studio 2022 需要 C++ ARM64 编译工具、ARM64 ATL 与 Windows SDK，
以及当前 7-Zip、Go 和 Inno Setup 6.7.3。
媒体准备脚本会按固定 SHA-256 校验 ARM64 mpv 和 ANGLE，生成 ARM64 MSVC
导入库，并保留上游组件许可。来源详见
`assets/licenses/Windows-ARM64-media-NOTICES.txt`。

正式本机构建沿用 `.local/build-config.json` 和已有私有接口配置：

```powershell
$env:FLUTTER_STORAGE_BASE_URL = 'https://storage.flutter-io.cn'
.\tool\build-official.ps1 -Platform windows -WindowsArchitecture arm64 `
  -Flutter 'D:\Tools\FlutterWindowsArm64-3.47.9\flutter\bin\flutter.bat' `
  -Go 'D:\Tools\go\bin\go.exe' `
  -SevenZip 'D:\Tools\7zip\x64\7za.exe' `
  -Iscc 'D:\Tools\InnoSetup6\ISCC.exe'
```

安装器输出位于 `build/windows/installer/arm64`，只允许在 Windows ARM64
安装，逐文件清单记录真实架构和校验值。Inno Setup 安装向导使用通用 x86
引导程序；运行中的应用及其全部 DLL/EXE 均为原生 ARM64。
微软 ARM64 CRT 目录中附带的 x64 `vcruntime140_1.dll` 不被本应用导入，
已从 ARM64 包中排除。

Android 与当前 x64 开发环境继续使用 Flutter 3.41.4。切换 SDK 后应重新
执行该 SDK 的 `flutter pub get`，避免沿用另一 SDK 的生成配置；无需全局
升级 Flutter，也无需清理原有下载或账号数据。

验证包含 ARM64 PE 文件、AArch64 Dart AOT、随包 DLL 导入及函数解析，
并执行账号添加、夸克认证和边下边播回归。最终仍需在 Windows ARM64
电脑上验证实际安装、登录和视频播放。
