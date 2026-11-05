import 'dart:io';
import 'dart:typed_data';
import 'package:flutter_test/flutter_test.dart';
import 'package:asterlink/core/json.dart';
import 'package:asterlink/data/backup.dart';
import 'package:asterlink/data/state_store.dart';
import 'package:asterlink/domain/auth.dart';
import 'package:asterlink/domain/models.dart';
import 'browser_test_support.dart';
import 'support.dart' show until;

Credential _credential(String name, int revision) => Credential('fixture', {
  'primary': 'fixture-token',
  'accessToken': 'fixture-token',
  'authType': 'webToken',
  'nickname': name,
}, updatedAt: revision);

Vault _oldBackup(CloudPlatform platform) {
  final credential = _credential('原昵称', 42).toJson();
  return Vault(
    StateStore.memory({
      'credentials': {platform.key: credential},
      'activeCloudAccounts': {platform.key: 'original'},
      'cloudAccounts': {
        platform.key: {
          'original': {'name': '原昵称', 'credential': credential},
        },
      },
    }),
  );
}

Future<void> _login(Vault vault, CloudPlatform platform, String name) async {
  final login = AccountLoginService(vault, (_, _) async => CloudAccount(name));
  await login.submit(
    platform,
    (_) async => LoginResult(_credential(name, 100), CloudAccount(name)),
    accountId: 'original',
  );
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test(
    'Custom name and original account survive closing and reopening encrypted storage',
    () async {
      final dir = await Directory.systemTemp.createTemp(
        'account-name-persistence-',
      );
      final key = Uint8List.fromList(List.filled(32, 7));
      try {
        final first = await StateStore.open(dir, testKey: key);
        final vault = Vault(first);
        await vault.putCredential(
          CloudPlatform.aliyun,
          _credential('网盘昵称', 42),
        );
        final id = vault.activeAccountId(CloudPlatform.aliyun)!;
        await vault.renameAccount(CloudPlatform.aliyun, id, '工作资料');
        await first.flush();
        first.dispose();
        final reopened = await StateStore.open(dir, testKey: key);
        final restored = Vault(reopened);
        await restored.initializeAccounts();
        expect(restored.profiles(CloudPlatform.aliyun).single.id, id);
        expect(
          restored.profiles(CloudPlatform.aliyun).single.customName,
          '工作资料',
        );
        expect(
          restored.credential(CloudPlatform.aliyun)!.primary,
          'fixture-token',
        );
        reopened.dispose();
      } finally {
        await dir.delete(recursive: true);
      }
    },
  );
  for (final platform in [CloudPlatform.aliyun, CloudPlatform.pan123]) {
    test(
      '${platform.key} services persist refreshed nicknames without losing custom names',
      () async {
        final fixture = await BrowserUiFixture.create(platform: platform);
        try {
          final services = fixture.services, vault = services.vault;
          await vault.putCredential(platform, _credential('初始昵称', 42));
          await until(() => !services.accountLoading.contains(platform));
          final id = vault.activeAccountId(platform)!;
          final original = vault.credential(platform)!;
          await vault.updateAccountNickname(
            platform,
            id,
            original.updatedAt,
            '过期昵称',
          );
          await services.refreshAccount(platform);
          await services.store.flush();
          expect(vault.profiles(platform).single.name, '测试账号');
          await vault.renameAccount(platform, id, '家庭备份');
          await services.refreshAccount(platform);
          await services.store.flush();
          expect(vault.profiles(platform).single.name, '家庭备份');
          expect(vault.profiles(platform).single.nickname, '测试账号');
          expect(vault.credential(platform)!.updatedAt, original.updatedAt);
          expect(vault.credential(platform)!.primary, original.primary);
        } finally {
          await fixture.close();
        }
      },
    );
    test(
      '${platform.key} old backup display names do not freeze the nickname',
      () async {
        final vault = _oldBackup(platform);
        expect(vault.profiles(platform).single.customName, isEmpty);
        await _login(vault, platform, '重新登录后的昵称');
        final profile = vault.profiles(platform).single;
        expect(profile.name, '重新登录后的昵称');
        expect(profile.id, 'original');
        expect(vault.activeAccountId(platform), 'original');
      },
    );

    test(
      '${platform.key} custom names survive re-login even when equal to the old nickname',
      () async {
        final vault = _oldBackup(platform);
        await vault.renameAccount(platform, 'original', '原昵称');
        await _login(vault, platform, '新昵称');
        final profile = vault.profiles(platform).single;
        expect(profile.name, '原昵称');
        expect(profile.customName, '原昵称');
        expect(profile.nickname, '新昵称');
        expect(profile.id, 'original');
        await vault.renameAccount(platform, 'original', '');
        expect(vault.profiles(platform).single.name, '新昵称');
      },
    );

    test(
      '${platform.key} refreshing profile metadata preserves tokens and download revision',
      () async {
        final vault = _oldBackup(platform);
        expect(
          await vault.updateAccountNickname(platform, 'original', 42, '刷新昵称'),
          isTrue,
        );
        expect(vault.profiles(platform).single.name, '刷新昵称');
        expect(vault.credential(platform)!.updatedAt, 42);
        expect(vault.credential(platform)!.primary, 'fixture-token');
        await _login(vault, platform, '新登录');
        expect(
          await vault.updateAccountNickname(platform, 'original', 42, '迟到的旧昵称'),
          isFalse,
        );
        expect(vault.profiles(platform).single.name, '新登录');
      },
    );
  }

  test(
    'Background profile updates cannot rename another account or cloud',
    () async {
      final vault = _oldBackup(CloudPlatform.aliyun);
      final other = await vault.createAccount(CloudPlatform.aliyun);
      await vault.withAccount(
        CloudPlatform.aliyun,
        other,
        () =>
            vault.putCredential(CloudPlatform.aliyun, _credential('另一账号', 100)),
      );
      await vault.activate(CloudPlatform.aliyun, other);
      await vault.putCredential(
        CloudPlatform.pan123,
        _credential('123 昵称', 150),
      );
      await vault.updateAccountNickname(
        CloudPlatform.aliyun,
        'original',
        42,
        '阿里原账号的新昵称',
      );
      expect(vault.credential(CloudPlatform.aliyun)!.field('nickname'), '另一账号');
      expect(vault.profiles(CloudPlatform.pan123).single.name, '123 昵称');
    },
  );

  test('Backups distinguish custom names from automatic nicknames', () async {
    final vault = _oldBackup(CloudPlatform.aliyun);
    await vault.putCredential(
      CloudPlatform.pan123,
      _credential('123 自动昵称', 50),
    );
    await vault.renameAccount(CloudPlatform.aliyun, 'original', '原昵称');
    final bytes = await BackupRepository(
      vault.store,
    ).create('fixture-password');
    final payload = decryptBackup((bytes, 'fixture-password'));
    final records = payload.list('cloudAccounts');
    expect(records.firstWhere((r) => r['platform'] == 'Pan123')['name'], '');
    expect(
      records.firstWhere((r) => r['platform'] == 'Aliyun')['nameIsCustom'],
      isTrue,
    );
    final restored = Vault(StateStore.memory());
    await BackupRepository(restored.store).restore(bytes, 'fixture-password');
    final ali = restored.profiles(CloudPlatform.aliyun).single;
    final pan = restored.profiles(CloudPlatform.pan123).single;
    await restored.updateAccountNickname(
      CloudPlatform.aliyun,
      ali.id,
      restored.credential(CloudPlatform.aliyun)!.updatedAt,
      '阿里刷新昵称',
    );
    await restored.updateAccountNickname(
      CloudPlatform.pan123,
      pan.id,
      restored.credential(CloudPlatform.pan123)!.updatedAt,
      '123 刷新昵称',
    );
    expect(restored.profiles(CloudPlatform.aliyun).single.name, '原昵称');
    expect(restored.profiles(CloudPlatform.aliyun).single.nickname, '阿里刷新昵称');
    expect(restored.profiles(CloudPlatform.pan123).single.name, '123 刷新昵称');
  });
}
