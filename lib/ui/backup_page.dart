import 'dart:io';
import 'dart:typed_data';
import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart';
import '../app_services.dart';
import '../core/json.dart';
import '../data/backup.dart';
import '../data/backup_targets.dart';
import '../data/classified_backup.dart';
import '../data/http.dart';
import '../data/state_store.dart';
import '../domain/models.dart';
import '../platform/document_actions.dart';
import 'app_switch.dart';
import 'browser_page.dart';
import 'common.dart';

class BackupPage extends StatefulWidget {
  const BackupPage(this.services, {super.key, this.restoring = false});
  final AppServices services;
  final bool restoring;
  @override
  State<BackupPage> createState() => _BackupPageState();
}

class _BackupPageState extends State<BackupPage> {
  AppServices get services => widget.services;
  late final repository = ClassifiedBackupRepository(
    services.store,
    backgrounds: services.backgrounds,
  );
  late final transfers = BackupTransfers(
    services.store,
    Directory('${services.dataDirectory.path}/backup-staging'),
  );
  late bool restoring = widget.restoring;
  final categories = {...ClassifiedBackupRepository.defaults};
  final accounts = <String>{};
  String location = 'local';
  Json? cloudLocation;
  bool encrypt = false;
  final password = TextEditingController(),
      confirmation = TextEditingController();
  final davUrl = TextEditingController(),
      davUser = TextEditingController(),
      davPassword = TextEditingController();

  @override
  void initState() {
    super.initState();
    final saved = services.store.data.obj('backupWebDav');
    davUrl.text = saved.str('url');
    davUser.text = saved.str('username');
    cloudLocation = services.store.data['backupCloudLocation'] is Map
        ? services.store.data.obj('backupCloudLocation')
        : null;
    services.store.addListener(_changed);
  }

  void _changed() {
    if (mounted) setState(() {});
  }

  @override
  void dispose() {
    services.store.removeListener(_changed);
    for (final controller in [
      password,
      confirmation,
      davUrl,
      davUser,
      davPassword,
    ]) {
      controller.dispose();
    }
    super.dispose();
  }

  List<CloudAccountProfile> get profiles => [
    for (final p in CloudPlatform.values) ...services.vault.profiles(p),
  ];

  Future<void> _chooseCloud() async {
    final account = await showDialog<CloudAccountProfile>(
      context: context,
      builder: (context) => SimpleDialog(
        title: const Text('选择已登录的网盘'),
        children: [
          if (profiles.isEmpty)
            const Padding(
              padding: EdgeInsets.all(24),
              child: Text('请先在网盘页面登录账号，也可以使用本地文件恢复。'),
            ),
          for (final profile in profiles)
            SimpleDialogOption(
              onPressed: () => Navigator.pop(context, profile),
              child: Text('${profile.platform.label} · ${profile.name}'),
            ),
        ],
      ),
    );
    if (account == null || !mounted) return;
    final session = await busy(
      context,
      () => services.cloud.personal(account.platform, accountId: account.id),
    );
    if (session == null || !mounted) return;
    BrowseSession selected = session;
    List<(String, String)> trail = [(session.rootId, '全部文件')];
    final parent = await Navigator.push<String>(
      context,
      MaterialPageRoute(
        builder: (_) => BrowserPage(
          services,
          session,
          picking: true,
          onDestinationPicked: (s, t) {
            selected = s;
            trail = t;
          },
        ),
      ),
    );
    if (parent == null || !mounted) return;
    if (!restoring &&
        (!selected.canManageFiles ||
            !services.cloud
                .connector(selected.platform)
                .canUploadTo(selected, parent))) {
      message(context, '当前网盘目录不支持上传，请选择其他目录');
      return;
    }
    final saved = BrowseSession(
      platform: selected.platform,
      mode: selected.mode,
      title: selected.title,
      rootId: selected.rootId,
      metadata: {
        ...selected.spaceMetadata,
        'accountId': selected.accountId ?? '',
      },
    );
    cloudLocation = {
      'kind': 'cloud',
      'session': saved.toJson(),
      'parent': parent,
      'label':
          '${account.platform.shortName} · ${account.name} / ${trail.map((e) => e.$2).join(' / ')}',
    };
    await services.store.put('backupCloudLocation', cloudLocation);
    if (mounted) setState(() {});
  }

