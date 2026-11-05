part of 'remote_control.dart';

/// Only known field paths and local explanations are exposed to diagnostics.
class ControlFormatException extends FormatException {
  const ControlFormatException(this.path, String message) : super(message);
  final String path;
}

class ControlConfigIssue {
  const ControlConfigIssue(this.section, this.path, this.message);
  final String section, path, message;
  Json toJson() => {'section': section, 'path': path, 'message': message};

  static bool isKnownPath(String path) {
    final fields = <String, List<String>>{
      'announcement': [
        'enabled',
        'id',
        'title',
        'content',
        'buttonText',
        'buttonUrl',
      ],
      'clouds': [],
      for (final p in CloudPlatform.values)
        'clouds.${p.name}': ['enabled', 'message', 'expiresAt'],
      'updates': [],
      for (final p in ['android', 'windows', 'macos'])
        'updates.$p': [
          'enabled',
          'version',
          'build',
          'downloadUrl',
          'inAppDownloadUrl',
          'inAppPasscode',
          'notes',
          'force',
          'expiresAt',
        ],
      'help': ['enabled', 'url'],
      'about': ['description'],
      'parserHub': ['url'],
    };
    return fields.containsKey(path) ||
        fields.entries.any(
          (entry) => entry.value.any((field) => path == '${entry.key}.$field'),
        );
  }
}

/// A complete publication with independent validation for each known section.
/// Invalid sections retain their previous values; absent display sections reset
/// them. The service address survives older publications that omit its field.
class RemoteControlDocument {
  const RemoteControlDocument._(
    this.config,
    this.validSections,
    this.issues,
    this.fingerprint,
  );
  final RemoteControlConfig config;
  final Set<String> validSections;
  final List<ControlConfigIssue> issues;
  final String fingerprint;
  static final sectionNames = List<String>.unmodifiable([
    'announcement',
    for (final platform in CloudPlatform.values) 'clouds.${platform.name}',
    'updates.android',
    'updates.windows',
    'help',
    'about',
    'parserHub',
  ]);

  RemoteControlConfig get validated {
    if (issues.isNotEmpty) {
      final issue = issues.first;
      throw ControlFormatException(issue.path, issue.message);
    }
    return config;
  }

  factory RemoteControlDocument.decode(
    String text, {
    RemoteControlConfig previous = RemoteControlConfig.defaults,
  }) {
    if (text.length > RemoteControlConfig.maxBytes ||
        utf8.encode(text).length > RemoteControlConfig.maxBytes) {
      throw const ControlFormatException('control', '配置文件超过 256 KiB');
    }
    Object? root;
    try {
      root = jsonDecode(text);
    } on FormatException {
      throw const ControlFormatException('control', '配置不是完整有效的 JSON');
    }
    return RemoteControlDocument.parse(root, previous: previous);
  }

