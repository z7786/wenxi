import 'package:flutter_test/flutter_test.dart';
import 'package:asterlink/core/json.dart';
import 'package:asterlink/domain/auth.dart';
import 'package:asterlink/domain/links.dart';
import 'package:asterlink/domain/models.dart';
import 'package:asterlink/domain/settings.dart';
import 'package:asterlink/domain/downloads.dart';
import 'package:asterlink/download/hls.dart';
import 'package:asterlink/download/space_budget.dart';
import 'package:asterlink/platform/file_access.dart';
import 'package:asterlink/data/providers/c139.dart';
import 'package:asterlink/data/providers/pan123.dart';
import 'package:asterlink/data/providers/xunlei_protocol.dart';

void main() {
  test('All supported share formats recognize their own extraction codes', () {
    final links = LinkParser.parse('''
https://pan.baidu.com/s/1Baidu_Test?pwd=a1b2
https://pan.quark.cn/s/Quark123 提取码：q123
https://drive.uc.cn/s/Uc123456 访问码：u123
https://pan.xunlei.com/s/Xunlei_123 密码：x123
https://www.123pan.com/s/2785Vv-T4Ded?pwd=p123
https://yun.139.com/shareweb/#/w/i/C139_ID 提取码：m139
https://cloud.189.cn/web/share?code=TianyiExample 访问码：t189
https://example.lanzouu.com/iExample123 提取码：l123
https://www.alipan.com/s/Ali123 提取码：a123
https://115cdn.com/s/swfixture?password=k115
https://pan.wo.cn/s/1F1t6r76400?password=w123
https://www.guangyapan.com/s/Guangya123 提取码：g123
https://url69.ctfile.com/f/66485969-17569901563698-90650b?p=1664
https://share.feijipan.com/s/Share123?code=f123
https://mypikpak.com/s/Pikpak_123?pwd=k123
https://github.com/example/files
''');
    expect(links.length, 16);
    expect(
      links.map((l) => l.platform).toSet(),
      CloudPlatform.values.where((p) => p.supportsShareParsing).toSet(),
    );
    expect(links.map((l) => l.passcode), [
      'a1b2',
      'q123',
      'u123',
      'x123',
      'p123',
      'm139',
      't189',
      'l123',
      'a123',
      'k115',
      'w123',
      'g123',
      '1664',
      'f123',
      'k123',
      null,
    ]);
    expect(links.every((l) => l.kind == LinkKind.cloudShare), isTrue);
  });
  test('Signed URLs retain escape case, repeated query keys and ordering', () {
    expect(
      LinkParser.normalize('HTTPS://Example.COM/X%2fY%2Fz?b=2&a=%2b+%20&a=3'),
      'https://example.com/X%2fY%2Fz?b=2&a=%2b+%20&a=3',
    );
    expect(
      () => LinkParser.normalize('https://user:pass@example.com/file'),
      throwsA(isA<AppException>()),
    );
    expect(
      () => LinkParser.normalize('https://example.com/%oops'),
      throwsA(isA<AppException>()),
    );
  });
  test('Punctuation and duplicate links do not create duplicate tasks', () {
    final links = LinkParser.parse(
      'https://example.com/file.zip。 https://example.com/file.zip magnet:?xt=urn:btih:ABC123',
    );
    expect(links.length, 2);
    expect(links.first.url, 'https://example.com/file.zip');
    expect(links.last.kind, LinkKind.magnet);
  });
  test('Passcodes on separate shares never bleed into each other', () {
    final links = LinkParser.parse(
      'https://pan.quark.cn/s/First123 提取码：aaaa\nhttps://drive.uc.cn/s/Second456',
    );
    expect(links[0].passcode, 'aaaa');
    expect(links[1].passcode, isNull);
  });
  test(
    'Cookie presence and trusted local storage origins follow original login rules',
    () {
      expect(
        LoginCredentials.plausible(CloudPlatform.quark, '__pus=a'),
        isFalse,
      );
      expect(
        LoginCredentials.plausible(CloudPlatform.quark, '__pus=a; __puus=b'),
        isTrue,
      );
      expect(
        LoginCredentials.plausible(CloudPlatform.baidu, 'BDUSS='),
        isFalse,
      );
      expect(
        LoginCredentials.plausible(CloudPlatform.c139, 'Os_SSo_Sid=a; RMKEY=b'),
        isTrue,
      );
      final target = WebLoginTarget.targets[CloudPlatform.pan123]!;
      expect(target.canReadLocalStorage('https://yun.123pan.cn/web'), isTrue);
      for (final url in [
        'http://yun.123pan.cn',
        'https://yun.123pan.cn.evil.test',
        'https://yun.123pan.cn:444/',
        'https://evil@yun.123pan.cn',
      ]) {
        expect(target.canReadLocalStorage(url), isFalse);
      }
      expect(
        LoginCredentials.normalize(CloudPlatform.pan123, '"Bearer test-token"'),
        'test-token',
      );
    },
  );
  test(
    'Login polling suppresses repeated failed tokens and uses monotonic delays',
    () {
      final policy = LoginPollingPolicy();
      expect(policy.canAttempt('a', 0), isTrue);
      policy.started(0);
      policy.failed('a', 0);
      expect(policy.canAttempt('a', 6000), isFalse);
      expect(policy.canAttempt('b', 6000), isTrue);
      expect(policy.canAttempt('a', 10001), isTrue);
    },
  );
  test('Gopeed thread presets, global inheritance and explicit overrides', () {
    const defaults = AppSettings();
    expect(defaults.connectionsFor(CloudPlatform.quark), 512);
    expect(defaults.connectionsFor(CloudPlatform.uc), 512);
    expect(defaults.connectionsFor(CloudPlatform.baidu), 8);
    expect(defaults.connectionsFor(CloudPlatform.baidu, 'baidu_public'), 64);
    expect(defaults.connectionsFor(CloudPlatform.baidu, 'baidu_direct'), 3);
    expect(
      const AppSettings(
        threadOverrides: {'baidu_direct': 512},
      ).connectionsFor(CloudPlatform.baidu, 'baidu_direct'),
      8,
    );
    expect(
      const AppSettings(
        threadOverrides: {'baidu': 1, 'baidu_public': 32},
      ).connectionsFor(CloudPlatform.baidu, 'baidu_public'),
      32,
    );
    expect(
      const AppSettings(
        threads: 16,
        threadOverrides: {'baidu_public': 0},
      ).connectionsFor(CloudPlatform.baidu, 'baidu_public'),
      16,
    );
    expect(defaults.connectionsFor(CloudPlatform.baidu, 'baidu_preview'), 8);
    expect(
      defaults.connectionProfileFor(null, 'baidu_preview'),
      'baidu_preview',
    );
    expect(
      const AppSettings(
        threads: 512,
        threadOverrides: {'baidu': 512},
      ).connectionsFor(null, 'baidu_preview'),
      512,
    );
    expect(
      const AppSettings(
        threads: 512,
        threadOverrides: {'baidu': 512},
      ).connectionsFor(CloudPlatform.baidu),
      512,
    );
    expect(
      const AppSettings(
        threads: 512,
        threadOverrides: {'baidu': 0},
      ).connectionsFor(null, 'baidu'),
      512,
    );
    expect(defaults.connectionsFor(CloudPlatform.xunlei), 64);
    expect(defaults.connectionsFor(null), 64);
    const custom = AppSettings(
      threads: 16,
      threadOverrides: {'quark_route_1': 0, 'uc': 128},
    );
    expect(custom.connectionsFor(CloudPlatform.quark), 16);
    expect(custom.connectionsFor(CloudPlatform.uc), 128);
    expect(
      const AppSettings(
        threadOverrides: {'xunlei': 128},
      ).connectionsFor(CloudPlatform.xunlei),
      128,
    );
    expect(
      AppSettings.fromJson({'concurrent': 500, 'threads': 0}).concurrent,
      32,
    );
    expect(AppSettings.fromJson({'retries': 10}).retries, 10);
  });
  test(
    'Retry defaults migrate once and saved task budgets survive restore',
    () {
      expect(const AppSettings().retries, 64);
      expect(AppSettings.fromJson({}).retries, 64);
      final upgraded = AppSettings.fromJson({'retries': 3});
      expect(upgraded.retries, 64);
      for (final retries in [0, 1, 2, 3, 10, 64]) {
        final chosen = upgraded.update({'retries': retries});
        expect(AppSettings.fromJson(chosen.toJson()).retries, retries);
      }
      expect(AppSettings.fromJson({'retries': 2}).retries, 2);
      expect(AppSettings.fromJson({'retries': -1}).retries, 0);
      expect(AppSettings.fromJson({'retries': 999}).retries, 64);
      const task = DownloadTask(
        id: 'retry-budget',
        spec: DownloadSpec(
          url: 'https://example.com/file',
          fileName: 'file.bin',
        ),
        createdAt: 1,
      );
      expect(DownloadTask.fromJson(task.toJson()).retries, 64);
      expect(
        DownloadTask.fromJson({...task.toJson(), 'retries': 3}).retries,
        3,
      );
      expect(
        DownloadTask.fromJson({...task.toJson(), 'retries': 99}).retries,
        64,
      );
    },
  );
  test('Font size and custom concurrency survive settings serialization', () {
    final defaults = AppSettings.fromJson({});
    expect(defaults.fontScalePercent, 100);
    expect(defaults.concurrent, 3);
    final restored = AppSettings.fromJson(
      const AppSettings(fontScalePercent: 135, concurrent: 17).toJson(),
    ).update({'threads': 12});
    expect(restored.fontScalePercent, 135);
    expect(restored.concurrent, 17);
    expect(restored.threads, 12);
    expect(AppSettings.fromJson({'fontScalePercent': 0}).fontScalePercent, 80);
    expect(
      AppSettings.fromJson({'fontScalePercent': 999}).fontScalePercent,
      180,
    );
    expect(AppSettings.fromJson({'concurrent': 0}).concurrent, 1);
  });
  test('Resume requires strong identity and matching length', () {
    const first = RemoteIdentity(100, '"a"', 'yesterday');
    expect(first.canResume(const RemoteIdentity(100, '"a"', 'today')), isTrue);
    expect(first.canResume(const RemoteIdentity(101, '"a"', 'today')), isFalse);
    expect(
      first.canResume(const RemoteIdentity(100, '"b"', 'yesterday')),
      isFalse,
    );
    expect(
      const RemoteIdentity(
        100,
        'W/"a"',
        null,
      ).canResume(const RemoteIdentity(100, 'W/"a"', null)),
      isFalse,
    );
    expect(
      const RemoteIdentity(
        100,
        null,
        'today',
      ).canResume(const RemoteIdentity(100, null, 'today')),
      isTrue,
    );
  });
  test('Legacy source records keep share ID and account revision', () {
    final source = DownloadOrigin.fromJson({
      'version': 1,
      'platform': 'Quark',
      'mode': 'Share',
      'title': 'test',
      'rootId': '0',
      'metadata': {'stoken': 'fixture'},
      'accountRevision': 42,
      'share': {
        'id': 'share',
        'source': 'text',
        'url': 'https://pan.quark.cn/s/abc',
        'shareId': 'abc',
        'passcode': '1234',
      },
      'file': {'id': 'file', 'name': 'x.zip', 'size': 15, 'parentId': '0'},
    });
    expect(source.session.mode, BrowseMode.share);
    expect(source.session.sourceLink!.kind, LinkKind.cloudShare);
    expect(source.session.sourceLink!.passcode, '1234');
    expect(source.accountRevision, 42);
    expect(DownloadOrigin.fromJson(source.toJson()).file.id, 'file');
  });
  test('C139 request signatures match the Java known answer', () {
    expect(
      C139Protocol.calculateSign(
        '{"a":1}',
        '2026-08-25 12:34:56',
        'AbCdEf0123456789',
      ),
      '37671010D4036E42486B7EDC6BC52965',
    );
  });
  test('Xunlei device and captcha signatures match the Java known answers', () {
    const device = '00000000000000000000000000000000';
    expect(
      XunleiProtocol.deviceSign(device),
      'div101.0000000000000000000000000000000082cf6e7d4529eb5c46c55ec7f46ea30f',
    );
    expect(
      XunleiProtocol.captchaSign(device, '1700000000000'),
      '1.a388fee14ed707a34724ff836a3267de',
    );
    expect(
      XunleiProtocol.trustedPage('https://i.xunlei.com.evil.test/verify'),
      isFalse,
    );
    expect(XunleiProtocol.trustedPage('https://i.xunlei.com/verify'), isTrue);
    expect(
      XunleiProtocol.trustedCallback(
        'xlaccsdk01://xunlei.com/callback?state=harbor',
      ),
      isTrue,
    );
    expect(
      XunleiProtocol.trustedCallback('xlaccsdk01://xunlei.com/other'),
      isFalse,
    );
  });
  test('123 CRC32 uses unsigned 32-bit arithmetic', () {
    expect(Pan123Connector.crc32('123456789'), 'cbf43926');
  });
  test(
    '123 signatures retain the YunX UTC plus 16 hours boundary and unpadded CRC',
    () {
      expect(
        Pan123Connector.makeSign(
          '/b/api/user/info',
          epochSeconds: 1700000000,
          random: 123456,
        ),
        ('f2ac3dd', '1700000000-123456-d49a505'),
      );
      expect(
        Pan123Connector.makeSign(
          '/b/api/share/download/info',
          epochSeconds: 0,
          random: 0,
        ),
        ('6b61bf1b', '0-0-3d983037'),
      );
      expect(
        Pan123Connector.makeSign(
          '/api/file/download_info',
          epochSeconds: 1798734600,
          random: 9999999,
        ),
        ('dd96a6bf', '1798734600-9999999-212b35d7'),
      );
    },
  );
  test('HLS resolves ordered initialization and media segments', () {
    final media = HlsPlaylist.media(
      'https://example.com/path/list.m3u8',
      '#EXTM3U\n#EXT-X-MAP:URI="init.mp4"\n#EXTINF:4,\nseg.m4s\n#EXTINF:4,\n../next.m4s\n#EXT-X-ENDLIST',
    );
    expect(media.urls, [
      'https://example.com/path/init.mp4',
      'https://example.com/path/seg.m4s',
      'https://example.com/next.m4s',
    ]);
    expect(media.fragmentedMp4, isTrue);
    expect(
      HlsPlaylist.choose(
        'https://example.com/list',
        '#EXTM3U\n#EXT-X-STREAM-INF:BANDWIDTH=100\nlow\n#EXT-X-STREAM-INF:BANDWIDTH=200\nhi',
      ),
      'https://example.com/hi',
    );
  });
  test(
    'HLS encryption, live streams and byte ranges are rejected explicitly',
    () {
      for (final playlist in [
        '#EXTM3U\n#EXT-X-KEY:METHOD=AES-128,URI="key"\na.ts\n#EXT-X-ENDLIST',
        '#EXTM3U\na.ts',
        '#EXTM3U\n#EXT-X-BYTERANGE:4@0\na.ts\n#EXT-X-ENDLIST',
      ]) {
        expect(
          () => HlsPlaylist.media('https://example.com/a', playlist),
          throwsA(isA<AppException>()),
        );
      }
      expect(
        () => HlsPlaylist.choose(
          'https://example.com/a',
          '#EXTM3U\n#EXT-X-SESSION-KEY:METHOD=AES-128,URI="key"',
        ),
        throwsA(isA<AppException>()),
      );
    },
  );
  test(
    'Concurrent disk reservations include the destination copy and margin',
    () async {
      final budget = SpaceBudget(() async => 250, margin: 10);
      expect(SpaceBudget.required(100, 20), 180);
      await budget.reserve('a', 100);
      await expectLater(budget.reserve('b', 140), throwsA(isA<AppException>()));
      budget.release('a');
      await budget.reserve('b', 140);
    },
  );
  test(
    'Windows file names and relative paths cannot escape the chosen folder',
    () {
      expect(safeFileName('CON.txt'), '_CON.txt');
      expect(safeFileName('..'), 'download.bin');
      expect(safeFileName('a:b?.zip'), 'a_b_.zip');
      expect(safeRelativePath('../a/../../b').contains('..'), isFalse);
    },
  );
}
