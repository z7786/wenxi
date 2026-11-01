# Android 后台下载

下载、上传和设备互联共用传输前台服务。下载队列在等待下一文件、重试、校验与保存阶段仍持有保护，任务全部结束或暂停后释放下载唤醒锁。应用的常驻保活通知由另一服务负责，空闲时不持有下载唤醒锁。

下载每 2 秒向原生服务提交队列状态。相同内容与相同通知权限不会重复构建通知；允许通知后，即使进度未变，也会刷新显示。通知权限被拒绝时仍可以启动传输前台服务，系统可能只在“正在运行的应用”中显示状态。

原生服务每 30 秒检查心跳并维护带超时的唤醒锁。超过 2 分钟没有收到状态时，停止下载保护并通知队列暂停；迟到的心跳不能在后台重新启动服务。返回应用后可继续任务。

通知栏暂停会先保存停止意图，再通知下载队列。通知更新异常不会阻止暂停。队列 10 秒未确认时释放服务资源；返回应用后可重试暂停确认，旧回调不会影响新的传输会话。

系统重建下载服务时，只恢复有中断标记的任务。正常打开应用不会自动继续手动暂停或失败的历史任务。下载队列与文件检查点负责保留进度，服务本身不保存账号、下载地址或文件路径。

## 系统限制

手机厂商的后台限制、强行停止和深度省电仍可能中断传输。可在应用的“后台下载保护”页面查看电池优化、通知权限和系统后台限制。

Android 15 及以上会限制 `dataSync` 前台服务的后台运行时间，通常为 24 小时内累计 6 小时；用户将应用带回前台会重置计时。达到限制时，应用立即停止服务并保存暂停状态，避免系统因服务未停止而报错。常驻保活通知不能绕过此限制。详见 [Android 前台服务超时规则](https://developer.android.com/develop/background-work/services/fgs/timeout)。

## 验证

下载队列保活、任务恢复、传输状态合并与设置页面：

```powershell
flutter test --concurrency=1 test/download_keepalive_test.dart test/transfer_activity_test.dart test/download_protection_page_test.dart
```

原生前台服务、暂停回调、通知异常、权限变化、唤醒锁释放（Android 9 与 Android 15）：

```powershell
cd android
.\gradlew.bat :app:testDebugUnitTest --tests com.asterlink.app.DownloadKeepAliveTest --tests com.asterlink.app.AppKeepAliveTest
```

单元测试模拟系统生命周期和时间推进；各厂商手机长时间锁屏及切换网络的实际表现仍需真机验证。
