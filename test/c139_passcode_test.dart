import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'package:flutter_test/flutter_test.dart';
import 'package:xml/xml.dart';
import 'package:asterlink/core/crypto_box.dart';
import 'package:asterlink/core/json.dart';
import 'package:asterlink/data/cloud_command_resolver.dart';
import 'package:asterlink/data/http.dart';
import 'package:asterlink/data/providers/c139.dart';
import 'package:asterlink/data/providers/c139_passcode.dart';
import 'package:asterlink/domain/c139_passcode.dart';
import 'package:asterlink/domain/auth.dart';
import 'package:asterlink/domain/links.dart';
import 'package:asterlink/domain/models.dart';
import 'support.dart';

void main() {
  const command = '复制这段内容到移动云盘 /*b9gaLFbe4PUz:/ 提取码：a1B2';
  final authorization =
      'Basic ${base64Encode(utf8.encode('pc:13800000000:fixture-token'))}';
  final credential = Credential('fixture', {'authorization': authorization});

  HttpResult general({String id = 'resolved-share', String password = ''}) =>
      jsonResponse({
        'resultCode': '0',
        'data': {
          'getOutLinkGeneralResp': {
            'outLinkGeneral': [
              {'linkID': id, 'passwd': password, 'lkName': '样本分享'},
            ],
          },
        },
      });

  HttpResult page(String children, {int total = 1, String code = '0'}) =>
      HttpResult(
        200,
        C139Protocol.encrypt(
          jsonEncode(
            C139PasscodeProtocol.response(
              '<response resultCode="$code" desc="fixture"><getOutLinkInfoRes>'
              '<lkName>分享目录</lkName><nodNum>$total</nodNum>$children'
              '</getOutLinkInfoRes></response>',
            ),
          ),
        ),
      );
  String file(int index, {String size = '1073741824'}) =>
      '<outLinkCoInfo><coID>file-$index</coID><coName>第 $index 集.mp4</coName>'
      '<coSize>$size</coSize><udTime>20260922192512</udTime></outLinkCoInfo>';

  test(
    'clipboard and command resolver recognize supplied mobile command without a network request',
    () async {
      final parsed = C139Passcode.parse(command)!;
      expect(parsed.code, 'b9gaLFbe4PUz');
      expect(parsed.password, 'a1B2');
      expect(parsed.codeType, 1);
      expect(C139Passcode.parse('/*一二三四五六七八九:/')!.codeType, 2);
      expect(C139Passcode.parse('/*:/'), isNull);
      expect(C139Passcode.parse('/*a\nb:/'), isNull);
      expect(C139Passcode.parse('a' * 2001), isNull);
      final http = FakeHttp();
      final link = await CloudCommandResolver(
        http,
      ).resolve(CloudPlatform.c139, command);
      expect(http.calls, isEmpty);
      expect(link.platform, CloudPlatform.c139);
      expect(link.passcode, 'a1B2');
      expect(LinkParser.parse(command).single.url, link.url);
      expect(LinkParser.parse(link.url).single.shareId, parsed.code);
    },
  );

  test('AES envelope matches independent Python AES192 CBC fixture', () {
    expect(
      C139PasscodeProtocol.encrypt(
        '移动 /*test+%:/ ]]>',
        iv: Uint8List.fromList(List.generate(16, (i) => i)),
      ),
      'AAECAwQFBgcICQoLDA0OD+uOXY9WpBkMyKpBWaafTaNtFVS7jWPh2ZMcHAXRurEO',
    );
    expect(
      () => C139PasscodeProtocol.encrypt('fixture', iv: Uint8List(15)),
      throwsA(isA<AppException>()),
    );
  });

  test('XML preserves plus percent and special characters exactly', () {
    final xml = C139PasscodeProtocol.request(
      const C139Passcode('code+%]]><&', password: 'a+%]]>'),
      'account&<>',
      parent: 'folder+%]]>',
      begin: 201,
      end: 400,
    );
    final doc = XmlDocument.parse(xml);
    String value(String tag) => doc.findAllElements(tag).single.innerText;
    expect(value('account'), 'account&<>');
    expect(value('linkCode'), 'code+%]]><&');
    expect(value('passwd'), 'a+%]]>');
    expect(value('pCaID'), 'folder+%]]>');
    expect(value('bNum'), '201');
    expect(value('eNum'), '400');
  });

  test(
    'XML and encrypted response support singleton and repeated file entries',
    () {
      final response = page(
        '<caLst><outLinkCaInfo><caID>folder</caID><caName>目录</caName></outLinkCaInfo></caLst>'
        '<coLst>${file(1)}${file(2)}</coLst>',
        total: 3,
      );
      for (final body in [
        C139Protocol.decrypt(response.body),
        C139PasscodeProtocol.encrypt(C139Protocol.decrypt(response.body)),
      ]) {
        final value = C139PasscodeProtocol.response(body);
        expect(value.str('resultCode'), '0');
        expect(
          C139PasscodeProtocol.items(
            value.obj('data'),
            'caLst',
            'outLinkCaInfo',
          ).single.str('caID'),
          'folder',
        );
        expect(
          C139PasscodeProtocol.items(
            value.obj('data'),
            'coLst',
            'outLinkCoInfo',
          ).length,
          2,
        );
      }
      expect(
        () =>
            C139PasscodeProtocol.response('<!DOCTYPE a [<!ENTITY b "c">]><a/>'),
        throwsA(isA<AppException>()),
      );
      expect(
        () => C139PasscodeProtocol.response('not a response'),
        throwsA(isA<AppException>()),
      );
    },
  );

  test('App response reads encrypted gzip and BOM without losing nodes', () {
    final plain =
        '\uFEFF<response resultCode="0"><getOutLinkInfoRes>'
        '<coLst>${file(1)}</coLst></getOutLinkInfoRes></response>';
    final iv = Uint8List.fromList(List.generate(16, (i) => i));
    final packed = base64Encode([
      ...iv,
      ...CryptoBox.aesCbc(
        true,
        gzip.encode(utf8.encode(plain)),
        utf8.encode(C139PasscodeProtocol.key),
        iv,
      ),
    ]);
    final data = C139PasscodeProtocol.response(packed).obj('data');
    expect(
      C139PasscodeProtocol.items(
        data,
        'coLst',
        'outLinkCoInfo',
      ).single.str('coID'),
      'file-1',
    );
    expect(
      () => C139PasscodeProtocol.response(''),
      throwsA(isA<AppException>()),
    );
  });

  test(
    'logged in command lists the supplied folder fixture and its child files',
    () async {
      final http = FakeHttp((request) {
        expect(request.method, 'POST');
        expect(request.headers['Authorization'], authorization);
        expect(request.headers['hcy-cool-flag'], '1');
        expect(request.headers['Accept-Encoding'], 'identity');
        final plain = C139Protocol.decrypt(request.body as String);
        final sign = request.headers['mcloud-sign']!.split(',');
        expect(sign[2], C139Protocol.calculateSign(plain, sign[0], sign[1]));
        if (request.uri.path.endsWith('/getOutLinkGeneral')) {
          expect(asJson(jsonDecode(plain)).obj('getOutLinkGeneralReq'), {
            'account': '13800000000',
            'linkCode': 'b9gaLFbe4PUz',
            'linkCodeType': 1,
            'passwd': 'a1B2',
            'isPasswd': 0,
          });
          return general(password: 'old-code');
        }
        expect(
          request.uri.toString(),
          '${C139Connector.shareBase}/IOutLink/getOutLinkInfoV6',
        );
        final doc = asJson(jsonDecode(plain)).obj('getOutLinkInfoReq');
        expect(doc.str('linkCode'), 'b9gaLFbe4PUz');
        expect(doc.str('passwd'), 'a1B2');
        expect(doc.str('account'), '13800000000');
        final parent = doc.str('pCaID');
        if (parent == 'root') {
          return page(
            '<caLst length="1"><outLinkCaInfo><caID>FmTeffDJB_8RlcK8CxkVI5YyVJI_vwerE</caID>'
            '<caName>样本目录</caName><udTime>20260922192512</udTime></outLinkCaInfo></caLst><coLst length="0"/>',
          );
        }
        expect(parent, 'FmTeffDJB_8RlcK8CxkVI5YyVJI_vwerE');
        return page('<coLst>${file(1)}</coLst>');
      });
      final connector = C139Connector(http);
      final link = LinkParser.parse(command).single;
      await expectLater(
        connector.openShare(link, null),
        throwsA(isA<AccountLoginRequired>()),
      );
      expect(http.calls, isEmpty);
      final session = await connector.openShare(link, credential);
      expect(session.meta('linkId'), 'resolved-share');
      expect(session.meta('linkId'), isNot(link.shareId));
      expect(session.meta('password'), 'a1B2');
      final folders = await connector.list(session, 'root', credential);
      expect(folders.single.isDirectory, isTrue);
      expect(folders.single.modifiedAt, '20260922192512');
      final videos = await connector.list(
        session,
        folders.single.id,
        credential,
      );
      expect(videos.single.size, 1073741824);
      expect(videos.single.name, '第 1 集.mp4');
      expect(http.calls.length, 4);
    },
  );

  test(
    'pagination requests all declared nodes without losing final partial page',
    () async {
      final http = FakeHttp((request) {
        if (request.uri.path.endsWith('/getOutLinkGeneral')) return general();
        final data = asJson(
          jsonDecode(C139Protocol.decrypt(request.body as String)),
        ).obj('getOutLinkInfoReq');
        final begin = data.integer('bNum');
        return page(
          '<coLst>${[for (var i = begin; i <= (begin == 1 ? 200 : 201); i++) file(i)].join()}</coLst>',
          total: 201,
        );
      });
      final connector = C139Connector(http);
      final session = await connector.openShare(
        LinkParser.parse(command).single,
        credential,
      );
      final files = await connector.list(session, 'root', credential);
      expect(files.length, 201);
      expect(files.last.id, 'file-201');
      expect(http.calls.length, 4);
    },
  );

  for (final invalid in [
    const HttpResult(403, '<html>blocked</html>'),
    const HttpResult(500, ''),
    page('', code: '401'),
    const HttpResult(200, '<response><getOutLinkInfoRes/></response>'),
    const HttpResult(200, '<html>login page</html>'),
  ]) {
    test(
      'HTTP and business failure are never treated as empty successful shares ${invalid.status} ${invalid.body.length}',
      () async {
        final connector = C139Connector(FakeHttp((_) => invalid));
        await expectLater(
          connector.openShare(LinkParser.parse(command).single, credential),
          throwsA(isA<AppException>()),
        );
      },
    );
  }

  for (final children in [
    '<coLst>${file(1)}</coLst>',
    '<coLst>${file(1, size: 'invalid')}</coLst>',
  ]) {
    test(
      'inconsistent count and invalid file size fail visibly ${children.length}',
      () async {
        final connector = C139Connector(
          FakeHttp(
            (request) => request.uri.path.endsWith('/getOutLinkGeneral')
                ? general()
                : page(children, total: 201),
          ),
        );
        final session = await connector.openShare(
          LinkParser.parse(command).single,
          credential,
        );
        await expectLater(
          connector.list(session, 'root', credential),
          throwsA(isA<AppException>()),
        );
      },
    );
  }

  for (final malformed in [
    jsonResponse({'resultCode': '0', 'data': {}}),
    general(id: ''),
    const HttpResult(500, ''),
  ]) {
    test(
      'Missing command share details fail before temporary transfer ${malformed.body.length}',
      () async {
        final http = FakeHttp(
          (request) => request.uri.path.endsWith('/getOutLinkGeneral')
              ? malformed
              : page('<coLst>${file(1)}</coLst>'),
        );
        final connector = C139Connector(http);
        await expectLater(
          connector.openShare(LinkParser.parse(command).single, credential),
          throwsA(isA<AppException>()),
        );
        expect(http.calls, hasLength(2));
        expect(
          http.calls.every((r) => r.uri.path.contains('/IOutLink/')),
          isTrue,
        );
      },
    );
  }
}
