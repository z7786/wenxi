import 'dart:convert';
import 'package:flutter_test/flutter_test.dart';
import 'package:asterlink/core/json.dart';
import 'package:asterlink/data/cleanup_outbox.dart';
import 'package:asterlink/data/cloud_repository.dart';
import 'package:asterlink/data/http.dart';
import 'package:asterlink/data/providers/ctfile.dart';
import 'package:asterlink/data/state_store.dart';
import 'package:asterlink/diagnostics/redaction.dart';
import 'package:asterlink/domain/ctfile_captcha.dart';
import 'package:asterlink/domain/downloads.dart';
import 'package:asterlink/domain/links.dart';
import 'package:asterlink/domain/models.dart';
import 'support.dart';

final _link = LinkParser.parse(
  'https://url53.ctfile.com/f/39602953-965073660-1b43c4?p=8761',
).single;
const _proofToken = 'fixture-official-widget-proof-0123456789';
const _accessPass = 'fixture-share-access-pass';
const _file = {
  'file_id': 965073660,
  'file_name': '8b103b38.rar',
  'file_size': '1.26 MB',
  'file_time': '2023-10-30',
  'userid': 39602953,
  'file_chk': 'fixture-fresh-check',
  'start_time': 100,
  'wait_seconds': 0,
};

HttpResult _captcha({bool v2 = false, String error = 'captcha_required'}) =>
    jsonResponse({
      'code': 423,
      if (v2) 'msg': 'Share passcode needs a human check.',
      v2 ? 'data' : 'file': {
        'captcha_type': 'altcha',
        'error_type': error,
        'passcode_required': 1,
      },
    }, 423);

CtfileCaptchaProof _proof(CtfileCaptchaChallenge challenge) =>
    challenge.proofFromMessage({
      'source': 'ctfile-captcha',
      'type': 'altcha',
      'event': 'success',
      'token': _proofToken,
    })!;

Future<CtfileCaptchaChallenge> _challenge(
  CtfileConnector connector, [
  ParsedLink? link,
]) async {
  try {
    await connector.openShare(link ?? _link, null);
  } on CtfileShareVerificationRequired catch (error) {
    return error.challenge;
  }
  throw StateError('Expected the official share verification challenge');
}

class _ShareHttp extends FakeHttp {
  _ShareHttp({this.rejectResource = false});
  final bool rejectResource;
  @override
  Future<HttpResult> request(
    String method,
    String url, {
    Object? body,
    Map<String, String> headers = const {},
    bool followRedirects = true,
    String? contentType,
  }) async {
    final request = RecordedRequest(method, url, body, headers);
    calls.add(request);
    expect(headers.containsKey('Cookie'), isFalse);
    expect(headers.containsKey('Authorization'), isFalse);
    final query = request.uri.queryParameters;
    if (request.uri.path == '/api/v2/resource') {
      expect(request.uri.host, 'urlapi.ctfile.com');
      expect(query['kind'], 'file');
      expect(query['id'], '39602953-965073660-1b43c4');
      expect(query['folder_id'], '0');
      expect(query['passcode'], '8761');
      expect(
        query['altcha_token'] == _proofToken ||
            query['access_pass'] == _accessPass,
        isTrue,
      );
      if (rejectResource) return _captcha(v2: true, error: 'captcha_wrong');
      return jsonResponse({
        'code': 200,
        'data': {
          'file': {..._file, 'file_size_bytes': 1256561},
          'access_pass': _accessPass,
        },
      });
    }
    if (request.uri.path == '/getfile.php') {
      expect(query.containsKey('altcha_token'), isFalse);
      if (query['access_pass'] != _accessPass) return _captcha();
      return jsonResponse({'code': 200, 'file': _file});
    }
    expect(request.uri.path, '/get_down_url.php');
    expect(query['file_chk'], 'fixture-fresh-check');
    expect(query['uid'], '39602953');
    expect(query['fid'], '965073660');
    return jsonResponse({
      'code': 200,
      'downurl': 'https://download.ctfile.com/fixture-original',
      'file_size': 1256561,
    });
  }
}

