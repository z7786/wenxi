import 'dart:convert';
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:asterlink/core/json.dart';
import 'package:asterlink/domain/models.dart';
import 'package:asterlink/domain/remote_control.dart';
import 'remote_control_support.dart';

void main() {
  test(
    'Apple update sections roundtrip independently and retain valid values on a bad publication',
    () {
      final root = controlJson(androidBuild: 221, windowsBuild: 222);
      final updates = root['updates'] as Map;
      for (final (platform, build) in [('ios', 223), ('macos', 224)]) {
        updates[platform] = {
          'enabled': true,
          'version': '2.2.1',
          'build': build,
          'downloadUrl': 'https://example.test/$platform',
          'notes': 'Apple update',
          'force': true,
          'expiresAt': '2026-12-01T00:00:00Z',
        };
      }
      final previous = RemoteControlDocument.parse(root);
      expect(
        previous.validSections,
        containsAll(['updates.ios', 'updates.macos']),
      );
      final restored = RemoteControlConfig.fromJson(previous.config.toJson());
      expect(restored.updates['ios']!.build, 223);
      expect(restored.updates['macos']!.build, 224);
      (updates['ios'] as Map)['downloadUrl'] = 'http://insecure.test/app.ipa';
      (updates['macos'] as Map)['build'] = 225;
      final next = RemoteControlDocument.parse(root, previous: previous.config);
      expect(next.issues.single.path, 'updates.ios.downloadUrl');
      expect(ControlConfigIssue.isKnownPath(next.issues.single.path), isTrue);
      expect(next.config.updates['ios']!.build, 223);
      expect(next.config.updates['macos']!.build, 225);
      expect(RemoteControlConfig.fromJson(controlJson()).updates, isEmpty);
    },
  );

  test(
    'Optional in-app update link and passcode survive roundtrip; old configs use browser URL',
    () {
      final source = controlJson(androidBuild: 120, windowsBuild: 120);
      final android = (source['updates'] as Map)['android'] as Map;
      android['inAppDownloadUrl'] = 'https://wwanc.lanzouq.com/iabc123';
      android['inAppPasscode'] = '1234';
      final config = RemoteControlConfig.fromJson(source);
      final restored = RemoteControlConfig.fromJson(config.toJson());
      expect(
        restored.updates['android']!.appDownloadUrl.host,
        'wwanc.lanzouq.com',
      );
      expect(restored.updates['android']!.inAppPasscode, '1234');
      expect(
        restored.updates['android']!.downloadUrl.host,
        'download.example.test',
      );
      expect(
        restored.updates['windows']!.appDownloadUrl,
        restored.updates['windows']!.downloadUrl,
      );
      android['inAppDownloadUrl'] = 'http://example.test/app.apk';
      expect(() => RemoteControlConfig.fromJson(source), throwsFormatException);
    },
  );
  test('The shipped single JSON is valid and inactive until configured', () {
    final config = RemoteControlConfig.decode(
      File('config/control.example.json').readAsStringSync(),
    );
    expect(config.revision, 1);
    expect(config.announcement, isNull);
    expect(config.updates, isEmpty);
    expect(config.helpUrl, isNull);
    expect(config.clouds.length, CloudPlatform.values.length);
    expect(CloudPlatform.values.every((p) => config.cloud(p).enabled), isTrue);
  });

  test('Optional sections default to enabled clouds and no prompts', () {
    final config = RemoteControlConfig.fromJson({'schema': 1, 'revision': 2});
    expect(config.announcement, isNull);
    expect(config.updates, isEmpty);
    expect(config.helpUrl, isNull);
    expect(config.aboutText, RemoteControlConfig.defaultAboutDescription);
    expect(CloudPlatform.values.every((p) => config.cloud(p).enabled), isTrue);
  });

  test('About text is plain, bounded, optional and included in cache', () {
    final json = controlJson()..['about'] = {'description': '  自定义介绍\n第二行  '};
    final config = RemoteControlConfig.fromJson(json);
    expect(config.aboutText, '自定义介绍\n第二行');
    expect(
      RemoteControlConfig.fromJson(config.toJson()).aboutText,
      config.aboutText,
    );
    json['about'] = {'description': '   '};
    expect(
      RemoteControlConfig.fromJson(json).aboutText,
      RemoteControlConfig.defaultAboutDescription,
    );
    for (final invalid in [123, 'x' * 8193]) {
      json['about'] = {'description': invalid};
      expect(() => RemoteControlConfig.fromJson(json), throwsFormatException);
    }
  });

  test('All four sections round-trip with independent platform updates', () {
    final config = RemoteControlConfig.fromJson(
      controlJson(
        noticeId: 'notice-1',
        androidBuild: 50,
        windowsBuild: 51,
        force: true,
        buttonText: '查看活动',
        buttonUrl: 'https://notice.example.test/event?from=app#details',
        disabled: ['uc', 'c139'],
        help: true,
      ),
    );
    expect(config.announcement!.content, contains('\n'));
    expect(config.announcement!.buttonText, '查看活动');
    expect(config.announcement!.buttonUrl!.fragment, 'details');
    expect(config.cloud(CloudPlatform.uc).enabled, isFalse);
    expect(config.cloud(CloudPlatform.c139).enabled, isFalse);
    expect(config.cloud(CloudPlatform.tianyi).enabled, isTrue);
    expect(config.updates['android']!.build, 50);
    expect(config.updates['android']!.force, isTrue);
    expect(config.updates['windows']!.build, 51);
    expect(config.helpUrl!.fragment, 'cloud');
    expect(
      RemoteControlConfig.fromJson(config.toJson()).toJson(),
      config.toJson(),
    );
  });

  test(
    'Existing JSON without new fields keeps an ordinary update and plain notice',
    () {
      final old = controlJson(noticeId: 'old', androidBuild: 50);
      (old['updates'] as Map)['android'].remove('force');
      final config = RemoteControlConfig.fromJson(old);
      expect(config.updates['android']!.force, isFalse);
      expect(config.announcement!.buttonText, isEmpty);
      expect(config.announcement!.buttonUrl, isNull);
    },
  );

  test('Startup announcements accept and cache mini-program buttons', () {
    final source = controlJson(
      noticeId: 'mini-program',
      buttonText: '打开微信小程序',
      buttonUrl: 'weixin://dl/business/?t=example-ticket',
    );
    (source['announcement'] as Map)['content'] =
        '活动详情\n\n![图片](https://images.example.test/notice.png)';
    final config = RemoteControlConfig.fromJson(source);
    final restored = RemoteControlConfig.fromJson(config.toJson());
    expect(restored.announcement!.buttonUrl, config.announcement!.buttonUrl);
    expect(restored.announcement!.contentKey, config.announcement!.contentKey);
    expect(restored.announcement!.content, config.announcement!.content);
    (source['announcement'] as Map)['buttonUrl'] = 'weixin://dl/scan/';
    final rejected = RemoteControlDocument.parse(source, previous: config);
    expect(rejected.issues.single.path, 'announcement.buttonUrl');
    expect(rejected.config.announcement, same(config.announcement));
  });

  test('Update policies remain independent for Android and Windows', () {
    final json = controlJson(androidBuild: 50, windowsBuild: 51, force: true);
    (json['updates'] as Map)['windows']['force'] = false;
    final config = RemoteControlConfig.fromJson(json);
    expect(config.updates['android']!.force, isTrue);
    expect(config.updates['windows']!.force, isFalse);
  });

  test('Announcements no longer require a publisher-managed ID', () {
    final json = controlJson(noticeId: 'legacy');
    (json['announcement'] as Map).remove('id');
    final config = RemoteControlConfig.fromJson(json);
    expect(config.announcement!.id, isEmpty);
    expect(config.announcement!.content, contains('网盘维护说明'));
    expect((config.toJson()['announcement'] as Map).containsKey('id'), isFalse);
    expect(
      RemoteControlConfig.fromJson(config.toJson()).announcement!.contentKey,
      config.announcement!.contentKey,
    );
  });

  test(
    'Local announcement identity follows text and links, not legacy IDs',
    () {
      final first = RemoteControlConfig.fromJson(
        controlJson(noticeId: 'a'),
      ).announcement!;
      final second = RemoteControlConfig.fromJson(
        controlJson(revision: 2, noticeId: 'b'),
      ).announcement!;
      expect(first.contentKey, second.contentKey);
      final changed = controlJson(
        noticeId: 'a',
        buttonText: '详情',
        buttonUrl: 'https://example.test/notice',
      );
      expect(
        RemoteControlConfig.fromJson(changed).announcement!.contentKey,
        isNot(first.contentKey),
      );
    },
  );

  for (final fields in [
    {'buttonText': '查看活动'},
    {'buttonUrl': 'https://notice.example.test/event'},
    {'buttonText': ' ', 'buttonUrl': 'https://notice.example.test/event'},
    {'buttonText': '字' * 25, 'buttonUrl': 'https://notice.example.test/event'},
    {'buttonText': 123, 'buttonUrl': 'https://notice.example.test/event'},
    {'buttonText': '查看活动', 'buttonUrl': false},
  ]) {
    test('Rejects incomplete or invalid announcement button $fields', () {
      final json = controlJson(noticeId: 'a');
      (json['announcement'] as Map).addAll(fields);
      expect(() => RemoteControlConfig.fromJson(json), throwsFormatException);
    });
  }

  test('Empty announcement button fields disable the link', () {
    final config = RemoteControlConfig.fromJson(
      controlJson(noticeId: 'a', buttonText: '', buttonUrl: ''),
    );
    expect(config.announcement!.buttonUrl, isNull);
  });

  for (final force in ['true', 1, null]) {
    test('Rejects non-boolean update policy $force', () {
      final json = controlJson(androidBuild: 50);
      (json['updates'] as Map)['android']['force'] = force;
      expect(() => RemoteControlConfig.fromJson(json), throwsFormatException);
    });
  }

  test('Disabled cloud without a reason has an actionable fallback', () {
    final config = RemoteControlConfig.fromJson({
      'schema': 1,
      'revision': 1,
      'clouds': {
        'baidu': {'enabled': false},
      },
    });
    expect(
      config.cloud(CloudPlatform.baidu).reason(CloudPlatform.baidu),
      contains('百度'),
    );
  });

  final invalid = <String, Object?>{
    'array root': [],
    'string switch': {
      'schema': 1,
      'revision': 1,
      'clouds': {
        'uc': {'enabled': 'false'},
      },
    },
    'null switch': {
      'schema': 1,
      'revision': 1,
      'clouds': {
        'uc': {'enabled': null},
      },
    },
    'unknown cloud': {
      'schema': 1,
      'revision': 1,
      'clouds': {
        'tiany': {'enabled': false},
      },
    },
    'incomplete notice': {
      'schema': 1,
      'revision': 1,
      'announcement': {'enabled': true},
    },
    'incomplete update': {
      'schema': 1,
      'revision': 1,
      'updates': {
        'android': {'enabled': true},
      },
    },
    'negative build': {
      'schema': 1,
      'revision': 1,
      'updates': {
        'windows': {'enabled': true, 'version': '1.0', 'build': -1},
      },
    },
    'non-object help': {'schema': 1, 'revision': 1, 'help': []},
    'enabled help without a URL': {
      'schema': 1,
      'revision': 1,
      'help': {'enabled': true},
    },
    'string help switch': {
      'schema': 1,
      'revision': 1,
      'help': {'enabled': 'false', 'url': 'https://example.com/help'},
    },
    'long reason': {
      'schema': 1,
      'revision': 1,
      'clouds': {
        'uc': {'enabled': false, 'message': 'a' * 201},
      },
    },
  };
  test('Publication metadata never blocks readable content', () {
    for (final metadata in <Json>[
      {},
      {'schema': 2},
      {'schema': null, 'revision': null},
      {'schema': 'future', 'revision': 'same'},
      {'revision': 1.5},
      {'revision': 0},
      {'revision': -1},
      {'revision': 2147483648},
    ]) {
      final config = RemoteControlConfig.fromJson({
        ...metadata,
        'announcement': {
          'enabled': true,
          'id': {'unused': true},
          'title': '新公告',
          'content': '直接生效',
        },
        'about': {'description': '新介绍'},
      });
      expect(config.announcement!.content, '直接生效');
      expect(config.aboutText, '新介绍');
      expect(RemoteControlConfig.fromJson(config.toJson()).aboutText, '新介绍');
    }
  });
  for (final entry in invalid.entries) {
    test('Rejects ${entry.key} without coercing remote values', () {
      expect(
        () => RemoteControlConfig.fromJson(entry.value),
        throwsFormatException,
      );
    });
  }

  for (final url in [
    'http://example.com/a',
    'javascript:alert(1)',
    'file:///C:/test',
    'https://user:password@example.com/',
    'https:///a',
    'https://example.com/a\nb',
    'https://example.com:99999/',
    'https://example.com\\@other.test/',
  ]) {
    test(
      'Rejects unsafe link $url in help, updates and announcement buttons',
      () {
        final help = controlJson()..['help'] = {'enabled': true, 'url': url};
        expect(() => RemoteControlConfig.fromJson(help), throwsFormatException);
        final update = controlJson(androidBuild: 50);
        (update['updates'] as Map)['android']['downloadUrl'] = url;
        expect(
          () => RemoteControlConfig.fromJson(update),
          throwsFormatException,
        );
        final notice = controlJson(
          noticeId: 'a',
          buttonText: '查看详情',
          buttonUrl: url,
        );
        expect(
          () => RemoteControlConfig.fromJson(notice),
          throwsFormatException,
        );
      },
    );
  }

  test('Enforces the UTF-8 byte limit and rejects truncated JSON', () {
    final oversized = jsonEncode({
      'schema': 1,
      'revision': 1,
      'extra': '文' * 90000,
    });
    expect(oversized.length, lessThan(RemoteControlConfig.maxBytes));
    expect(() => RemoteControlConfig.decode(oversized), throwsFormatException);
    expect(
      () => RemoteControlConfig.decode('{"schema":1,'),
      throwsFormatException,
    );
  });
}