  Json _targetDescription() => location == 'webdav'
      ? {'kind': 'webdav', 'url': davUrl.text.trim(), 'username': davUser.text}
      : cloudLocation ?? (throw const AppException('请先选择网盘账号和备份目录'));

  Future<BackupTarget> _target(Json descriptor, {String? davSecret}) async {
    if (descriptor.str('kind') == 'webdav') {
      final target = WebDavBackupTarget(
        url: descriptor.str('url'),
        username: descriptor.str('username'),
        password: davSecret ?? davPassword.text,
      );
      await services.store.put('backupWebDav', {
        'url': descriptor.str('url'),
        'username': descriptor.str('username'),
      });
      return target;
    }
    final session = await services.cloud.reopenSpace(
      BrowseSession.fromJson(descriptor.obj('session')),
    );
    return CloudBackupTarget(
      cloud: services.cloud,
      uploads: services.uploads,
      http: services.transfer,
      cleanups: services.cleanups,
      directory: transfers.directory,
      session: session,
      parent: descriptor.str('parent'),
    );
  }

  Future<void> _export() async {
    if (categories.isEmpty) {
      message(context, '请至少选择一类备份内容');
      return;
    }
    if (encrypt &&
        (password.text.length < 6 || password.text != confirmation.text)) {
      message(
        context,
        password.text.length < 6 ? '备份密码至少需要 6 位' : '两次输入的备份密码不一致',
      );
      return;
    }
    if (categories.contains(BackupCategory.accounts) && accounts.isEmpty) {
      message(context, '请勾选要备份的账号');
      return;
    }
    final saved = await busy(context, () async {
      final bytes = await repository.create(
        categories: {...categories},
        accountKeys: {...accounts},
        password: encrypt ? password.text : '',
      );
      RequestScope.checkpoint();
      if (!mounted) return false;
      if (location == 'local') {
        final result = await const DocumentActions().saveBytes(
          bytes,
          'asterlink-backup-${DateTime.now().millisecondsSinceEpoch}.json',
          mime: 'application/json',
          acceptedTypeGroups: const [backupFileType],
        );
        return result != null;
      }
      final descriptor = _targetDescription(),
          target = await _target(descriptor);
      try {
        final job = await transfers.stage(bytes, descriptor);
        await transfers.send(job, target);
        return true;
      } finally {
        target.close();
      }
    }, label: location == 'local' ? '正在生成备份…' : '正在上传并校验备份…');
    if (saved == true && mounted) {
      password.clear();
      confirmation.clear();
      message(context, '备份已保存${encrypt ? '，恢复时需要备份密码' : ''}');
    }
  }

  Future<void> _resume(Json job) async {
    String? secret;
    if (job.obj('target').str('kind') == 'webdav') {
      secret = await askText(context, '输入 WebDAV 登录密码', secret: true);
      if (secret == null || !mounted) return;
    }
    final done = await busy(context, () async {
      final target = await _target(job.obj('target'), davSecret: secret);
      try {
        await transfers.send(job, target);
        return true;
      } finally {
        target.close();
      }
    }, label: '正在继续备份并校验…');
    if (done == true && mounted) message(context, '备份已完成并通过回读校验');
  }

  Future<void> _discard(Json job) async {
    if (!await confirm(
          context,
          '放弃未完成的备份',
          '停止对应上传并移除本机暂存包。远端已有文件和以前的完整备份会保留。',
        ) ||
        !mounted) {
      return;
    }
    await busy(
      context,
      () => transfers.discard(job, services.uploads),
      cancellable: false,
    );
  }

