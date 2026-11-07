<div align="center">
  <img src="docs/images/app-icon.png" width="112" height="112" alt="文析助手图标">
  <h1>文析助手 · AsterLink</h1>
  <p>把网盘放在一起，在手机与电脑上完成解析、搜索、传输和播放。</p>
  <p>
    <img src="https://img.shields.io/badge/Android-7.0%2B-3DDC84?logo=android&logoColor=white" alt="Android 7.0 及以上">
    <img src="https://img.shields.io/badge/Windows-10%20%2F%2011-0078D4" alt="Windows 10 / 11">
    <img src="https://img.shields.io/badge/iOS%20%2F%20iPadOS-13.0%2B-555555?logo=apple&logoColor=white" alt="iOS / iPadOS 13.0 及以上测试版">
    <img src="https://img.shields.io/badge/macOS-11.0%2B-555555?logo=apple&logoColor=white" alt="macOS 11.0 及以上测试版">
    <a href="LICENSE"><img src="https://img.shields.io/badge/License-AGPL--3.0-blue" alt="AGPL-3.0"></a>
  </p>
  <p>
    <a href="#安卓界面">安卓界面</a> · <a href="#windows-界面">Windows 界面</a> · <a href="#支持网盘">支持网盘</a> · <a href="#功能">功能</a> · <a href="#下载">下载</a> · <a href="docs/BUILDING.md">编译</a> · <a href="CHANGELOG.md">更新记录</a>
  </p>
</div>


## 项目介绍

**文析助手（AsterLink）** 是一款免费、开源的跨平台网盘管理、资源搜索与文件传输应用，支持 **Android、Windows、iOS / iPadOS 和 macOS**，已接入 **17 个网盘和 GitHub 文件源**。iOS 与 macOS 当前提供测试版。

粘贴分享链接、提取码或网盘口令，即可浏览目录、下载文件和在线播放；也可以搜索公开分享，按链接有效性筛选资源。登录账号后，可管理个人网盘、切换多个账号、搜索文件、上传文件夹，并收藏常用文件和分享。

下载与上传集中在「传输」页，支持 HTTP / HTTPS、磁力、BT 种子和 ED2K 文件链接；手机与电脑可通过局域网互传文字、链接、文件和文件夹。内置播放器提供断点续播、片头片尾跳过、字幕、截图和布局自定义，还可选择外部播放器或连接支持 DLNA 的电视。主题、液态玻璃效果和日夜背景均可调整。


## 安卓界面

四个主页面的当前界面预览，账号、文件与任务均为演示数据。点击图片可查看高清宣传图。

[![文析助手 Android 宣传图：分享解析、网盘管理、传输管理和我的设置](docs/images/promo-android.png)](docs/images/promo-android.png)

单页原图：[分享解析](docs/images/android-parse.png) · [网盘管理](docs/images/android-clouds.png) · [传输管理](docs/images/android-downloads.png) · [我的设置](docs/images/android-settings.png)

## Windows 界面

桌面端使用侧边导航与宽屏布局，展示相同的四个主页面。

[![文析助手 Windows 宣传图：分享解析、网盘列表、传输管理和我的设置](docs/images/promo-windows.png)](docs/images/promo-windows.png)

单页原图：[分享解析](docs/images/windows-parse.png) · [网盘列表](docs/images/windows-clouds.png) · [传输管理](docs/images/windows-downloads.png) · [我的设置](docs/images/windows-settings.png)


## 支持网盘

**17 个网盘 + GitHub 文件源**，其中 **15 个网盘支持分享链接解析**；GitHub 另支持仓库文件与 Releases 链接。

