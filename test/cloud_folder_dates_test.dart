import 'dart:async';
import 'package:flutter_test/flutter_test.dart';
import 'package:asterlink/data/cloud_folder_dates.dart';
import 'package:asterlink/domain/models.dart';
import 'support.dart' show until;

const session = BrowseSession(
  platform: CloudPlatform.quark,
  mode: BrowseMode.personal,
  title: 'test',
  rootId: '0',
);
const folder = CloudFile(id: 'folder', name: 'folder', isDirectory: true);
void main() {
  test(
    'walks nested folders and every page, ignoring directory timestamps and cycles',
    () async {
      final calls = <String>[];
      final dates = CloudFolderDates(
        directoryId: (_, f) => f.id,
        validate: (_) {},
        read: (_, parent, cursor) async {
          calls.add('$parent/$cursor');
          if (parent == 'folder' && cursor == null) {
            return CloudFilePage(const [
              CloudFile(id: 'old', name: 'old', modifiedAt: '2026-01-01'),
              CloudFile(
                id: 'child',
                name: 'child',
                isDirectory: true,
                modifiedAt: '2030-01-01',
              ),
            ], nextCursor: '2');
          }
          if (parent == 'folder') {
            return CloudFilePage(const [
              CloudFile(id: 'middle', name: 'middle', modifiedAt: '2026-04-01'),
            ]);
          }
          return CloudFilePage(const [
            folder,
            CloudFile(id: 'new', name: 'new', modifiedAt: '2026-11-20'),
          ]);
        },
      );
      addTearDown(dates.dispose);
      dates.update(1, session, [folder], DateTime(2026, 11, 23), enabled: true);
      await until(() => !dates.busy);
      expect(dates.dates['folder'], DateTime(2026, 11, 20));
      expect(calls, ['folder/null', 'folder/2', 'child/null']);
      dates.update(1, session, [folder], DateTime.now(), enabled: true);
      expect(calls, hasLength(3));
    },
  );

  test(
    'repeated pagination fails without publishing a partial latest time',
    () async {
      final dates = CloudFolderDates(
        directoryId: (_, f) => f.id,
        validate: (_) {},
        read: (_, _, _) async => CloudFilePage(const [
          CloudFile(id: 'new', name: 'new', modifiedAt: '2026-11-20'),
        ], nextCursor: 'same'),
      );
      addTearDown(dates.dispose);
      dates.update(1, session, [folder], DateTime.now(), enabled: true);
      await until(() => !dates.busy);
      expect(dates.failed, 1);
      expect(dates.dates, isEmpty);
    },
  );

  test(
    'navigation cancels stale results and bounds simultaneous requests',
    () async {
      final barriers = <Completer<CloudFilePage>>[];
      final dates = CloudFolderDates(
        directoryId: (_, f) => f.id,
        validate: (_) {},
        read: (_, _, _) {
          final hold = Completer<CloudFilePage>();
          barriers.add(hold);
          return hold.future;
        },
      );
      addTearDown(dates.dispose);
      dates.update(
        1,
        session,
        [
          folder,
          const CloudFile(id: 'b', name: 'b', isDirectory: true),
          const CloudFile(id: 'c', name: 'c', isDirectory: true),
        ],
        DateTime.now(),
        enabled: true,
      );
      await until(() => barriers.length == 2);
      dates.update(2, session, [], DateTime.now(), enabled: false);
      for (final hold in barriers) {
        hold.complete(
          CloudFilePage(const [
            CloudFile(id: 'x', name: 'x', modifiedAt: '2026-11-20'),
          ]),
        );
      }
      await Future<void>.delayed(Duration.zero);
      expect(dates.dates, isEmpty);
      expect(dates.failed, 0);
      expect(barriers, hasLength(2));
    },
  );
}
