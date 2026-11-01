import 'package:asterlink/data/providers/baidu_link_service.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:asterlink/core/json.dart';
import 'package:asterlink/data/providers/baidu_app_client.dart';
import 'package:asterlink/data/providers/baidu.dart';
import 'package:asterlink/data/state_store.dart';
import 'package:asterlink/domain/models.dart';
import 'support.dart';

void main() {
  test(
    'Personal API query and UA use the same current application version',
    () async {
      for (final environment in <Json>[
        {},
        {'model': 'Phone', 'osVersion': '15'},
      ]) {
        final client = BaiduAppClient(readEnvironment: () async => environment);
        final http = FakeHttp((r) {
          expect(r.uri.queryParameters['version'], '13.15.4');
          expect(r.headers['User-Agent'], startsWith('netdisk;13.15.4;'));
          if (r.uri.path == '/api/quota') {
            return jsonResponse({'errno': 0, 'used': 1, 'total': 100});
          }
          if (r.uri.path == '/rest/2.0/xpan/nas') {
            return jsonResponse({'errno': 0, 'netdisk_name': 'fixture'});
          }
          return jsonResponse({'errno': 0, 'list': []});
        });
        final connector = BaiduConnector(http, client: client);
        final c = Credential('fixture', {'primary': 'BDUSS=fixture'});
        await connector.account(c);
        final session = await connector.openPersonal(c);
        await connector.list(session, '/', c);
        expect(client.downloadUserAgent, client.userAgent);
        expect(client.serviceDevice['downloadVersion'], '13.15.4');
        expect(http.calls, hasLength(3));
      }
    },
  );

  test(
    'Installation identity survives restart and changing accounts',
    () async {
      final store = Vault(StateStore.memory());
      final client = BaiduAppClient(
        store: store,
        readEnvironment: () async => {},
      );
      await Future.wait([client.prepare(), client.prepare()]);
      final id = client.deviceId;
      expect(id, matches(r'^[A-F0-9]{32}\|0$'));
      await store.putCredential(
        CloudPlatform.baidu,
        Credential('new-account', {'primary': 'BDUSS=changed'}),
      );
      final restarted = BaiduAppClient(
        store: store,
        readEnvironment: () async => {},
      );
      await restarted.prepare();
      expect(restarted.deviceId, id);
      expect(BaiduAppClient().deviceId, isNot(id));
    },
  );

  test(
    'Android UA and channel agree and network changes refresh without new identity',
    () async {
      Json environment = {
        'model': 'Test Phone 中文',
        'osVersion': '14',
        'networkType': 'WIFI',
        'networkSubtype': 0,
      };
      final client = BaiduAppClient(readEnvironment: () async => environment);
      await client.prepare();
      final id = client.deviceId;
      expect(
        client.userAgent,
        contains(';Test+Phone+%E4%B8%AD%E6%96%87;android-android;14;'),
      );
      expect(client.channel, 'android_14_Test Phone 中文_bd-netdisk_1');
      expect(client.parameters['network_type'], 'wifi');
      expect(client.parameters['apn_id'], '1_0');
      environment = {
        ...environment,
        'networkType': 'cmnet',
        'networkSubtype': 13,
      };
      await client.prepare();
      expect(client.deviceId, id);
      expect(client.parameters['network_type'], 'cmnet');
      expect(client.parameters['apn_id'], '31_13');
      environment = {};
      await client.prepare();
      expect(client.parameters.containsKey('network_type'), isFalse);
      expect(client.parameters['apn_id'], '0_0');
      expect(client.parameters['queryfree'], 2);
      expect(client.userAgent, BaiduConnector.netdiskUa);
    },
  );

  test(
    'The link service receives the same device used for download headers',
    () async {
      final client = BaiduAppClient(
        readEnvironment: () async => {
          'model': 'Test Device',
          'osVersion': '14',
          'networkType': 'wifi',
        },
      );
      final cookies = <String>[];
      final connector = BaiduConnector(
        FakeHttp(),
        client: client,
        linkLookup:
            ({
              required cookie,
              required path,
              required fileId,
              required appId,
              required device,
            }) async {
              cookies.add(cookie);
              expect(device['id'], client.deviceId);
              expect(device['model'], 'Test Device');
              expect(device['osVersion'], '14');
              expect(device['networkType'], 'wifi');
              expect(device['downloadVersion'], '13.15.4');
              return const BaiduResolvedLink(
                url: 'https://fixture.baidupcs.com/file',
                preview: true,
              );
            },
      );
      const session = BrowseSession(
        platform: CloudPlatform.baidu,
        mode: BrowseMode.personal,
        title: 'fixture',
        rootId: '/',
      );
      const file = CloudFile(
        id: '42',
        name: 'original.zip',
        token: '/original.zip',
      );
      for (final cookie in ['BDUSS=fixture', 'BDUSS=second']) {
        final spec = await connector.download(
          session,
          file,
          Credential('fixture', {'primary': cookie}),
        );
        expect(
          spec.headers['User-Agent'],
          'netdisk;13.15.4;Test+Device;android-android;14;JSbridge4.4.0;jointBridge;1.1.0;',
        );
        expect(spec.headers['Cookie'], cookie);
        expect(spec.profile, 'baidu_preview');
      }
      expect(cookies, ['BDUSS=fixture', 'BDUSS=second']);
    },
  );
}
