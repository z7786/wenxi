# Android 画面流畅性

适用反馈：声音正常，但画面有规律地抖动、掉帧或不顺。网络缓冲、解码器卡死和显示节奏不匹配是不同问题；自动恢复机制见 `PLAYER-RECOVERY.md`。

## 本轮调整

- `PlaybackBackend.displayFrameRate` 从当前视频轨道读取帧率，乘以实际播放速度。保留 23.976/29.97 等小数帧率，排除封面、图片、禁用的视频及无效数值。未知帧率不提交匹配请求。
- Android 11 及以上向 **FlutterSurfaceView 的最终显示 Surface** 提交 `FRAME_RATE_COMPATIBILITY_FIXED_SOURCE` 提示。Android 12 及以上明确使用 `CHANGE_FRAME_RATE_ONLY_IF_SEAMLESS`；Android 11 的双参数接口同样只允许无缝切换。系统根据屏幕支持情况决定是否调整，不强制显示模式、分辨率或最高刷新率。
- 不能照搬对视频纹理 Surface 调用 `setFrameRate` 的做法：该 Surface 由 Flutter 消费，并不直接提交到系统合成器，这种调用没有显示帧率匹配效果。
- 对相同请求去重；暂停、退出、进入后台、切换会话及纯音频播放清除提示。仍可见的系统画中画保留提示，隐藏后清除。Surface 重建后重新提交，旧会话不能修改新会话。
- 电视控制栏隐藏或锁定后停止订阅播放进度；再次展开时显示最新进度。

不使用 `estimated-vf-fps` 驱动刷新率：它是最近若干视频帧时间戳的估计，精确跳转、丢帧和时间戳误差都会使其波动。

## 后续修复（2026-11-11）

此前 Android 纹理按片源尺寸创建。现已 vendor `media_kit_video 2.0.1`，实现 Android `setSize` 并按视口物理像素调整纹理，处理 Surface 引用生命周期，去掉重配 VO 后额外执行的 seek。桌面端也调用 `setSize`。

布局变化合并 200 ms 后应用。缓冲、代理 isolate、UI 诊断、零拷贝和掉帧降级见 `PLAYER-PERFORMANCE-CHECKLIST.md`。横竖屏、放大、HDR、字幕与画中画仍需反馈真机验证。

## 验证范围

自动测试覆盖轨道选择、小数帧率、倍速、非法值、请求去重、暂停及后台清理、会话替换、画中画、Surface 重建，以及电视控制栏隐藏后的进度刷新。

本轮验证：Flutter 相关 129 项测试通过（播放器界面 101 项，其余帧率、设备桥及投屏界面 28 项）；最后补充的播完清理断言单独复测通过。Android API 28/30/33 的帧率与生命周期测试共 20 项通过；变更涉及的 Dart 文件静态检查无问题。Android 测试通过编译当前生产 Kotlin 实现，但不等于真机性能验证。

这些测试不能证明某一手机的 GPU、解码器或系统实际采用了匹配刷新率。真机复核应使用同一个视频，在 24/25/30/50/60 fps、倍速、横竖屏、后台恢复及画中画下对照观看；结合现有诊断中的 `hwdecCurrent`、`decoderDroppedFrames`、`outputDroppedFrames` 判断剩余瓶颈。固定 60 Hz 屏幕播放 24/25 fps 内容时，刷新率提示无法创造屏幕不支持的模式。

参考：

- Android 官方帧率指南：https://developer.android.com/media/optimize/performance/frame-rate
- Android `Surface.setFrameRate`：https://developer.android.com/reference/android/view/Surface
- mpv `estimated-vf-fps`：https://mpv.io/manual/stable/#command-interface-estimated-vf-fps
- mpvRx（参照 Surface 帧率提示方式）：https://github.com/Riteshp2001/mpvRx
