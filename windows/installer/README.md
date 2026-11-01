# Windows 安装器

## 安装行为

- 中文安装向导，支持 Windows 10/11 x64；普通用户安装，无需主动请求管理员权限。
- 增加独立 Windows ARM64 包：`-Architecture arm64`，仅允许 ARM64 Windows 安装；应用与依赖使用原生 ARM64。完整构建见 [Windows ARM64 构建说明](../../docs/WINDOWS-ARM64-BUILD.md)。
- 默认安装到 `%LOCALAPPDATA%\Programs\AsterLink`，可以选择 D 盘等可写目录。
- 默认勾选创建桌面快捷方式，同时创建开始菜单入口和系统卸载入口。
- 完成页面可以选择运行软件；静默安装不会自动启动软件。
- 固定 AppId，覆盖安装沿用上次路径和快捷方式选项。升级前需从托盘退出软件，等待下载进程结束；安装器不会强行结束下载任务。
- 卸载只删除安装器登记的应用文件和快捷方式。`%APPDATA%\com.asterlink\文析助手\AsterLink` 下的账号、设置、播放记录和下载缓存，以及用户下载的文件均保留。
- Visual C++ 运行库、Gopeed 和播放器已内嵌。若检测不到 Microsoft WebView2，向导提供可取消的联网补装选项；电脑已有该组件时跳过。断网或补装失败时，软件仍可安装，完成页说明网页登录暂不可用并提供官方下载入口。
- 不修改文件关联、不设为开机自启、不添加防火墙规则。

此安装 EXE 没有 Windows Authenticode 发布证书。Android 签名密钥不能用于 Windows 安装包签名。

## 构建

先按 [Windows 构建说明](../../docs/BUILDING.md) 生成完整 Release，再执行：

```powershell
.\tool\build-windows-installer.ps1 -Iscc D:\Tools\InnoSetup6\ISCC.exe
```

默认输出到 `build\windows\installer`，包含安装 EXE、SHA-256、构建日志和逐文件清单。已有同名 EXE 时，加 `-Force` 才会覆盖。也可复用经过校验的发布目录：

```powershell
.\tool\build-windows-installer.ps1 `
  -RuntimeDir 'D:\releases\文析助手' `
  -OutputDir 'D:\releases\installer' `
  -Iscc 'D:\Tools\InnoSetup6\ISCC.exe'
```

脚本检查应用版本、必需运行文件、开发文件及用户数据混入、WebView2 官方签名和 SHA-256。输出目录不能位于运行目录内部。它不重编 Flutter，也不读取签名密钥或应用账号数据。

编译器使用 **Inno Setup 6.7.3**。可从[加速下载地址](https://gh-proxy.com/https://github.com/jrsoftware/issrc/releases/download/is-6_7_3/innosetup-6.7.3.exe)获取；上游由 [Inno Setup 官网](https://jrsoftware.org/isdl.php)列出。下载文件的 SHA-256 为 `9c73c3bae7ed48d44112a0f48e66742c00090bdb5bef71d9d3c056c66e97b732`，有效 Authenticode 发布者为 `Pyrsys B.V.`。本机安装在 `D:\Tools\InnoSetup6`。

首次构建会从微软官方固定地址下载 **1.3.269.9** 版 WebView2 引导安装程序（约 1.8 MB），缓存到 `.local\windows-installer`。安装包内只附带引导程序；目标电脑缺少组件时，用户勾选补装才会联网下载安装完整的共享 WebView2。其 SHA-256 为 `83004a28553bcf2f932bf03564fbab407b8e1f59cd265f8dc99cc53d028e459c`，发布者为 `Microsoft Corporation`。分发方式和检测依据见[微软部署文档](https://learn.microsoft.com/en-us/microsoft-edge/webview2/concepts/distribution)。

## 中文语言文件

`languages/ChineseSimplified.isl` 原样取自 `jrsoftware/issrc` 的 `is-6_7_3` 标签下 `Files/Languages/Unofficial/ChineseSimplified.isl`，通过加速地址下载。SHA-256 为 `7d544b9bb1d142cfa11f2e5d3cc8abe2e55f8e066c5124e3772675aa236e1278`。保留原作者说明；Inno Setup 许可见 `INNO-LICENSE.txt`。产品专用文案写在 `.iss` 文件中，未修改上游翻译。