  Future<void> _restore() async {
    List<int>? data;
    if (location == 'local') {
      final file = await openFile(acceptedTypeGroups: const [backupFileType]);
      if (file == null || !mounted) return;
      data = await busy(context, () async {
        require(await file.length() <= backupSizeLimit, '备份文件过大');
        return file.readAsBytes();
      });
    } else {
      final target = await busy(
        context,
        () => _target(_targetDescription()),
        label: '正在连接备份位置…',
      );
      if (target == null) return;
      try {
        if (!mounted) return;
        final choice = await showDialog<(BackupRemoteFile, bool)>(
          context: context,
          builder: (_) =>
              _BackupVersionsDialog(transfers: transfers, target: target),
        );
        if (choice == null || !mounted) return;
        data = await busy(
          context,
          () => transfers.download(target, choice.$1, unconfirmed: choice.$2),
          label: '正在下载并校验备份…',
        );
      } finally {
        target.close();
      }
    }
    if (data == null || !mounted) return;
    final bytes = Uint8List.fromList(data);
    final secret = isPlainBackup(bytes)
        ? ''
        : await askText(context, '输入备份密码', secret: true);
    if (secret == null || !mounted) return;
    final preview = await busy(
      context,
      () => repository.preview(bytes, secret),
      label: '正在验证备份内容…',
    );
    if (preview == null || !mounted) return;
    final choice = await showDialog<_RestoreChoice>(
      context: context,
      builder: (_) =>
          _RestorePreviewDialog(preview: preview, profiles: profiles),
    );
    if (choice == null || !mounted) return;
    final result = await busy(
      context,
      () => repository.restore(
        preview,
        categories: choice.categories,
        bindings: choice.bindings,
        replaceAccounts: choice.replaceAccounts,
      ),
      label: '正在保存回退副本并恢复…',
      cancellable: false,
    );
    if (result == null || !mounted) return;
    await _settingsChanged();
    if (mounted) {
      message(
        context,
        '已恢复所选分类${result.pending > 0 ? '，${result.pending} 组数据等待关联账号' : ''}',
      );
    }
  }

  Future<void> _settingsChanged() async {
    services.uploads.settingsChanged();
    services.rapidTransfers.settingsChanged();
    await services.downloads.settingsChanged();
  }

  Future<void> _undo() async {
    if (!await confirm(
          context,
          '回退上次恢复',
          '将上次恢复涉及的分类还原到恢复前。恢复后对这些分类的修改也会回退，下载文件保持原样。',
        ) ||
        !mounted) {
      return;
    }
    final result = await busy(
      context,
      () async {
        await repository.undo();
        return true;
      },
      label: '正在回退恢复…',
      cancellable: false,
    );
    if (result == true) {
      await _settingsChanged();
      if (mounted) message(context, '已回退上次恢复');
    }
  }