  factory RemoteControlDocument.parse(
    Object? value, {
    RemoteControlConfig previous = RemoteControlConfig.defaults,
  }) {
    final root = _ControlFields(value, 'control');
    // Publication metadata is optional. Apply recognized content regardless
    // of missing, reused or older schema/revision values.
    final revision = root.value['revision'] is int
        ? root.value['revision'] as int
        : 0;
    final valid = <String>{};
    final issues = <ControlConfigIssue>[];
    final wire = <String, Object?>{};
    final raw = root.value;
    T section<T>(
      String key,
      Object? source,
      T old,
      T Function() read,
      Object? Function(T) encode,
    ) {
      try {
        final result = read();
        wire[key] = {'valid': encode(result)};
        valid.add(key);
        return result;
      } on ControlFormatException catch (error) {
        issues.add(ControlConfigIssue(key, error.path, error.message));
        // Keep a content fingerprint for diagnostics and cache compatibility.
        // Rejected source values are never persisted or printed.
        wire[key] = {'invalid': source};
        return old;
      }
    }

    final announcement = section<RemoteAnnouncement?>(
      'announcement',
      raw['announcement'],
      previous.announcement,
      () {
        if (!raw.containsKey('announcement')) return null;
        final f = _ControlFields(raw['announcement'], 'announcement');
        if (!f.boolean('enabled', fallback: false)) return null;
        final title = f.string('title', 80),
            content = f.string('content', 8192);
        if (title.isEmpty) f.fail('title', '启用公告需要填写标题');
        if (content.isEmpty) f.fail('content', '启用公告需要填写正文');
        final button = f.string('buttonText', 24),
            url = f.string('buttonUrl', 2048);
        if (button.isEmpty != url.isEmpty) {
          f.fail(button.isEmpty ? 'buttonText' : 'buttonUrl', '按钮文字和地址需要同时填写');
        }
        return RemoteAnnouncement(
          f.value['id'] is String ? (f.value['id'] as String).trim() : '',
          title,
          content,
          buttonText: button,
          buttonUrl: url.isEmpty
              ? null
              : f.read('buttonUrl', () => announcementButtonUri(url)),
        );
      },
      (a) => a == null
          ? null
          : RemoteControlConfig(announcement: a).toJson()['announcement'],
    );

    final clouds = <CloudPlatform, CloudControl>{};
    for (final platform in CloudPlatform.values) {
      final key = 'clouds.${platform.name}';
      final container = raw['clouds'];
      final source = container is Map ? container[platform.name] : container;
      clouds[platform] = section<CloudControl>(
        key,
        source,
        previous.cloud(platform),
        () {
          if (!raw.containsKey('clouds')) return const CloudControl();
          final group = _ControlFields(container, 'clouds');
          if (!group.value.containsKey(platform.name)) {
            return const CloudControl();
          }
          final f = _ControlFields(source, key);
          if (f.boolean('enabled')) return const CloudControl();
          return CloudControl(
            enabled: false,
            message: f.string('message', 200),
            expiresAt: f.expiry(),
          );
        },
        (c) => {
          'enabled': c.enabled,
          'message': c.message,
          if (c.expiresAt != null)
            'expiresAt': c.expiresAt!.toUtc().toIso8601String(),
        },
      );
    }
    if (raw['clouds'] case final Map<String, dynamic> entries) {
      final unknown = {
        for (final entry in entries.entries)
          if (!CloudPlatform.values.any((p) => p.name == entry.key))
            entry.key: entry.value,
      };
      if (unknown.isNotEmpty) {
        issues.add(
          const ControlConfigIssue('clouds', 'clouds', '已忽略无法识别的网盘名称'),
        );
        wire['clouds.unknown'] = {'invalid': unknown};
      }
    }

    final updates = <String, RemoteUpdate>{};
    for (final platform in ['android', 'windows', 'macos']) {
      final key = 'updates.$platform', container = raw['updates'];
      final source = container is Map ? container[platform] : container;
      final update = section<RemoteUpdate?>(
        key,
        source,
        previous.updates[platform],
        () {
          if (!raw.containsKey('updates')) return null;
          final group = _ControlFields(container, 'updates');
          if (!group.value.containsKey(platform)) return null;
          final f = _ControlFields(source, key);
          if (!f.boolean('enabled', fallback: false)) return null;
          final version = f.string('version', 64), build = f.integer('build');
          if (version.isEmpty) f.fail('version', '启用更新需要填写版本号');
          if (build < 1) f.fail('build', '启用更新需要正整数 build');
          final url = f.link('downloadUrl', f.string('downloadUrl', 2048));
          final force = f.boolean('force', fallback: false);
          final appUrl = f.string('inAppDownloadUrl', 2048);
          final passcode = f.string('inAppPasscode', 32).trim();
          return RemoteUpdate(
            version,
            build,
            url,
            f.string('notes', 8192),
            force: force,
            expiresAt: force ? f.expiry() : null,
            inAppDownloadUrl: appUrl.isEmpty
                ? null
                : f.link('inAppDownloadUrl', appUrl),
            inAppPasscode: passcode,
          );
        },
        (u) => u == null
            ? null
            : (RemoteControlConfig(updates: {platform: u}).toJson()['updates']
                  as Map)[platform],
      );
      if (update != null) updates[platform] = update;
    }

    final help = section<Uri?>('help', raw['help'], previous.helpUrl, () {
      if (!raw.containsKey('help')) return null;
      final f = _ControlFields(raw['help'], 'help');
      if (!f.boolean('enabled', fallback: false)) return null;
      return f.link('url', f.string('url', 2048));
    }, (value) => value?.toString());
    final about = section<String>(
      'about',
      raw['about'],
      previous.aboutDescription,
      () {
        if (!raw.containsKey('about')) return '';
        return _ControlFields(
          raw['about'],
          'about',
        ).string('description', 8192);
      },
      (value) => value,
    );
    final parserHubUrl = section<Uri?>(
      'parserHub',
      raw['parserHub'],
      previous.parserHubUrl,
      () {
        if (!raw.containsKey('parserHub')) return previous.parserHubUrl;
        final f = _ControlFields(raw['parserHub'], 'parserHub');
        return f.read('url', () => parserHubUri(f.string('url', 2048)));
      },
      (value) => value?.toString(),
    );
    final config = RemoteControlConfig(
      revision: revision,
      announcement: announcement,
      clouds: Map.unmodifiable(clouds),
      updates: Map.unmodifiable(updates),
      helpUrl: help,
      aboutDescription: about,
      parserHubUrl: parserHubUrl,
    );
    return RemoteControlDocument._(
      config,
      Set.unmodifiable(valid),
      List.unmodifiable(issues),
      sha256
          .convert(utf8.encode(jsonEncode(_canonicalControl(wire))))
          .toString(),
    );
  }
}

