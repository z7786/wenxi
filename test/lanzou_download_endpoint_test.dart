import 'package:flutter_test/flutter_test.dart';
import 'package:asterlink/core/json.dart';
import 'package:asterlink/data/http.dart';
import 'lanzou_support.dart';
import 'lanzou_folder_support.dart';
import 'support.dart';

void main() {
  test(
    'Rejected download API exposes HTTP status for device diagnostics',
    () async {
      final f = LanzouFixture();
      f.override = (request) async =>
          request.method == 'POST' ? const HttpResult(407, '') : null;
      await expectLater(
        f.open(),
        throwsA(
          isA<AppException>().having(
            (error) => error.message,
            'message',
            contains('HTTP 407'),
          ),
        ),
      );
    },
  );

  for (final endpoint in [
    'https://apifile.woozooo.com/ajaxfile.php?file=42',
    '//apifile.woozooo.com/ajaxfile.php?file=42',
    'https://apifile.lanzouw.com/ajaxfile.php?file=42',
    '//apifile.lanzouw.com/ajaxfile.php?file=42',
  ]) {
    test('Folder child uses complete official endpoint $endpoint', () async {
      final f = LanzouFolderFixture();
      f.frame = lanzouTestFrame.replaceAll('/ajaxm.php?file=42', endpoint);
      f.folderOverride = (request) async {
        if (request.uri.path != '/ajaxfile.php') return null;
        if (request.uri.host !=
            Uri.parse(
              endpoint.startsWith('//') ? 'https:$endpoint' : endpoint,
            ).host) {
          return const HttpResult(407, '');
        }
        return jsonResponse(f.result);
      };
      final session = await f.openFolder('Ab12');
      final files = await f.connector.list(session, session.rootId, null);
      final spec = await f.connector.download(session, files.single, null);
      expect(spec.url, lanzouTestFinal);
      final request = f.http.calls.singleWhere(
        (call) => call.uri.path == '/ajaxfile.php',
      );
      expect(
        request.uri.host,
        Uri.parse(
          endpoint.startsWith('//') ? 'https:$endpoint' : endpoint,
        ).host,
      );
      expect(request.uri.scheme, 'https');
      expect(request.uri.queryParameters['file'], '42');
      expect(request.headers['Origin'], 'https://author.lanzouu.com');
      expect(request.headers['Cookie'], isNull);
      expect(
        Uri.splitQueryString(request.body as String)['sign'],
        'opaque-sign',
      );
    });
  }

  test('Password form uses the same official cross-origin endpoint', () async {
    final f = LanzouFixture();
    f.page = lanzouTestPasswordPage.replaceAll(
      '/ajaxfile.php?file=43',
      'https://apifile.woozooo.com/ajaxfile.php?file=43',
    );
    await f.open('a&b+');
    final request = f.http.calls.last;
    expect(request.uri.host, 'apifile.woozooo.com');
    expect(Uri.splitQueryString(request.body as String)['p'], 'a&b+');
    expect(request.headers['Cookie'], isNull);
  });

  for (final endpoint in [
    'https://apifile.woozooo.com.evil.test/ajaxfile.php?file=42',
    'https://evil.test/ajaxfile.php?file=42',
    'https://user@apifile.woozooo.com/ajaxfile.php?file=42',
    'https://apifile.woozooo.com:8443/ajaxfile.php?file=42',
  ]) {
    test(
      'Unexpected endpoint is rejected before any POST: $endpoint',
      () async {
        final f = LanzouFixture();
        f.frame = lanzouTestFrame.replaceAll('/ajaxm.php?file=42', endpoint);
        await expectLater(f.open(), throwsA(isA<AppException>()));
        expect(f.http.calls.where((r) => r.method == 'POST'), isEmpty);
      },
    );
  }
}
