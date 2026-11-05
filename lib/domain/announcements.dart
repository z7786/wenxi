import 'dart:convert';
import 'package:crypto/crypto.dart';
import '../core/json.dart';
import 'remote_control.dart';

class AnnouncementMessage {
  const AnnouncementMessage({
    this.id = '',
    required this.title,
    required this.content,
    this.publishedAt,
    this.pinned = false,
    this.buttonText = '',
    this.buttonUrl,
  });

  final String id, title, content, buttonText;
  final DateTime? publishedAt;
  final bool pinned;
  final Uri? buttonUrl;

  // A changed message becomes unread even when its ID is reused. Reordering,
  // pinning or correcting a date does not ask the reader to read it again.
  String get contentKey => sha256
      .convert(
        utf8.encode(
          jsonEncode([title, content, buttonText, buttonUrl?.toString()]),
        ),
      )
      .toString();

  Json toJson() => {
    if (id.isNotEmpty) 'id': id,
    'title': title,
    'content': content,
    if (publishedAt != null)
      'publishedAt': publishedAt!.toUtc().toIso8601String(),
    if (pinned) 'pinned': true,
    if (buttonUrl != null) ...{
      'buttonText': buttonText,
      'buttonUrl': buttonUrl.toString(),
    },
  };
}

class AnnouncementFeed {
  const AnnouncementFeed(this.messages, {this.skippedItems = 0});

  static const maxItems = 100;
  static const maxBytes = RemoteControlConfig.maxBytes;
  final List<AnnouncementMessage> messages;
  final int skippedItems;

  factory AnnouncementFeed.decode(String text) {
    if (text.length > maxBytes || utf8.encode(text).length > maxBytes) {
      throw const FormatException('公告文件不能超过 256 KiB');
    }
    return AnnouncementFeed.fromJson(
      jsonDecode(text.startsWith('\uFEFF') ? text.substring(1) : text),
    );
  }

  factory AnnouncementFeed.fromJson(Object? value) {
    if (value is! Map<String, dynamic>) {
      throw const FormatException('公告文件必须是 JSON 对象');
    }
    if (!_flag(value, 'enabled')) return const AnnouncementFeed([]);
    final rows = value['announcements'];
    if (rows is! List || rows.length > maxItems) {
      throw const FormatException('announcements 必须是不超过 100 条的数组');
    }
    final messages = <AnnouncementMessage>[];
    final keys = <String>{};
    var skipped = 0, valid = 0;
    for (final row in rows) {
      try {
        if (row is! Map<String, dynamic>) {
          throw const FormatException('公告必须是 JSON 对象');
        }
        if (!_flag(row, 'enabled')) {
          valid++;
          continue;
        }
        final title = _text(row, 'title', 80);
        final content = _text(row, 'content', 8192);
        if (title.isEmpty || content.isEmpty) {
          throw const FormatException('公告标题和正文不能为空');
        }
        final button = _text(row, 'buttonText', 24);
        final link = _text(row, 'buttonUrl', 2048);
        if (button.isEmpty != link.isEmpty) {
          throw const FormatException('按钮文字和地址需要同时填写');
        }
        final message = AnnouncementMessage(
          id: row['id'] is String ? _text(row, 'id', 160) : '',
          title: title,
          content: content,
          publishedAt: _date(_text(row, 'publishedAt', 40)),
          pinned: _flag(row, 'pinned', fallback: false),
          buttonText: button,
          buttonUrl: link.isEmpty ? null : announcementButtonUri(link),
        );
        valid++;
        if (keys.add(message.contentKey)) messages.add(message);
      } on FormatException {
        skipped++;
      }
    }
    if (rows.isNotEmpty && valid == 0) {
      throw const FormatException('公告文件中没有可读取的公告');
    }
    final order = {for (var i = 0; i < messages.length; i++) messages[i]: i};
    messages.sort((a, b) {
      if (a.pinned != b.pinned) return a.pinned ? -1 : 1;
      final aDate = a.publishedAt, bDate = b.publishedAt;
      if (aDate != null && bDate != null) {
        final dateOrder = bDate.compareTo(aDate);
        if (dateOrder != 0) return dateOrder;
      } else if (aDate != bDate) {
        return aDate == null ? 1 : -1;
      }
      return order[a]!.compareTo(order[b]!);
    });
    return AnnouncementFeed(List.unmodifiable(messages), skippedItems: skipped);
  }

  Json toJson() => {
    'announcements': messages.map((item) => item.toJson()).toList(),
  };

  static bool _flag(Json value, String key, {bool fallback = true}) {
    if (!value.containsKey(key)) return fallback;
    final flag = value[key];
    if (flag is! bool) throw const FormatException('开关必须为 true 或 false');
    return flag;
  }

  static String _text(Json value, String key, int limit) {
    if (!value.containsKey(key)) return '';
    final text = value[key];
    if (text is! String || text.length > limit) {
      throw const FormatException('公告文本类型或长度不正确');
    }
    return text.trim();
  }

  static DateTime? _date(String value) {
    if (value.isEmpty) return null;
    final match = RegExp(
      r'^(\d{4})-(\d{2})-(\d{2})(?:T(\d{2}):(\d{2}):(\d{2})(?:\.\d{1,6})?(?:Z|[+-](\d{2}):(\d{2})))?$',
    ).firstMatch(value);
    if (match == null) throw const FormatException('公告日期格式不正确');
    final year = int.parse(match[1]!),
        month = int.parse(match[2]!),
        day = int.parse(match[3]!);
    final calendar = DateTime.utc(year, month, day);
    final result = DateTime.tryParse(value);
    if (result == null ||
        calendar.year != year ||
        calendar.month != month ||
        calendar.day != day ||
        (match[4] != null &&
            (int.parse(match[4]!) > 23 ||
                int.parse(match[5]!) > 59 ||
                int.parse(match[6]!) > 59)) ||
        (match[7] != null &&
            (int.parse(match[7]!) > 23 || int.parse(match[8]!) > 59))) {
      throw const FormatException('公告日期无效');
    }
    return result;
  }
}
