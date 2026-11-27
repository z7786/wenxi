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
import '../data/providers/webdav.dart';
import '../domain/models.dart';
import '../platform/document_actions.dart';
import 'app_switch.dart';
import 'browser_page.dart';
import 'cloud_accounts_page.dart';
import 'common.dart';
import 'login_page.dart';

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
  final _scroll = ScrollController();
  bool _working = false, _passwordVisible = false, _confirmationVisible = false;

  @override
  void initState() {
    super.initState();
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
    _scroll.dispose();
    for (final controller in [password, confirmation]) {
      controller.dispose();
    }
    super.dispose();
  }

  List<CloudAccountProfile> get profiles => [
    for (final p in CloudPlatform.values) ...services.vault.profiles(p),
  ];

  Future<void> _chooseCloud() async {
    final choice = await showDialog<String>(
      context: context,
      builder: (context) => SimpleDialog(
        title: const Text('选择网盘账号'),
        children: [
          if (profiles.isEmpty)
            const Padding(
              padding: EdgeInsets.all(24),
              child: Text('先添加网盘账号，再选择存放备份的目录。'),
            ),
          for (final profile in profiles)
            SimpleDialogOption(
              onPressed: () => Navigator.pop(
                context,
                backupAccountKey(profile.platform.key, profile.id),
              ),
              child: Row(
                children: [
                  PlatformMark(platform: profile.platform, size: 30),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(profile.name),
                        Text(
                          profile.platform.label,
                          style: TextStyle(
                            color: secondary(context),
                            fontSize: 12,
                          ),
                        ),
                      ],
                    ),
                  ),
                  const Icon(Icons.chevron_right, size: 20),
                ],
              ),
            ),
          const Divider(),
          SimpleDialogOption(
            onPressed: () => Navigator.pop(context, 'webdav'),
            child: const Row(
              children: [
                PlatformMark(platform: CloudPlatform.webdav, size: 30),
                SizedBox(width: 12),
                Expanded(child: Text('添加 WebDAV 连接')),
              ],
            ),
          ),
          SimpleDialogOption(
            onPressed: () => Navigator.pop(context, 'manage'),
            child: const Row(
              children: [
                SizedBox(
                  width: 30,
                  child: Icon(Icons.manage_accounts_outlined),
                ),
                SizedBox(width: 12),
                Expanded(child: Text('管理网盘账号')),
              ],
            ),
          ),
        ],
      ),
    );
    if (choice == null || !mounted) return;
    CloudAccountProfile? account;
    if (choice == 'manage') {
      await Navigator.push<void>(
        context,
        MaterialPageRoute(builder: (_) => CloudAccountsPage(services)),
      );
      if (mounted) await _chooseCloud();
      return;
    }
    if (choice == 'webdav') {
      final before = services.vault.credential(CloudPlatform.webdav)?.updatedAt;
      await openLogin(
        context,
        services,
        CloudPlatform.webdav,
        addAccount: true,
      );
      if (!mounted ||
          services.vault.credential(CloudPlatform.webdav)?.updatedAt ==
              before) {
        return;
      }
      account = services.vault
          .profiles(CloudPlatform.webdav)
          .where((p) => p.active)
          .firstOrNull;
    } else {
      account = profiles
          .where((p) => backupAccountKey(p.platform.key, p.id) == choice)
          .firstOrNull;
    }
    if (account == null || !mounted) return;
    final selectedAccount = account;
    if (!await _ensureWebDavLogin(
          selectedAccount.platform,
          selectedAccount.id,
        ) ||
        !mounted) {
      return;
    }
    final session = await busy(
      context,
      () => services.cloud.personal(
        selectedAccount.platform,
        accountId: selectedAccount.id,
      ),
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
        if (selected.platform == CloudPlatform.webdav)
          'webdavRoot': selected.meta('webdavRoot'),
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

  Json _targetDescription() =>
      cloudLocation ?? (throw const AppException('请先选择网盘账号和备份目录'));

  Future<bool> _ensureWebDavLogin(CloudPlatform platform, String? id) async {
    if (platform != CloudPlatform.webdav) return true;
    final connector = services.cloud.connector(platform) as WebDavConnector;
    final credential = services.vault.credentialFor(platform, id);
    require(credential != null, 'WebDAV 账号已移除，请重新选择备份目录');
    if (connector.hasPassword(credential!)) return true;
    await openLogin(context, services, platform, accountId: id);
    final current = services.vault.credentialFor(platform, id);
    return mounted && current != null && connector.hasPassword(current);
  }

  Future<BackupTarget?> _connectTarget(Json descriptor) async {
    String? secret;
    if (descriptor.str('kind') == 'webdav') {
      secret = await askText(context, '输入 WebDAV 登录密码', secret: true);
      if (secret == null || !mounted) return null;
    } else {
      final session = BrowseSession.fromJson(descriptor.obj('session'));
      if (!await _ensureWebDavLogin(session.platform, session.accountId) ||
          !mounted) {
        return null;
      }
    }
    return busy(
      context,
      () => _target(descriptor, davSecret: secret),
      label: '正在连接备份位置…',
    );
  }

  Future<BackupTarget> _target(Json descriptor, {String? davSecret}) async {
    if (descriptor.str('kind') == 'webdav') {
      final target = WebDavBackupTarget(
        url: descriptor.str('url'),
        username: descriptor.str('username'),
        password: davSecret ?? '',
      );
      return target;
    }
    final previous = BrowseSession.fromJson(descriptor.obj('session'));
    final session = await services.cloud.reopenSpace(previous);
    if (session.platform == CloudPlatform.webdav) {
      final connector =
          services.cloud.connector(session.platform) as WebDavConnector;
      final credential = services.cloud.sessionCredential(session)!;
      require(
        previous.meta('webdavRoot').isEmpty ||
            previous.meta('webdavRoot') == session.meta('webdavRoot'),
        'WebDAV 地址已变化，请重新选择备份目录',
      );
      final directory = connector
          .location(session, credential)
          .uri(descriptor.str('parent'), directory: true);
      return WebDavBackupTarget(
        url: directory.toString(),
        username: credential.field('username'),
        password: connector.password(credential),
        connection: connector.client,
        guard: () {
          services.cloud.ensureAvailable(session.platform);
          require(
            services.cloud.sessionCredential(session)?.updatedAt ==
                credential.updatedAt,
            'WebDAV 账号已变化，请重新选择备份目录',
          );
        },
      );
    }
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
    final descriptor = location == 'local' ? null : _targetDescription();
    final target = descriptor == null ? null : await _connectTarget(descriptor);
    if (descriptor != null && target == null || !mounted) {
      target?.close();
      return;
    }
    bool? saved;
    try {
      saved = await busy(context, () async {
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
        final job = await transfers.stage(bytes, descriptor!);
        await transfers.send(job, target!);
        return true;
      }, label: location == 'local' ? '正在生成备份…' : '正在上传并校验备份…');
    } finally {
      target?.close();
    }
    if (saved == true && mounted) {
      password.clear();
      confirmation.clear();
      message(context, '备份已保存${encrypt ? '，恢复时需要备份密码' : ''}');
    }
  }

  Future<void> _resume(Json job) async {
    final target = await _connectTarget(job.obj('target'));
    if (target == null || !mounted) {
      target?.close();
      return;
    }
    final done = await busy(context, () async {
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
      final target = await _connectTarget(_targetDescription());
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
              child: Row(
                children: [
                  PlatformMark(platform: account.platform, size: 30),
                  const SizedBox(width: 12),
                  Expanded(child: Text(account.name)),
                ],
              ),
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

  Future<void> _perform(Future<void> Function() action) async {
    if (_working) return;
    FocusScope.of(context).unfocus();
    setState(() => _working = true);
    try {
      await action();
    } catch (error) {
      if (mounted) message(context, errorText(error));
    } finally {
      if (mounted) setState(() => _working = false);
    }
  }

  void _setCategory(BackupCategory category, bool selected) {
    setState(() {
      if (selected) {
        categories.add(category);
      } else {
        categories.remove(category);
      }
    });
  }

  Widget _locationSection() => _BackupSection(
    title: restoring ? '恢复来源' : '保存位置',
    icon: Icons.folder_outlined,
    children: [
      SegmentedButton<String>(
        segments: const [
          ButtonSegment(
            value: 'local',
            label: Text('本地文件'),
            icon: Icon(Icons.description_outlined),
          ),
          ButtonSegment(
            value: 'cloud',
            label: Text('网盘'),
            icon: Icon(Icons.cloud_outlined),
          ),
        ],
        selected: {location},
        showSelectedIcon: false,
        onSelectionChanged: _working
            ? null
            : (value) => setState(() => location = value.single),
      ),
      const SizedBox(height: 16),
      if (location == 'local')
        _BackupNote(
          icon: Icons.description_outlined,
          text: restoring ? '选择本机备份文件，查看内容后再恢复。' : '生成备份文件，自行选择保存位置。',
        )
      else ...[
        Material(
          color: fill(context),
          borderRadius: BorderRadius.circular(12),
          clipBehavior: Clip.antiAlias,
          child: ListTile(
            key: const Key('backup-target'),
            contentPadding: const EdgeInsets.symmetric(
              horizontal: 14,
              vertical: 6,
            ),
            leading: switch (CloudPlatform.fromKey(
              cloudLocation?.obj('session').str('platform'),
            )) {
              final platform? => PlatformMark(platform: platform, size: 30),
              null => const Icon(Icons.folder_open_outlined),
            },
            title: Text(
              cloudLocation == null ? '选择网盘与目录' : '已选目录',
              style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w600),
            ),
            subtitle: Text(
              cloudLocation?.str('label') ?? '支持已登录网盘与 WebDAV',
              maxLines: 3,
              overflow: TextOverflow.ellipsis,
            ),
            trailing: const Icon(Icons.chevron_right, size: 20),
            onTap: _working ? null : () => _perform(_chooseCloud),
          ),
        ),
        const SizedBox(height: 12),
        Text(
          restoring ? '读取目录中的备份版本，下载并校验后预览。' : '上传完成后会回读校验，保留以前的完整版本。',
          style: TextStyle(
            fontSize: 12,
            height: 1.5,
            color: secondary(context),
          ),
        ),
      ],
    ],
  );

  Widget _categoriesSection() => _BackupSection(
    title: '备份内容',
    icon: Icons.checklist_outlined,
    trailing: TextButton(
      onPressed: _working
          ? null
          : () => setState(() {
              if (categories.length == BackupCategory.values.length) {
                categories.clear();
              } else {
                categories.addAll(BackupCategory.values);
              }
            }),
      child: Text(
        categories.length == BackupCategory.values.length ? '取消全选' : '全选',
      ),
    ),
    caption: '已选择 ${categories.length} / ${BackupCategory.values.length} 类内容',
    children: [
      for (final category in BackupCategory.values) ...[
        Material(
          color: categories.contains(category)
              ? themeAccent(context).withValues(alpha: .06)
              : Colors.transparent,
          borderRadius: BorderRadius.circular(12),
          clipBehavior: Clip.antiAlias,
          child: CheckboxListTile(
            key: ValueKey('backup-category-${category.name}'),
            controlAffinity: ListTileControlAffinity.leading,
            contentPadding: const EdgeInsets.symmetric(
              horizontal: 8,
              vertical: 4,
            ),
            value: categories.contains(category),
            title: Text(
              category.label,
              style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w600),
            ),
            subtitle: Text(
              category.description,
              style: TextStyle(
                fontSize: 12,
                height: 1.5,
                color: secondary(context),
              ),
            ),
            onChanged: _working
                ? null
                : (value) => _setCategory(category, value == true),
          ),
        ),
        if (category == BackupCategory.accounts &&
            categories.contains(category))
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 12, 0, 8),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Row(
                  children: [
                    Expanded(
                      child: Text(
                        '选择账号 · ${accounts.length} 个',
                        style: const TextStyle(
                          fontSize: 13,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ),
                    if (profiles.isNotEmpty)
                      TextButton(
                        onPressed: _working
                            ? null
                            : () => setState(() {
                                final keys = profiles
                                    .map(
                                      (p) => backupAccountKey(
                                        p.platform.key,
                                        p.id,
                                      ),
                                    )
                                    .toSet();
                                if (accounts.containsAll(keys)) {
                                  accounts.removeAll(keys);
                                } else {
                                  accounts.addAll(keys);
                                }
                              }),
                        child: Text(
                          profiles.every(
                                (p) => accounts.contains(
                                  backupAccountKey(p.platform.key, p.id),
                                ),
                              )
                              ? '清空'
                              : '全选账号',
                        ),
                      ),
                  ],
                ),
                if (profiles.isEmpty)
                  Text(
                    '当前没有已登录账号',
                    style: TextStyle(fontSize: 12, color: secondary(context)),
                  ),
                for (final profile in profiles)
                  CheckboxListTile(
                    contentPadding: EdgeInsets.zero,
                    controlAffinity: ListTileControlAffinity.leading,
                    secondary: PlatformMark(
                      platform: profile.platform,
                      size: 26,
                    ),
                    title: Text(
                      '${profile.platform.shortName} · ${profile.name}',
                      style: const TextStyle(fontSize: 13),
                    ),
                    value: accounts.contains(
                      backupAccountKey(profile.platform.key, profile.id),
                    ),
                    onChanged: _working
                        ? null
                        : (value) => setState(() {
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
              ],
            ),
          ),
        if (category != BackupCategory.values.last) const SizedBox(height: 4),
      ],
    ],
  );

  Widget _securitySection() => _BackupSection(
    title: '密码保护',
    icon: Icons.lock_outline,
    children: [
      ListTile(
        contentPadding: EdgeInsets.zero,
        title: const Text(
          '使用密码加密备份',
          style: TextStyle(fontSize: 14, fontWeight: FontWeight.w600),
        ),
        subtitle: Text(
          encrypt ? '恢复此备份时需要输入密码' : '生成明文备份文件',
          style: const TextStyle(fontSize: 12, height: 1.5),
        ),
        onTap: _working ? null : () => setState(() => encrypt = !encrypt),
        trailing: AppSwitch(
          key: const Key('backup-password-toggle'),
          semanticLabel: '使用密码加密备份',
          value: encrypt,
          onChanged: _working
              ? null
              : (value) => setState(() => encrypt = value),
        ),
      ),
      if (encrypt) ...[
        const SizedBox(height: 12),
        TextField(
          key: const Key('backup-password'),
          controller: password,
          enabled: !_working,
          obscureText: !_passwordVisible,
          enableSuggestions: false,
          autocorrect: false,
          textInputAction: TextInputAction.next,
          decoration: _backupInput(
            '备份密码（至少 6 位）',
            suffix: IconButton(
              tooltip: _passwordVisible ? '隐藏备份密码' : '显示备份密码',
              onPressed: () =>
                  setState(() => _passwordVisible = !_passwordVisible),
              icon: Icon(
                _passwordVisible
                    ? Icons.visibility_off_outlined
                    : Icons.visibility_outlined,
                size: 20,
              ),
            ),
          ),
        ),
        const SizedBox(height: 14),
        TextField(
          key: const Key('backup-confirmation'),
          controller: confirmation,
          enabled: !_working,
          obscureText: !_confirmationVisible,
          enableSuggestions: false,
          autocorrect: false,
          textInputAction: TextInputAction.done,
          decoration: _backupInput(
            '再次输入备份密码',
            suffix: IconButton(
              tooltip: _confirmationVisible ? '隐藏确认密码' : '显示确认密码',
              onPressed: () =>
                  setState(() => _confirmationVisible = !_confirmationVisible),
              icon: Icon(
                _confirmationVisible
                    ? Icons.visibility_off_outlined
                    : Icons.visibility_outlined,
                size: 20,
              ),
            ),
          ),
        ),
        const SizedBox(height: 12),
        Text(
          '备份密码不会保存，请妥善保管。',
          style: TextStyle(
            fontSize: 12,
            height: 1.5,
            color: secondary(context),
          ),
        ),
      ],
      const SizedBox(height: 14),
      const _BackupNote(icon: Icons.info_outline, text: '本地数据仍为明文。背景图片不参与备份。'),
    ],
  );

  Widget _restoreGuide() => const _BackupSection(
    title: '先预览，再恢复',
    icon: Icons.restore_outlined,
    caption: '按分类恢复你需要的数据',
    children: [
      _RestoreStep(number: '1', title: '选择备份', detail: '从本地文件或网盘读取，先校验完整性。'),
      SizedBox(height: 20),
      _RestoreStep(
        number: '2',
        title: '预览与勾选',
        detail: '查看备份时间、内容数量，选择要恢复的分类。',
      ),
      SizedBox(height: 20),
      _RestoreStep(number: '3', title: '确认恢复', detail: '收藏和历史会合并，恢复前自动保存回退副本。'),
      SizedBox(height: 20),
      _BackupNote(icon: Icons.lock_outline, text: '加密备份在读取时询问密码；下载目录沿用本机设置。'),
    ],
  );

  Widget _followUpSections() => Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      if (repository.canUndo) ...[
        const SizedBox(height: 20),
        _BackupSection(
          title: '最近一次恢复',
          icon: Icons.history,
          children: [
            Text(
              '可以将上次涉及的分类回退到恢复前，回退前会再次确认。',
              style: TextStyle(
                fontSize: 13,
                height: 1.5,
                color: secondary(context),
              ),
            ),
            const SizedBox(height: 12),
            Align(
              alignment: Alignment.centerLeft,
              child: OutlinedButton.icon(
                onPressed: _working ? null : () => _perform(_undo),
                icon: const Icon(Icons.undo, size: 18),
                label: const Text('回退上次恢复'),
              ),
            ),
          ],
        ),
      ],
      if (transfers.pending.isNotEmpty) ...[
        const SizedBox(height: 20),
        _BackupSection(
          title: '未完成的远程备份',
          icon: Icons.cloud_upload_outlined,
          caption: '${transfers.pending.length} 个备份可继续上传或校验',
          children: [
            for (final job in transfers.pending) ...[
              _BackupTaskRow(
                title: job.str('name'),
                detail: job
                    .obj('target')
                    .str('label')
                    .ifEmpty(job.obj('target').str('url')),
                metadata:
                    '${formatBytes(job.integer('size'))} · ${formatDate(job.integer('createdAt'))}',
                actions: [
                  TextButton(
                    onPressed: _working
                        ? null
                        : () => _perform(() => _discard(job)),
                    child: const Text('放弃'),
                  ),
                  OutlinedButton.icon(
                    onPressed: _working
                        ? null
                        : () => _perform(() => _resume(job)),
                    icon: const Icon(Icons.play_arrow_outlined, size: 18),
                    label: const Text('继续备份'),
                  ),
                ],
              ),
              if (job != transfers.pending.last) const Divider(height: 28),
            ],
          ],
        ),
      ],
      if (repository.pending.isNotEmpty) ...[
        const SizedBox(height: 20),
        _BackupSection(
          title: '待关联账号的数据',
          icon: Icons.person_outline,
          caption: '记录已保留，关联原账号后即可使用',
          children: [
            for (final item in repository.pending) ...[
              _BackupTaskRow(
                title:
                    '${CloudPlatform.fromKey(item.obj('account').str('platform'))?.label ?? ''} · ${item.obj('account').str('name').ifEmpty('原账号')}',
                detail: '请选择原来的同一个网盘账号',
                actions: [
                  OutlinedButton(
                    onPressed: _working
                        ? null
                        : () => _perform(() => _bind(item)),
                    child: const Text('关联账号'),
                  ),
                ],
              ),
              if (item != repository.pending.last) const Divider(height: 28),
            ],
          ],
        ),
      ],
    ],
  );

  Widget _footer() {
    final needsTarget = location == 'cloud' && cloudLocation == null;
    final label = needsTarget
        ? '选择网盘目录'
        : restoring
        ? '选择备份并预览'
        : '立即备份';
    final summary = restoring
        ? '预览后选择分类，确认后写入本机'
        : '已选 ${categories.length} 类内容 · ${encrypt ? '密码加密' : '明文备份'}';
    final button = FilledButton.icon(
      key: const Key('backup-primary'),
      onPressed: _working || (!restoring && categories.isEmpty)
          ? null
          : () => _perform(
              needsTarget
                  ? _chooseCloud
                  : restoring
                  ? _restore
                  : _export,
            ),
      style: FilledButton.styleFrom(
        minimumSize: const Size(0, 48),
        padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 14),
      ),
      icon: Icon(restoring ? Icons.restore : Icons.backup_outlined, size: 20),
      label: Text(_working ? '正在处理…' : label),
    );
    return Padding(
      padding: EdgeInsets.only(bottom: MediaQuery.viewInsetsOf(context).bottom),
      child: DecoratedBox(
        decoration: BoxDecoration(
          color: Theme.of(context).colorScheme.surface,
          border: Border(top: BorderSide(color: border(context))),
        ),
        child: SafeArea(
          top: false,
          child: Align(
            heightFactor: 1,
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 1100),
              child: Padding(
                padding: const EdgeInsets.symmetric(
                  horizontal: 16,
                  vertical: 12,
                ),
                child: LayoutBuilder(
                  builder: (context, constraints) {
                    final text = Text(
                      summary,
                      style: TextStyle(fontSize: 12, color: secondary(context)),
                    );
                    if (constraints.maxWidth >= 680) {
                      return Row(
                        children: [
                          Expanded(child: text),
                          const SizedBox(width: 20),
                          SizedBox(width: 240, child: button),
                        ],
                      );
                    }
                    return Column(
                      mainAxisSize: MainAxisSize.min,
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [text, const SizedBox(height: 10), button],
                    );
                  },
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) => PopScope(
    canPop: !_working,
    child: Scaffold(
      appBar: AppBar(title: const Text('备份与恢复')),
      bottomNavigationBar: _footer(),
      body: SafeArea(
        top: false,
        bottom: false,
        child: LayoutBuilder(
          builder: (context, constraints) {
            final wide =
                constraints.maxWidth >= 900 &&
                MediaQuery.textScalerOf(context).scale(14) <= 21;
            return Align(
              alignment: Alignment.topCenter,
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 1100),
                child: Column(
                  children: [
                    Padding(
                      padding: EdgeInsets.fromLTRB(
                        wide ? 24 : 16,
                        8,
                        wide ? 24 : 16,
                        16,
                      ),
                      child: Row(
                        children: [
                          Expanded(
                            child: SegmentedButton<bool>(
                              segments: const [
                                ButtonSegment(
                                  value: false,
                                  label: Text('备份'),
                                  icon: Icon(Icons.backup_outlined),
                                ),
                                ButtonSegment(
                                  value: true,
                                  label: Text('恢复'),
                                  icon: Icon(Icons.restore),
                                ),
                              ],
                              selected: {restoring},
                              showSelectedIcon: false,
                              onSelectionChanged: _working
                                  ? null
                                  : (value) {
                                      FocusScope.of(context).unfocus();
                                      setState(() => restoring = value.single);
                                      if (_scroll.hasClients) _scroll.jumpTo(0);
                                    },
                            ),
                          ),
                          if (wide) ...[
                            const SizedBox(width: 28),
                            Expanded(
                              child: Text(
                                restoring ? '从已有备份找回需要的数据' : '选择内容，留一份可恢复的副本',
                                style: TextStyle(
                                  fontSize: 14,
                                  color: secondary(context),
                                ),
                              ),
                            ),
                          ],
                        ],
                      ),
                    ),
                    Expanded(
                      child: Scrollbar(
                        controller: _scroll,
                        child: SingleChildScrollView(
                          key: const Key('backup-scroll'),
                          controller: _scroll,
                          keyboardDismissBehavior:
                              ScrollViewKeyboardDismissBehavior.onDrag,
                          padding: EdgeInsets.fromLTRB(
                            wide ? 24 : 16,
                            0,
                            wide ? 24 : 16,
                            24,
                          ),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.stretch,
                            children: [
                              if (wide)
                                Row(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    Expanded(
                                      flex: 3,
                                      child: restoring
                                          ? _restoreGuide()
                                          : _categoriesSection(),
                                    ),
                                    const SizedBox(width: 24),
                                    Expanded(
                                      flex: 2,
                                      child: Column(
                                        crossAxisAlignment:
                                            CrossAxisAlignment.stretch,
                                        children: [
                                          _locationSection(),
                                          if (!restoring) ...[
                                            const SizedBox(height: 20),
                                            _securitySection(),
                                          ],
                                        ],
                                      ),
                                    ),
                                  ],
                                )
                              else ...[
                                _locationSection(),
                                const SizedBox(height: 20),
                                restoring
                                    ? _restoreGuide()
                                    : _categoriesSection(),
                                if (!restoring) ...[
                                  const SizedBox(height: 20),
                                  _securitySection(),
                                ],
                              ],
                              _followUpSections(),
                            ],
                          ),
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            );
          },
        ),
      ),
    ),
  );
}

InputDecoration _backupInput(String label, {Widget? suffix}) => InputDecoration(
  labelText: label,
  suffixIcon: suffix,
  border: OutlineInputBorder(borderRadius: BorderRadius.circular(12)),
  contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 18),
);

class _BackupSection extends StatelessWidget {
  const _BackupSection({
    required this.title,
    required this.icon,
    required this.children,
    this.caption,
    this.trailing,
  });
  final String title;
  final IconData icon;
  final List<Widget> children;
  final String? caption;
  final Widget? trailing;
  @override
  Widget build(BuildContext context) => Container(
    decoration: BoxDecoration(
      color: Theme.of(context).colorScheme.surface,
      borderRadius: BorderRadius.circular(16),
      border: Border.all(color: border(context)),
    ),
    padding: const EdgeInsets.all(16),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          children: [
            Icon(icon, size: 20, color: themeAccent(context)),
            const SizedBox(width: 10),
            Expanded(
              child: Text(
                title,
                style: const TextStyle(
                  fontSize: 16,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ),
            ?trailing,
          ],
        ),
        if (caption != null) ...[
          const SizedBox(height: 6),
          Text(
            caption!,
            style: TextStyle(
              fontSize: 12,
              height: 1.5,
              color: secondary(context),
            ),
          ),
        ],
        const SizedBox(height: 16),
        ...children,
      ],
    ),
  );
}

class _BackupNote extends StatelessWidget {
  const _BackupNote({required this.icon, required this.text});
  final IconData icon;
  final String text;
  @override
  Widget build(BuildContext context) => Row(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      Icon(icon, size: 17, color: secondary(context)),
      const SizedBox(width: 9),
      Expanded(
        child: Text(
          text,
          style: TextStyle(
            fontSize: 12,
            height: 1.6,
            color: secondary(context),
          ),
        ),
      ),
    ],
  );
}

class _RestoreStep extends StatelessWidget {
  const _RestoreStep({
    required this.number,
    required this.title,
    required this.detail,
  });
  final String number, title, detail;
  @override
  Widget build(BuildContext context) => Row(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      Container(
        width: 30,
        height: 30,
        alignment: Alignment.center,
        decoration: BoxDecoration(
          color: fill(context),
          borderRadius: BorderRadius.circular(10),
        ),
        child: Text(
          number,
          style: TextStyle(
            fontSize: 13,
            fontWeight: FontWeight.w600,
            color: themeAccent(context),
          ),
        ),
      ),
      const SizedBox(width: 14),
      Expanded(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              title,
              style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w600),
            ),
            const SizedBox(height: 6),
            Text(
              detail,
              style: TextStyle(
                fontSize: 12,
                height: 1.6,
                color: secondary(context),
              ),
            ),
          ],
        ),
      ),
    ],
  );
}

