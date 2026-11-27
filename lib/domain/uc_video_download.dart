import '../core/json.dart';
import 'models.dart';

/// Describes the downloaded transcode, independently of the original file.
class UcVideoDownload {
  const UcVideoDownload({
    required this.resolution,
    required this.width,
    required this.height,
    required this.size,
    this.format = 'mp4',
  });

  static const labels = {
    'low': '流畅',
    'normal': '标清',
    'high': '高清',
    'super': '超清',
    '2k': '2K',
    '4k': '4K',
  };
  final String resolution;
  final String format;
  final int width, height, size;
  bool get segmented => format != 'mp4';
  String get extension => format == 'hls_ts' ? 'ts' : 'mp4';
  String get label => labels[resolution]!;
  String get dimensions => '$width×$height';
  bool sameAs(UcVideoDownload other) =>
      resolution == other.resolution &&
      width == other.width &&
      height == other.height &&
      size == other.size &&
      format == other.format;

  String fileName(String original) {
    final dot = original.lastIndexOf('.');
    final stem = dot > 0 ? original.substring(0, dot) : original;
    return '$stem（$label $dimensions）.$extension';
  }

  Json toJson() => {
    'resolution': resolution,
    'width': width,
    'height': height,
    'size': size,
    if (format != 'mp4') 'format': format,
  };

  factory UcVideoDownload.fromJson(Json json) {
    final resolution = json.str('resolution'),
        format = json.str('format', 'mp4'),
        width = json.integer('width'),
        height = json.integer('height'),
        size = json.integer('size');
    require(
      labels.containsKey(resolution) &&
          {'mp4', 'hls_ts', 'hls_mp4'}.contains(format) &&
          width > 0 &&
          width <= 32768 &&
          height > 0 &&
          height <= 32768 &&
          size > 0,
      'UC 可播放版本的画质或大小信息不完整，请重新打开文件列表',
    );
    return UcVideoDownload(
      resolution: resolution,
      width: width,
      height: height,
      size: size,
      format: format,
    );
  }

  static UcVideoDownload? fromSpec(DownloadSpec spec) =>
      spec.source?.containsKey('ucVideo') == true
      ? UcVideoDownload.fromJson(asJson(spec.source!['ucVideo']))
      : null;
}