  Future<void> _bind(Json item) async {
    final ref = item.obj('account');
    final candidates = profiles
        .where((p) => p.platform.key == ref.str('platform'))
        .toList();
    final id = await showDialog<String>(
      context: context,
      builder: (context) => SimpleDialog(
        title: const Text('关联到本机账号'),
        children: [
          const Padding(
            padding: EdgeInsets.symmetric(horizontal: 24, vertical: 8),
            child: Text('请选择原来保存这些文件的同一个网盘账号。'),
          ),
          if (candidates.isEmpty)
            const Padding(
              padding: EdgeInsets.all(24),
              child: Text('请先在网盘页面登录对应账号。'),
            ),
          for (final account in candidates)
            SimpleDialogOption(
              onPressed: () => Navigator.pop(context, account.id),
              child: Text(account.name),
            ),
        ],
      ),
    );
    if (id == null || !mounted) return;
    final result = await busy(
      context,
      () => repository.bindPending(item, id),
      cancellable: false,
    );
    if (result != null && mounted) message(context, '已关联账号并恢复记录');
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: const Text('备份与恢复')),
    body: Align(
      alignment: Alignment.topCenter,
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 760),
        child: ListView(
          padding: const EdgeInsets.all(16),
          children: [
            SegmentedButton<bool>(
              segments: const [
                ButtonSegment(value: false, label: Text('备份')),
                ButtonSegment(value: true, label: Text('恢复')),
              ],
              selected: {restoring},
              onSelectionChanged: (value) =>
                  setState(() => restoring = value.single),
            ),
            const SizedBox(height: 16),
            const Text('本地数据不加密。备份可单独设置密码；密码不会保存，遗忘后无法解密。'),
            const SizedBox(height: 16),
            DropdownButtonFormField<String>(
              initialValue: location,
              decoration: InputDecoration(
                labelText: restoring ? '恢复来源' : '保存位置',
                border: const OutlineInputBorder(),
              ),
              items: const [
                DropdownMenuItem(value: 'local', child: Text('本地文件')),
                DropdownMenuItem(value: 'webdav', child: Text('WebDAV')),
                DropdownMenuItem(value: 'cloud', child: Text('已登录网盘')),
              ],
              onChanged: (value) => setState(() => location = value!),
            ),
            if (location == 'webdav') ...[
              const SizedBox(height: 12),
              TextField(
                controller: davUrl,
                keyboardType: TextInputType.url,
                decoration: const InputDecoration(
                  labelText: 'WebDAV 目录地址',
                  hintText: 'https://example.com/dav/backups/',
                ),
              ),
              TextField(
                controller: davUser,
                decoration: const InputDecoration(labelText: 'WebDAV 用户名'),
              ),
              TextField(
                controller: davPassword,
                obscureText: true,
                enableSuggestions: false,
                autocorrect: false,
                decoration: const InputDecoration(
                  labelText: 'WebDAV 登录密码（仅本次使用）',
                ),
              ),
              Align(
                alignment: Alignment.centerLeft,
                child: TextButton(
                  onPressed: () async {
                    final ok = await busy(context, () async {
                      final target =
                          await _target(_targetDescription())
                              as WebDavBackupTarget;
                      try {
                        await target.test();
                        return true;
                      } finally {
                        target.close();
                      }
                    }, label: '正在测试目录读写与删除…');
                    if (ok == true && context.mounted) {
                      message(context, '目录读写、回读和删除测试通过');
                    }
                  },
                  child: const Text('测试连接与读写'),
                ),
              ),
            ],
            if (location == 'cloud')
              ListTile(
                contentPadding: EdgeInsets.zero,
                title: const Text('备份目录'),
                subtitle: Text(cloudLocation?.str('label') ?? '选择账号与目录'),
                trailing: const Icon(Icons.chevron_right),
                onTap: _chooseCloud,
              ),
            if (!restoring) ...[
              const SizedBox(height: 12),
              for (final category in BackupCategory.values) ...[
                CheckboxListTile(
                  contentPadding: EdgeInsets.zero,
                  value: categories.contains(category),
                  title: Text(category.label),
                  subtitle: Text(category.description),
                  onChanged: (value) => setState(() {
                    if (value == true) {
                      categories.add(category);
                    } else {
                      categories.remove(category);
                    }
                  }),
                ),
                if (category == BackupCategory.accounts &&
                    categories.contains(category)) ...[
                  if (profiles.isEmpty) const Text('当前没有已登录账号'),
                  for (final profile in profiles)
                    Padding(
                      padding: const EdgeInsets.only(left: 16),
                      child: CheckboxListTile(
                        contentPadding: EdgeInsets.zero,
                        title: Text(
                          '${profile.platform.shortName} · ${profile.name}',
                        ),
                        value: accounts.contains(
                          backupAccountKey(profile.platform.key, profile.id),
                        ),
                        onChanged: (value) => setState(() {
                          final key = backupAccountKey(
                            profile.platform.key,
                            profile.id,
                          );
                          if (value == true) {
                            accounts.add(key);
                          } else {
                            accounts.remove(key);
                          }
                        }),
                      ),
                    ),
                ],
              ],
              const Divider(),
              ListTile(
                contentPadding: EdgeInsets.zero,
                title: const Text('使用密码加密备份'),
                subtitle: Text(encrypt ? '仅加密导出文件，本地数据仍为明文' : '生成明文备份文件'),
                trailing: AppSwitch(
                  value: encrypt,
                  onChanged: (value) => setState(() => encrypt = value),
                ),
              ),
              if (encrypt) ...[
                TextField(
                  controller: password,
                  obscureText: true,
                  enableSuggestions: false,
                  autocorrect: false,
                  decoration: const InputDecoration(labelText: '备份密码（至少 6 位）'),
                ),
                TextField(
                  controller: confirmation,
                  obscureText: true,
                  enableSuggestions: false,
                  autocorrect: false,
                  decoration: const InputDecoration(labelText: '再次输入备份密码'),
                ),
              ],
            ],
            const SizedBox(height: 20),
            FilledButton.icon(
              onPressed: restoring ? _restore : _export,
              icon: Icon(restoring ? Icons.restore : Icons.backup_outlined),
              label: Text(restoring ? '选择备份并预览' : '立即备份'),
            ),
            if (repository.canUndo)
              TextButton(onPressed: _undo, child: const Text('回退上次恢复')),
            if (transfers.pending.isNotEmpty) ...[
              const Divider(),
              const Text('未完成的远程备份'),
              for (final job in transfers.pending)
                ListTile(
                  contentPadding: EdgeInsets.zero,
                  title: Text(job.str('name'), maxLines: 2),
                  subtitle: Text(
                    job
                        .obj('target')
                        .str('label')
                        .ifEmpty(job.obj('target').str('url')),
                  ),
                  trailing: Wrap(
                    children: [
                      TextButton(
                        onPressed: () => _resume(job),
                        child: const Text('继续'),
                      ),
                      IconButton(
                        onPressed: () => _discard(job),
                        tooltip: '放弃此备份',
                        icon: const Icon(Icons.close),
                      ),
                    ],
                  ),
                ),
            ],
            if (repository.pending.isNotEmpty) ...[
              const Divider(),
              const Text('待关联账号的数据'),
              for (final item in repository.pending)
                ListTile(
                  contentPadding: EdgeInsets.zero,
                  title: Text(
                    '${CloudPlatform.fromKey(item.obj('account').str('platform'))?.label ?? ''} · ${item.obj('account').str('name').ifEmpty('原账号')}',
                  ),
                  subtitle: const Text('记录已保留，关联原账号后即可使用'),
                  trailing: TextButton(
                    onPressed: () => _bind(item),
                    child: const Text('关联'),
                  ),
                ),
            ],
          ],
        ),
      ),
    ),
  );
}