<table>
  <tr>
    <td align="center" width="33%"><img src="assets/icons/quark.png" width="40" height="40" alt="夸克网盘"><br><strong>夸克网盘</strong></td>
    <td align="center" width="33%"><img src="assets/icons/uc.png" width="40" height="40" alt="UC 网盘"><br><strong>UC 网盘</strong></td>
    <td align="center" width="33%"><img src="assets/icons/xunlei.png" width="40" height="40" alt="迅雷云盘"><br><strong>迅雷云盘</strong></td>
  </tr>
  <tr>
    <td align="center"><img src="assets/icons/baidu.png" width="40" height="40" alt="百度网盘"><br><strong>百度网盘</strong></td>
    <td align="center"><img src="assets/icons/123.webp" width="40" height="40" alt="123 云盘"><br><strong>123 云盘</strong></td>
    <td align="center"><img src="assets/icons/yidong.png" width="40" height="40" alt="中国移动云盘"><br><strong>中国移动云盘</strong></td>
  </tr>
  <tr>
    <td align="center"><img src="assets/icons/tianyi.png" width="40" height="40" alt="天翼云盘"><br><strong>天翼云盘</strong></td>
    <td align="center"><img src="assets/icons/guangya.png" width="40" height="40" alt="光鸭云盘"><br><strong>光鸭云盘</strong></td>
    <td align="center"><img src="assets/icons/ali.png" width="40" height="40" alt="阿里云盘"><br><strong>阿里云盘</strong></td>
  </tr>
  <tr>
    <td align="center"><img src="assets/icons/lanzous.png" width="40" height="40" alt="蓝奏云"><br><strong>蓝奏云</strong></td>
    <td align="center"><img src="assets/icons/wopan.png" width="40" height="40" alt="中国联通云盘"><br><strong>中国联通云盘</strong></td>
    <td align="center"><img src="assets/icons/115.png" width="40" height="40" alt="115 网盘"><br><strong>115 网盘</strong></td>
  </tr>
  <tr>
    <td align="center"><img src="assets/icons/ctfile.png" width="40" height="40" alt="城通网盘"><br><strong>城通网盘</strong></td>
    <td align="center"><img src="assets/icons/lanzous.png" width="40" height="40" alt="蓝奏云优享版"><br><strong>蓝奏云优享版</strong><br><sub>仅个人网盘管理</sub></td>
    <td align="center"><img src="assets/icons/weiyun.png" width="40" height="40" alt="腾讯微云"><br><strong>腾讯微云</strong><br><sub>仅个人网盘管理</sub></td>
  </tr>
  <tr>
    <td align="center"><img src="assets/icons/feijipan.png" width="40" height="40" alt="小飞机网盘"><br><strong>小飞机网盘</strong></td>
    <td align="center"><img src="assets/icons/pikpak.png" width="40" height="40" alt="PikPak"><br><strong>PikPak</strong></td>
    <td align="center"><img src="assets/icons/github.png" width="40" height="40" alt="GitHub"><br><strong>GitHub 文件源</strong><br><sub>仓库文件与发布附件</sub></td>
  </tr>
</table>

网盘列表支持自定义排序和隐藏，账号可自定义名称并保留配置。蓝奏云优享版与腾讯微云目前提供个人文件管理，暂不支持分享链接解析；文件操作和下载能力以对应平台与账号权限为准。


## 功能

| 功能 | 可以做什么 |
| --- | --- |
| **链接与口令解析** | 识别完整分享文案、提取码与多条链接，保留解析历史；夸克、迅雷、UC、移动提供独立口令入口，选择平台后解析并进入文件列表，部分口令需要登录对应网盘账号。 |
| **公开资源搜索** | 按关键词搜索公开分享，支持网盘分类、包含词、排除词与优先可解析筛选；链接检测后逐批显示，按「有效 → 无法检测 → 失效」排序，浏览时保持已显示结果的位置。 |
| **多网盘、多账号** | 快速切换账号、自定义账号名称，查看和复制该账号的登录信息；下载、播放与收藏保留账号归属。 |
| **文件管理与搜索** | 列表或网格浏览，名称、大小、时间均可正序或倒序排列，名称支持中文拼音与数字自然排序；文件夹置顶，返回上级目录恢复滚动位置。支持多选、新建文件夹及平台允许的重命名、移动、删除与分享；账号内搜索支持类型筛选、搜索历史及子目录搜索。 |
| **存储空间切换** | 阿里云盘可切换资源库、备份盘与相册；支持的移动、天翼和联通账号可浏览家庭云。 |
| **统一下载管理** | 支持网盘文件、HTTP / HTTPS、磁力链接、BT 种子与 ED2K 文件链接，提供暂停、继续、失败自动重试、批量操作及连接数、任务数和限速设置。BT 支持 Tracker 检测、找源缓存、上传限速、来源状态显示和连续下载同种子文件时复用连接。 |
| **文件与文件夹上传** | 支持的平台可上传整个文件夹，保留子目录和空目录；Windows / macOS 支持拖入文件或文件夹。任务独立排队，离开文件页面仍可继续，在「传输 → 上传」查看进度、取消或重试；继续文件夹任务时跳过已完成文件。详见 [文件夹上传](docs/FOLDER-UPLOAD.md)。 |
| **预览与在线播放** | 预览图片、文本和 PDF；PDF 与 Office 文档可调用在线查看器（需确认向第三方提交临时链接和文件内容）。播放器支持断点续播、播放列表、倍速、音轨与字幕、截图、定时停止、画面比例和字幕外观；支持的任务可边下边播。 |
| **播放手势与布局** | 自定义片头片尾跳过时长、视频缩放、控制按钮显示和面板布局，可在当前视频画面上调整布局；长按默认 2 倍播放，左右滑动每档调整 0.5 倍，上滑锁定、下滑取消。 |
| **外部播放与小窗** | 记住多条外部播放器使用记录，支持快速选择。Android 支持系统画中画，Windows / macOS 支持多个独立视频窗口，可继续操作主界面；iOS 当前不提供画中画，外部播放支持已安装的 Infuse / VLC，受视频链接访问方式限制。 |
| **电视投屏** | 支持局域网 DLNA / UPnP 接收设备，投屏后可控制播放、暂停、进度和切集；设备支持时可调节电视音量。Apple 平台可手动输入电视地址，投屏期间需保持应用运行。 |
| **设备互联** | 同一局域网内互传文字、链接、文件和文件夹，支持扫码连接、选择已连接设备发送、收件箱回复，以及限时文件链接与二维码分享。 |
| **安卓传输悬浮窗** | 同时查看下载、上传进度，支持拖动、调整宽高和收起为悬浮球；闲置 3 秒自动贴边半隐藏。 |
| **收藏与重命名** | 收藏分享链接、文件和文件夹，自定义收藏名称；保留提取码，快速重新解析分享或定位文件目录。 |
| **主题与背景** | 五套配色，液态玻璃、磨砂、实色三种效果，支持浅色、深色和跟随系统；自定义日夜背景、亮度、模糊和卡片透明度，分别记住手机与电脑的裁剪位置。可选择实色效果减少滤镜开销，折射效果取决于设备渲染支持。 |
| **备份与恢复** | 导出账号、设置和收藏，可选择携带背景图片。新版备份为明文并带完整性校验，无需密码；导入旧加密备份时仍需原密码。本地数据兼容旧版迁移，备份含登录凭据，请妥善保管。 |
| **消息公告** | 在解析页查看多条远程图文公告，支持 Markdown、图片、跳转按钮、微信小程序链接、置顶与已读管理；详见 [公告配置说明](docs/ANNOUNCEMENTS.md)。 |

