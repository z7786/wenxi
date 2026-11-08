import 'dart:convert';
import 'package:asterlink/core/json.dart';
import 'package:asterlink/data/providers/c139.dart';
import 'package:asterlink/data/providers/pan123.dart';
import 'package:asterlink/data/providers/tianyi.dart';
import 'package:asterlink/data/state_store.dart';
import 'package:asterlink/domain/links.dart';
import 'package:asterlink/domain/models.dart';
import 'package:flutter_test/flutter_test.dart';
import 'support.dart';

void main() {
  test(
    'Tianyi H5 encoded copy labels reach anonymous share and child requests',
    () async {
      final http = FakeHttp((request) {
        expect(request.uri.host, 'cloud.189.cn');
        final parameters = request.uri.queryParameters;
        expect(
          request.headers.keys.map((key) => key.toLowerCase()),
          isNot(contains('authorization')),
        );
        if (request.uri.path.endsWith('/getShareInfoByCodeV2.action')) {
          expect(parameters['shareCode'], 'jy6R3u3YvQB3');
          return jsonResponse({
            'res_code': 0,
            'shareId': '123456',
            'fileId': '100',
            'fileName': '分享目录',
            'isFolder': true,
            'shareType': 3,
            'shareMode': '1',
          });
        }
        if (request.uri.path.endsWith('/checkAccessCode.action')) {
          expect(parameters['shareCode'], 'jy6R3u3YvQB3');
          expect(parameters['accessCode'], 'm6h5');
          return jsonResponse({'res_code': 0, 'shareId': '123456'});
        }
        expect(request.uri.path, '/api/open/share/listShareDir.action');
        expect(parameters['shareId'], '123456');
        expect(parameters['accessCode'], 'm6h5');
        expect(request.headers['Cookie'], contains('share_123456=m6h5'));
        final parent = parameters['shareDirFileId'];
        expect(parameters['fileId'], parent);
        return jsonResponse({
          'res_code': 0,
          'fileListAO': {
            'count': 1,
            'folderList': parent == '100'
                ? [
                    {'id': '200', 'name': '子目录'},
                  ]
                : [],
            'fileList': parent == '200'
                ? [
                    {'id': '300', 'name': '示例.mp4', 'size': '1024'},
                  ]
                : [],
          },
        });
      });
      final connector = TianyiConnector(http);
      final link = LinkParser.parse(
        'https://h5.cloud.189.cn/share.html#/t/jy6R3u3YvQB3'
        '%EF%BC%88%E8%AE%BF%E9%97%AE%E7%A0%81%EF%BC%9Am6h5%EF%BC%89',
      ).single;
      expect(link.kind, LinkKind.cloudShare);
      final session = await connector.openShare(link, null);
      expect(session.meta('shareCode'), 'jy6R3u3YvQB3');
      expect(session.meta('accessCode'), 'm6h5');
      final root = await connector.list(session, session.rootId, null);
      expect(root.single.id, '200');
      expect(root.single.isDirectory, isTrue);
      final child = await connector.list(session, root.single.id, null);
      expect(child.single.id, '300');
      expect(child.single.parentId, root.single.id);
      expect(http.calls, hasLength(4));
    },
  );
  for (final host in [
    'www.123684.com',
    'author.share.123pan.com',
    '123912.cn',
  ]) {
    test(
      '123 alias $host sends the extracted key and password to the share API',
      () async {
        final store = StateStore.memory();
        addTearDown(store.dispose);
        final http = FakeHttp((request) {
          expect(request.uri.host, 'yun.123pan.cn');
          expect(request.uri.path, '/b/api/share/get');
          expect(request.uri.queryParameters['shareKey'], 'Abc_Def');
          expect(request.uri.queryParameters['SharePwd'], 'p123');
          return jsonResponse({
            'code': 0,
            'data': {'InfoList': []},
          });
        });
        final link = LinkParser.parse(
          'https://$host/s/Abc_Def?pass=p123 提取码：a123',
        ).single;
        final session = await Pan123Connector(
          http,
          Vault(store),
        ).openShare(link, null);
        expect(session.meta('shareKey'), 'Abc_Def');
        expect(session.meta('passcode'), 'p123');
        expect(http.calls, hasLength(1));
      },
    );
  }

  for (final url in [
    'https://caiyun.139.com/m/i?Mobile123&pass=m123',
    'https://yun.139.com/shareweb/#/w/i/Mobile123?pwd=m123',
  ]) {
    test('Mobile input $url reaches the encrypted share request', () async {
      final http = FakeHttp((request) {
        expect(request.uri.path, endsWith('/IOutLink/getOutLinkGeneral'));
        final body = asJson(
          jsonDecode(C139Protocol.decrypt(request.body as String)),
        );
        expect(body.obj('getOutLinkGeneralReq')['linkID'], 'Mobile123');
        return jsonResponse({
          'code': 0,
          'data': {
            'getOutLinkGeneralResp': {
              'outLinkGeneral': [
                {'lkName': 'fixture', 'passwd': 'old1'},
              ],
            },
          },
        });
      });
      final session = await C139Connector(
        http,
      ).openShare(LinkParser.parse(url).single, null);
      expect(session.meta('linkId'), 'Mobile123');
      expect(session.meta('password'), 'm123');
      expect(http.calls, hasLength(1));
    });
  }
}
