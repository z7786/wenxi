import '../core/json.dart';
import '../domain/models.dart';
import '../domain/resource_search.dart';

List<Json> parseClientTelegram(Json message) {
  final lines = message
      .str('text')
      .split('\n')
      .map(
        (line) => line
            .replaceAll(
              RegExp(
                r'[\u{10000}-\u{10ffff}\u2600-\u27bf\u200d\ufe0f]',
                unicode: true,
              ),
              '',
            )
            .trim(),
      )
      .where((line) => line.isNotEmpty)
      .toList();
  final urls = RegExp(r'''https?://[^\s<>"'，。；]+''');
  String title(String line) => line
      .replaceAll(
        RegExp(
          r'^(?:(?:【|\[)?(?:资源名称|影视名称|片名|剧名|名称|标题|title|资源)(?:】|\])?\s*[:：]\s*)+',
          caseSensitive: false,
        ),
        '',
      )
      .replaceAll(RegExp(r'(?:[|—-]\s*)?@[a-zA-Z0-9_]+.*$'), '')
      .trim()
      .replaceAll(RegExp(r'^[【\[:：|\- ]+|[】\]:：|\- ]+$'), '');
  bool label(String line) => RegExp(
    r'^(?:夸克|百度|阿里|阿里云盘|UC|迅雷|天翼|移动|联通|115|123|PikPak|下载|链接)(?:网盘|云盘)?(?:下载|链接)?$',
    caseSensitive: false,
  ).hasMatch(title(line));
  bool ignore(String line) =>
      label(line) ||
      line.startsWith('#') ||
      RegExp(r'^(?:简介|描述|说明|内容|备注|提取码|密码|访问码)\s*[:：]').hasMatch(line) ||
      RegExp(r'关注频道|入群交流|永久发布页|版权归原作者|防走丢').hasMatch(line);
  final links = <String, String>{};
  for (final line in lines) {
    for (final match in urls.allMatches(line)) {
      try {
        final hit = ResourceSearchHit.fromRaw({
          'url': match[0],
          'title': '频道资源',
        });
        if (hit.link?.kind == LinkKind.cloudShare) {
          links[hit.identity] = hit.cloudName;
        }
      } catch (_) {}
    }
  }
  final multi = links.length > links.values.toSet().length;
  var heading =
      lines
          .where((line) => !urls.hasMatch(line) && !ignore(line))
          .map(title)
          .where((t) => t.isNotEmpty)
          .firstOrNull ??
      '';
  if (heading.isEmpty || RegExp(r'^v?\d+\.').hasMatch(heading)) {
    final tags = lines
        .where((line) => line.startsWith('#'))
        .expand(
          (line) => RegExp(r'#([^\s#]+)').allMatches(line).map((m) => m[1]!),
        )
        .where(
          (tag) =>
              !label(tag) &&
              !{'Android', 'Windows', '安卓', '软件', '合集'}.contains(tag),
        );
    if (tags.isNotEmpty) heading = '${tags.first} $heading'.trim();
  }
  var current = heading;
  final output = <Json>[], seen = <String>{};
  for (var i = 0; i < lines.length; i++) {
    final line = lines[i], matches = urls.allMatches(line).toList();
    if (matches.isEmpty) {
      if (!ignore(line) && (multi || current.isEmpty)) current = title(line);
      continue;
    }
    final prefix = line.substring(0, matches.first.start).trim();
    final name = prefix.isNotEmpty && !ignore(prefix) ? title(prefix) : current;
    if (name.isEmpty) continue;
    for (var j = 0; j < matches.length; j++) {
      final m = matches[j], url = m[0]!.replaceAll(RegExp(r'[.,;，。；、)]+$'), '');
      try {
        final hit = ResourceSearchHit.fromRaw({'url': url, 'title': name});
        if (hit.link?.kind != LinkKind.cloudShare || !seen.add(hit.identity)) {
          continue;
        }
        final end = j + 1 < matches.length ? matches[j + 1].start : line.length;
        var context = line.substring(m.end, end);
        if (i + 1 < lines.length && !urls.hasMatch(lines[i + 1])) {
          context += ' ${lines[i + 1]}';
        }
        final code =
            RegExp(
              r'(?:提取码|访问码|密码)\s*[:：]?\s*([a-zA-Z0-9]{4,8})\b',
            ).firstMatch(context)?.group(1) ??
            '';
        output.add({
          'title': name,
          'url': url,
          'password': hit.password.ifEmpty(code),
          'datetime': message.str('datetime'),
          'cover_url': message.str('cover_url'),
          'description': multi ? '' : message.str('text'),
        });
      } catch (_) {}
    }
  }
  return output;
}
