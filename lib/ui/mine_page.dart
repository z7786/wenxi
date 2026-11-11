import 'dart:io';
import 'package:file_selector/file_selector.dart';
import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'app_switch.dart';
import '../app_services.dart';
import '../data/backup.dart';
import '../diagnostics/app_log.dart';
import '../diagnostics/diagnostic_bundle.dart';
import '../domain/download_retries.dart';
import '../domain/settings.dart';
import '../platform/document_actions.dart';
import '../playback/windows_player_components.dart';
import 'common.dart';
import 'appearance_page.dart';
import 'theme_mode_switch.dart';
import 'remote_control_dialogs.dart';
import 'diagnostics_page.dart';
import 'download_protection_page.dart';
import 'download_destination_dialog.dart';
import 'experimental_features_page.dart';
import 'github_acceleration_page.dart';
import 'font_size_page.dart';
import 'download_concurrency_dialog.dart';
import 'contact_author_dialog.dart';
import 'link_opening_page.dart';
import 'player_components_page.dart';

class MinePage extends StatelessWidget {
  const MinePage(this.services, {super.key, this.linkLauncher});
  final AppServices services;
  final RemoteLinkLauncher? linkLauncher;
  Future<void> _number(
    BuildContext context,
    String title,
    String key,
    int initial,
    int min,
    int max,
  ) async {
    final text = await askText(
      context,
      title,
      initial: '$initial',
      hint: '$min–$max',
      numeric: true,
    );
    if (text == null || !context.mounted) return;
    final value = int.tryParse(text.trim());
    if (value == null || value < min || value > max) {
      message(context, '请输入 $min–$max 之间的整数');
      return;
    }
    await busy(context, () => services.updateSettings({key: value}));
  }

  Future<void> _threads(BuildContext context, String key) async {
    final profile = AppSettings.profiles[key]!;
    final current = services.settings.threadOverrides[key];
    final limited = key == 'aliyun' || key == 'baidu_direct';
    final maximum = limited ? 8 : 512;
    final choice = await showDialog<int>(
      context: context,
      builder: (context) => SimpleDialog(
        title: Text('${profile.$1}${limited ? '连接上限' : '连接数'}'),
        children: [
          SimpleDialogOption(
            onPressed: () => Navigator.pop(context, -1),
            child: Text('平台预设（${profile.$2}）${current == null ? ' ✓' : ''}'),
          ),
          SimpleDialogOption(
            onPressed: () => Navigator.pop(context, 0),
            child: Text(
              '跟随全局（${services.settings.threads.clamp(1, maximum)}）${current == 0 ? ' ✓' : ''}',
            ),
          ),
          SimpleDialogOption(
            onPressed: () => Navigator.pop(context, 1),
            child: const Text('自定义连接数…'),
          ),
          if (key == 'aliyun')
            const Padding(
              padding: EdgeInsets.fromLTRB(24, 8, 24, 12),
              child: Text('根据连接情况自动调整，最高不超过所设上限。'),
            ),
          if (key == 'baidu_direct')
            const Padding(
              padding: EdgeInsets.fromLTRB(24, 8, 24, 12),
              child: Text('默认 3 个连接，最多 8 个；较高并发未必更快。'),
            ),
          if (key == 'baidu_public')
            const Padding(
              padding: EdgeInsets.fromLTRB(24, 8, 24, 12),
              child: Text('此设置用于公益解析。账号下载连接数请分别在“百度网盘”和“百度网盘 · 账号直链”中设置。'),
            ),
        ],
      ),
    );
    if (choice == null || !context.mounted) return;
    int? value;
    if (choice == 1) {
      final text = await askText(
        context,
        '自定义连接数',
        initial: '${services.settings.connectionsFor(null, key)}',
        hint: '1–$maximum',
        numeric: true,
      );
      if (text == null || !context.mounted) return;
      value = int.tryParse(text.trim());
      if (value == null || value < 1 || value > maximum) {
        message(context, '连接数范围为 1–$maximum');
        return;
      }
    } else if (choice == 0) {
      value = 0;
    }
    final values = {...services.settings.threadOverrides};
    if (value == null) {
      values.remove(key);
    } else {
      values[key] = value;
    }
    await services.updateSettings({'downloadThreadOverrides': values});
  }

