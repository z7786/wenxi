import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:crypto/crypto.dart';
import '../core/crypto_box.dart';
import '../core/json.dart';
import '../domain/models.dart';
import '../domain/settings.dart';
import 'state_store.dart';
import 'http.dart';
import 'cloud_favorites.dart';
import 'backgrounds.dart';
import '../domain/background.dart';

const backupSecretKeys = {
  'pan123.login_uuid',
  'pan123.access_token',
  'xunlei.device_id',
  'xunlei.peer_id',
  'xunlei.device_sign',
};

Uint8List encodePlainBackup(Json payload) => Uint8List.fromList(
  utf8.encode(
    const JsonEncoder.withIndent('  ').convert({
      'format': 'asterlink-backup-v2',
      'sha256': sha256.convert(utf8.encode(jsonEncode(payload))).toString(),
      'data': payload,
    }),
  ),
);

bool isPlainBackup(Uint8List bytes) {
  try {
    return asJson(jsonDecode(utf8.decode(bytes))).str('format') ==
        'asterlink-backup-v2';
  } catch (_) {
    return false;
  }
}

Uint8List encryptBackup((Json, String) input) {
  final salt = CryptoBox.random(16);
  final actualKey = CryptoBox.derive(input.$2, salt, 210000);
  try {
    final packed = CryptoBox.seal(actualKey, utf8.encode(jsonEncode(input.$1)));
    return Uint8List.fromList(
      utf8.encode(
        const JsonEncoder.withIndent('  ').convert({
          'format': 'asterlink-backup-v1',
          'kdf': 'PBKDF2WithHmacSHA1',
          'iterations': 210000,
          'salt': base64Encode(salt),
          'iv': base64Encode(packed.sublist(0, 12)),
          'data': base64Encode(packed.sublist(12)),
        }),
      ),
    );
  } finally {
    actualKey.fillRange(0, actualKey.length, 0);
  }
}

Json decryptBackup((Uint8List, String) input) {
  require(input.$1.length <= 16 * 1024 * 1024, '备份文件过大');
  Json envelope;
  try {
    envelope = asJson(jsonDecode(utf8.decode(input.$1)));
  } catch (_) {
    throw const AppException('不是有效的文析助手备份文件');
  }
  if (envelope.str('format') == 'asterlink-backup-v2') {
    require(envelope['data'] is Map, '备份文件已损坏');
    final payload = envelope.obj('data');
    require(
      envelope.str('sha256') ==
          sha256.convert(utf8.encode(jsonEncode(payload))).toString(),
      '备份文件已损坏',
    );
    require(
      {'com.asterlink.app', 'com.wenxi.app'}.contains(payload.str('package')),
      '备份文件不属于当前应用',
    );
    require(payload.integer('schema', 1) == 1, '此备份版本暂不支持');
    return payload;
  }
  require(input.$2.length >= 6, '备份密码至少需要 6 位');
  require(
    {'asterlink-backup-v1', 'wenxi-backup-v1'}.contains(envelope.str('format')),
    '不是有效的文析助手备份文件',
  );
  require(
    envelope.str('kdf', 'PBKDF2WithHmacSHA1') == 'PBKDF2WithHmacSHA1',
    '不支持此备份的加密方式',
  );
  Uint8List salt, iv, encrypted;
  try {
    salt = base64Decode(envelope.str('salt'));
    iv = base64Decode(envelope.str('iv'));
    encrypted = base64Decode(envelope.str('data'));
  } catch (_) {
    throw const AppException('备份文件已损坏');
  }
  require(iv.length == 12 && encrypted.length >= 16, '备份文件已损坏');
  final key = CryptoBox.derive(
    input.$2,
    salt,
    envelope.integer('iterations', 210000),
  );
  try {
    Json payload;
    try {
      payload = asJson(
        jsonDecode(utf8.decode(CryptoBox.open(key, [...iv, ...encrypted]))),
      );
    } catch (_) {
      throw const AppException('备份密码错误或文件已损坏');
    }
    require(
      {'com.asterlink.app', 'com.wenxi.app'}.contains(payload.str('package')),
      '备份文件不属于当前应用',
    );
    require(payload.integer('schema', 1) == 1, '此备份版本暂不支持');
    return payload;
  } finally {
    key.fillRange(0, key.length, 0);
  }
}