class _BackupVersionsDialog extends StatefulWidget {
  const _BackupVersionsDialog({required this.transfers, required this.target});
  final BackupTransfers transfers;
  final BackupTarget target;
  @override
  State<_BackupVersionsDialog> createState() => _BackupVersionsDialogState();
}

class _BackupVersionsDialogState extends State<_BackupVersionsDialog> {
  bool unconfirmed = false;
  late Future<List<BackupRemoteFile>> files = widget.transfers.versions(
    widget.target,
  );
  @override
  Widget build(BuildContext context) => AlertDialog(
    title: const Text('选择备份版本'),
    content: SizedBox(
      width: 540,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          CheckboxListTile(
            contentPadding: EdgeInsets.zero,
            title: const Text('显示旧版或未确认文件'),
            subtitle: const Text('恢复前仍会验证文件内容'),
            value: unconfirmed,
            onChanged: (value) => setState(() {
              unconfirmed = value ?? false;
              files = widget.transfers.versions(
                widget.target,
                includeUnconfirmed: unconfirmed,
              );
            }),
          ),
          Flexible(
            child: FutureBuilder<List<BackupRemoteFile>>(
              future: files,
              builder: (context, snapshot) {
                if (snapshot.hasError) {
                  return Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(errorText(snapshot.error!)),
                      TextButton(
                        onPressed: () => setState(() {
                          files = widget.transfers.versions(
                            widget.target,
                            includeUnconfirmed: unconfirmed,
                          );
                        }),
                        child: const Text('重试'),
                      ),
                    ],
                  );
                }
                if (!snapshot.hasData) {
                  return const Padding(
                    padding: EdgeInsets.all(24),
                    child: CircularProgressIndicator(),
                  );
                }
                if (snapshot.data!.isEmpty) {
                  return const Padding(
                    padding: EdgeInsets.all(16),
                    child: Text('此目录没有已完成的备份'),
                  );
                }
                return ListView(
                  shrinkWrap: true,
                  children: [
                    for (final file in snapshot.data!)
                      ListTile(
                        title: Text(file.name),
                        subtitle: Text(
                          '${(file.size / 1024).toStringAsFixed(1)} KB',
                        ),
                        onTap: () =>
                            Navigator.pop(context, (file, unconfirmed)),
                      ),
                  ],
                );
              },
            ),
          ),
        ],
      ),
    ),
    actions: [
      TextButton(
        onPressed: () => Navigator.pop(context),
        child: const Text('取消'),
      ),
    ],
  );
}

