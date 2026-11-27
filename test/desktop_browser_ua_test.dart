import 'dart:math';
import 'package:flutter_test/flutter_test.dart';
import 'package:asterlink/data/desktop_browser_ua.dart';
import 'package:asterlink/data/http.dart';
import 'package:asterlink/core/json.dart';
import 'package:asterlink/domain/links.dart';
import 'lanzou_support.dart';
import 'lanzou_folder_support.dart';

void main() {
  test(
    'Desktop UA pool includes unique Chrome, Edge and Firefox identities',
    () {
      final identities = DesktopBrowserUa.builtIn;
      expect(identities, hasLength(12));
      expect(identities.map((ua) => ua.value).toSet(), hasLength(12));
      expect(identities.map((ua) => ua.model).toSet(), {
        'chrome',
        'edge',
        'firefox',
      });
      for (final ua in identities) {
        expect(ua.value, startsWith('Mozilla/5.0 ('));
        expect(ua.value, isNot(contains('Mobile')));
        expect(ua.value, isNot(contains('Chrome/131.')));
        expect(ua.value, contains(ua.version));
      }
    },
  );

  test('Random draw visits every UA before reshuffling', () {
    final first = DesktopBrowserUaPool(random: Random(7));
    final other = DesktopBrowserUaPool(random: Random(8));
    final drawn = List.generate(12, (_) => first.next().value);
    expect(drawn.toSet(), hasLength(12));
    expect(drawn, isNot(List.generate(12, (_) => other.next().value)));
    expect(List.generate(12, (_) => first.next().value).toSet(), drawn.toSet());
  });

  test('One session rotates only twice and never repeats its UA', () {
    final session = DesktopBrowserUaPool(random: Random(3)).start();
    final used = {session.current.value};
    expect(session.rotate(), isTrue);
    used.add(session.current.value);
    expect(session.rotate(), isTrue);
    used.add(session.current.value);
    expect(used, hasLength(3));
    final last = session.current;
    expect(session.rotate(), isFalse);
    expect(session.current, same(last));
  });

  test(
    'New Lanzou parses randomly draw; each download keeps its parse UA',
    () async {
      final fixture = LanzouFixture(random: Random(4));
      final starts = <String>{};
      for (var i = 0; i < 12; i++) {
        fixture.http.calls.clear();
        final session = await fixture.open();
        final spec = await fixture.download(session);
        final ua = fixture.http.calls.first.headers['User-Agent']!;
        starts.add(ua);
        expect(fixture.http.calls.map((r) => r.headers['User-Agent']).toSet(), {
          ua,
        });
        expect(spec.headers['User-Agent'], ua);
      }
      expect(starts, hasLength(12));
    },
  );

  test('Lanzou 403 refreshes page and cookies under a different UA', () async {
    final fixture = LanzouFixture(random: Random(5));
    var posts = 0;
    fixture.override = (r) {
      if (r.method == 'POST' && posts++ == 0) {
        return const HttpResult(403, '', {
          'set-cookie': ['rejected_identity=old; Path=/; Secure'],
        });
      }
      return null;
    };
    final session = await fixture.open();
    final spec = await fixture.download(session);
    final attempts = fixture.http.calls
        .where((r) => r.method == 'POST')
        .toList();
    expect(attempts, hasLength(2));
    expect(
      attempts.last.headers['User-Agent'],
      isNot(attempts.first.headers['User-Agent']),
    );
    expect(
      attempts.last.headers['Cookie'],
      isNot(contains('rejected_identity')),
    );
    expect(spec.headers['User-Agent'], attempts.last.headers['User-Agent']);
    expect(fixture.http.calls.where((r) => r.uri.path == '/fn'), hasLength(2));
  });

  test('Lanzou page 403 also changes UA before retrying', () async {
    final fixture = LanzouFixture(random: Random(5));
    var pages = 0;
    fixture.override = (r) => r.uri.path == '/iExample123' && pages++ == 0
        ? const HttpResult(403, '')
        : null;
    await fixture.open();
    expect(
      fixture.http.calls.take(2).map((r) => r.headers['User-Agent']).toSet(),
      hasLength(2),
    );
  });

  test('Repeated Lanzou 403 stops after three fresh identities', () async {
    final fixture = LanzouFixture(random: Random(5));
    fixture.override = (r) =>
        r.method == 'POST' ? const HttpResult(403, '') : null;
    await expectLater(fixture.open(), throwsA(isA<AppException>()));
    final posts = fixture.http.calls.where((r) => r.method == 'POST').toList();
    expect(posts, hasLength(3));
    expect(posts.map((r) => r.headers['User-Agent']).toSet(), hasLength(3));
  });

  test(
    'UA rotation in a later folder page leaves other cached files unchanged',
    () async {
      final fixture = LanzouFolderFixture();
      final fileSession = await fixture.open();
      final original = (await fixture.download(
        fileSession,
      )).headers['User-Agent'];
      var lists = 0;
      fixture.folderOverride = (r) =>
          r.uri.path == '/filemoreajax.php' && lists++ == 0
          ? const HttpResult(403, '')
          : null;
      await fixture.openFolder();
      final reused = await fixture.download(fileSession);
      expect(reused.headers['User-Agent'], original);
    },
  );

  test(
    'Lanzou folder list 403 refreshes its page and preserves file results',
    () async {
      final fixture = LanzouFolderFixture();
      var lists = 0;
      fixture.folderOverride = (r) =>
          r.uri.path == '/filemoreajax.php' && lists++ == 0
          ? const HttpResult(403, '')
          : null;
      final session = await fixture.openFolder();
      final files = await fixture.connector.list(session, session.rootId, null);
      expect(files.single.id, 'iExample123');
      final posts = fixture.http.calls
          .where((r) => r.uri.path == '/filemoreajax.php')
          .toList();
      expect(posts, hasLength(3)); // Successful page plus terminal page.
      expect(
        posts[1].headers['User-Agent'],
        isNot(posts.first.headers['User-Agent']),
      );
      expect(posts.last.headers['User-Agent'], posts[1].headers['User-Agent']);
    },
  );

  test(
    'Independent concurrent Lanzou parses keep separate identities',
    () async {
      final fixture = LanzouFixture(random: Random(2));
      final sessions = await Future.wait([
        fixture.connector.openShare(fixture.link(), null),
        fixture.connector.openShare(
          LinkParser.parse('https://author.lanzouu.com/iOther123').single,
          null,
        ),
      ]);
      expect(sessions, hasLength(2));
      final gets = fixture.http.calls
          .where((r) => r.uri.path.startsWith('/i'))
          .toList();
      expect(gets.map((r) => r.headers['User-Agent']).toSet(), hasLength(2));
    },
  );
}
