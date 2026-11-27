import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:asterlink/core/json.dart';
import 'package:asterlink/data/backup_targets.dart';
import 'package:asterlink/data/classified_backup.dart';
import 'package:asterlink/data/http.dart';
import 'package:asterlink/data/http_retry.dart';
import 'package:asterlink/data/providers/webdav.dart';
import 'package:asterlink/data/state_store.dart';
import 'package:asterlink/domain/account_login_info.dart';
import 'package:asterlink/domain/auth.dart';
import 'package:asterlink/domain/models.dart';
import 'package:asterlink/domain/uploads.dart';
import 'package:asterlink/domain/webdav.dart';

String _path(Uri uri) =>
    '/${uri.pathSegments.where((s) => s.isNotEmpty).join('/')}';
String _href(String path) => Uri(pathSegments: path.split('/')).toString();

class DavServer {
  DavServer._(this.server);
  final HttpServer server;
  final files = <String, List<int>>{};
  final directories = {'/dav', '/other'};
  final calls = <({String method, String path, String auth, String range})>[];
  Future<bool> Function(HttpRequest)? intercept;
  String get url => 'http://127.0.0.1:${server.port}/dav/';

  static Future<DavServer> start() async {
    final fixture = DavServer._(
      await HttpServer.bind(InternetAddress.loopbackIPv4, 0),
    );
    fixture.server.listen((r) => unawaited(fixture.handle(r)));
    return fixture;
  }

  Future<void> handle(HttpRequest request) async {
    final path = _path(request.uri);
    calls.add((
      method: request.method,
      path: path,
      auth: request.headers.value('authorization') ?? '',
      range: request.headers.value('range') ?? '',
    ));
    try {
      if (await intercept?.call(request) == true) return;
      if (!const ['session-secret', 'second-secret'].any(
        (secret) =>
            request.headers.value('authorization') ==
            WebDavClient.authorization('user', secret)['Authorization'],
      )) {
        request.response.statusCode = 401;
        return;
      }
      switch (request.method) {
        case 'PROPFIND':
          await request.drain<void>();
          if (!directories.contains(path)) {
            request.response.statusCode = 404;
            break;
          }
          String row(String child, bool collection, int length) =>
              '<v:response><v:href>${_href(child)}</v:href><v:propstat>'
              '<v:prop><v:resourcetype>${collection ? '<v:collection/>' : ''}'
              '</v:resourcetype><v:getcontentlength>$length</v:getcontentlength>'
              '<v:getlastmodified>Mon, 23 Nov 2026 12:00:00 GMT</v:getlastmodified>'
              '<v:getetag>fixture-etag</v:getetag></v:prop>'
              '<v:status>HTTP/1.1 200 OK</v:status></v:propstat></v:response>';
          bool child(String name) =>
              name.startsWith('$path/') &&
              !name.substring(path.length + 1).contains('/');
          request.response.statusCode = 207;
          request.response.write(
            '<v:multistatus xmlns:v="DAV:">${row(path, true, 0)}'
            '${directories.where(child).map((d) => row(d, true, 0)).join()}'
            '${files.entries.where((e) => child(e.key)).map((e) => row(e.key, false, e.value.length)).join()}'
            '</v:multistatus>',
          );
        case 'MKCOL':
          request.response.statusCode = directories.add(path) ? 201 : 405;
        case 'PUT':
          final content = await request.fold<List<int>>(
            [],
            (bytes, chunk) => bytes..addAll(chunk),
          );
          if (files.containsKey(path) &&
              request.headers.value('if-none-match') == '*') {
            request.response.statusCode = 412;
          } else {
            files[path] = content;
            request.response.statusCode = 201;
          }
        case 'MOVE':
          final destination = _path(
            Uri.parse(request.headers.value('destination')!),
          );
          if (request.headers.value('overwrite') == 'F' &&
              files.containsKey(destination)) {
            request.response.statusCode = 412;
          } else if (files.containsKey(path)) {
            files[destination] = files.remove(path)!;
            request.response.statusCode = 201;
          } else {
            request.response.statusCode = 404;
          }
        case 'GET' || 'HEAD':
          final content = files[path];
          if (content == null) {
            request.response.statusCode = 404;
            break;
          }
          final range = RegExp(
            r'^bytes=(\d+)-(\d*)$',
          ).firstMatch(request.headers.value('range') ?? '');
          final start = range == null ? 0 : int.parse(range[1]!);
          final end = range == null || range[2]!.isEmpty
              ? content.length - 1
              : int.parse(range[2]!);
          request.response.headers.set('etag', 'fixture-etag');
          request.response.headers.set('accept-ranges', 'bytes');
          if (start >= content.length || end < start) {
            request.response.statusCode = 416;
            request.response.headers.set(
              'content-range',
              'bytes */${content.length}',
            );
          } else {
            final stop = end.clamp(0, content.length - 1);
            if (range != null) {
              request.response.statusCode = 206;
              request.response.headers.set(
                'content-range',
                'bytes $start-$stop/${content.length}',
              );
            }
            request.response.contentLength = stop - start + 1;
            if (request.method == 'GET') {
              request.response.add(content.sublist(start, stop + 1));
            }
          }
        case 'DELETE':
          files.remove(path);
          directories.remove(path);
          request.response.statusCode = 204;
        default:
          request.response.statusCode = 405;
      }
    } catch (_) {
      // Clients intentionally cancel or sever the connection in several tests.
    } finally {
      try {
        await request.response.close();
      } catch (_) {
        /* Disconnected client. */
      }
    }
  }

