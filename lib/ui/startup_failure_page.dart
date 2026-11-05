import 'package:file_selector/file_selector.dart';
import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import '../core/json.dart';
import '../data/startup_recovery.dart';
import '../data/backup.dart';
import '../data/state_store.dart';
import '../diagnostics/app_log.dart';
import '../diagnostics/diagnostic_bundle.dart';
import 'common.dart';
import 'diagnostics_page.dart';
import 'remote_control_dialogs.dart' show openRemoteLink;

class StartupFailurePage extends StatefulWidget {
  const StartupFailurePage(
    this.error, {
    super.key,
    this.onRetry,
    this.chooseBackup,
    this.recovery,
  });
  final Object error;
  final VoidCallback? onRetry;
  final Future<XFile?> Function()? chooseBackup;
  final StartupRecovery? recovery;

  @override
  State<StartupFailurePage> createState() => _StartupFailurePageState();
}

class _StartupFailurePageState extends State<StartupFailurePage> {
  bool _working = false, _complete = false;
  bool _canUnlock = false;
  String? _notice;
  String _progress = '正在处理…';
  StartupRecovery? get _recovery => widget.error is StateRecoveryRequired
      ? widget.recovery ??
            StartupRecovery(widget.error as StateRecoveryRequired)
      : null;

  @override
  void initState() {
    super.initState();
    _checkUnlock();
  }

  Future<void> _checkUnlock() async {
    try {
      final available = await _recovery?.canUnlock() ?? false;
      if (mounted) setState(() => _canUnlock = available);
    } catch (_) {
      // The existing backup recovery remains available if the sidecar is unreadable.
    }
  }

  Future<void> _unlock() async {
    final recovery = _recovery;
    if (_working || _complete || recovery == null) return;
    setState(() {
      _working = true;
      _notice = null;
      _progress = '等待输入备份密码…';
    });
    try {
      final password = await askText(
        context,
        '输入备份密码',
        hint: '建立本机密码恢复保护时使用的备份密码',
        secret: true,
        barrierDismissible: false,
      );
      if (password == null || !mounted) return;
      setState(() => _progress = '正在恢复本地数据访问…');
      await recovery.unlock(password);
      if (!mounted) return;
      _notice = '本地数据已解锁，当前账号、设置和下载记录均已保留。';
      _complete = true;
      DiagnosticLog.event(
        'app.state_recovery_completed',
        fields: {'mode': 'local_password'},
      );
    } catch (error, stack) {
      DiagnosticLog.error('app.state_recovery_failed', error, stack);
      if (mounted) _notice = errorText(error);
    } finally {
      if (mounted) setState(() => _working = false);
    }
  }

  Future<void> _recover({required bool fromBackup}) async {
    final recovery = _recovery;
    if (_working || _complete || recovery == null) return;
    setState(() {
      _working = true;
      _notice = null;
      _progress = '等待确认…';
    });
    try {
      StartupRecoveryResult result;
      if (fromBackup) {
        final file =
            await (widget.chooseBackup?.call() ??
                openFile(
                  acceptedTypeGroups: const [
                    XTypeGroup(
                      label: '文析助手备份',
                      extensions: ['json', 'bak'],
                      mimeTypes: [
                        'application/json',
                        'application/octet-stream',
                      ],
                    ),
                  ],
                ));
        if (file == null || !mounted) return;
        require(await file.length() <= 16 * 1024 * 1024, '备份文件过大');
        if (!mounted) return;
        final bytes = await file.readAsBytes();
        if (!mounted) return;
        final password = isPlainBackup(bytes)
            ? ''
            : await askText(
                context,
                '输入旧备份密码',
                secret: true,
                barrierDismissible: false,
              );
        if (password == null || !mounted) return;
        if (!await _confirm(
              '恢复备份',
              '将恢复备份中的账号、设置和收藏。原数据会单独保留，已下载文件不会删除。备份中不包含的记录无法还原。',
              '验证并恢复',
            ) ||
            !mounted) {
          return;
        }
        setState(() => _progress = '正在验证备份并恢复…');
        result = await recovery.restore(bytes, password);
        if (!mounted) return;
        _notice = '已恢复 ${result.accounts} 个账号及备份中的设置和收藏。原数据已单独保留。';
      } else {
        if (!await _confirm(
              '保留旧数据后重新初始化',
              '将以全新状态启动，需要重新登录网盘。旧账号、设置、收藏及下载记录不会出现在新界面中。原数据和旧任务库会保留，已下载文件不会删除。旧版加密数据仍需原密钥或备份才能恢复。',
              '保留并重新初始化',
            ) ||
            !mounted) {
          return;
        }
        setState(() => _progress = '正在保留旧数据并重新初始化…');
        result = await recovery.reinitialize();
        if (!mounted) return;
        _notice = '重新初始化完成。原数据和已下载文件已保留，请进入应用后重新登录网盘。';
      }
      _complete = true;
      DiagnosticLog.event(
        'app.state_recovery_completed',
        fields: {
          'mode': fromBackup ? 'backup' : 'reinitialize',
          'accounts': result.accounts,
        },
      );
    } catch (error, stack) {
      DiagnosticLog.error('app.state_recovery_failed', error, stack);
      if (mounted) _notice = errorText(error);
    } finally {
      if (mounted) setState(() => _working = false);
    }
  }

