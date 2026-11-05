import '../core/json.dart';

enum PlaybackFailureKind {
  expired,
  missing,
  network,
  changed,
  decoder,
  unknown,
  paused,
}

class PlaybackFailure extends AppException {
  const PlaybackFailure(
    super.message,
    this.kind, {
    this.status,
    this.decoderUnavailable = false,
  });
  final PlaybackFailureKind kind;
  final int? status;

  /// A released MediaCodec cannot recover by skipping a damaged frame.
  final bool decoderUnavailable;
  bool get refreshable =>
      kind == PlaybackFailureKind.expired ||
      kind == PlaybackFailureKind.network;
  bool get sourceFailure =>
      kind != PlaybackFailureKind.decoder &&
      kind != PlaybackFailureKind.unknown;

  static PlaybackFailure? http(int status) => switch (status) {
    401 || 403 => PlaybackFailure(
      '播放地址或登录凭证已失效，请刷新重试；仍失败时请重新登录网盘',
      PlaybackFailureKind.expired,
      status: status,
    ),
    404 || 410 => PlaybackFailure(
      '视频文件已删除或播放地址已失效，请从网盘文件列表重新打开',
      PlaybackFailureKind.missing,
      status: status,
    ),
    408 || 429 || >= 500 => PlaybackFailure(
      status == 429 ? '网盘请求过于频繁，请稍后重试' : '视频源暂时无法连接，请稍后重试',
      PlaybackFailureKind.network,
      status: status,
    ),
    _ => null,
  };

  static PlaybackFailure? fromLog(String message) {
    if (RegExp(
      r'\b(?:a?mediacodec|\w+_mediacodec)\b[^\r\n]*'
      r'(?:\b(?:released|uninitialized) state\b|\bstate[:= ]+(?:released|uninitialized)\b|'
      r'failed to dequeue (?:input|output) buffer[^\r\n]*status\s*=\s*-542398533)',
      caseSensitive: false,
    ).hasMatch(message)) {
      return const PlaybackFailure(
        '系统硬件解码器已异常停止，播放进度已保留；请关闭硬件解码后重试或选择外部播放器',
        PlaybackFailureKind.decoder,
        decoderUnavailable: true,
      );
    }
    final code = RegExp(
      r'\b(?:http|server returned)\b[^\r\n]*?\b(401|403|404|408|410|429|5\d\d)\b',
      caseSensitive: false,
    ).firstMatch(message);
    if (code != null) return http(int.parse(code[1]!));
    if (RegExp(
      r'connection (?:refused|reset|timed out)|network is unreachable|'
      r'(?:failed|unable|could not) to (?:resolve|reconnect)|'
      r'failed to open https?://|'
      r'connection timeout|server returned 4XX|input/output error',
      caseSensitive: false,
    ).hasMatch(message)) {
      return const PlaybackFailure(
        '视频连接中断，请刷新链接重试',
        PlaybackFailureKind.network,
      );
    }
    if (RegExp(
      r'(?:could not|failed to|cannot) (?:initialize|open|find|create) (?:video |audio )?decoder|'
      r'video output initialization failed|no video or audio streams selected',
      caseSensitive: false,
    ).hasMatch(message)) {
      return const PlaybackFailure(
        '当前视频解码失败，可切换软件解码重试或下载后打开',
        PlaybackFailureKind.decoder,
      );
    }
    return null;
  }
}