  Future<void> close() => server.close(force: true);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  HttpOverrides.global = null;

  test('collection paths roundtrip Chinese and reserved characters', () {
    final root = WebDavLocation('https://nas.example/dav/家庭 备份/');
    expect(root.base.pathSegments.where((s) => s.isNotEmpty), ['dav', '家庭 备份']);
    final child = root.child('/', '文件 #?%.json');
    expect(child, '/${Uri.encodeComponent('文件 #?%.json')}');
    final nested = root.child(child, '视频.mp4');
    expect(root.id(root.uri(nested)), nested);
    expect(root.uri(nested).pathSegments.last, '视频.mp4');
    expect(root.id(Uri.parse('https://nas.example/dav/其他/a.json')), isNull);
    for (final invalid in [
      'https://user:secret@nas.example/dav/',
      'https://nas.example/dav/?token=value',
      'https://nas.example/dav/#fragment',
      'ftp://nas.example/dav/',
      'https://nas.example/dav/%2Foutside/',
    ]) {
      expect(() => WebDavLocation(invalid), throwsA(isA<AppException>()));
    }
    for (final invalid in [
      '/a%2Fb',
      '/%2E%2E/outside',
      '//other/file',
      '/a?b=1',
    ]) {
      expect(() => root.uri(invalid), throwsA(isA<AppException>()));
    }
  });

  test(
    'DAV parsing ignores failed properties, nested files and external hrefs',
    () {
      final root = WebDavLocation('https://nas.example/dav/');
      String row(String href, {String status = '200 OK', String size = '12'}) =>
          '<d:response><d:href>$href</d:href><d:propstat><d:prop>'
          '<d:getcontentlength>$size</d:getcontentlength>'
          '<d:resourcetype/><d:getlastmodified>Mon, 23 Nov 2026 12:00:00 GMT</d:getlastmodified>'
          '</d:prop><d:status>HTTP/1.1 $status</d:status></d:propstat></d:response>';
      final files = parseWebDavFiles(
        '<d:multistatus xmlns:d="DAV:">${row('/dav/正确.json')}'
            '${row('/dav/失败.json', status: '404 Not Found')}'
            '${row('/dav/nested/file.json')}${row('/dav/')}'
            '${row('https://other.example/dav/file.json')}'
            '${row('/dav/正确.json', status: '404 Not Found', size: '900')}'
            '</d:multistatus>',
        root,
        '/',
      );
      expect(files, hasLength(1));
      expect(files.single.name, '正确.json');
      expect(files.single.size, 12);
      expect(files.single.modifiedAt, '2026-11-23T12:00:00.000Z');
      expect(
        () => parseWebDavFiles(
          '<!DOCTYPE x><d:multistatus xmlns:d="DAV:"/>',
          root,
          '/',
        ),
        throwsA(isA<AppException>()),
      );
      expect(
        () => parseWebDavFiles('<html>login</html>', root, '/'),
        throwsA(isA<AppException>()),
      );
    },
  );

  group('WebDAV cloud connector with loopback service', () {
    late DavServer server;
    late WebDavConnector connector;
    late Credential credential;
    late BrowseSession session;
    setUp(() async {
      server = await DavServer.start();
      connector = WebDavConnector(client: WebDavClient(client: Dio()));
      credential = WebDavLocation.credential(
        url: server.url,
        username: 'user',
        password: 'session-secret',
        rememberPassword: true,
      );
      session = await connector.openPersonal(credential);
    });
    tearDown(() async {
      await connector.close();
      await server.close();
    });

    test(
      'streams upload, confirms size, creates folders and protects same names',
      () async {
        final directory = await connector.createFolder(
          session,
          '/',
          '家庭 备份',
          credential,
        );
        final payload = utf8.encode('streamed payload');
        final source = UploadFile(
          name: '文件 #?%.json',
          size: payload.length,
          read: (start, end) => Stream.value(payload.sublist(start, end)),
        );
        final progress = <UploadProgress>[];
        final scope = WriteRequestScope();
        final file = await scope.run(
          () => connector.upload(
            session,
            directory.id,
            source,
            credential,
            onProgress: progress.add,
          ),
        );
        expect(file.name, source.name);
        expect(file.size, payload.length);
        expect(scope.mayHaveWritten, isTrue);
        expect(progress.first.phase, UploadPhase.preparing);
        expect(progress.last.phase, UploadPhase.finishing);
        expect(progress.last.sent, payload.length);
        await expectLater(
          connector.upload(session, directory.id, source, credential),
          throwsA(
            isA<AppException>().having(
              (e) => e.message,
              'message',
              contains('未覆盖'),
            ),
          ),
        );
        expect(server.files.values.single, payload);
        await connector.rename(session, file, '改名.json', credential);
        final renamed = (await connector.list(
          session,
          directory.id,
          credential,
        )).single;
        await connector.move(session, [renamed], '/', credential);
        final moved = (await connector.list(
          session,
          '/',
          credential,
        )).where((f) => !f.isDirectory).single;
        await connector.delete(session, [moved], credential);
        expect(server.files, isEmpty);
      },
    );

    test(
      'temporary passwords never enter state, backups or download headers; range access is revoked',
      () async {
        final temporary = WebDavLocation.credential(
          url: server.url,
          username: 'user',
          rememberPassword: false,
        );
        await connector.connect(temporary, 'session-secret');
        connector.retainSessions(
          const [],
        ); // A login commit can notify mid-flight.
        expect(connector.hasPassword(temporary), isTrue);
        final store = StateStore.memory(), vault = Vault(store);
        await vault.putCredential(CloudPlatform.webdav, temporary);
        connector.finishConnection(temporary, saved: true);
        connector.retainSessions([temporary]);
        expect(temporary.fields.containsKey('password'), isFalse);
        expect(jsonEncode(store.data), isNot(contains('session-secret')));
        final backup = await ClassifiedBackupRepository(
          store,
        ).create(categories: {BackupCategory.accounts});
        expect(utf8.decode(backup), isNot(contains('session-secret')));
        expect(
          AccountLoginInfo.from(CloudPlatform.webdav, credential).json,
          isNot(contains('session-secret')),
        );

        final firstSession = await connector.openPersonal(temporary);
        final name = '视频 #?%.mp4';
        server.files['/dav/$name'] = List.generate(12, (i) => i);
        final file = (await connector.list(
          firstSession,
          '/',
          temporary,
        )).single;
        final spec = await connector.download(firstSession, file, temporary);
        expect(spec.headers, isEmpty);
        expect(spec.url, startsWith('http://127.0.0.1:'));
        expect(spec.url, isNot(contains('session-secret')));
        expect(
          spec.url,
          isNot(contains(base64Encode(utf8.encode('user:session-secret')))),
        );

        final reader = Dio();
        addTearDown(() => reader.close(force: true));
        final range = await reader.get<List<int>>(
          spec.url,
          options: Options(
            responseType: ResponseType.bytes,
            headers: {'Range': 'bytes=3-7'},
          ),
        );
        expect(range.statusCode, 206);
        expect(range.data, [3, 4, 5, 6, 7]);
        expect(range.headers.value('content-range'), 'bytes 3-7/12');
        final head = await reader.head<void>(spec.url);
        expect(head.statusCode, 200);
        expect(head.headers.value('content-length'), '12');
        expect(head.headers.value('etag'), 'fixture-etag');

        final second = WebDavLocation.credential(
          url: server.url.replaceFirst('/dav/', '/other/'),
          username: 'user',
          password: 'second-secret',
          rememberPassword: true,
        );
        connector.retainSessions([temporary, second]);
        server.files['/other/$name'] = [90, 91, 92];
        final secondSession = await connector.openPersonal(second);
        final otherFile = (await connector.list(
          secondSession,
          '/',
          second,
        )).single;
        final otherSpec = await connector.download(
          secondSession,
          otherFile,
          second,
        );
        expect(
          (await reader.get<List<int>>(
            otherSpec.url,
            options: Options(responseType: ResponseType.bytes),
          )).data,
          [90, 91, 92],
        );
        expect(
          (await reader.get<List<int>>(
            spec.url,
            options: Options(responseType: ResponseType.bytes),
          )).data,
          List.generate(12, (i) => i),
        );
        expect(server.calls.last.path, '/dav/$name');
        expect(
          server.calls.last.auth,
          WebDavClient.authorization('user', 'session-secret')['Authorization'],
        );

        connector.retainSessions([second]);
        final reads = server.calls.length;
        final revoked = await reader.get<List<int>>(
          spec.url,
          options: Options(
            responseType: ResponseType.bytes,
            validateStatus: (_) => true,
          ),
        );
        expect(revoked.statusCode, 404);
        expect(server.calls, hasLength(reads));
        final restarted = WebDavConnector();
        addTearDown(restarted.close);
        expect(restarted.hasPassword(temporary), isFalse);
        await expectLater(
          restarted.openPersonal(temporary),
          throwsA(isA<AccountLoginRequired>()),
        );
      },
    );

    test(
      'account identity includes root and username; reconnect preserves owner',
      () async {
        final store = StateStore.memory(), vault = Vault(store);
        final login = AccountLoginService(
          vault,
          (_, c) => connector.account(c),
        );
        Future<String> save(String url, String secret) async {
          final pending = await vault.createAccount(CloudPlatform.webdav);
          final candidate = WebDavLocation.credential(
            url: url,
            username: 'user',
            password: secret,
            rememberPassword: true,
          );
          try {
            await login.submit(
              CloudPlatform.webdav,
              (_) => connector.connect(candidate, secret),
              accountId: pending,
            );
            return vault.activeAccountId(CloudPlatform.webdav)!;
          } finally {
            await vault.removeAccount(
              CloudPlatform.webdav,
              pending,
              onlyIfEmpty: true,
            );
          }
        }

        final first = await save(server.url, 'session-secret');
        final second = await save(
          server.url.replaceFirst('/dav/', '/other/'),
          'second-secret',
        );
        expect(second, isNot(first));
        expect(vault.profiles(CloudPlatform.webdav), hasLength(2));
        expect(await save(server.url, 'session-secret'), first);
        expect(vault.profiles(CloudPlatform.webdav), hasLength(2));
        await expectLater(
          connector.list(
            session,
            '/',
            WebDavLocation.credential(
              url: server.url.replaceFirst('/dav/', '/other/'),
              username: 'user',
              password: 'second-secret',
              rememberPassword: true,
            ),
          ),
          throwsA(
            isA<AppException>().having(
              (e) => e.message,
              'message',
              contains('地址已变化'),
            ),
          ),
        );
      },
    );

    test(
      'retry budgets apply to reads; unauthorized and interrupted writes stop',
      () async {
        var attempts = 0;
        server.intercept = (request) async {
          if (request.method == 'PROPFIND' && attempts++ == 0) {
            request.response.statusCode = 503;
            return true;
          }
          return false;
        };
        final retries = <ReadRetryAttempt>[];
        final scope = ReadRetryScope(
          retries: 1,
          checkpoint: RequestScope.checkpoint,
          wait: (_) async {},
          onRetry: (attempt) async => retries.add(attempt),
        );
        await scope.run(() => connector.list(session, '/', credential));
        expect(retries, hasLength(1));
        expect(attempts, 2);
        await expectLater(
          connector.account(
            credential.withFields({'password': 'wrong-password'}),
          ),
          throwsA(isA<AccountLoginRequired>()),
        );

        var puts = 0;
        server.intercept = (request) async {
          if (request.method == 'PUT') {
            puts++;
            await request.drain<void>();
            final socket = await request.response.detachSocket(
              writeHeaders: false,
            );
            socket.destroy();
            return true;
          }
          return false;
        };
        final write = WriteRequestScope();
        await expectLater(
          scope.run(
            () => write.run(
              () => connector.upload(
                session,
                '/',
                UploadFile(
                  name: 'interrupted.json',
                  size: 3,
                  read: (start, end) =>
                      Stream.value([1, 2, 3].sublist(start, end)),
                ),
                credential,
              ),
            ),
          ),
          throwsA(isA<AppException>()),
        );
        expect(puts, 1);
        expect(write.mayHaveWritten, isTrue);
      },
    );

    test('cancelled directory read stops without retry or hanging', () async {
      final entered = Completer<void>();
      server.intercept = (request) async {
        if (request.method == 'PROPFIND') {
          entered.complete();
          await request.response.done.catchError((_) {});
          return true;
        }
        return false;
      };
      final scope = RequestScope();
      final response = scope.run(
        () => connector.list(session, '/', credential),
      );
      final expectation = expectLater(response, throwsA(isA<AppException>()));
      await entered.future;
      scope.cancel();
      await expectation;
      expect(server.calls, hasLength(1));
    });

    test(
      'cloud WebDAV backup retries marker, restores encrypted categories and keeps borrowed client',
      () async {
        final root = await Directory.systemTemp.createTemp('webdav-backup-');
        addTearDown(() => root.delete(recursive: true));
        final store = StateStore.memory({
          'settings': {'destination': 'D:/original'},
        });
        await Vault(store).putCredential(CloudPlatform.webdav, credential);
        final repository = ClassifiedBackupRepository(store);
        final bytes = await repository.create(
          categories: {BackupCategory.settings, BackupCategory.accounts},
          password: 'backup-password',
        );
        final target = WebDavBackupTarget(
          url: server.url,
          username: 'user',
          password: connector.password(credential),
          connection: connector.client,
        );
        final transfers = BackupTransfers(store, root);
        final job = await transfers.stage(bytes, {
          'kind': 'cloud',
          'session': session
              .withAccount(Vault(store).activeAccountId(CloudPlatform.webdav))
              .toJson(),
          'parent': '/',
        });
        var interrupted = true;
        server.intercept = (request) async {
          if (interrupted &&
              request.method == 'PUT' &&
              request.uri.path.endsWith('.complete')) {
            request.response.statusCode = 503;
            await request.drain<void>();
            return true;
          }
          return false;
        };
        await expectLater(
          transfers.send(job, target),
          throwsA(isA<AppException>()),
        );
        expect(transfers.pending, hasLength(1));
        expect(await transfers.versions(target), isEmpty);
        interrupted = false;
        final resumed = BackupTransfers(StateStore.memory(store.data), root);
        await resumed.send(resumed.pending.single, target);
        final versions = await resumed.versions(target);
        expect(versions, hasLength(1));
        expect(
          server.calls.where(
            (c) => c.method == 'PUT' && c.path.endsWith('.json'),
          ),
          hasLength(1),
        );
        final downloaded = await resumed.download(target, versions.single);
        final destination = StateStore.memory({
          'settings': {'destination': 'D:/current'},
        });
        final restore = ClassifiedBackupRepository(destination);
        final preview = await restore.preview(downloaded, 'backup-password');
        await restore.restore(preview, categories: preview.categories);
        expect(
          destination.data.obj('settings').str('destination'),
          'D:/current',
        );
        expect(Vault(destination).profiles(CloudPlatform.webdav), hasLength(1));
        target.close();
        expect(await connector.list(session, '/', credential), isNotEmpty);
        expect(await File('${root.path}/${job.str('name')}').exists(), isFalse);
      },
    );
  });
}
