import 'package:flutter_test/flutter_test.dart';
import 'package:asterlink/core/html_entities.dart';
import 'package:asterlink/data/providers/quark_uc.dart';
import 'package:asterlink/domain/models.dart';
import 'support.dart';

const _rawEpisode =
    '[DAY][仮面ライダー555][第15話 落ちた偶像？Φ&#39;s VS χ]'
    '[BDrip][1080P][X264 PCM][60FPS].mkv';
const _displayEpisode =
    "[DAY][仮面ライダー555][第15話 落ちた偶像？Φ's VS χ]"
    '[BDrip][1080P][X264 PCM][60FPS].mkv';

void main() {
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