class _BackupTaskRow extends StatelessWidget {
  const _BackupTaskRow({
    required this.title,
    required this.detail,
    required this.actions,
    this.metadata,
  });
  final String title, detail;
  final String? metadata;
  final List<Widget> actions;
  @override
  Widget build(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      Text(
        title,
        maxLines: 2,
        overflow: TextOverflow.ellipsis,
        style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w600),
      ),
      const SizedBox(height: 6),
      Text(
        detail,
        maxLines: 3,
        overflow: TextOverflow.ellipsis,
        style: TextStyle(fontSize: 12, height: 1.5, color: secondary(context)),
      ),
      if (metadata != null) ...[
        const SizedBox(height: 6),
        Text(
          metadata!,
          style: TextStyle(fontSize: 12, color: secondary(context)),
        ),
      ],
      const SizedBox(height: 12),
      Align(
        alignment: Alignment.centerRight,
        child: Wrap(spacing: 8, runSpacing: 8, children: actions),
      ),
    ],
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
  final _scope = RequestScope();
  bool unconfirmed = false;
  late Future<List<BackupRemoteFile>> files = _load();
  Future<List<BackupRemoteFile>> _load() => _scope.run(
    () => widget.transfers.versions(
      widget.target,
      includeUnconfirmed: unconfirmed,
    ),
  );
  @override
  void dispose() {
    _scope.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
    insetPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 24),
    title: const Text('选择备份版本'),
    content: SizedBox(
      width: 540,
      height: MediaQuery.sizeOf(context).height * .55,
      child: FutureBuilder<List<BackupRemoteFile>>(
        future: files,
        builder: (context, snapshot) => CustomScrollView(
          key: const Key('backup-versions-scroll'),
          slivers: [
            SliverToBoxAdapter(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Text(
                    '选择一个版本，下载并校验后进入内容预览。',
                    style: TextStyle(
                      fontSize: 13,
                      height: 1.5,
                      color: secondary(context),
                    ),
                  ),
                  const SizedBox(height: 12),
                  CheckboxListTile(
                    controlAffinity: ListTileControlAffinity.leading,
                    contentPadding: EdgeInsets.zero,
                    title: const Text(
                      '显示旧版或未确认文件',
                      style: TextStyle(fontSize: 13),
                    ),
                    subtitle: const Text(
                      '恢复前仍会验证文件内容',
                      style: TextStyle(fontSize: 12),
                    ),
                    value: unconfirmed,
                    onChanged: (value) => setState(() {
                      unconfirmed = value ?? false;
                      files = _load();
                    }),
                  ),
                  const Divider(height: 24),
                ],
              ),
            ),
            _versionsSliver(context, snapshot),
          ],
        ),
      ),
    ),
    actions: [
      TextButton(
        onPressed: () => Navigator.pop(context),
        child: const Text('取消'),
      ),
    ],
  );

  Widget _versionsSliver(
    BuildContext context,
    AsyncSnapshot<List<BackupRemoteFile>> snapshot,
  ) {
    if (snapshot.hasError) {
      return SliverToBoxAdapter(
        child: Column(
          children: [
            Icon(Icons.cloud_off_outlined, size: 32, color: secondary(context)),
            const SizedBox(height: 12),
            Text(errorText(snapshot.error!), textAlign: TextAlign.center),
            const SizedBox(height: 12),
            OutlinedButton.icon(
              onPressed: () => setState(() {
                files = _load();
              }),
              icon: const Icon(Icons.refresh, size: 18),
              label: const Text('重试'),
            ),
          ],
        ),
      );
    }
    if (!snapshot.hasData) {
      return const SliverToBoxAdapter(
        child: Padding(
          padding: EdgeInsets.all(24),
          child: Center(child: CircularProgressIndicator()),
        ),
      );
    }
    if (snapshot.data!.isEmpty) {
      return SliverToBoxAdapter(
        child: Column(
          children: [
            Icon(
              Icons.inventory_2_outlined,
              size: 36,
              color: secondary(context),
            ),
            const SizedBox(height: 12),
            Text(
              unconfirmed ? '此目录没有可用的备份文件' : '此目录没有已完成的备份',
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 8),
            Text(
              '可选择其他目录${unconfirmed ? '' : '，或显示旧版文件'}。',
              textAlign: TextAlign.center,
              style: TextStyle(fontSize: 12, color: secondary(context)),
            ),
          ],
        ),
      );
    }
    return SliverList.separated(
      itemCount: snapshot.data!.length,
      separatorBuilder: (_, _) => const Divider(height: 1),
      itemBuilder: (context, index) {
        final file = snapshot.data![index];
        final date = _backupFileDate(file.name);
        return ListTile(
          contentPadding: const EdgeInsets.symmetric(
            horizontal: 4,
            vertical: 8,
          ),
          leading: const Icon(Icons.inventory_2_outlined),
          title: Text(
            date ?? file.name,
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w600),
          ),
          subtitle: Text(
            '${date == null ? '' : '${file.name}\n'}${formatBytes(file.size)}',
            maxLines: 3,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(fontSize: 12),
          ),
          trailing: const Icon(Icons.chevron_right, size: 20),
          onTap: () => Navigator.pop(context, (file, unconfirmed)),
        );
      },
    );
  }
}

