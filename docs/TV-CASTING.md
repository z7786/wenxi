# 电视投屏

Android、Windows 播放器支持局域网 DLNA / UPnP AVTransport 电视和接收器。

使用时，手机或电脑与电视连接同一局域网，在电视上打开 DLNA 投屏或媒体接收功能。打开视频后，点击播放器右上角的投屏图标，或在「播放设置 → 电视投屏」中选择电视。

连接后，播放器的播放、暂停和进度控制作用于电视。投屏面板支持电视音量（接收器支持时）、切换设备、结束投屏和返回本机播放。切集及自动下一集沿用当前电视；返回本机时恢复电视回传的进度。定时停止和退出播放器会停止电视播放并关闭中转。

网盘 Cookie、Authorization 等请求头留在应用内，由当前设备中转视频。电视使用每次会话生成的随机地址读取视频。支持远程普通 HTTP 视频、HLS 播放列表及其密钥/分片，也支持单个本地视频文件（含 Android 文件授权 URI）。中转支持 HEAD、字节 Range，按流读取，不会先完整下载整个视频。

投屏期间保持应用运行和网络连接。Android 使用前台播放服务和唤醒锁维持锁屏后的中转，结束时释放。Windows 防火墙需允许应用使用专用网络。访客 Wi-Fi、路由器设备隔离、VPN 或电视未打开接收功能可能阻止搜索或读取视频。

电视负责解码和音轨、内嵌字幕的选择；应用不会转码。Chromecast 专用协议、AirPlay、DASH、本地 M3U8 播放列表及应用侧外挂字幕暂不在支持范围。电视不支持 Seek 或音量接口时，会提示使用遥控器。

## 验证

协议、来源中转、取消/关闭时的资源持有、自动切集和面板布局测试：

```powershell
flutter test --concurrency=1 test/cast_protocol_test.dart test/cast_stream_test.dart test/cast_playback_test.dart test/cast_widget_test.dart
```

Android 前台服务、通知、唤醒锁及独立组播锁测试：

```powershell
cd android
.\gradlew.bat :app:testDebugUnitTest --tests com.asterlink.app.CastServiceTest
```

模拟接收器使用真实 UDP / HTTP / SOAP，覆盖协议与应用逻辑。不同电视的格式兼容性、Wi-Fi 隔离和锁屏后的系统行为仍需在真机验证。
