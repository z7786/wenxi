import 'package:flutter_test/flutter_test.dart';
import 'package:asterlink/core/json.dart';
import 'package:asterlink/data/cloud_search_history.dart';
import 'package:asterlink/data/state_store.dart';
import 'package:asterlink/domain/cloud_search_options.dart';
import 'package:asterlink/domain/models.dart';

BrowseSession _session(
  String account, [
  CloudPlatform platform = CloudPlatform.quark,
]) => BrowseSession(
  platform: platform,
  mode: BrowseMode.personal,
  title: '文件',
  rootId: '0',
).withAccount(account);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test(
    'Search history persists in local state and stays within its account and platform',
    () async {
      final store = StateStore.memory(),
          first = _session('first'),
          second = _session('second');
      addTearDown(store.dispose);
      final history = CloudSearchHistory(store);
      await history.remember(first, '  年度报告  ');
      await history.remember(second, '相册');
      await history.remember(_session('first', CloudPlatform.uc), '视频');
      final reopened = CloudSearchHistory(store);
      expect(reopened.read(first), ['年度报告']);
      expect(reopened.read(second), ['相册']);
      expect(reopened.read(_session('first', CloudPlatform.uc)), ['视频']);
      await reopened.clear(first);
      expect(reopened.read(first), isEmpty);
      expect(reopened.read(second), ['相册']);
    },
  );

  test(
    'History deduplicates terms, caps its size and handles concurrent writes',
    () async {
      final store = StateStore.memory(), session = _session('first');
      addTearDown(store.dispose);
      final history = CloudSearchHistory(store);
      await Future.wait([
        for (var i = 0; i < 20; i++) history.remember(session, 'file-$i'),
      ]);
      expect(history.read(session), hasLength(12));
      expect(history.read(session).first, 'file-19');
      await history.remember(session, 'FILE-10');
      expect(history.read(session).first, 'FILE-10');
      expect(
        history
            .read(session)
            .where((value) => value.toLowerCase() == 'file-10'),
        hasLength(1),
      );
      await history.remove(session, 'FILE-10');
      expect(history.read(session), isNot(contains('FILE-10')));
      final before = history.read(session);
      await history.remember(session, ' ');
      await history.remember(session, '长' * 121);
      expect(history.read(session), before);
    },
  );

  test(
    'incognito blocks cloud history across accounts and resumes when disabled',
    () async {
      final store = StateStore.memory(), first = _session('first');
      addTearDown(store.dispose);
      final history = CloudSearchHistory(store);
      await history.remember(first, '原记录');
      final enabling = store.change((draft) {
        draft['resourceSearch'] = {'incognito': true};
      });
      await history.remember(first, '正在开启');
      await enabling;
      await history.remember(first, '不留记录');
      await history.remember(_session('second', CloudPlatform.uc), '其它网盘');
      final reopened = CloudSearchHistory(store);
      expect(reopened.read(first), ['原记录']);
      expect(reopened.read(_session('second', CloudPlatform.uc)), isEmpty);
      await reopened.clear(first);
      expect(reopened.read(first), isEmpty);
      await reopened.remember(first, '清空后搜索');
      expect(reopened.read(first), isEmpty);
      final disabling = store.change((draft) {
        draft['resourceSearch'] = {'incognito': false};
      });
      await reopened.remember(first, '正在关闭');
      await disabling;
      expect(reopened.read(first), isEmpty);
      await reopened.remember(first, '恢复记录');
      expect(reopened.read(first), ['恢复记录']);
    },
  );

  test('Malformed restored history does not prevent opening search', () async {
    final store = StateStore.memory(), session = _session('first');
    addTearDown(store.dispose);
    final history = CloudSearchHistory(store);
    await history.remember(session, '报告');
    final key = store.data.obj('cloudSearchHistory').keys.single;
    await store.change((draft) {
      draft['cloudSearchHistory'] = {
        key: {'invalid': true},
      };
    });
    expect(history.read(session), isEmpty);
    await history.remember(session, '恢复');
    expect(history.read(session), ['恢复']);
  });

  test(
    'Document filters include office files and directories are never classified by their suffix',
    () {
      for (final name in [
        '报告.DOCX',
        '工作表.xlsx',
        '演示.pptx',
        '说明.md',
        '文件.pdf',
        '笔记.txt',
      ]) {
        final file = CloudFile(id: name, name: name);
        expect(CloudSearchCategory.document.matches(file), isTrue);
        expect(CloudSearchCategory.other.matches(file), isFalse);
      }
      const folder = CloudFile(id: 'dir', name: '电影.mp4', isDirectory: true);
      expect(CloudSearchCategory.folder.matches(folder), isTrue);
      expect(CloudSearchCategory.video.matches(folder), isFalse);
      expect(
        CloudSearchCategory.other.matches(
          const CloudFile(id: 'apk', name: 'app.apk'),
        ),
        isTrue,
      );
    },
  );
}
