import 'dart:io';
import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:asterlink/core/json.dart';
import 'package:asterlink/domain/settings.dart';
import 'package:asterlink/lan/lan_models.dart';

void main() {
  final token = lanId();
  LanFileEntry file(String path, {String? id}) => LanFileEntry(
    id: id ?? lanId(),
    path: path,
    size: 123,
    sha256: sha256.convert([1, 2, 3]).toString(),
  );
  LanManifest manifest(
    List<LanFileEntry> files, [
    List<String> directories = const [],
  ]) => LanManifest.fromJson(
    LanManifest(
      token: token,
      name: '测试分享',
      files: files,
      directories: directories,
    ).toJson(),
  );

  test('Only explicit local and shared IPv4 HTTP endpoints are accepted', () {
    for (final host in [
      '10.0.0.1',
      '172.16.0.1',
      '172.31.255.254',
      '192.168.1.2',
      '169.254.1.1',
      '127.0.0.1',
      '100.64.0.1',
      '100.127.255.254',
    ]) {
      expect(isLanAddress(host), isTrue, reason: host);
      expect(lanAddress('$host:52381').host, host);
    }
    for (final value in [
      'https://192.168.1.2',
      'http://example.com',
      'http://192.168.1.2@example.com',
      'http://user:pass@192.168.1.2',
      'http://8.8.8.8',
      'http://172.32.0.1',
      'http://100.63.255.254',
      'http://100.128.0.1',
      'http://[::1]',
      'file:///tmp/a',
      'http://0.0.0.0',
      'http://192.168.1.2:0',
      'http://192.168.1.2:65536',
    ]) {
      expect(
        () => lanAddress(value),
        throwsA(isA<AppException>()),
        reason: value,
      );
    }
  });

  test('Cross-platform paths cannot traverse or silently change on export', () {
    expect(lanRelativePath('旅行/照片 01.jpg'), '旅行/照片 01.jpg');
    for (final path in [
      '../secret',
      '/etc/passwd',
      'a//b',
      'a/./b',
      r'a\b',
      'a/../../b',
      'C:/file',
      'a/NUL.txt',
      'a/CON',
      'a/b.',
      'a/ file',
      'a/file ',
      'a/a:b',
      'a/\u0000b',
      '',
    ]) {
      expect(
        () => lanRelativePath(path),
        throwsA(isA<AppException>()),
        reason: path,
      );
    }
    expect(
      () => lanRelativePath(List.filled(65, 'a').join('/')),
      throwsA(isA<AppException>()),
    );
  });

  test(
    'Manifest rejects duplicates, reused IDs and file/directory collisions',
    () {
      expect(manifest([file('资料/a.txt')], ['资料', '资料/空目录']).files.length, 1);
      expect(
        () => manifest([file('a.txt'), file('A.txt')]),
        throwsA(isA<AppException>()),
      );
      final first = file('a.txt');
      expect(
        () => manifest([first, file('b.txt', id: first.id)]),
        throwsA(isA<AppException>()),
      );
      expect(
        () => manifest([file('资料')], ['资料']),
        throwsA(isA<AppException>()),
      );
      expect(
        () => manifest([file('A'), file('a/b.txt')]),
        throwsA(isA<AppException>()),
      );
      expect(
        () => manifest([file('A')], ['a/empty']),
        throwsA(isA<AppException>()),
      );
      expect(() => manifest([], ['A', 'a']), throwsA(isA<AppException>()));
      expect(() => manifest([]), throwsA(isA<AppException>()));
      expect(manifest([], ['空目录']).size, 0);
      expect(
        () => LanManifest.fromJson({
          ...manifest([file('valid')]).toJson(),
          'protocol': 'unknown',
        }),
        throwsA(isA<AppException>()),
      );
    },
  );

  test(
    'LAN downloads retain names, folders, integrity and one transfer ID per batch',
    () {
      final share = manifest(
        [file('资料/第一份.bin'), file('资料/second.apk')],
        ['资料'],
      );
      final specs = share.downloads(
        Uri.parse('http://192.168.0.12:12345/s/old?old=1#fragment'),
      );
      expect(specs.map((s) => s.fileName), ['第一份.bin', 'second.apk']);
      expect(
        specs.every((s) => s.relativePath == '资料' && s.profile == 'lan'),
        isTrue,
      );
      expect(
        specs.every((s) => s.checksumType == 'sha256' && s.expectedSize == 123),
        isTrue,
      );
      expect(specs.every((s) => s.source == null && s.headers.isEmpty), isTrue);
      final urls = specs.map((s) => Uri.parse(s.url)).toList();
      expect(
        urls.every(
          (u) =>
              u.host == '192.168.0.12' &&
              u.port == 12345 &&
              u.fragment.isEmpty &&
              u.path.startsWith('/v1/files/$token/'),
        ),
        isTrue,
      );
      expect(urls.map((u) => u.queryParameters['transfer']).toSet().length, 1);
      expect(urls.first.queryParameters.keys, ['transfer']);
      expect(share.downloads(urls.first).first.url, isNot(specs.first.url));
      expect(
        AppSettings.fromJson({'threads': 64}).connectionsFor(null, 'lan'),
        4,
      );
      expect(
        AppSettings.fromJson({'threads': 1}).connectionsFor(null, 'lan'),
        1,
      );
    },
  );

  test(
    'Byte ranges cover regular, open, suffix, clamped and invalid requests',
    () {
      expect(lanByteRange(null, 0), isNull);
      expect(lanByteRange('bytes=0-0', 10), (0, 1));
      expect(lanByteRange('bytes=3-6', 10), (3, 7));
      expect(lanByteRange('bytes=3-', 10), (3, 10));
      expect(lanByteRange('bytes=-3', 10), (7, 10));
      expect(lanByteRange('bytes=-30', 10), (0, 10));
      expect(lanByteRange('bytes=0-999', 10), (0, 10));
      for (final value in [
        'bytes=10-',
        'bytes=4-3',
        'bytes=-0',
        'bytes=-',
        'bytes=0-1,3-4',
        'bytes=x-y',
        'items=0-1',
      ]) {
        expect(
          () => lanByteRange(value, 10),
          throwsA(isA<HttpException>()),
          reason: value,
        );
      }
      expect(() => lanByteRange('bytes=0-', 0), throwsA(isA<HttpException>()));
    },
  );
}
