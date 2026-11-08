import 'dart:async';
import 'dart:convert';
import 'package:flutter_test/flutter_test.dart';
import 'package:asterlink/data/state_store.dart';
import 'package:asterlink/domain/settings.dart';
import 'package:asterlink/domain/models.dart';
import 'package:asterlink/platform/clipboard_links.dart';

void main() {
  test('Tianyi official copied links preserve access codes through replay', () {
    final suggestion = ClipboardLinkSuggestion.fromText(
      'https://cloud.189.cn/web/share?code=TestShare123（访问码：a1B2）',
    );
    expect(suggestion, isNotNull);
    final link = suggestion!.links.single;
    expect(link.kind, LinkKind.cloudShare);
    expect(link.platform, CloudPlatform.tianyi);
    expect(link.shareId, 'TestShare123');
    expect(link.passcode, 'a1B2');
    expect(
      ClipboardLinkSuggestion.fromText(suggestion.text)!.fingerprint,
      suggestion.fingerprint,
    );
  });

  test(
    'Tianyi H5 encoded copy labels preserve codes through clipboard replay',
    () {
      const url = 'https://h5.cloud.189.cn/share.html#/t/jy6R3u3YvQB3';
      final suggestion = ClipboardLinkSuggestion.fromText(
        '$url${Uri.encodeComponent('（访问码：m6h5）')}',
      )!;
      final link = suggestion.links.single;
      expect(link.kind, LinkKind.cloudShare);
      expect(link.platform, CloudPlatform.tianyi);
      expect(link.shareId, 'jy6R3u3YvQB3');
      expect(link.passcode, 'm6h5');
      expect(link.url, url);
      final replay = ClipboardLinkSuggestion.fromText(suggestion.text)!;
      expect(replay.fingerprint, suggestion.fingerprint);
      expect(replay.links.single.shareId, link.shareId);
      expect(replay.links.single.passcode, link.passcode);
    },
  );

  test('New cloud formats keep IDs and codes through clipboard replay', () {
    const text =
        'private note\n'
        'https://pan.baidu.com/share/init?surl=Baidu123&pass=b123\n\n'
        'author.share.123pan.com/s/Pan_123 提取码：old1 密码：p123\n\n'
        'https://caiyun.139.com/m/i?Mobile123&pwd=m123\n\n'
        'https://www.alipan.com/s/Ali123 提取码：a123';
    final suggestion = ClipboardLinkSuggestion.fromText(text)!;
    expect(suggestion.links.map((link) => link.shareId), [
      'Baidu123',
      'Pan_123',
      'Mobile123',
      'Ali123',
    ]);
    expect(suggestion.links.map((link) => link.passcode), [
      'b123',
      'p123',
      'm123',
      'a123',
    ]);
    expect(suggestion.text, isNot(contains('private note')));
    expect(
      ClipboardLinkSuggestion.fromText(suggestion.text)!.fingerprint,
      suggestion.fingerprint,
    );
    final unsupported = ClipboardLinkSuggestion.fromText(
      'https://share.weiyun.com/Wei123',
    )!;
    expect(unsupported.label, '微云分享链接（暂不支持分享解析）');
    expect(ClipboardLinkSuggestion.fromText('https://www.alipan.com/'), isNull);
    expect(
      ClipboardLinkSuggestion.fromText('https://yun.139.com/shareweb/#/'),
      isNull,
    );
  });

  test(
    'MoePal Lanzou aliases use the same clipboard classification and passcode rules',
    () {
      final suggestion = ClipboardLinkSuggestion.fromText(
        '下载：author.lanzou123.net/iExample123提取码：Ab12。\n\n'
        '目录：https://author.lansox.org/bFolder123 提取码：cd34\n'
        'https://lanzou123.net.evil.test/iWrong123',
      );
      expect(suggestion!.links, hasLength(2));
      expect(
        suggestion.links.map((link) => link.platform),
        everyElement(CloudPlatform.lanzou),
      );
      expect(suggestion.links.map((link) => link.passcode), ['Ab12', 'cd34']);
      expect(suggestion.links.map((link) => link.url), [
        'https://author.lanzou123.net/iExample123',
        'https://author.lansox.org/bFolder123',
      ]);
      expect(suggestion.text, isNot(contains('evil.test')));
    },
  );
  test(
    'old settings default to recognition; explicit choice survives other updates',
    () {
      expect(AppSettings.fromJson({}).clipboardRecognition, isTrue);
      final settings = AppSettings.fromJson({'clipboardRecognition': false});
      expect(settings.update({'theme': 'Dark'}).clipboardRecognition, isFalse);
    },
  );

  test(
    'recognizes mixed supported links and retains each extraction code only',
    () {
      final suggestion = ClipboardLinkSuggestion.fromText(
        'private unrelated note\n'
        'https://drive.uc.cn/s/aa123 提取码：a123\n\n'
        'https://pan.quark.cn/s/bb456 提取码：b456\n'
        'https://example.com/help\n'
        'https://example.com/movie.torrent',
      );
      expect(suggestion!.links, hasLength(3));
      expect(suggestion.links[0].passcode, 'a123');
      expect(suggestion.links[1].passcode, 'b456');
      expect(suggestion.text, isNot(contains('private')));
      expect(suggestion.text, isNot(contains('/help')));
      expect(suggestion.text, contains('提取码：a123'));
      expect(
        ClipboardLinkSuggestion.fromText(suggestion.text)!.fingerprint,
        suggestion.fingerprint,
      );
    },
  );

  test(
    'accepts valid magnets and rejects ordinary pages, logins, invalid magnets and oversized text',
    () {
      expect(
        ClipboardLinkSuggestion.fromText('magnet:?xt=urn:btih:${'a' * 40}'),
        isNotNull,
      );
      expect(
        ClipboardLinkSuggestion.fromText('magnet:?xt=urn:btih:${'A' * 32}'),
        isNotNull,
      );
      for (final text in [
        null,
        '',
        'hello',
        'https://example.com/help',
        'https://drive.uc.cn/',
        'https://pan.quark.cn/account/login',
        'https://drive.uc.cn.evil.example/s/abc',
        'magnet:?xt=urn:btih:bad',
        '${'x' * (64 * 1024)} https://drive.uc.cn/s/abc',
      ]) {
        expect(
          ClipboardLinkSuggestion.fromText(text),
          isNull,
          reason: 'unsupported clipboard',
        );
      }
    },
  );

  test(
    'leaves large batches to manual paste and deduplicates repeated share URLs',
    () {
      final suggestion = ClipboardLinkSuggestion.fromText(
        [
          for (var i = 0; i < 25; i++) 'https://drive.uc.cn/s/abc$i',
          'https://drive.uc.cn/s/abc0',
        ].join('\n'),
      );
      expect(suggestion, isNull);
      expect(
        ClipboardLinkSuggestion.fromText(
          'https://drive.uc.cn/s/abc0\nhttps://drive.uc.cn/s/abc0',
        )!.links,
        hasLength(1),
      );
    },
  );

  late StateStore store;
  late ClipboardLinks monitor;
  String? text;
  int reads = 0;
  Future<String?> Function()? reader;
  setUp(() {
    store = StateStore.memory();
    text = 'https://drive.uc.cn/s/abc123 提取码：a123';
    reads = 0;
    reader = null;
    monitor = ClipboardLinks(
      store,
      read: () async {
        reads++;
        return reader == null ? text : await reader!();
      },
    );
  });
  tearDown(() {
    monitor.dispose();
    store.dispose();
  });

  test(
    'only reads while visible; repeated focus keeps one suggestion',
    () async {
      await monitor.check();
      expect(reads, 0);
      monitor.setForeground(true);
      await monitor.check();
      final first = monitor.suggestion;
      expect(first, isNotNull);
      var changes = 0;
      monitor.addListener(() => changes++);
      monitor.setForeground(true);
      await monitor.check();
      expect(identical(first, monitor.suggestion), isTrue);
      expect(changes, 0);
      monitor.setForeground(false);
      await monitor.check();
      expect(reads, 2);
    },
  );

  test(
    'ignoring survives recreation without persisting copied contents',
    () async {
      monitor.setForeground(true);
      await monitor.check();
      final fingerprint = monitor.suggestion!.fingerprint;
      await monitor.acknowledge(monitor.suggestion!);
      expect(monitor.suggestion, isNull);
      expect(store.data['clipboardRecognitionLastHandled'], fingerprint);
      final saved = jsonEncode(store.data);
      expect(saved, isNot(contains('drive.uc.cn')));
      expect(saved, isNot(contains('a123')));
      monitor.dispose();
      monitor = ClipboardLinks(store, read: () async => text);
      monitor.setForeground(true);
      await monitor.check();
      expect(monitor.suggestion, isNull);
      text = 'https://drive.uc.cn/s/abc123 提取码：b456';
      await monitor.check();
      expect(monitor.suggestion, isNotNull);
    },
  );

  test('different surrounding prose does not repeat a handled link', () async {
    monitor.setForeground(true);
    await monitor.check();
    await monitor.acknowledge(monitor.suggestion!);
    text = 'new description: $text\nmore text';
    await monitor.check();
    expect(monitor.suggestion, isNull);
  });

  test(
    'manual paste, app copies and incoming shares can suppress their matching suggestion',
    () async {
      await monitor.acknowledgeText(text!);
      monitor.setForeground(true);
      await monitor.check();
      expect(monitor.suggestion, isNull);
      text = 'https://pan.quark.cn/s/different';
      await monitor.check();
      expect(monitor.suggestion, isNotNull);
    },
  );

  test('disabling removes pending UI and prevents subsequent reads', () async {
    monitor.setForeground(true);
    await monitor.check();
    await store.put('settings', {'clipboardRecognition': false});
    expect(monitor.suggestion, isNull);
    monitor.setForeground(false);
    monitor.setForeground(true);
    await monitor.check();
    expect(reads, 1);
    await store.put('settings', {'clipboardRecognition': true});
    await monitor.check();
    expect(reads, 2);
    expect(monitor.suggestion, isNotNull);
  });

  for (final action in ['background', 'disabled']) {
    test('late clipboard response is discarded after $action', () async {
      final waiting = Completer<String?>();
      reader = () => waiting.future;
      monitor.setForeground(true);
      final read = monitor.check();
      if (action == 'background') {
        monitor.setForeground(false);
      } else {
        await store.put('settings', {'clipboardRecognition': false});
      }
      waiting.complete(text);
      await read;
      expect(monitor.suggestion, isNull);
    });
  }

  test(
    'a failed clipboard read is silent and can recover on next focus',
    () async {
      monitor.setForeground(true);
      reader = () async => throw StateError('unavailable');
      await monitor.check();
      expect(monitor.suggestion, isNull);
      reader = null;
      await monitor.check();
      expect(monitor.suggestion, isNotNull);
      text = 'unrelated contents';
      await monitor.check();
      expect(monitor.suggestion, isNull);
    },
  );

  test('concurrent lifecycle reads are serialized', () async {
    final waiting = Completer<String?>();
    reader = () => waiting.future;
    monitor.setForeground(true);
    final first = monitor.check();
    await monitor.check();
    expect(reads, 1);
    waiting.complete(text);
    await first;
    expect(monitor.suggestion, isNotNull);
    monitor.setForeground(false);
  });
}