class BackupRepository {
  BackupRepository(this.store, {this.backgrounds});
  final StateStore store;
  final BackgroundRepository? backgrounds;
  Future<Uint8List> create(
    String password, {
    bool includeBackgroundImages = false,
  }) async {
    final credentials = store.data.obj('credentials'),
        secrets = store.data.obj('secrets');
    final vault = Vault(store);
    final profiles = [
      for (final p in CloudPlatform.values) ...vault.profiles(p),
    ];
    final settings = AppSettings.fromJson(store.data.obj('settings')).toJson()
      ..remove('destination');
    final background = BackgroundSettings.fromJson(settings.obj('background'));
    final images = includeBackgroundImages && background.hasImage
        ? await backgrounds?.exportImages(background)
        : null;
    require(
      !includeBackgroundImages || !background.hasImage || images != null,
      '当前环境无法备份背景图片',
    );
    if (images == null) {
      settings['background'] = background.withoutImages().toJson();
    }
    final bytes = await compute(encodePlainBackup, {
      'schema': 1,
      'package': 'com.asterlink.app',
      'createdAt': DateTime.now().millisecondsSinceEpoch,
      'settings': settings,
      'backgroundImages': ?images,
      'credentials': [
        for (final p in CloudPlatform.values)
          if (credentials[p.key] != null)
            {'platform': p.key, 'credential': credentials[p.key]},
      ],
      'secrets': {
        for (final k in backupSecretKeys)
          if (secrets[k] != null) k: secrets[k],
      },
      'cloudAccounts': [
        for (final account in profiles)
          {
            'id': account.id,
            'platform': account.platform.key,
            'name': account.customName,
            'nameIsCustom': account.customName.isNotEmpty,
            'credential': vault
                .credentialFor(account.platform, account.id)!
                .toJson(),
            'secrets': vault.withAccount(
              account.platform,
              account.id,
              () => {
                for (final key in backupSecretKeys)
                  if (Vault.accountSecret(account.platform, key) &&
                      vault.secret(key) != null)
                    key: vault.secret(key),
              },
            ),
          },
      ],
      'activeCloudAccounts': {
        for (final account in profiles)
          if (account.active) account.platform.key: account.id,
      },
      'cloudFavorites': store.data.list('cloudFavorites'),
      'cloudFavoriteSort': CloudFavoriteSort.fromName(
        store.data.str('cloudFavoriteSort'),
      ).name,
    });
    require(bytes.length <= 16 * 1024 * 1024, '备份文件过大，请取消携带背景图后重试');
    return bytes;
  }

  /// Exported v2 backups are plain data; v1 imports still accept their password.
  Future<bool> exportTo(
    String password,
    Future<bool> Function(Uint8List bytes) save, {
    bool includeBackgroundImages = false,
  }) async {
    final bytes = await create(
      password,
      includeBackgroundImages: includeBackgroundImages,
    );
    RequestScope.checkpoint();
    if (!await save(bytes)) return false;
    return true;
  }

