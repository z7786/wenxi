import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'package:crypto/crypto.dart';
import 'package:file_selector/file_selector.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:asterlink/app_services.dart';
import 'package:asterlink/core/crypto_box.dart';
import 'package:asterlink/core/json.dart';
import 'package:asterlink/data/backup.dart';
import 'package:asterlink/data/backgrounds.dart';
import 'package:asterlink/data/state_store.dart';
import 'package:asterlink/domain/appearance.dart';
import 'package:asterlink/domain/background.dart';
import 'package:asterlink/domain/settings.dart';
import 'package:asterlink/platform/background_image.dart';
import 'background_support.dart';
import 'support.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('old, corrupt and foreign paths cannot enable an unsafe background', () {
    expect(AppSettings.fromJson({}).background.hasImage, isFalse);
    for (final id in [
      '../../private.png',
      'C:/photo.png',
      'https://example.com/a.png',
      '',
    ]) {
      final settings = AppSettings.fromJson({
        'background': {
          'day': {'id': id, 'width': 10, 'height': 10},
          'brightness': double.nan,
          'blur': double.infinity,
          'cardOpacity': -1,
        },
      });
      expect(settings.background.day, isNull);
      expect(settings.background.brightness, .9);
      expect(settings.background.blur, 6);
      expect(settings.background.cardOpacity, .6);
    }
    final crop = BackgroundCrop.fromJson({'x': -1, 'y': 3, 'zoom': 999});
    expect(crop, const BackgroundCrop(x: 0, y: 1, zoom: 3));
  });

  test(
    'large images are bounded before use; invalid inputs fail cleanly',
    () async {
      final large = await backgroundFixture(width: 4000, height: 3000);
      final prepared = await prepareBackgroundImage(large);
      final (width, height) = backgroundPngSize(prepared);
      expect(width, lessThanOrEqualTo(backgroundMaxSide));
      expect(height, lessThanOrEqualTo(backgroundMaxSide));
      expect(width * height, lessThanOrEqualTo(3000000));
      expect(prepared.length, lessThanOrEqualTo(backgroundMaxBytes));
      await validateBackgroundImage(prepared);
      await expectLater(
        prepareBackgroundImage(Uint8List.fromList([1, 2, 3])),
        throwsA(isA<AppException>()),
      );
      await expectLater(
        prepareBackgroundImage(Uint8List(backgroundSourceMaxBytes + 1)),
        throwsA(isA<AppException>()),
      );
    },
  );

  test(
    'private image and separate crops survive deletion of source and a restart',
    () async {
      final directory = await Directory.systemTemp.createTemp(
        'wenxi-background-reopen-',
      );
      addTearDown(() => directory.delete(recursive: true));
      final key = CryptoBox.random(32);
      final store = await StateStore.open(directory, testKey: key);
      final native = FakeNative();
      final services = AppServices(
        store: store,
        dataDirectory: directory,
        cacheDirectory: Directory('${directory.path}/cache'),
        transport: native,
        files: FakeFiles(directory),
        http: FakeHttp(),
        controlEnabled: false,
        platformFeatures: false,
      );
      final source = await File(
        '${directory.path}/original.png',
      ).writeAsBytes(await backgroundFixture());
      final draft = services.backgrounds.beginDraft();
      final image =
          (await services.backgrounds.importFile(XFile(source.path), draft))
              .withCrop(
                const BackgroundCrop(x: .2, y: .3, zoom: 1.4),
                wide: false,
              )
              .withCrop(
                const BackgroundCrop(x: .7, y: .8, zoom: 2),
                wide: true,
              );
      final before = List<String>.of(native.calls);
      await services.updateAppearance(
        mode: 'System',
        palette: AppPalette.mint,
        glassStyle: GlassStyle.frosted,
        background: BackgroundSettings(day: image, brightness: .8, blur: 9),
      );
      expect(
        native.calls,
        before,
        reason: 'Wallpaper must not restart downloads',
      );
      await services.backgrounds.endDraft(draft);
      await source.delete();
      await store.flush();
      final reopened = await StateStore.open(directory, testKey: key);
      final restored = AppSettings.fromJson(
        reopened.data.obj('settings'),
      ).background;
      expect(restored.day, image);
      expect(restored.brightness, .8);
      expect(restored.blur, 9);
      final repo = BackgroundRepository(directory, current: () => restored);
      expect(await repo.file(restored.day!.id).exists(), isTrue);
      await validateBackgroundImage(
        await repo.file(restored.day!.id).readAsBytes(),
      );
      expect(jsonEncode(restored.toJson()), isNot(contains(directory.path)));
      expect(restored.pictureFor(true), image);
      expect(restored.pictureFor(false), image);
      await services.close();
      reopened.dispose();
    },
  );

  test(
    'abandoned drafts are removed while saved images and other drafts are retained',
    () async {
      final directory = await Directory.systemTemp.createTemp(
        'wenxi-background-draft-',
      );
      addTearDown(() => directory.delete(recursive: true));
      var current = const BackgroundSettings();
      final repo = BackgroundRepository(directory, current: () => current);
      final first = repo.beginDraft(), second = repo.beginDraft();
      final saved = await repo.importFile(
        XFile.fromData(await backgroundFixture()),
        first,
      );
      final abandoned = await repo.importFile(
        XFile.fromData(await backgroundFixture(night: true)),
        second,
      );
      current = current.withPicture(saved);
      await repo.endDraft(first);
      expect(await repo.file(abandoned.id).exists(), isTrue);
      await repo.endDraft(second);
      expect(await repo.file(saved.id).exists(), isTrue);
      expect(await repo.file(abandoned.id).exists(), isFalse);
      await expectLater(
        repo.importFile(XFile.fromData(await backgroundFixture()), second),
        throwsA(isA<AppException>()),
      );
      current = current.withoutImages();
      await repo.collectUnused();
      expect(await repo.file(saved.id).exists(), isFalse);
    },
  );

  test(
    'optional background backup restores pictures and crops on another device',
    () async {
      final directory = await Directory.systemTemp.createTemp(
        'wenxi-background-backup-',
      );
      addTearDown(() => directory.delete(recursive: true));
      final sourceStore = StateStore.memory();
      final repo = BackgroundRepository(
        Directory('${directory.path}/source'),
        current: () =>
            AppSettings.fromJson(sourceStore.data.obj('settings')).background,
      );
      final draft = repo.beginDraft();
      final day = await repo.importFile(
        XFile.fromData(await backgroundFixture()),
        draft,
      );
      final night = (await repo.importFile(
        XFile.fromData(await backgroundFixture(night: true)),
        draft,
      )).withCrop(const BackgroundCrop(x: .2, zoom: 1.5), wide: true);
      final background = BackgroundSettings(
        day: day,
        night: night,
        cardOpacity: .77,
      );
      await sourceStore.put(
        'settings',
        AppSettings(
          background: background,
          themePalette: AppPalette.rose,
          destination: 'D:/Downloads',
        ).toJson(),
      );
      await repo.endDraft(draft);
      final backup = BackupRepository(sourceStore, backgrounds: repo);
      const password = 'background-test-password';
      final exported = await backup.create(password);
      final payload = decryptBackup((exported, password));
      expect(payload.containsKey('backgroundImages'), isFalse);
      expect(
        AppSettings.fromJson(payload.obj('settings')).background.hasImage,
        isFalse,
      );
      // Old packages containing images remain readable.
      final bytes = encryptBackup((
        {
          ...payload,
          'settings': {
            ...payload.obj('settings'),
            'background': background.toJson(),
          },
          'backgroundImages': await repo.exportImages(background),
        },
        password,
      ));
      expect(bytes.length, lessThanOrEqualTo(16 * 1024 * 1024));
      final targetStore = StateStore.memory();
      final targetRepo = BackgroundRepository(
        Directory('${directory.path}/target'),
        current: () =>
            AppSettings.fromJson(targetStore.data.obj('settings')).background,
      );
      final targetBackup = BackupRepository(
        targetStore,
        backgrounds: targetRepo,
      );
      await targetBackup.restore(bytes, password);
      final restored = AppSettings.fromJson(targetStore.data.obj('settings'));
      expect(restored.background, background);
      expect(restored.destination, isNull);
      for (final id in background.ids) {
        expect(
          await targetRepo.file(id).readAsBytes(),
          await repo.file(id).readAsBytes(),
        );
      }
      final noImages = await backup.create(password);
      await targetBackup.restore(noImages, password);
      expect(
        AppSettings.fromJson(
          targetStore.data.obj('settings'),
        ).background.hasImage,
        isFalse,
      );
      expect(
        AppSettings.fromJson(targetStore.data.obj('settings')).themePalette,
        AppPalette.rose,
      );
      expect(
        (await targetRepo.directory.list().toList()).whereType<File>(),
        isEmpty,
      );
      sourceStore.dispose();
      targetStore.dispose();
    },
    timeout: const Timeout(Duration(seconds: 90)),
  );

  test(
    'corrupt backup images cannot replace existing settings or pictures',
    () async {
      final directory = await Directory.systemTemp.createTemp(
        'wenxi-background-invalid-',
      );
      addTearDown(() => directory.delete(recursive: true));
      final store = StateStore.memory();
      final repo = BackgroundRepository(
        directory,
        current: () =>
            AppSettings.fromJson(store.data.obj('settings')).background,
      );
      final draft = repo.beginDraft();
      final picture = await repo.importFile(
        XFile.fromData(await backgroundFixture()),
        draft,
      );
      final original = AppSettings(
        theme: 'Dark',
        background: BackgroundSettings(day: picture),
      ).toJson();
      await store.put('settings', original);
      await repo.endDraft(draft);
      final broken = Uint8List.fromList(
        await repo.file(picture.id).readAsBytes(),
      ).sublist(0, 33);
      final brokenId = '${sha256.convert(broken)}.png';
      final backup = encryptBackup((
        {
          'schema': 1,
          'package': 'com.asterlink.app',
          'credentials': [],
          'settings': {
            'theme': 'Light',
            'background': {
              'day': {...picture.toJson(), 'id': brokenId},
            },
          },
          'backgroundImages': {brokenId: base64Encode(broken)},
        },
        'background-test-password',
      ));
      await expectLater(
        BackupRepository(
          store,
          backgrounds: repo,
        ).restore(backup, 'background-test-password'),
        throwsA(isA<AppException>()),
      );
      expect(store.data.obj('settings'), original);
      expect(await repo.file(picture.id).exists(), isTrue);
      expect(await repo.file(brokenId).exists(), isFalse);
      store.dispose();
    },
  );
}