  Future<bool> _saveBytes(Uint8List bytes, String name) async {
    final location = await const DocumentActions().saveBytes(
      bytes,
      name,
      mime: 'application/json',
      acceptedTypeGroups: const [
        XTypeGroup(label: 'JSON', extensions: ['json']),
      ],
    );
    return location != null;
  }

  Future<void> _export(BuildContext context) async {
    var includeImages = false;
    if (services.settings.background.hasImage) {
      final choice = await showDialog<bool>(
        context: context,
        builder: (context) => StatefulBuilder(
          builder: (context, update) => AlertDialog(
            title: const Text('导出备份'),
            content: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                CheckboxListTile(
                  contentPadding: EdgeInsets.zero,
                  title: const Text('同时备份背景图片'),
                  value: includeImages,
                  onChanged: (value) =>
                      update(() => includeImages = value ?? false),
                ),
                const Text(
                  '不携带图片时，恢复后使用纯色背景；主题配色和其他设置仍会保留。',
                  style: TextStyle(fontSize: 13, height: 1.5),
                ),
              ],
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(context),
                child: const Text('取消'),
              ),
              FilledButton(
                onPressed: () => Navigator.pop(context, includeImages),
                child: const Text('继续'),
              ),
            ],
          ),
        ),
      );
      if (choice == null || !context.mounted) return;
      includeImages = choice;
    }
    final exported = await busy(
      context,
      () => services.backup.exportTo(
        '',
        (bytes) => context.mounted
            ? _saveBytes(
                bytes,
                '文析助手-backup-${DateTime.now().millisecondsSinceEpoch}.json',
              )
            : Future.value(false),
        includeBackgroundImages: includeImages,
      ),
      label: '正在导出备份…',
    );
    if (exported == true && context.mounted) {
      message(context, '备份已导出，请妥善保管，文件包含账号登录信息');
    }
  }

  Future<void> _restore(BuildContext context) async {
    final file = await openFile(acceptedTypeGroups: const [backupFileType]);
    if (file == null || !context.mounted) return;
    if (await file.length() > 16 * 1024 * 1024) {
      if (context.mounted) message(context, '备份文件过大');
      return;
    }
    if (!context.mounted ||
        !await confirm(context, '恢复备份', '备份中的账号和设置将覆盖本机对应项目，下载文件不会被删除。') ||
        !context.mounted) {
      return;
    }
    final bytes = await file.readAsBytes();
    if (!context.mounted) return;
    final password = isPlainBackup(bytes)
        ? ''
        : await askText(context, '输入旧备份密码', secret: true);
    if (password == null || !context.mounted) return;
    final count = await busy(
      context,
      () => services.backup.restore(bytes, password),
      label: '正在验证并恢复备份…',
    );
    if (count != null && context.mounted) {
      await services.downloads.settingsChanged();
      if (context.mounted) message(context, '已恢复 $count 个账号及下载设置');
    }
  }

  Widget _settingIcon(BuildContext context, IconData icon) => Container(
    width: 34,
    height: 34,
    decoration: BoxDecoration(
      color: themeAccent(context).withValues(alpha: .09),
      borderRadius: BorderRadius.circular(10),
    ),
    child: Icon(icon, size: 19, color: themeAccent(context)),
  );

  Widget _tile(
    BuildContext context,
    IconData icon,
    String title,
    String subtitle,
    VoidCallback action, {
    String? value,
  }) => ListTile(
    contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
    minLeadingWidth: 34,
    horizontalTitleGap: 12,
    minVerticalPadding: 12,
    leading: _settingIcon(context, icon),
    title: Text(
      title,
      style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w500),
    ),
    subtitle: subtitle.isEmpty
        ? null
        : Text(
            subtitle,
            style: TextStyle(
              fontSize: 12,
              height: 1.5,
              color: secondary(context),
            ),
          ),
    trailing: Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        if (value != null) ...[
          Text(
            value,
            style: TextStyle(fontSize: 13, color: secondary(context)),
          ),
          const SizedBox(width: 8),
        ],
        Icon(CupertinoIcons.chevron_right, size: 13, color: secondary(context)),
      ],
    ),
    onTap: action,
  );

  Widget _section(
    BuildContext context,
    String title,
    List<Widget> children, {
    String? footer,
  }) => Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      Padding(
        padding: const EdgeInsets.only(left: 4, bottom: 10),
        child: Align(
          alignment: Alignment.centerLeft,
          child: BackgroundReadable(
            child: Text(
              title,
              style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w600),
            ),
          ),
        ),
      ),
      Material(
        color: backgroundSurface(context),
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(16),
          side: BorderSide(color: border(context), width: .7),
        ),
        clipBehavior: Clip.antiAlias,
        child: Column(
          children: [
            for (var index = 0; index < children.length; index++) ...[
              if (index > 0)
                Divider(
                  height: 1,
                  thickness: .6,
                  indent: 62,
                  endIndent: 16,
                  color: border(context),
                ),
              children[index],
            ],
          ],
        ),
      ),
      if (footer != null)
        Padding(
          padding: const EdgeInsets.fromLTRB(4, 10, 4, 0),
          child: Text(
            footer,
            style: TextStyle(
              fontSize: 11,
              height: 1.6,
              color: secondary(context),
            ),
          ),
        ),
    ],
  );

  Widget _appearance(
    BuildContext context,
    AppSettings settings,
    bool desktop,
  ) => _section(context, '外观', [
    ThemeModeSwitch(services, icon: _settingIcon(context, CupertinoIcons.moon)),
    _tile(
      context,
      CupertinoIcons.paintbrush,
      '主题与外观',
      '${settings.themePalette.label} · ${settings.glassStyle.label}',
      () => Navigator.of(
        context,
      ).push(MaterialPageRoute<void>(builder: (_) => AppearancePage(services))),
      value: switch (settings.theme) {
        'Light' => '浅色',
        'Dark' => '深色',
        _ => '跟随系统',
      },
    ),
    _tile(
      context,
      Icons.format_size,
      '字体大小',
      '调整软件内的文字大小',
      () => Navigator.of(
        context,
      ).push(MaterialPageRoute<void>(builder: (_) => FontSizePage(services))),
      value: settings.fontScalePercent == 100
          ? '跟随系统'
          : '${settings.fontScalePercent}%',
    ),
  ]);

  Widget _platformThreads(BuildContext context, AppSettings settings) =>
      ExpansionTile(
        key: const PageStorageKey('mine-platform-connections'),
        tilePadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
        childrenPadding: const EdgeInsets.only(bottom: 8),
        shape: const Border(),
        collapsedShape: const Border(),
        iconColor: themeAccent(context),
        collapsedIconColor: secondary(context),
        leading: _settingIcon(context, CupertinoIcons.slider_horizontal_3),
        title: const Text(
          '各网盘连接数',
          style: TextStyle(fontSize: 14, fontWeight: FontWeight.w500),
        ),
        subtitle: Text(
          '为不同网盘单独设置',
          style: TextStyle(fontSize: 12, color: secondary(context)),
        ),
        children: [
          for (final entry in AppSettings.profiles.entries.where(
            (entry) => entry.key != 'baidu',
          ))
            ListTile(
              contentPadding: const EdgeInsets.only(left: 62, right: 18),
              title: Text(entry.value.$1, style: const TextStyle(fontSize: 13)),
              trailing: Text(
                entry.key == 'aliyun' || entry.key == 'baidu_direct'
                    ? '最多 ${settings.connectionsFor(null, entry.key)}'
                    : settings.threadOverrides[entry.key] == null
                    ? '预设 ${entry.value.$2}'
                    : settings.threadOverrides[entry.key] == 0
                    ? '跟随全局'
                    : '${settings.threadOverrides[entry.key]}',
                style: TextStyle(fontSize: 12, color: themeAccent(context)),
              ),
              onTap: () => _threads(context, entry.key),
            ),
        ],
      );

  Widget _linkRecognition(
    BuildContext context,
    AppSettings settings,
  ) => _section(context, '链接识别', [
    _tile(
      context,
      CupertinoIcons.link,
      '链接唤起',
      Platform.isAndroid ? '从浏览器、分享菜单或选中文字进入解析' : '通过网页按钮或复制链接进入解析',
      () => Navigator.push<void>(
        context,
        MaterialPageRoute(builder: (_) => const LinkOpeningPage()),
      ),
    ),
    AppSwitchListTile(
      contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
      secondary: _settingIcon(context, CupertinoIcons.doc_on_clipboard),
      title: const Text('自动识别剪贴板链接', style: TextStyle(fontSize: 14)),
      subtitle: Text(
        '启动或返回应用时识别分享、磁力和种子链接，点击后直接进入解析流程。',
        style: TextStyle(fontSize: 12, height: 1.5, color: secondary(context)),
      ),
      value: settings.clipboardRecognition,
      onChanged: (value) =>
          services.updateSettings({'clipboardRecognition': value}),
    ),
  ]);

  Widget _experimental(BuildContext context) => _section(context, '更多设置', [
    if (WindowsPlayerComponents.isSupported &&
        Theme.of(context).platform == TargetPlatform.windows)
      AnimatedBuilder(
        animation: WindowsPlayerComponents.shared,
        builder: (context, _) {
          final components = WindowsPlayerComponents.shared;
          return KeyedSubtree(
            key: const Key('player-components-settings'),
            child: _tile(
              context,
              Icons.extension_outlined,
              '播放器组件',
              '${components.active == WindowsPlayerVariant.full ? '完整版' : '精简版'}'
                  '${components.restartRequired ? ' · 重启后切换' : ' · 可按需下载完整版'}',
              () => Navigator.push<void>(
                context,
                MaterialPageRoute(
                  builder: (_) => PlayerComponentsPage(
                    acceleration: () => services.settings.githubAcceleration,
                  ),
                ),
              ),
            ),
          );
        },
      ),
    _tile(
      context,
      CupertinoIcons.lab_flask,
      '实验性功能',
      '夸克与 UC 网盘的下载功能与说明',
      () => Navigator.push<void>(
        context,
        MaterialPageRoute(builder: (_) => ExperimentalFeaturesPage(services)),
      ),
    ),
  ]);

  Widget _downloads(BuildContext context, AppSettings settings) => _section(
    context,
    '下载设置',
    [
      _tile(
        context,
        CupertinoIcons.arrow_down_circle,
        'HTTP 下载连接数',
        '普通链接与设为跟随全局的网盘使用',
        () => _number(context, '全局连接数', 'threads', settings.threads, 1, 512),
        value: '${settings.threads}',
      ),
      _tile(
        context,
        CupertinoIcons.square_stack,
        '同时下载任务数',
        '其余任务自动排队',
        () => editDownloadConcurrency(context, services),
        value: '${settings.concurrent} 个',
      ),
      _platformThreads(context, settings),
      if (services.mobileDataDownloads.supported)
        AppSwitchListTile(
          key: const ValueKey('mobile-data-download-warning-setting'),
          contentPadding: const EdgeInsets.symmetric(
            horizontal: 16,
            vertical: 4,
          ),
          secondary: _settingIcon(context, Icons.network_cell),
          title: const Text('流量下载提醒', style: TextStyle(fontSize: 14)),
          subtitle: Text(
            '使用移动数据下载前提醒',
            style: TextStyle(fontSize: 12, color: secondary(context)),
          ),
          value: settings.warnOnMobileDataDownload,
          onChanged: (value) =>
              services.updateSettings({'warnOnMobileDataDownload': value}),
        ),
      _tile(
        context,
        CupertinoIcons.globe,
        'GitHub 加速',
        '常用代理与自定义加速地址',
        () => Navigator.push<void>(
          context,
          MaterialPageRoute(builder: (_) => GitHubAccelerationPage(services)),
        ),
        value: settings.githubAcceleration.label,
      ),
      _tile(
        context,
        CupertinoIcons.arrow_2_circlepath,
        '失败重试次数',
        '',
        () => _number(
          context,
          '失败重试次数',
          'retries',
          settings.retries,
          0,
          maxDownloadRetries,
        ),
        value: '${settings.retries} 次',
      ),
      _tile(
        context,
        CupertinoIcons.speedometer,
        '单任务限速',
        '',
        () async {
          final text = await askText(
            context,
            '限速（KB/s）',
            initial: '${settings.speedLimit ~/ 1024}',
            hint: '0 表示不限速',
            numeric: true,
          );
          if (text == null || !context.mounted) return;
          final value = int.tryParse(text);
          if (value == null || value < 0 || value > 10000000) {
            message(context, '请输入有效的速度');
            return;
          }
          await services.updateSettings({'speedLimit': value * 1024});
        },
        value: settings.speedLimit == 0
            ? '不限速'
            : '${formatBytes(settings.speedLimit)}/s',
      ),
      _tile(
        context,
        CupertinoIcons.arrow_up_circle,
        'BT 上传限速',
        '给网络留出余量，保留分片交换；恢复下载时应用',
        () async {
          final text = await askText(
            context,
            'BT 上传限速（KB/s）',
            initial: '${settings.btUploadLimit ~/ 1024}',
            hint: '0 表示不限速',
            numeric: true,
          );
          if (text == null || !context.mounted) return;
          final value = int.tryParse(text);
          if (value == null || value < 0 || value > 10000000) {
            message(context, '请输入有效的速度');
            return;
          }
          await services.updateSettings({'btUploadLimit': value * 1024});
        },
        value: settings.btUploadLimit == 0
            ? '不限速'
            : '${formatBytes(settings.btUploadLimit)}/s',
      ),
      _tile(
        context,
        CupertinoIcons.folder,
        '下载保存目录',
        settings.destination ?? '系统下载目录',
        () async {
          final directory = await busy(
            context,
            services.files.chooseDirectory,
            label: '选择下载目录…',
          );
          if (directory != null && context.mounted) {
            await _changeDownloadDirectory(context, directory);
          }
        },
      ),
      if (settings.destination != null)
        Padding(
          padding: const EdgeInsets.only(left: 54, bottom: 8),
          child: Align(
            alignment: Alignment.centerLeft,
            child: TextButton(
              onPressed: () => _changeDownloadDirectory(context, null),
              child: const Text('恢复默认目录'),
            ),
          ),
        ),
      if (services.platformFeatures &&
          (Platform.isAndroid ||
              Platform.isIOS ||
              Platform.isWindows ||
              Platform.isMacOS))
        _tile(
          context,
          CupertinoIcons.shield_lefthalf_fill,
          '后台下载保护',
          Platform.isIOS
              ? '前台下载与后台续传说明'
              : Platform.isMacOS
              ? '最小化窗口与自动休眠保护'
              : Platform.isWindows
              ? '最小化到托盘与自动休眠保护'
              : '锁屏下载、通知与系统后台设置',
          () => Navigator.push<void>(
            context,
            MaterialPageRoute(builder: (_) => const DownloadProtectionPage()),
          ),
        ),
    ],
    footer:
        '连接数、重试和限速设置用于新任务。更改保存目录时可同步未完成任务。实际连接数由文件大小与服务器决定；BT 最多连接 80 个对等节点。',
  );

  Future<void> _changeDownloadDirectory(
    BuildContext context,
    String? directory,
  ) async {
    final unfinished = services.downloads.tasks
        .where((task) => !task.terminal)
        .length;
    if (directory == services.settings.destination && unfinished == 0) return;
    var choice = DownloadDestinationChoice.newTasks;
    if (unfinished > 0) {
      final selected = await chooseDownloadDestinationScope(
        context,
        destination: directory,
        unfinished: unfinished,
        directDownloads: services.downloads.files.directDownloads,
      );
      if (selected == null || !context.mounted) return;
      choice = selected;
    }
    final updated = await busy(
      context,
      () => services.updateDownloadDestination(
        directory,
        includeUnfinished: choice == DownloadDestinationChoice.unfinished,
      ),
      label: '更新下载目录…',
    );
    if (updated != null && context.mounted) {
      message(
        context,
        updated > 0 ? '目录已更新，已同步 $updated 个任务，请到传输管理继续' : '目录已更新，新任务将保存到此处',
      );
    }
  }

  Widget _data(BuildContext context) => _section(context, '备份与数据', [
    _tile(
      context,
      CupertinoIcons.lock_shield,
      '导出备份',
      '保存账号与应用设置',
      () => _export(context),
    ),
    _tile(
      context,
      CupertinoIcons.arrow_up_doc,
      '恢复备份',
      '从已有备份中导入',
      () => _restore(context),
    ),
    if (services.migrationError != null)
      _tile(
        context,
        CupertinoIcons.arrow_2_squarepath,
        '旧版数据导入',
        services.migrationError!,
        () => busy(context, services.retryLegacyImport, label: '读取旧版数据…'),
      ),
  ]);

  Widget _help(BuildContext context) => _section(context, '帮助与诊断', [
    if (services.control.platform == 'ios')
      _tile(
        context,
        CupertinoIcons.arrow_down_circle,
        '版本与更新',
        '当前版本 ${applicationVersion.split('+').first} · iOS 测试版',
        () => message(
          context,
          'iOS 测试版请通过签名安装渠道更新；发布到 TestFlight 或 App Store 后，请通过对应渠道更新。',
        ),
      )
    else
      _tile(
        context,
        CupertinoIcons.arrow_down_circle,
        '检查更新',
        services.control.checking
            ? '正在检查…'
            : services.control.availableUpdate != null
            ? '发现新版本 ${services.control.availableUpdate!.version}'
            : '当前版本 ${applicationVersion.split('+').first}',
        () => checkForAppUpdate(
          context,
          services.control,
          launcher: linkLauncher,
          updater: services.appUpdates,
        ),
      ),
    _tile(
      context,
      CupertinoIcons.question_circle,
      '使用帮助',
      services.control.config.helpUrl?.host ?? '暂未提供帮助链接',
      () {
        final url = services.control.config.helpUrl;
        if (url == null) {
          message(context, '暂未提供帮助链接');
        } else {
          openRemoteLink(context, url, launcher: linkLauncher);
        }
      },
    ),
    _tile(
      context,
      CupertinoIcons.link,
      '项目地址',
      'github.com/z7786/wenxi',
      () => openRemoteLink(
        context,
        Uri.parse('https://github.com/z7786/wenxi'),
        launcher: linkLauncher,
      ),
    ),
    _tile(
      context,
      CupertinoIcons.doc_text_search,
      '日志与故障排查',
      '查看、导出崩溃与操作日志',
      () => Navigator.push<void>(
        context,
        MaterialPageRoute(
          builder: (_) => DiagnosticsPage(
            DiagnosticBundle(
              DiagnosticLog.active ?? DiagnosticLog.open(null),
              snapshot: services.diagnostics,
              nativeEnabled: services.platformFeatures,
            ),
            linkLauncher: linkLauncher,
          ),
        ),
      ),
    ),
    _tile(
      context,
      CupertinoIcons.envelope,
      '联系作者/侵权投诉',
      authorEmail,
      () => showContactAuthorDialog(context),
    ),
  ]);

  Widget _identity(BuildContext context, bool desktop) => Row(
    children: [
      ClipRRect(
        borderRadius: BorderRadius.circular(12),
        child: Image.asset('assets/icons/app.png', width: 44, height: 44),
      ),
      const SizedBox(width: 13),
      Expanded(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text(
              '文析助手',
              style: TextStyle(fontSize: 18, fontWeight: FontWeight.w600),
            ),
            const SizedBox(height: 4),
            Text(
              '版本 ${applicationVersion.split('+').first}',
              style: TextStyle(fontSize: 12, color: secondary(context)),
            ),
          ],
        ),
      ),
      if (desktop)
        Text('应用设置', style: TextStyle(fontSize: 12, color: secondary(context))),
    ],
  );

  @override
  Widget build(BuildContext context) => AnimatedBuilder(
    animation: Listenable.merge([services.store, services]),
    builder: (context, _) => LayoutBuilder(
      builder: (context, bounds) {
        final settings = services.settings;
        final desktop =
            Theme.of(context).platform == TargetPlatform.windows ||
            Theme.of(context).platform == TargetPlatform.macOS;
        final columns =
            desktop &&
            bounds.maxWidth >= 880 &&
            MediaQuery.textScalerOf(context).scale(14) <= 21;
        final downloads = _downloads(context, settings);
        final appearance = _appearance(context, settings, desktop);
        final recognition = _linkRecognition(context, settings);
        final experimental = _experimental(context);
        final data = _data(context);
        final help = _help(context);
        return ListView(
          key: const PageStorageKey('mine'),
          padding: EdgeInsets.fromLTRB(
            desktop ? 28 : 18,
            desktop ? 24 : 18,
            desktop ? 28 : 18,
            28 + MediaQuery.paddingOf(context).bottom,
          ),
          children: [
            BackgroundReadable(
              padding: const EdgeInsets.all(12),
              radius: 16,
              child: _identity(context, desktop),
            ),
            SizedBox(height: desktop ? 26 : 24),
            if (columns)
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Expanded(flex: 3, child: downloads),
                  const SizedBox(width: 22),
                  Expanded(
                    flex: 2,
                    child: Column(
                      children: [
                        appearance,
                        const SizedBox(height: 24),
                        recognition,
                        const SizedBox(height: 24),
                        experimental,
                        const SizedBox(height: 24),
                        data,
                        const SizedBox(height: 24),
                        help,
                      ],
                    ),
                  ),
                ],
              )
            else ...[
              appearance,
              const SizedBox(height: 24),
              recognition,
              const SizedBox(height: 24),
              experimental,
              const SizedBox(height: 24),
              downloads,
              const SizedBox(height: 24),
              data,
              const SizedBox(height: 24),
              help,
            ],
          ],
        );
      },
    ),
  );
}