  Future<bool> _confirm(String title, String body, String action) async =>
      await showDialog<bool>(
        context: context,
        barrierDismissible: false,
        builder: (context) => AlertDialog(
          title: Text(title),
          content: SingleChildScrollView(child: Text(body)),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: const Text('取消'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(context, true),
              child: Text(action),
            ),
          ],
        ),
      ) ??
      false;

  @override
  Widget build(BuildContext context) => PopScope(
    canPop: !_working,
    child: Scaffold(
      appBar: AppBar(title: const Text('文析助手 启动恢复')),
      body: SafeArea(
        child: Center(
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(24),
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 440),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Icon(
                    _complete
                        ? CupertinoIcons.checkmark_shield
                        : CupertinoIcons.lock_shield,
                    size: 48,
                    color: themeAccent(context),
                  ),
                  const SizedBox(height: 20),
                  Text(
                    _complete ? '可以重新进入应用了' : '应用暂时无法启动',
                    textAlign: TextAlign.center,
                    style: Theme.of(context).textTheme.titleLarge,
                  ),
                  const SizedBox(height: 12),
                  Text(
                    _complete ? _notice! : errorText(widget.error),
                    textAlign: TextAlign.center,
                    style: TextStyle(color: secondary(context), height: 1.6),
                  ),
                  const SizedBox(height: 24),
                  if (!_complete && _recovery != null) ...[
                    if (_canUnlock) ...[
                      FilledButton.icon(
                        key: const Key('startup-unlock'),
                        onPressed: _working ? null : _unlock,
                        icon: const Icon(CupertinoIcons.lock_open),
                        label: const Text('输入备份密码恢复访问'),
                      ),
                      const SizedBox(height: 8),
                      Text(
                        '无需选择备份文件，备份后新增的本机数据也会保留。',
                        textAlign: TextAlign.center,
                        style: TextStyle(color: secondary(context)),
                      ),
                      const SizedBox(height: 16),
                    ],
                    FilledButton.icon(
                      key: const Key('startup-restore-backup'),
                      onPressed: _working
                          ? null
                          : () => _recover(fromBackup: true),
                      icon: const Icon(CupertinoIcons.arrow_counterclockwise),
                      label: const Text('恢复备份'),
                    ),
                    const SizedBox(height: 12),
                    OutlinedButton(
                      key: const Key('startup-reinitialize'),
                      onPressed: _working
                          ? null
                          : () => _recover(fromBackup: false),
                      child: const Text(
                        '保留旧数据后重新初始化',
                        textAlign: TextAlign.center,
                      ),
                    ),
                    const SizedBox(height: 12),
                  ],
                  if (_working) ...[
                    const Center(child: CircularProgressIndicator()),
                    const SizedBox(height: 12),
                    Text(_progress, textAlign: TextAlign.center),
                  ],
                  if (!_complete && _notice != null) ...[
                    const SizedBox(height: 12),
                    Text(
                      _notice!,
                      key: const Key('startup-recovery-notice'),
                      textAlign: TextAlign.center,
                      style: TextStyle(
                        color: Theme.of(context).colorScheme.error,
                      ),
                    ),
                  ],
                  if (widget.onRetry != null)
                    TextButton(
                      onPressed: _working ? null : widget.onRetry,
                      child: Text(_complete ? '进入应用' : '重试'),
                    ),
                  TextButton(
                    onPressed: _working
                        ? null
                        : () => _openDiagnostics(context),
                    child: const Text('导出故障日志'),
                  ),
                  TextButton.icon(
                    onPressed: _working
                        ? null
                        : () => openRemoteLink(
                            context,
                            Uri.parse('https://github.com/z7786/wenxi/issues'),
                          ),
                    icon: const Icon(CupertinoIcons.arrow_up_right_square),
                    label: const Text('项目地址'),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    ),
  );
}

void _openDiagnostics(BuildContext context) {
  final log = DiagnosticLog.active;
  if (log == null) return;
  Navigator.push<void>(
    context,
    MaterialPageRoute(
      builder: (_) => DiagnosticsPage(
        DiagnosticBundle(
          log,
          snapshot: () => <String, dynamic>{'startupFailed': true},
        ),
      ),
    ),
  );
}
