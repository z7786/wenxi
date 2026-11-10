# 电视投屏

Android、Windows 播放器支持局域网 DLNA / UPnP AVTransport 电视和接收器。

使用时，手机或电脑与电视连接同一局域网，在电视上打开 DLNA 投屏或媒体接收功能。打开视频后，点击播放器右上角的投屏图标，或在「播放设置 → 电视投屏」中选择电视。

连接后，播放器的播放、暂停和进度控制作用于电视。投屏面板支持电视音量（接收器支持时）、切换设备、结束投屏和返回本机播放。切集及自动下一集沿用当前电视；返回本机时恢复电视回传的进度。定时停止和退出播放器会停止电视播放并关闭中转。

切到电视时保留原来的播放/暂停状态。由于部分 DLNA 电视需要先播放才能定位，暂停来源会在准备视频并定位后向电视发送暂停；电视若不支持暂停，会报告连接失败。切换接收器、重新连接或返回本机前会等待电视状态查询完成，尽量取得最新进度；无法查询时使用最后一次成功回传的进度。返回本机保留电视的播放/暂停状态，已播放结束的内容保持停止。

连接中断时继续自动查询状态，面板显示自动重试；恢复网络后继续控制。也可点击「重新连接」重建中转并恢复进度。已经连接的电视始终保留在设备列表中，重复点击不会重新加载视频。

## Android TV 播放

应用识别电视 UI 模式及 Leanback 设备，在播放器中使用电视控制栏：52 dp 按钮、明显的焦点边框、进度条和选集/字幕/设置入口。控件位于屏幕边缘约 5% 的安全区域，视频保持全屏。电视不使用手机的自动旋转和屏幕亮度功能。

Android TV 启动器可显示应用入口和电视横幅，触摸屏标记为可选；手机仍使用原来的启动入口。

- 控件显示时：方向键移动焦点，确认键操作当前控件，进度条上左右键调节进度。
- 控件隐藏时：左右键后退/前进 15 秒，上下键显示控件，确认键切换播放/暂停。
- 播放时控件闲置 4 秒自动隐藏，同时移除隐藏控件的焦点。
- 返回键先收起控件，再按一次退出播放器；菜单键打开设置。
- 遥控器的播放、暂停、快进、快退和上一集/下一集媒体键可直接控制播放，在面板打开时仍有效。

交互设计参考 [mpvRx](https://github.com/Riteshp2001/mpvRx) 的 `CastPlaybackController`、`TvPlayerRemotePolicy` 和电视安全区域规则（参考提交 `4f0b913ae6f3e716735f0efda275659d53b60fa5`），在现有 Flutter / DLNA 架构中独立实现。此改动覆盖播放器和播放面板；应用其他页面仍沿用现有布局。

网盘 Cookie、Authorization 等请求头留在应用内，由当前设备中转视频。电视使用每次会话生成的随机地址读取视频。支持远程普通 HTTP 视频、HLS 播放列表及其密钥/分片，也支持单个本地视频文件（含 Android 文件授权 URI）。中转支持 HEAD、字节 Range，按流读取，不会先完整下载整个视频。

投屏期间保持应用运行和网络连接。Android 使用前台播放服务和唤醒锁维持锁屏后的中转，结束时释放。Windows 防火墙需允许应用使用专用网络。访客 Wi-Fi、路由器设备隔离、VPN 或电视未打开接收功能可能阻止搜索或读取视频。

电视负责解码和音轨、内嵌字幕的选择；应用不会转码。Chromecast 专用协议、AirPlay、DASH、本地 M3U8 播放列表及应用侧外挂字幕暂不在支持范围。电视不支持 Seek 或音量接口时，会提示使用遥控器。

## 验证

协议、来源中转、取消/关闭时的资源持有、自动切集和面板布局测试：

```powershell
flutter test --concurrency=1 test/cast_protocol_test.dart test/cast_stream_test.dart test/cast_playback_test.dart test/cast_widget_test.dart test/playback_device_test.dart test/player_widget_test.dart
```

Android 前台服务、通知、唤醒锁及独立组播锁测试：

```powershell
cd android
.\gradlew.bat :app:testDebugUnitTest --tests com.asterlink.app.CastServiceTest
.\gradlew.bat :app:testDebugUnitTest --tests com.asterlink.app.PlaybackLifecycleTest
```

当前环境的清华 Flutter 引擎镜像返回 HTTP 403；验证时仅为该命令切换到官方源，并限定 ARM64：

```powershell
$env:FLUTTER_STORAGE_BASE_URL = 'https://storage.googleapis.com'
.\gradlew.bat :app:testDebugUnitTest --tests com.asterlink.app.CastServiceTest --tests com.asterlink.app.PlaybackLifecycleTest -Ptarget-platform=android-arm64
```

模拟接收器使用真实 UDP / HTTP / SOAP，覆盖协议与应用逻辑。不同电视的格式兼容性、Wi-Fi 隔离和锁屏后的系统行为仍需在真机验证。