Object? _canonicalControl(Object? value) {
  if (value is Map) {
    final keys = value.keys.cast<String>().toList()..sort();
    return {for (final key in keys) key: _canonicalControl(value[key])};
  }
  if (value is List) return value.map(_canonicalControl).toList();
  return value;
}

class _ControlFields {
  _ControlFields(Object? raw, this.path) {
    try {
      value = _object(raw, path);
    } on FormatException {
      throw ControlFormatException(path, '必须是 JSON 对象');
    }
  }
  final String path;
  late final Map<String, dynamic> value;
  String field(String key) => path == 'control' ? key : '$path.$key';
  Never fail(String key, String reason) =>
      throw ControlFormatException(field(key), reason);
  T read<T>(String key, T Function() action) {
    try {
      return action();
    } on FormatException catch (error) {
      fail(key, error.message);
    }
  }

  bool boolean(String key, {bool fallback = true}) =>
      read(key, () => _boolean(value, key, fallback: fallback));
  String string(String key, int max) =>
      read(key, () => _string(value, key, max: max));
  int integer(String key, {bool required = false}) =>
      read(key, () => _integer(value, key, required: required));
  Uri link(String key, String text) => read(key, () => httpsUri(text));
  DateTime? expiry() {
    final text = string('expiresAt', 32);
    if (text.isEmpty) return null;
    final match = RegExp(
      r'^(\d{4})-(\d{2})-(\d{2})T(\d{2}):(\d{2}):(\d{2})(?:\.(\d{1,3}))?Z$',
    ).firstMatch(text);
    if (match == null) fail('expiresAt', '请使用 UTC 时间，例如 2026-10-01T00:00:00Z');
    final parts = [for (var i = 1; i <= 6; i++) int.parse(match[i]!)];
    final date = DateTime.utc(
      parts[0],
      parts[1],
      parts[2],
      parts[3],
      parts[4],
      parts[5],
      int.parse((match[7] ?? '0').padRight(3, '0')),
    );
    if (date.year != parts[0] ||
        date.month != parts[1] ||
        date.day != parts[2] ||
        date.hour != parts[3] ||
        date.minute != parts[4] ||
        date.second != parts[5]) {
      fail('expiresAt', '结束时间不是有效日期');
    }
    return date;
  }
}
