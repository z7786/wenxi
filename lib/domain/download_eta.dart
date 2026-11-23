import 'downloads.dart';

/// Uses the same current speed as the download row. Finishing work is not
/// network transfer and cannot be estimated from bytes per second.
String? downloadEta(DownloadTask task) {
  if (task.status != DownloadStatus.running ||
      task.payloadReady ||
      const {'等待校验 / 保存', '校验文件', '保存文件'}.contains(task.phase)) {
    return null;
  }
  if (task.total <= 0 || task.speed <= 0) return '剩余时间估算中';
  final remaining = task.total - task.downloaded;
  if (remaining <= 0) return null;
  final seconds = (remaining + task.speed - 1) ~/ task.speed;
  if (seconds < 60) return '约剩 $seconds 秒';
  final minutes = (seconds + 59) ~/ 60;
  if (minutes < 60) return '约剩 $minutes 分钟';
  final hours = minutes ~/ 60, rest = minutes % 60;
  if (hours < 24) return '约剩 $hours 小时${rest > 0 ? ' $rest 分钟' : ''}';
  return '约剩 ${hours ~/ 24} 天 ${hours % 24} 小时';
}
