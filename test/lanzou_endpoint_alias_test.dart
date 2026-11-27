import 'package:flutter_test/flutter_test.dart';
import 'package:asterlink/core/json.dart';
import 'package:asterlink/data/http.dart';
import 'package:asterlink/data/desktop_browser_ua.dart';
import 'package:asterlink/data/providers/lanzou_protocol.dart';
import 'lanzou_folder_support.dart';
import 'lanzou_support.dart';
import 'support.dart';

const aliasFrame = r'''<script>
var wp_sign = 'opaque-sign';
var ajaxdata = 'fixture-key';
var domain1 = 'https://apifile.woozooo.com/ajaxfile.php?file=42';
var domain2 = 'https://apifile.lanzouw.com/ajaxfile.php?file=42';
var dom_ajaxs;
if (typeof(killdnsweb)=='undefined') {
  dom_ajaxs = domain2;
} else {
  dom_ajaxs = domain1;
}
$.ajax({url: dom_ajaxs,
data: {'action':'downprocess','sign':wp_sign,'websignkey':ajaxdata,
'signs':ajaxdata,'websign':'','kd':1,'ves':1}});
// dom_ajaxs = fakeEndpoint;
</script>''';

void main() {
  test('Conditional alias exposes only its reachable API alternatives', () {
    final page = LanzouPage(
      aliasFrame.replaceFirst(
        'var dom_ajaxs;',
        "var unrelated = 'https://evil.test/ajaxfile.php?file=42'; var dom_ajaxs;",
      ),
    );
    expect(page.ajaxUrls, [
      'https://apifile.woozooo.com/ajaxfile.php?file=42',
      'https://apifile.lanzouw.com/ajaxfile.php?file=42',
    ]);
  });

  test(
    'Public parsing uses the current identity accepted by the API',
    () async {
      final fixture = LanzouFixture()..frame = aliasFrame;
      fixture.override = (request) {
        if (request.method == 'POST' &&
            !DesktopBrowserUa.builtIn.any(
              (ua) => ua.value == request.headers['User-Agent'],
            )) {
          return const HttpResult(403, 'Denied by http_custom');
        }
        return null;
      };
      final session = await fixture.open();
      final spec = await fixture.download(session);
      expect(spec.url, lanzouTestFinal);
      expect(
        spec.headers['User-Agent'],
        fixture.http.calls.first.headers['User-Agent'],
      );
    },
  );

  test('403 retries the official alternate with isolated cookies', () async {
    final fixture = LanzouFixture()..frame = aliasFrame;
    fixture.override = (request) {
      if (request.method == 'POST' &&
          request.uri.host == 'apifile.woozooo.com') {
        return const HttpResult(403, 'Denied by http_custom', {
          'set-cookie': ['primary_only=secret; Path=/; Secure'],
        });
      }
      return null;
    };
    final session = await fixture.open();
    final spec = await fixture.download(session);
    expect(spec.url, lanzouTestFinal);
    expect(spec.expectedSize, fixture.exactSize);
    final posts = fixture.http.calls.where((r) => r.method == 'POST').toList();
    expect(posts.map((r) => r.uri.host), [
      'apifile.woozooo.com',
      'apifile.lanzouw.com',
    ]);
    expect(posts.last.body, posts.first.body);
    expect(posts.last.headers['Cookie'], isNull);
    expect(posts.last.headers['Origin'], 'https://author.lanzouu.com');
    expect(posts.last.headers['Referer'], posts.first.headers['Referer']);
    expect(fixture.http.redirects, everyElement(isFalse));
  });

  test('Folder file downloads use the same 403 recovery', () async {
    final fixture = LanzouFolderFixture()..frame = aliasFrame;
    fixture.folderOverride = (request) =>
        request.method == 'POST' && request.uri.host == 'apifile.woozooo.com'
        ? const HttpResult(403, '')
        : null;
    final session = await fixture.openFolder();
    final files = await fixture.connector.list(session, session.rootId, null);
    final spec = await fixture.connector.download(session, files.single, null);
    expect(spec.url, lanzouTestFinal);
    expect(
      fixture.http.calls.where((r) => r.uri.path == '/ajaxfile.php'),
      hasLength(2),
    );
  });

  test(
    'Password form preserves encoded password on official fallback',
    () async {
      final fixture = LanzouFixture();
      fixture.page = lanzouTestPasswordPage
          .replaceFirst(
            'function down_p(){',
            '''var primary = 'https://apifile.woozooo.com/ajaxfile.php?file=43';
var alternate = 'https://apifile.lanzouw.com/ajaxfile.php?file=43';
var endpoint; if (flag) { endpoint = alternate; } else { endpoint = primary; }
function down_p(){''',
          )
          .replaceFirst("url: '/ajaxfile.php?file=43'", 'url: endpoint');
      fixture.override = (request) =>
          request.method == 'POST' && request.uri.host == 'apifile.woozooo.com'
          ? const HttpResult(403, '')
          : null;
      await fixture.open('a&b+');
      final posts = fixture.http.calls
          .where((r) => r.method == 'POST')
          .toList();
      expect(posts, hasLength(2));
      expect(Uri.splitQueryString(posts.last.body as String)['p'], 'a&b+');
      expect(posts.last.headers['Cookie'], isNull);
    },
  );

  for (final status in [429, 404, 500]) {
    test('HTTP $status does not trigger an alternate API request', () async {
      final fixture = LanzouFixture()..frame = aliasFrame;
      fixture.override = (r) =>
          r.method == 'POST' ? HttpResult(status, '') : null;
      await expectLater(fixture.open(), throwsA(isA<AppException>()));
      expect(fixture.http.calls.where((r) => r.method == 'POST'), hasLength(1));
    });
  }

  test('Wrong password does not trigger an alternate API request', () async {
    final fixture = LanzouFixture()..frame = aliasFrame;
    fixture.override = (r) =>
        r.method == 'POST' ? jsonResponse({'zt': 0, 'inf': '密码不正确'}) : null;
    await expectLater(fixture.open(), throwsA(isA<AppException>()));
    expect(fixture.http.calls.where((r) => r.method == 'POST'), hasLength(1));
  });

  test('Both blocked official APIs stop without looping', () async {
    final fixture = LanzouFixture()..frame = aliasFrame;
    fixture.override = (r) =>
        r.method == 'POST' ? const HttpResult(403, '') : null;
    await expectLater(
      fixture.open(),
      throwsA(
        isA<AppException>().having(
          (e) => e.message,
          'message',
          contains('HTTP 403'),
        ),
      ),
    );
    expect(fixture.http.calls.where((r) => r.method == 'POST'), hasLength(6));
  });

  test('Cancellation stops before trying the alternate API', () async {
    final fixture = LanzouFixture()..frame = aliasFrame;
    final scope = RequestScope();
    fixture.override = (r) {
      if (r.method != 'POST') return null;
      scope.cancel();
      return const HttpResult(403, '');
    };
    await expectLater(scope.run(fixture.open), throwsA(isA<AppException>()));
    expect(fixture.http.calls.where((r) => r.method == 'POST'), hasLength(1));
  });

  for (final alternate in [
    'https://apifile.lanzouw.com.evil.test/ajaxfile.php?file=42',
    'https://evil.test/ajaxfile.php?file=42',
    'https://apifile.lanzouw.com:8443/ajaxfile.php?file=42',
    'https://user@apifile.lanzouw.com/ajaxfile.php?file=42',
    'https://apifile.lanzouw.com/ajaxfile.php?file=99',
    'https://apifile.lanzouw.com/ajaxm.php?file=42',
  ]) {
    test('Invalid alternate is rejected before POST: $alternate', () async {
      final fixture = LanzouFixture()
        ..frame = aliasFrame.replaceFirst(
          'https://apifile.lanzouw.com/ajaxfile.php?file=42',
          alternate,
        );
      await expectLater(fixture.open(), throwsA(isA<AppException>()));
      expect(fixture.http.calls.where((r) => r.method == 'POST'), isEmpty);
    });
  }

  test('File download resolves the new conditional endpoint alias', () async {
    final fixture = LanzouFixture()..frame = aliasFrame;
    final session = await fixture.connector.openShare(fixture.link(), null);
    final files = await fixture.connector.list(session, session.rootId, null);
    final spec = await fixture.connector.download(session, files.single, null);
    expect(spec.url, lanzouTestFinal);
    final post = fixture.http.calls.singleWhere((r) => r.method == 'POST');
    expect(
      post.uri.toString(),
      'https://apifile.woozooo.com/ajaxfile.php?file=42',
    );
    expect(Uri.splitQueryString(post.body as String)['sign'], 'opaque-sign');
  });

  test('Unresolved or cyclic aliases do not select unrelated endpoints', () {
    for (final assignment in ['a = b; b = a;', 'a = missing;']) {
      final page = LanzouPage('''<script>
var unrelated = '/ajaxm.php?file=99';
$assignment
\$.ajax({url:a});
</script>''');
      expect(page.ajaxUrl, isEmpty);
    }
  });

  test(
    'Alias endpoint still requires a supported path and numeric file id',
    () {
      for (final url in ['/other.php?file=42', '/ajaxfile.php?file=invalid']) {
        final page = LanzouPage('''<script>
var endpoint = '$url'; var alias = endpoint;
\$.ajax({url:alias});
</script>''');
        expect(page.ajaxUrl, isEmpty);
      }
    },
  );
}
