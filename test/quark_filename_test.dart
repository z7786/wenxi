import 'package:flutter_test/flutter_test.dart';
import 'package:asterlink/core/html_entities.dart';
import 'package:asterlink/data/cleanup_outbox.dart';
import 'package:asterlink/data/cloud_repository.dart';
import 'package:asterlink/data/providers/quark_uc.dart';
import 'package:asterlink/data/state_store.dart';
import 'package:asterlink/domain/models.dart';
import 'package:asterlink/domain/downloads.dart';
import 'support.dart';

const _rawEpisode =
    '[DAY][仮面ライダー555][第15話 落ちた偶像？Φ&#39;s VS χ]'
    '[BDrip][1080P][X264 PCM][60FPS].mkv';
const _displayEpisode =
    "[DAY][仮面ライダー555][第15話 落ちた偶像？Φ's VS χ]"
    '[BDrip][1080P][X264 PCM][60FPS].mkv';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test(
    'Filename display decodes complete entities once and preserves text',
    () {
      expect(unescapeDisplayName(_rawEpisode), _displayEpisode);
      expect(
        unescapeDisplayName(
          '&#39; &#x27; &#X27; &apos; &quot; &amp; &lt; &gt;',
        ),
        "' ' ' ' \" & < >",
      );
      expect(unescapeDisplayName('第&#49;&#53;話 &#x1F3AC;.mkv'), '第15話 🎬.mkv');
      expect(unescapeDisplayName('&amp;#39;.mkv'), '&#39;.mkv');
      const literal =
          "<b>Φ's</b> & friends %27 &#39 &amp &notSomething; "
          '&unknown; &#xD800; &#1114112;.mkv';
      expect(unescapeDisplayName(literal), literal);
      expect(unescapeDisplayName('<b>Φ&#39;s</b>.mkv'), "<b>Φ's</b>.mkv");
    },
  );

  for (final mode in [BrowseMode.share, BrowseMode.personal]) {
    test('Quark $mode labels decode without changing file identity', () async {
      final http = FakeHttp((request) {
        expect(
          request.uri.path,
          endsWith(
            mode == BrowseMode.share ? '/sharepage/detail' : '/file/sort',
          ),
        );
        return jsonResponse({
          'status': 200,
          'code': 0,
          'data': {
            'list': [
              {
                'fid': 'episode-15',
                'file_name': _rawEpisode,
                'size': 2213557610,
                'dir': false,
                'pdir_fid': 'folder',
                'share_fid_token': 'share-file-token',
                'fid_token': 'account-file-token',
                'updated_at': '1700000000123',
              },
              {'fid': 'folder', 'file_name': 'A &amp; B', 'dir': true},
            ],
          },
        });
      });
      final files = await QuarkUcConnector(CloudPlatform.quark, http).list(
        BrowseSession(
          platform: CloudPlatform.quark,
          mode: mode,
          title: 'fixture',
          rootId: 'folder',
          metadata: const {'shareId': 'share', 'stoken': 'share-token'},
        ),
        'folder',
        null,
      );
      final video = files.first;
      expect(video.displayName, _displayEpisode);
      expect(video.name, _rawEpisode);
      expect(video.id, 'episode-15');
      expect(video.size, 2213557610);
      expect(video.isDirectory, isFalse);
      expect(video.parentId, 'folder');
      expect(
        video.token,
        mode == BrowseMode.share ? 'share-file-token' : 'account-file-token',
      );
      expect(video.modifiedAt, '1700000000123');
      expect(files.last.name, 'A &amp; B');
      expect(files.last.displayName, 'A & B');
      expect(files.last.isDirectory, isTrue);
      expect(http.calls, hasLength(1));

      final restored = CloudFile.fromJson(video.toJson());
      expect(restored.toJson(), video.toJson());
      expect(restored.name, _rawEpisode);
      expect(restored.displayName, _displayEpisode);
      final legacy = CloudFile.fromJson(
        {...video.toJson()}..remove('displayName'),
      );
      expect(legacy.name, _rawEpisode);
      expect(legacy.displayName, _rawEpisode);
      expect(legacy.toJson(), isNot(contains('displayName')));
    });
  }

  for (final returnedName in [_rawEpisode, '', '&amp;#39;.mkv']) {
    test(
      'Personal Quark download decodes API name once ($returnedName)',
      () async {
        final http = FakeHttp((request) {
          expect(request.uri.path, endsWith('/file/download'));
          expect(request.json['fids'], ['episode-15']);
          return jsonResponse({
            'status': 200,
            'code': 0,
            'data': [
              {
                'fid': 'episode-15',
                'file_name': returnedName,
                'download_url': 'https://cdn.example/episode',
                'size': 4,
              },
            ],
          });
        });
        final result = await QuarkUcConnector(CloudPlatform.quark, http)
            .download(
              const BrowseSession(
                platform: CloudPlatform.quark,
                mode: BrowseMode.personal,
                title: 'fixture',
                rootId: '0',
              ),
              const CloudFile(
                id: 'episode-15',
                name: _rawEpisode,
                displayName: _displayEpisode,
                size: 4,
              ),
              Credential('fixture', {'primary': 'fixture-cookie'}),
            );
        expect(
          result.fileName,
          returnedName == '&amp;#39;.mkv' ? '&#39;.mkv' : _displayEpisode,
        );
      },
    );
  }

  for (final directoryName in [
    ("A&#39;s &amp; B", "A's & B"),
    ('A&#47;B&#92;C', 'A_B_C'),
    ('&#46;&#46;', 'download.bin'),
    ('&amp;#39;', '&#39;'),
  ]) {
    test(
      'Folder download preserves one safe component for ${directoryName.$1}',
      () async {
        final store = StateStore.memory();
        final http = FakeHttp((request) {
          expect(request.uri.path, endsWith('/sharepage/detail'));
          expect(request.uri.queryParameters['pdir_fid'], 'selected-folder');
          return jsonResponse({
            'status': 200,
            'code': 0,
            'data': {
              'list': [
                {
                  'fid': 'episode-15',
                  'file_name': _rawEpisode,
                  'size': 4,
                  'dir': false,
                  'share_fid_token': 'file-token',
                },
              ],
            },
          });
        });
        final repository = CloudRepository(
          http,
          Vault(store),
          CleanupOutbox(store, http),
        );
        const session = BrowseSession(
          platform: CloudPlatform.quark,
          mode: BrowseMode.share,
          title: 'fixture',
          rootId: '0',
          metadata: {'shareId': 'share', 'stoken': 'share-token'},
        );
        final collected = await repository.collect(session, [
          CloudFile(
            id: 'selected-folder',
            name: directoryName.$1,
            displayName: unescapeDisplayName(directoryName.$1),
            isDirectory: true,
          ),
        ]);
        final (file, path) = collected.single;
        final plan = repository
            .planDownload(session, file)
            .copyWith(relativePath: path);
        expect(plan.fileName, _displayEpisode);
        expect(plan.relativePath, directoryName.$2);
        final restored = DownloadSpec.fromJson(plan.toJson());
        expect(restored.fileName, _displayEpisode);
        expect(restored.relativePath, directoryName.$2);
        final origin = DownloadOrigin.fromJson(restored.source!);
        expect(origin.file.name, _rawEpisode);
        expect(origin.file.displayName, _displayEpisode);
        expect(origin.file.id, 'episode-15');
        expect(origin.file.parentId, 'selected-folder');
        expect(origin.file.token, 'file-token');
      },
    );
  }

  test(
    'UC and ordinary CloudFile names retain their previous display',
    () async {
      final connector = QuarkUcConnector(
        CloudPlatform.uc,
        FakeHttp(
          (_) => jsonResponse({
            'status': 200,
            'code': 0,
            'data': {
              'list': [
                {'fid': 'episode-15', 'fname': _rawEpisode, 'isdir': 0},
              ],
            },
          }),
        ),
      );
      final file = (await connector.list(
        const BrowseSession(
          platform: CloudPlatform.uc,
          mode: BrowseMode.share,
          title: 'fixture',
          rootId: 'folder',
          metadata: {'shareId': 'share', 'stoken': 'share-token'},
        ),
        'folder',
        null,
      )).single;
      expect(file.name, _rawEpisode);
      expect(file.displayName, _rawEpisode);
      expect(file.toJson(), isNot(contains('displayName')));
      const ordinary = CloudFile(id: 'ordinary', name: "Φ's.mkv");
      expect(ordinary.displayName, ordinary.name);
    },
  );
}
