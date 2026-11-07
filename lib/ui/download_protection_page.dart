import 'dart:async';
import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import '../platform/download_protection.dart';
import 'common.dart';

class DownloadProtectionPage extends StatefulWidget {
  const DownloadProtectionPage({
    super.key,
    this.platform = const DownloadProtectionPlatform(),
  });
  final DownloadProtectionPlatform platform;
  @override
  State<DownloadProtectionPage> createState() => _DownloadProtectionPageState();
}

class _DownloadProtectionPageState extends State<DownloadProtectionPage>
    with WidgetsBindingObserver {
  DownloadProtectionStatus? _status;
  String? _error;
  bool _reading = false, _opening = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    unawaited(_refresh());
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) unawaited(_refresh());
  }

  Future<void> _refresh() async {
    if (_reading) return;
    _reading = true;
    try {
      final status = await widget.platform.status();
      if (mounted) {
        setState(() {
          _status = status;
          _error = null;
        });
      }
    } catch (_) {
      if (mounted) setState(() => _error = '暂时无法读取后台设置，请重试');
    } finally {
      _reading = false;
    }
  }

  Future<void> _open(String kind) async {
    if (_opening) return;
    setState(() => _opening = true);
    try {
      await widget.platform.openSettings(kind);
      await _refresh();
    } catch (error) {
      if (mounted) message(context, errorText(error));
    } finally {
      if (mounted) setState(() => _opening = false);
    }
  }

  Widget _setting({
    required IconData icon,
    required String title,
    required String detail,
    required bool enabled,
    required String action,
    required String kind,
  }) => Padding(
    padding: const EdgeInsets.symmetric(vertical: 12),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Icon(icon, color: themeAccent(context), size: 22),
            const SizedBox(width: 10),
            Expanded(
              child: Text(
                title,
                style: const TextStyle(
                  fontSize: 16,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ),
            if (enabled)
              const Icon(
                CupertinoIcons.checkmark_circle_fill,
                color: Color(0xff34c759),
                size: 20,
              ),
          ],
        ),
        const SizedBox(height: 8),
        Text(detail, style: TextStyle(color: secondary(context), height: 1.5)),
        const SizedBox(height: 8),
        OutlinedButton(
          onPressed: _opening ? null : () => _open(kind),
          child: Text(action),
        ),
      ],
    ),
  );

  @override
  Widget build(BuildContext context) {
    final state = _status;
    return PageFrame(
      title: '后台下载保护',
      child: RefreshIndicator(
        onRefresh: _refresh,
        child: ListView(
          padding: const EdgeInsets.all(20),
          children: [
            Text(
              state?.foregroundOnly == true ? 'iOS 下载与续传' : '锁屏后继续下载',
              style: Theme.of(context).textTheme.titleLarge,
            ),
            const SizedBox(height: 8),
            Text(
              state?.foregroundOnly == true
                  ? '请保持应用在前台完成下载。切后台或锁屏后，iOS 可能暂停网络和应用运行；这时可返回传输管理继续任务。'
                  : state?.desktop == true
                  ? widget.platform.operatingSystem == 'macos'
                        ? '下载期间防止系统自动休眠，最小化窗口后继续传输。任务全部结束或暂停后自动释放保护。'
                        : '下载期间防止系统自动休眠，支持锁屏和托盘下载。任务全部结束或暂停后自动释放保护。'
                  : '打开应用后自动显示保活通知。下载时额外启用锁屏保护，全部结束或暂停后释放下载资源，保活通知继续保留。允许以下系统设置，可减少后台中断。',
              style: TextStyle(color: secondary(context), height: 1.6),
            ),
            const SizedBox(height: 16),
            if (_error != null) ...[
              Text(_error!),
              TextButton(onPressed: _refresh, child: const Text('重新检查')),
            ] else if (state == null)
              const Center(
                child: Padding(
                  padding: EdgeInsets.all(24),
                  child: CircularProgressIndicator(),
                ),
              )
            else if (state.foregroundOnly) ...[
              Icon(
                CupertinoIcons.info_circle,
                color: themeAccent(context),
                size: 32,
              ),
              const SizedBox(height: 14),
              Text(
                '下载任务和已保存的进度会保留。大文件、BT、ED2K 和设备互传期间，请保持应用打开。',
                style: TextStyle(color: secondary(context), height: 1.6),
              ),
            ] else if (state.desktop) ...[
              Icon(
                CupertinoIcons.shield_lefthalf_fill,
                color: themeAccent(context),
                size: 32,
              ),
              const SizedBox(height: 14),
              Text(
                state.wakeLockHeld ? '下载保活运行中 · 自动休眠保护已开启' : '下载开始后自动启用保护',
                style: TextStyle(color: themeAccent(context)),
              ),
              const SizedBox(height: 12),
              Text(
                widget.platform.operatingSystem == 'macos'
                    ? '最小化窗口后下载和上传会继续。传输期间请保持应用运行，屏幕仍可自动熄灭。'
                    : '点击最小化按钮可收起到系统托盘，下载和上传会继续。单击托盘图标恢复窗口，右键可退出。关闭窗口时也可选择“后台传输”。屏幕仍可自动熄灭。',
                style: TextStyle(color: secondary(context), height: 1.6),
              ),
            ] else ...[
              _setting(
                icon: CupertinoIcons.battery_100,
                title: '电池优化',
                enabled: state.batteryUnrestricted,
                detail: state.batteryUnrestricted
                    ? '已允许忽略电池优化。'
                    : '允许应用在息屏时继续下载，可能增加下载期间的耗电。',
                action: state.batteryUnrestricted ? '查看电池设置' : '允许后台下载',
                kind: 'battery',
              ),
              const Divider(),
              _setting(
                icon: CupertinoIcons.bell,
                title: '保活与下载通知',
                enabled:
                    state.notificationsEnabled &&
                    state.keepAliveNotificationsEnabled,
                detail:
                    state.notificationsEnabled &&
                        state.keepAliveNotificationsEnabled
                    ? '已开启，保活通知可返回应用，下载通知可查看进度并暂停任务。'
                    : state.notificationsEnabled
                    ? '下载通知已开启，保活通知未开启。可在系统设置中开启“后台保活”。'
                    : state.keepAliveNotificationsEnabled
                    ? '保活通知已开启，下载通知未开启。可在系统设置中开启“下载任务”。'
                    : '开启后可查看保活状态和下载进度。系统通知权限未允许时，常驻通知不会显示在通知栏。',
                action:
                    state.notificationsEnabled &&
                        state.keepAliveNotificationsEnabled
                    ? '查看通知设置'
                    : '开启通知',
                kind: 'notifications',
              ),
              const Divider(),
              _setting(
                icon: CupertinoIcons.app_badge,
                title: '系统后台限制',
                enabled: !state.backgroundRestricted,
                detail: state.backgroundRestricted
                    ? '系统正在限制后台活动，请在应用信息中允许后台运行。'
                    : '系统未报告后台限制。若锁屏仍会暂停，可在应用信息中检查自启动和后台运行设置。',
                action: '打开应用信息',
                kind: 'app',
              ),
              const Divider(),
              Text(
                state.keepAliveRunning
                    ? '后台保活运行中${state.keepAliveNotificationsEnabled ? '' : ' · 通知未开启'}'
                    : '后台保活未运行，重新打开应用后重试',
                style: TextStyle(color: themeAccent(context)),
              ),
              const SizedBox(height: 8),
              Text(
                state.recovering
                    ? '正在恢复中断的下载…'
                    : state.serviceRunning
                    ? '下载保护运行中${state.wakeLockHeld ? ' · 锁屏保护已启用' : ''}'
                    : '下载开始后自动启用锁屏保护',
                style: TextStyle(color: themeAccent(context)),
              ),
              if (state.powerSaveMode) ...[
                const SizedBox(height: 8),
                const Text('当前已开启系统省电模式，后台网络可能受限。'),
              ],
            ],
            const SizedBox(height: 20),
            Text(
              state?.foregroundOnly == true
                  ? '重新选择系统“文件”中的下载目录可恢复访问权限。尚未保存的最后少量数据可能需要重新下载。'
                  : state?.desktop == true
                  ? '手动睡眠、关机或合上盖子触发的睡眠仍由系统处理，唤醒后可继续下载。'
                  : '系统强行停止应用或达到后台运行时限时，下载会保留进度，返回应用后可继续。',
              style: TextStyle(
                fontSize: 12,
                color: secondary(context),
                height: 1.6,
              ),
            ),
          ],
        ),
      ),
    );
  }
}