void main() {
  test('Share security check is distinct from a wrong password', () async {
    final challenge = await _challenge(CtfileConnector(_ShareHttp()));
    expect(challenge.share, isTrue);
    expect(challenge.type, 'altcha');
    expect(challenge.message, contains('安全验证'));
    expect(challenge.url.queryParameters['source'], 'urlweb');
    expect(challenge.url.queryParameters['action'], 'share_passcode');
    expect(challenge.url.queryParameters['api'], 'https://urlapi.ctfile.com');
    expect(challenge.trustedPage(challenge.url.toString()), isTrue);
    expect(
      challenge.trustedPage(CtfileCaptchaChallenge('altcha').url.toString()),
      isFalse,
    );
    await expectLater(
      CtfileConnector(
        FakeHttp(
          (_) => jsonResponse({
            'code': 423,
            'file': {'message': '访问密码错误'},
          }, 423),
        ),
      ).openShare(_link, null),
      throwsA(
        isA<AppException>().having(
          (error) => error.message,
          'message',
          '访问密码错误',
        ),
      ),
    );
  });

  test(
    'Verified sharing reads exact size and refreshes the guest download',
    () async {
      final http = _ShareHttp();
      final connector = CtfileConnector(http);
      final challenge = await _challenge(connector);
      final session = await connector.openShare(
        _link,
        null,
        proof: _proof(challenge),
      );
      final files = await connector.list(session, session.rootId, null);
      expect(files.single.size, 1256561);
      expect(files.single.modifiedAt, '2023-10-30');
      expect(session.meta('ctfileAccessPass'), _accessPass);
      expect(jsonEncode(session.toJson()), isNot(contains(_proofToken)));
      final spec = await connector.download(session, files.single, null);
      expect(spec.expectedSize, 1256561);
      expect(spec.url, 'https://download.ctfile.com/fixture-original');
      expect(http.calls.map((r) => r.uri.path), [
        '/getfile.php',
        '/api/v2/resource',
        '/getfile.php',
        '/api/v2/resource',
        '/getfile.php',
        '/get_down_url.php',
      ]);
    },
  );

  test(
    'Saved sharing credentials survive a new repository and origin refresh',
    () async {
      final store = StateStore.memory();
      final vault = Vault(store);
      final http = _ShareHttp();
      final first = CloudRepository(http, vault, CleanupOutbox(store, http));
      final connector =
          first.connector(CloudPlatform.ctfile) as CtfileConnector;
      final challenge = await _challenge(connector);
      final session = await first.share(_link, ctfileProof: _proof(challenge));
      final files = await first.list(session, session.rootId);
      final origin = DownloadOrigin.fromJson(
        jsonDecode(
          jsonEncode(DownloadOrigin(session, files.single, null).toJson()),
        ),
      );
      final second = CloudRepository(http, vault, CleanupOutbox(store, http));
      final restored = await second.restoreOrigin(origin);
      expect(restored.file.size, 1256561);
      expect(restored.session.meta('ctfileAccessPass'), _accessPass);
      final spec = await second
          .connector(CloudPlatform.ctfile)
          .download(restored.session, restored.file, null);
      expect(spec.expectedSize, 1256561);
    },
  );

  test(
    'A stale, foreign or consumed proof cannot replay verification',
    () async {
      final http = _ShareHttp();
      final connector = CtfileConnector(http);
      final first = await _challenge(connector);
      final current = await _challenge(connector);
      final before = http.calls.length;
      await expectLater(
        connector.openShare(_link, null, proof: _proof(first)),
        throwsA(isA<AppException>()),
      );
      expect(http.calls.length, before);
      await connector.openShare(_link, null, proof: _proof(current));
      final consumed = http.calls.length;
      await expectLater(
        connector.openShare(_link, null, proof: _proof(current)),
        throwsA(isA<AppException>()),
      );
      expect(http.calls.length, consumed);
      await expectLater(
        connector.openShare(
          _link.withPasscode('9999'),
          null,
          proof: _proof(current),
        ),
        throwsA(isA<AppException>()),
      );
      expect(http.calls.length, consumed);
    },
  );

  test('Expired verification requests a fresh official challenge', () async {
    final connector = CtfileConnector(_ShareHttp(rejectResource: true));
    final challenge = await _challenge(connector);
    CtfileCaptchaChallenge? next;
    try {
      await connector.openShare(_link, null, proof: _proof(challenge));
    } on CtfileShareVerificationRequired catch (error) {
      next = error.challenge;
    }
    expect(next, isNotNull);
    expect(next!.state, isNot(challenge.state));
  });

  test(
    'Cancellation before proof consumption leaves verification available',
    () async {
      final http = _ShareHttp();
      final connector = CtfileConnector(http);
      final challenge = await _challenge(connector);
      final scope = RequestScope()..cancel();
      await expectLater(
        scope.run(
          () => connector.openShare(_link, null, proof: _proof(challenge)),
        ),
        throwsA(isA<AppException>()),
      );
      expect(http.calls, hasLength(1));
      final session = await connector.openShare(
        _link,
        null,
        proof: _proof(challenge),
      );
      expect(session.meta('ctfileAccessPass'), _accessPass);
    },
  );

  test('Sharing grants and widget proofs are redacted from diagnostics', () {
    for (final key in ['access_pass', 'ctfileAccessPass', 'altcha_token']) {
      expect(
        LogRedactor.json({key: _accessPass}),
        isNot(contains(_accessPass)),
      );
      expect(
        LogRedactor.text('$key=$_accessPass'),
        isNot(contains(_accessPass)),
      );
    }
  });
}
