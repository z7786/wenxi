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

  for (final text in [
    '蕧郅岱等遥温琴扣炩',
    '"蕧郅岱等遥温琴扣炩"',
    '“蕧郅岱等遥温琴扣炩”',
    '【蕧郅岱等遥温琴扣炩】',
    '/*蕧郅岱等遥温琴扣炩:/',
    '复制口令：“蕧郅岱等遥温琴扣炩”，打开移动云盘查看分享',
  ]) {
    test(
      'Chinese mobile command resolves and survives link round-trip: $text',
      () async {
        final parsed = C139Passcode.parse(text)!;
        expect(parsed.code, '蕧郅岱等遥温琴扣炩');
        expect(parsed.codeType, 2);
        expect(parsed.password, isNull);
        final http = FakeHttp();
        final link = await CloudCommandResolver(
          http,
        ).resolve(CloudPlatform.c139, text);
        expect(http.calls, isEmpty);
        expect(link.platform, CloudPlatform.c139);
        expect(link.shareId, parsed.code);
        expect(link.source, text);
        expect(LinkParser.parse(text).single.url, link.url);
        final restored = C139Passcode.fromLink(
          LinkParser.parse(link.url).single,
        )!;
        expect(restored.code, parsed.code);
        expect(restored.codeType, 2);
      },
    );
  }

  test('Chinese mobile command keeps its explicit extraction password', () {
    final command = C139Passcode.parse('“蕧郅岱等遥温琴扣炩” 提取码：A1b2')!;
    expect(command.code, '蕧郅岱等遥温琴扣炩');
    expect(command.password, 'A1b2');
    final request = C139PasscodeProtocol.requestData(command, '13800000000');
    expect(request['linkCode'], command.code);
    expect(request['linkCodeType'], 2);
    expect(request['passwd'], 'A1b2');
  });

  test(
    'Selected mobile provider can read a Chinese command in generic prose',
    () async {
      const text = '复制口令：“蕧郅岱等遥温琴扣炩”，打开 App 查看';
      expect(C139Passcode.parse(text), isNull);
      final http = FakeHttp();
      final link = await CloudCommandResolver(
        http,
      ).resolve(CloudPlatform.c139, text);
      expect(link.shareId, '蕧郅岱等遥温琴扣炩');
      expect(http.calls, isEmpty);
    },
  );

  for (final input in [
    '蕧郅岱等遥温琴扣',
    '蕧郅岱等遥温琴扣炩蕧',
    '这里是一段分享说明，暂时没有移动口令',
    '请查找标题“这里是普通九字标题”',
    '咐置松君杂货铺叩苓',
    '觸三位一体煎饼就緒',
    '夸克口令：“一二三四五六七八九”',
    '移动云盘口令：蕧郅岱等遥温琴扣炩 / 一二三四五六七八九',
    '/*first:/ /*second:/',
    '/*a\nb:/ 蕧郅岱等遥温琴扣炩',
  ]) {
    test(
      'Unrelated prose and ambiguous mobile commands are not selected: $input',
      () {
        expect(C139Passcode.parse(input), isNull);
      },
    );
  }

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
        expect(doc.str('linkID'), 'resolved-share');
        expect(doc.containsKey('linkCode'), isFalse);
        expect(doc.containsKey('linkCodeType'), isFalse);
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
      expect(http.calls.length, 3);
      expect(http.calls.first.uri.path, endsWith('/getOutLinkGeneral'));
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
      expect(http.calls.length, 3);
    },
  );

  test(
    'Chinese command uses the resolved share ID for root, child, empty folder and return navigation',
    () async {
      final parents = <String>[];
      final http = FakeHttp((request) {
        expect(request.headers['Authorization'], authorization);
        final payload = asJson(
          jsonDecode(C139Protocol.decrypt(request.body as String)),
        );
        if (request.uri.path.endsWith('/getOutLinkGeneral')) {
          expect(payload.obj('getOutLinkGeneralReq'), {
            'account': '13800000000',
            'linkCode': '蕧郅岱等遥温琴扣炩',
            'linkCodeType': 2,
            'isPasswd': 0,
          });
          return general(password: 'A1b2');
        }
        final values = payload.obj('getOutLinkInfoReq');
        expect(values.str('linkID'), 'resolved-share');
        expect(values.containsKey('linkCode'), isFalse);
        expect(values.containsKey('linkCodeType'), isFalse);
        expect(values.str('account'), '13800000000');
        expect(values.str('passwd'), 'A1b2');
        expect(values.integer('bNum'), 1);
        expect(values.integer('eNum'), 200);
        final parent = values.str('pCaID');
        parents.add(parent);
        return jsonResponse({
          'resultCode': '0',
          'data': {
            'getOutLinkInfoResp': switch (parent) {
              'root' => {
                'nodNum': 1,
                'caLength': '1',
                'coLength': '0',
                'caLst': [
                  {'caID': 'folder+%', 'caName': '分享子目录'},
                ],
                'coLst': null,
              },
              'folder+%' => {
                'nodNum': 4,
                'caLength': '1',
                'coLength': '3',
                'caLst': [
                  {'caID': 'empty-child', 'caName': '空目录'},
                ],
                'coLst': [
                  for (var i = 1; i <= 3; i++)
                    {
                      'coID': 'file-$i',
                      'coName': '文件 $i.mp4',
                      'coSize': i * 1024,
                    },
                ],
              },
              'empty-child' => {'nodNum': 0, 'caLst': null, 'coLst': null},
              _ => throw StateError('Unexpected directory'),
            },
          },
        });
      });
      final connector = C139Connector(http);
      final session = await connector.openShare(
        LinkParser.parse('“蕧郅岱等遥温琴扣炩”').single,
        credential,
      );
      final root = await connector.list(session, session.rootId, credential);
      expect(root.single.id, 'folder+%');
      expect(root.single.isDirectory, isTrue);
      final child = await connector.list(session, root.single.id, credential);
      expect(child.where((file) => !file.isDirectory), hasLength(3));
      expect(child.every((file) => file.parentId == root.single.id), isTrue);
      final empty = await connector.list(session, child.first.id, credential);
      expect(empty, isEmpty);
      final returned = await connector.list(
        session,
        root.single.id,
        credential,
      );
      expect(returned.map((file) => file.id), child.map((file) => file.id));
      expect(parents, ['root', 'folder+%', 'empty-child', 'folder+%']);
      expect(
        http.calls.where(
          (request) => request.uri.path.endsWith('/getOutLinkGeneral'),
        ),
        hasLength(1),
      );
      await expectLater(
        connector.list(session, root.single.id, null),
        throwsA(isA<AccountLoginRequired>()),
      );
      expect(http.calls, hasLength(5));
    },
  );

  test(
    'Old command directory resolves its real share ID before child pagination',
    () async {
      final begins = <int>[];
      final http = FakeHttp((request) {
        if (request.uri.path.endsWith('/getOutLinkGeneral')) {
          return general(password: 'A1b2');
        }
        final values = asJson(
          jsonDecode(C139Protocol.decrypt(request.body as String)),
        ).obj('getOutLinkInfoReq');
        expect(values.str('linkID'), 'resolved-share');
        expect(values.str('passwd'), 'A1b2');
        expect(values.str('pCaID'), 'nested-folder');
        final begin = values.integer('bNum');
        begins.add(begin);
        return page(
          '<coLst>${[for (var i = begin; i <= (begin == 1 ? 200 : 201); i++) file(i)].join()}</coLst>',
          total: 201,
        );
      });
      final connector = C139Connector(http);
      final files = await connector.list(
        const BrowseSession(
          platform: CloudPlatform.c139,
          mode: BrowseMode.share,
          rootId: 'root',
          title: '旧口令目录',
          metadata: {'linkCode': '蕧郅岱等遥温琴扣炩'},
        ),
        'nested-folder',
        credential,
      );
      expect(begins, [1, 201]);
      expect(files, hasLength(201));
      expect(files.last.parentId, 'nested-folder');
      expect(http.calls, hasLength(3));
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
        final connector = C139Connector(
          FakeHttp(
            (request) => request.uri.path.endsWith('/getOutLinkGeneral')
                ? general()
                : invalid,
          ),
        );
        final session = await connector.openShare(
          LinkParser.parse(command).single,
          credential,
        );
        await expectLater(
          connector.list(session, session.rootId, credential),
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
        expect(http.calls, hasLength(1));
        expect(
          http.calls.every((r) => r.uri.path.contains('/IOutLink/')),
          isTrue,
        );
      },
    );
  }
}