String? _backupFileDate(String name) {
  final stamp = RegExp(
    r'^asterlink-backup-(\d{13})-',
  ).firstMatch(name)?.group(1);
  final milliseconds = int.tryParse(stamp ?? '');
  return milliseconds == null ? null : formatDate(milliseconds);
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
    insetPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 24),
    title: const Text('预览与分类恢复'),
    content: SizedBox(
      width: 600,
      child: SingleChildScrollView(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Container(
              padding: const EdgeInsets.all(14),
              decoration: BoxDecoration(
                color: fill(context),
                borderRadius: BorderRadius.circular(12),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    widget.preview.createdAt > 0
                        ? formatDate(widget.preview.createdAt)
                        : '备份时间未知',
                    style: const TextStyle(
                      fontSize: 14,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  const SizedBox(height: 6),
                  Text(
                    '包含 ${widget.preview.categories.length} 类内容，已选择 ${categories.length} 类',
                    style: TextStyle(fontSize: 12, color: secondary(context)),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 16),
            const _BackupNote(
              icon: Icons.info_outline,
              text: '收藏和历史合并；默认保留本机登录状态与下载目录。',
            ),
            if (widget.preview.unknownCategories.isNotEmpty) ...[
              const SizedBox(height: 12),
              Text(
                '以下分类需要更新版本，本次跳过：${widget.preview.unknownCategories.join('、')}',
                style: TextStyle(
                  fontSize: 12,
                  height: 1.5,
                  color: secondary(context),
                ),
              ),
            ],
            const SizedBox(height: 16),
            const Text(
              '选择恢复内容',
              style: TextStyle(fontSize: 14, fontWeight: FontWeight.w600),
            ),
            const SizedBox(height: 8),
            for (final category in widget.preview.categories)
              CheckboxListTile(
                key: ValueKey('restore-category-${category.name}'),
                contentPadding: EdgeInsets.zero,
                controlAffinity: ListTileControlAffinity.leading,
                title: Text(
                  category.label,
                  style: const TextStyle(fontSize: 14),
                ),
                subtitle: Text(
                  '${widget.preview.count(category)} 项',
                  style: const TextStyle(fontSize: 12),
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
            if (categories.contains(BackupCategory.accounts)) ...[
              const Divider(height: 24),
              CheckboxListTile(
                controlAffinity: ListTileControlAffinity.leading,
                contentPadding: EdgeInsets.zero,
                title: const Text(
                  '替换对应账号的现有登录信息',
                  style: TextStyle(fontSize: 13),
                ),
                subtitle: const Text(
                  '默认保留本机账号；勾选后使用备份中的登录信息',
                  style: TextStyle(fontSize: 12, height: 1.5),
                ),
                value: replace,
                onChanged: (value) => setState(() => replace = value ?? false),
              ),
            ],
            if (widget.preview.accounts.isNotEmpty &&
                categories.any(
                  (c) => {
                    BackupCategory.accounts,
                    BackupCategory.favorites,
                    BackupCategory.playback,
                    BackupCategory.history,
                  }.contains(c),
                )) ...[
              const Divider(height: 24),
              const Text(
                '账号关联',
                style: TextStyle(fontSize: 14, fontWeight: FontWeight.w600),
              ),
              const SizedBox(height: 6),
              Text(
                '请选择原来的同一个账号。未关联的数据会保留，之后可继续关联。',
                style: TextStyle(
                  fontSize: 12,
                  height: 1.5,
                  color: secondary(context),
                ),
              ),
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
                      padding: const EdgeInsets.only(top: 16),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          Text(
                            '${CloudPlatform.fromKey(ref.str('platform'))?.shortName ?? ''} · ${ref.str('name').ifEmpty(ref.str('id'))}',
                            maxLines: 3,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(fontSize: 13),
                          ),
                          const SizedBox(height: 8),
                          DropdownButtonFormField<String>(
                            isExpanded: true,
                            decoration: _backupInput('关联到本机账号'),
                            initialValue: bindings[key] ?? '',
                            items: [
                              const DropdownMenuItem(
                                value: '',
                                child: Text(
                                  '按原编号恢复',
                                  overflow: TextOverflow.ellipsis,
                                ),
                              ),
                              for (final account in matches)
                                DropdownMenuItem(
                                  value: account.id,
                                  child: Row(
                                    children: [
                                      PlatformMark(
                                        platform: account.platform,
                                        size: 22,
                                      ),
                                      const SizedBox(width: 10),
                                      Expanded(
                                        child: Text(
                                          account.name,
                                          overflow: TextOverflow.ellipsis,
                                        ),
                                      ),
                                    ],
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
                        ],
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
        child: Text('恢复所选内容（${categories.length}）'),
      ),
    ],
  );
}