class _RestoreChoice {
  const _RestoreChoice(this.categories, this.bindings, this.replaceAccounts);
  final Set<BackupCategory> categories;
  final Map<String, String> bindings;
  final bool replaceAccounts;
}

class _RestorePreviewDialog extends StatefulWidget {
  const _RestorePreviewDialog({required this.preview, required this.profiles});
  final BackupPreview preview;
  final List<CloudAccountProfile> profiles;
  @override
  State<_RestorePreviewDialog> createState() => _RestorePreviewDialogState();
}

class _RestorePreviewDialogState extends State<_RestorePreviewDialog> {
  late final categories = {...widget.preview.categories};
  final bindings = <String, String>{};
  bool replace = false;
  @override
  Widget build(BuildContext context) => AlertDialog(
    title: const Text('预览与分类恢复'),
    content: SizedBox(
      width: 600,
      child: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              '备份时间：${widget.preview.createdAt > 0 ? DateTime.fromMillisecondsSinceEpoch(widget.preview.createdAt).toLocal().toString().split('.').first : '未知'}',
            ),
            const SizedBox(height: 8),
            const Text('只恢复勾选内容。收藏和历史合并，账号默认保留本机登录状态，下载目录保持本机设置。'),
            if (widget.preview.unknownCategories.isNotEmpty)
              Text(
                '以下分类需要更新版本，本次跳过：${widget.preview.unknownCategories.join('、')}',
              ),
            for (final category in widget.preview.categories)
              CheckboxListTile(
                contentPadding: EdgeInsets.zero,
                title: Text(
                  '${category.label} · ${widget.preview.count(category)} 项',
                ),
                value: categories.contains(category),
                onChanged: (value) => setState(() {
                  if (value == true) {
                    categories.add(category);
                  } else {
                    categories.remove(category);
                  }
                }),
              ),
            if (categories.contains(BackupCategory.accounts))
              CheckboxListTile(
                contentPadding: EdgeInsets.zero,
                title: const Text('替换对应账号的现有登录信息'),
                value: replace,
                onChanged: (value) => setState(() => replace = value ?? false),
              ),
            if (categories.any(
              (c) => {
                BackupCategory.accounts,
                BackupCategory.favorites,
                BackupCategory.playback,
                BackupCategory.history,
              }.contains(c),
            )) ...[
              const Divider(),
              const Text('账号关联（请选择原来的同一个账号）'),
              for (final ref in widget.preview.accounts)
                Builder(
                  builder: (context) {
                    final key = backupAccountKey(
                      ref.str('platform'),
                      ref.str('id'),
                    );
                    final matches = widget.profiles
                        .where((p) => p.platform.key == ref.str('platform'))
                        .toList();
                    return Padding(
                      padding: const EdgeInsets.only(top: 12),
                      child: DropdownButtonFormField<String>(
                        isExpanded: true,
                        decoration: InputDecoration(
                          labelText:
                              '${CloudPlatform.fromKey(ref.str('platform'))?.shortName ?? ''} · ${ref.str('name').ifEmpty(ref.str('id'))}',
                        ),
                        initialValue: bindings[key] ?? '',
                        items: [
                          const DropdownMenuItem(
                            value: '',
                            child: Text('按原编号恢复，未登录则待关联'),
                          ),
                          for (final account in matches)
                            DropdownMenuItem(
                              value: account.id,
                              child: Text(
                                account.name,
                                overflow: TextOverflow.ellipsis,
                              ),
                            ),
                        ],
                        onChanged: (value) => setState(() {
                          if (value == null || value.isEmpty) {
                            bindings.remove(key);
                          } else {
                            bindings[key] = value;
                          }
                        }),
                      ),
                    );
                  },
                ),
            ],
          ],
        ),
      ),
    ),
    actions: [
      TextButton(
        onPressed: () => Navigator.pop(context),
        child: const Text('取消'),
      ),
      FilledButton(
        onPressed: categories.isEmpty
            ? null
            : () => Navigator.pop(
                context,
                _RestoreChoice({...categories}, {...bindings}, replace),
              ),
        child: const Text('恢复所选内容'),
      ),
    ],
  );
}