  Future<int> restore(Uint8List bytes, String password) async {
    final payload = await compute(decryptBackup, (bytes, password));
    // Parse everything before the single commit. Wrong password/partial payloads
    // cannot leave a half-restored set of credentials and settings.
    final credentials = <String, dynamic>{};
    for (final item in payload.list('credentials')) {
      final p = CloudPlatform.fromKey(item.str('platform'));
      if (p == null) continue;
      require(
        item['credential'] is Map && item.obj('credential')['fields'] is Map,
        '备份凭据格式错误',
      );
      final old = Credential.fromJson(item.obj('credential'));
      credentials[p.key] = Credential(old.label, old.fields).toJson();
    }
    final secrets = payload.obj('secrets');
    final settings = payload['settings'] == null
        ? null
        : AppSettings.fromJson(
            payload.obj('settings'),
          ).update({'destination': null}).toJson();
    List<Json>? accounts;
    final favorites = <Json>[];
    if (payload.containsKey('cloudAccounts')) {
      require(
        payload['cloudAccounts'] is List &&
            (payload['cloudAccounts'] as List).length <= 1000 &&
            (payload['cloudAccounts'] as List).every((item) => item is Map) &&
            payload['activeCloudAccounts'] is Map,
        '备份账号列表格式错误',
      );
      accounts = [];
      final seen = <String>{};
      for (final item in payload.list('cloudAccounts')) {
        final platform = CloudPlatform.fromKey(item.str('platform'));
        if (platform == null || !platform.requiresAccount) continue;
        final id = item.str('id');
        require(
          RegExp(r'^[a-zA-Z0-9_-]{1,100}$').hasMatch(id) &&
              seen.add('${platform.key}/$id') &&
              item.obj('credential')['fields'] is Map,
          '备份账号格式错误',
        );
        accounts.add({
          'id': id,
          'platform': platform.key,
          'name': item.str('name'),
          if (item.containsKey('nameIsCustom'))
            'nameIsCustom': item.boolean('nameIsCustom'),
          'credential': Credential.fromJson(item.obj('credential')).toJson(),
          'secrets': {
            for (final entry in item.obj('secrets').entries)
              if (backupSecretKeys.contains(entry.key) &&
                  Vault.accountSecret(platform, entry.key))
                entry.key: entry.value.toString(),
          },
        });
      }
      for (final selection in payload.obj('activeCloudAccounts').entries) {
        if (CloudPlatform.fromKey(selection.key) == null) continue;
        require(
          accounts.any(
            (a) =>
                a.str('platform') == selection.key &&
                a.str('id') == selection.value,
          ),
          '备份的当前账号不存在',
        );
      }
      require(
        payload['cloudFavorites'] == null ||
            payload['cloudFavorites'] is List &&
                (payload['cloudFavorites'] as List).every(
                  (item) => item is Map,
                ),
        '备份收藏格式错误',
      );
      for (final raw in payload.list('cloudFavorites')) {
        final favorite = CloudFavorite.fromJson(raw);
        require(
          favorite.id.isNotEmpty &&
              favorite.file.id.isNotEmpty &&
              (!favorite.isShareLink ||
                  favorite.session.mode == BrowseMode.share &&
                      favorite.session.sourceLink != null &&
                      favorite.file.isDirectory) &&
              favorite.trail.isNotEmpty &&
              favorite.trail.length <= 64,
          '备份收藏目录不完整',
        );
        favorites.add(favorite.toJson());
      }
      require(favorites.length <= 2000, '备份收藏数量过多');
    }
    Object? backgroundDraft;
    try {
      if (settings != null) {
        final background = BackgroundSettings.fromJson(
          settings.obj('background'),
        );
        if (backgrounds != null) {
          backgroundDraft = backgrounds!.beginDraft();
          settings['background'] = (await backgrounds!.restoreImages(
            background,
            payload['backgroundImages'],
            backgroundDraft,
          )).toJson();
        } else {
          settings['background'] = background.withoutImages().toJson();
        }
      }
      await store.change((draft) {
        Vault.migrateDraft(draft);
        if (accounts != null) {
          final all = draft.obj('cloudAccounts');
          for (final item in accounts) {
            final platform = CloudPlatform.fromKey(item.str('platform'))!;
            final records = all.obj(platform.key);
            var revision = DateTime.now().millisecondsSinceEpoch;
            for (final record in records.values) {
              final previous = asJson(
                record,
              ).obj('credential').integer('updatedAt');
              if (revision <= previous) revision = previous + 1;
            }
            final restored = Credential.fromJson(item.obj('credential'));
            records[item.str('id')] = {
              'name': item.str('name'),
              if (item.containsKey('nameIsCustom'))
                'nameIsCustom': item.boolean('nameIsCustom'),
              'secrets': item.obj('secrets'),
              'credential': Credential(
                restored.label,
                restored.fields,
                updatedAt: revision,
              ).toJson(),
            };
            all[platform.key] = records;
          }
          draft['cloudAccounts'] = all;
          for (final platform in CloudPlatform.values) {
            final selected = payload
                .obj('activeCloudAccounts')
                .str(platform.key)
                .ifEmpty(Vault.activeIdIn(draft, platform) ?? '');
            if (selected.isNotEmpty) {
              Vault.activateDraft(draft, platform, selected);
            }
          }
          final merged = {
            for (final f in draft.list('cloudFavorites')) f.str('id'): f,
          };
          for (final f in favorites) {
            final owner = f.str('accountId'),
                platform = CloudPlatform.fromKey(f.str('platform'))!;
            if (owner.isEmpty ||
                Vault.credentialIn(draft, platform, owner) != null) {
              merged[f.str('id')] = f;
            }
          }
          require(merged.length <= 2000, '合并后收藏超过 2000 项，请先清理收藏');
          draft['cloudFavorites'] = merged.values.toList();
          if (payload.containsKey('cloudFavoriteSort')) {
            draft['cloudFavoriteSort'] = CloudFavoriteSort.fromName(
              payload.str('cloudFavoriteSort'),
            ).name;
          }
          if (settings != null) draft['settings'] = settings;
          return;
        }
        // Account revisions invalidate pending requests and saved download sources.
        // A restore must advance them even when two changes share a millisecond.
        for (final entry in credentials.entries.toList()) {
          final restored = Credential.fromJson(asJson(entry.value));
          final previous = draft
              .obj('credentials')
              .obj(entry.key)
              .integer('updatedAt');
          final now = DateTime.now().millisecondsSinceEpoch;
          credentials[entry.key] = Credential(
            restored.label,
            restored.fields,
            updatedAt: now > previous ? now : previous + 1,
          ).toJson();
        }
        draft['credentials'] = {...draft.obj('credentials'), ...credentials};
        final previousSecrets = draft.obj('secrets');
        if (credentials.containsKey(CloudPlatform.pan123.key)) {
          previousSecrets.remove('pan123.access_token');
        }
        draft['secrets'] = {
          ...previousSecrets,
          for (final k in backupSecretKeys)
            if (secrets[k] != null) k: secrets[k],
        };
        if (settings != null) draft['settings'] = settings;
        Vault.migrateDraft(draft);
      }, recoveryPassword: password);
    } finally {
      if (backgroundDraft != null) await backgrounds!.endDraft(backgroundDraft);
    }
    return accounts?.length ?? credentials.length;
  }
}
