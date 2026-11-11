import 'dart:convert';
import 'dart:io';
import '../core/json.dart';
import 'app_log.dart';
import 'redaction.dart';

/// A small, redacted report suitable for a user-initiated clipboard copy.
/// Full stacks and the original structured records remain in the ZIP.
String diagnosticSummary(DiagnosticLog log, Json native, {String note = ''}) {
  String clean(Object? value, [int limit = 400]) =>
      LogRedactor.text(value ?? '', limit: limit);
  String timestamp(Object? value) => beijingLogTime(value);

  final text = StringBuffer()
    ..writeln('文析助手排查摘要')
    ..writeln('版本：$applicationVersion')
    ..writeln('生成时间：${beijingLogTime(log.clock())}（北京时间 UTC+08:00）')
    ..writeln('系统：${clean(Platform.operatingSystemVersion, 200)}');
  final device = [
    native.str('manufacturer'),
    native.str('model'),
  ].where((value) => value.isNotEmpty).join(' ');
  if (device.isNotEmpty) text.writeln('设备：${clean(device, 160)}');
  if (native['api'] is num) {
    text.writeln(
      'Android：${clean(native['android'], 40)} / API ${native['api']}',
    );
  }
  text.writeln('自动记录：${log.enabled ? '开启' : '关闭，摘要仅使用已有记录'}');
  if (log.storageError != null) text.writeln('日志存储：${clean(log.storageError)}');
  if (log.previousSessionInterrupted) {
    text.writeln('上次运行缺少正常结束标记，可能是系统回收或异常退出，不能据此认定崩溃。');
  }
  text
    ..writeln()
    ..writeln('问题说明：${note.trim().isEmpty ? '未填写' : clean(note, 1000)}')
    ..writeln()
    ..writeln('最近错误与警告（最多 3 条）：');
  final entries = log.entries(errorsOnly: true).take(3).toList();
  if (entries.isEmpty) text.writeln('暂无保存的 Flutter 错误或警告。');
  for (final entry in entries) {
    final data = entry.data;
    text.writeln(
      '- ${timestamp(entry.time)} · ${_eventLabel(entry.event)}'
      ' [${clean(entry.event, 120)} / ${clean(entry.level, 20)}]',
    );
    final fields = asJson(data['fields']);
    const labels = {
      'platform': '网盘',
      'stage': '阶段',
      'route': '路线',
      'flow': '流程',
      'httpStatus': 'HTTP',
      'errorCode': '错误码',
      'errorType': '错误类型',
      'elapsedMs': '耗时(ms)',
      'isMainFrame': '主页面',
      'didCrash': '渲染进程崩溃',
    };
    final context = [
      for (final field in labels.entries)
        if (fields[field.key] != null)
          '${field.value}=${clean(fields[field.key], 100)}',
    ];
    if (context.isNotEmpty) text.writeln('  ${context.join(' · ')}');
    if (data['message'] != null) text.writeln('  ${clean(data['message'])}');
  }

  final reports = <Json>[];
  for (final report in native.list('reports').take(8)) {
    try {
      reports.add(asJson(jsonDecode(report.str('content'))));
    } catch (_) {
      // Interrupted reports are already identified in the complete ZIP.
    }
  }
  reports.sort((a, b) => b.integer('time').compareTo(a.integer('time')));
  if (reports.isNotEmpty) {
    text
      ..writeln()
      ..writeln('已保存的原生异常（最多 2 条）：');
    for (final report in reports.take(2)) {
      text.writeln(
        '- ${timestamp(report['time'])} · ${clean(report['event'], 120)}',
      );
      final cause = report.list('causes').firstOrNull;
      if (cause != null) {
        text.writeln(
          '  ${clean(cause['type'], 120)}：${clean(cause['message'])}',
        );
      }
      _windowsFault(text, report, clean);
    }
  }
  final exits = native.list('exits').toList()
    ..sort((a, b) => b.integer('time').compareTo(a.integer('time')));
  if (exits.isNotEmpty) {
    text
      ..writeln()
      ..writeln('最近系统退出记录（最多 3 条，不均代表崩溃）：');
    for (final exit in exits.take(3)) {
      text.writeln(
        '- ${timestamp(exit['time'])} · ${_exitLabel(exit.str('reason'))}'
        ' [${clean(exit.str('reason'), 80)}]',
      );
      _windowsFault(text, exit, clean);
      if (exit.str('signalName').isNotEmpty) {
        text.writeln('  信号=${clean(exit['signalName'], 40)}');
      }
    }
  }
  if (native.boolean('collectionFailed') ||
      native.boolean('exitHistoryUnavailable')) {
    text.writeln('部分系统诊断暂时无法读取，摘要保留了可用记录。');
  }
  text
    ..writeln()
    ..write('摘要已按日志规则脱敏，完整堆栈与操作线索请查看日志 ZIP。');
  return LogRedactor.text(text.toString(), limit: 10000);
}

void _windowsFault(
  StringBuffer text,
  Json report,
  String Function(Object?, [int]) clean,
) {
  final details = <String>[
    if (report.str('exceptionCode').isNotEmpty)
      '异常代码=${clean(report['exceptionCode'], 40)}',
    if (report.str('faultModule').isNotEmpty)
      '模块=${clean(report['faultModule'], 160)}',
    if (report.str('faultOffset').isNotEmpty)
      '偏移=${clean(report['faultOffset'], 40)}',
    if (report.str('version').isNotEmpty) '版本=${clean(report['version'], 40)}',
  ];
  if (details.isNotEmpty) text.writeln('  ${details.join(' · ')}');
}

String _eventLabel(String event) => switch (event) {
  'flutter.framework' => '界面异常',
  'flutter.unhandled_async' => '异步操作异常',
  'app.bootstrap_failed' || 'app.services_failed' => '启动失败',
  'player.load_failed' => '播放加载失败',
  'player.terminal_error' => '播放中断',
  'cloud.playback_source_failed' => '播放取源失败',
  'web_login.initialize_failed' => '网页登录初始化失败',
  'webview.environment.attempt_failed' => '网页登录环境恢复记录',
  'web_login.resource_failed' => '网页登录网络错误',
  'web_login.http_failed' => '网页登录 HTTP 错误',
  'web_login.renderer_gone' => '网页登录渲染进程退出',
  'web_login.validation_failed' => '网页登录验证失败',
  'web_login.credential_read_failed' => '网页登录状态读取失败',
  'web_login.browser_state_read_failed' => '网页登录状态读取失败',
  'web_login.page_script_failed' => '登录页面处理失败',
  _ when event.startsWith('download.') => '下载相关记录',
  _ when event.startsWith('player.') => '播放相关记录',
  _ when event.startsWith('logging.') => '日志处理异常',
  _ => '操作异常',
};

String _exitLabel(String reason) => switch (reason) {
  'java_crash' => 'Java/Kotlin 崩溃',
  'native_crash' => '原生崩溃',
  'anr' => '应用无响应（ANR）',
  'low_memory' => '系统内存回收',
  'user_requested' || 'user_stopped' => '用户结束应用',
  'self_exit' => '应用主动退出',
  'initialization_failure' => '初始化失败',
  'signal' => '系统信号结束进程',
  _ => '其他系统退出',
};