不同网盘的接口、账号权益和网络环境会影响下载速度与功能可用性，连接数也会按平台限制调整。设备互联需处于可互通的局域网；手机端可扫码或手动输入地址，macOS 当前使用连接码或手动地址。

Android 可通过通知栏和传输悬浮窗查看后台任务；桌面端传输期间需保持应用运行。iOS 的后台传输受系统挂起规则限制，长时间下载建议保持应用在前台。iOS / macOS 的安装与功能差异见 [iOS 说明](docs/IOS-BUILD.md) 和 [macOS 说明](docs/MACOS-BUILD.md)。


## 使用

1. **管理网盘**：需要浏览个人文件时，在“网盘”页选择平台并登录；按需调整排序、隐藏平台或添加多个账号。
2. **查找资源**：在“解析”页粘贴链接或完整分享文案，核对提取码后开始解析；网盘口令从“口令解析”入口选择对应网盘，也可进入资源搜索查找公开分享。
3. **选择操作**：浏览文件并下载或预览；点击文件列表顶部的星标，可以收藏整个分享。个人网盘支持上传时，可从添加菜单选择文件或文件夹。
4. **管理任务**：在“传输”页切换下载和上传任务，查看进度并进行暂停、取消、重试等操作；安卓端也可手动开启传输悬浮窗。

## 下载

在 [Releases](https://github.com/z7786/wenxi/releases) 页面获取安装包。当前版本为 [2.2.0+220](https://github.com/z7786/wenxi/releases/tag/v2.2.0%2B220)，附 `SHA256SUMS.txt` 校验文件。

| 平台 | 安装包 | 系统要求 |
| --- | --- | --- |
| Android | ARM64 APK，沿用原签名 | Android 7.0 及以上，ARM64 设备 |
| Windows x64 | 安装包、便携 ZIP | Windows 10 / 11，x64 设备；便携包解压后运行 `asterlink.exe` |
| Windows ARM64 | ARM64 安装包 | Windows 10 / 11，ARM64 设备 |
| iOS / iPadOS | ARM64 未签名 IPA 测试包 | iOS / iPadOS 13.0 及以上，需用户自签后安装 |
| macOS | ARM64 DMG 测试包 | macOS 11.0 及以上，Apple Silicon（M 系列） |

macOS 测试包尚未完成 Developer ID 签名与苹果公证，首次运行可能需要在系统“隐私与安全性”中允许打开。iOS IPA 不能直接安装，需要签名工具及对应的 Apple 签名与描述文件。

本次重建沿用 **2.2.0+220** 版本号和构建号；已安装相同版本的用户请手动下载覆盖更新，保留应用数据。

## 编译与反馈

使用 Flutter 3.41.4、Dart 3.11.1 和 Go 1.24.7，Windows ARM64 使用单独固定的 Flutter SDK。各平台均有 GitHub Actions 构建流程，详见 [编译说明](docs/BUILDING.md)、[Windows ARM64](docs/WINDOWS-ARM64-BUILD.md)、[iOS](docs/IOS-BUILD.md) 和 [macOS](docs/MACOS-BUILD.md)。

问题和建议欢迎提交 **Issues**，请附上版本、系统、操作步骤及脱敏错误提示，不要上传账号密码、Cookie 或账号备份。


项目采用 [AGPL-3.0](LICENSE)，基于 Flutter、Gopeed 和 media_kit 构建。第三方组件保留各自许可，网盘名称及标识归对应服务所有，本项目并非网盘官方客户端。

[发布说明](docs/GITHUB-PUBLISH.md) · [隐私说明](docs/PRIVACY.md) · [第三方声明](assets/licenses/THIRD_PARTY_NOTICES.md) · [许可证范围](docs/LICENSING.md)
