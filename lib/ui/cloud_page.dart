import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:flutter/semantics.dart';
import 'app_switch.dart';
import '../app_services.dart';
import '../domain/auth.dart';
import '../domain/cloud_list_preferences.dart';
import '../domain/models.dart';
import 'browser_page.dart';
import 'common.dart';
import 'app_context_menu.dart';
import 'app_popup_menu.dart';
import 'login_page.dart';
import 'parse_page.dart';

Color quotaColor(int used, int total) {
  final ratio = total > 0 ? used / total : 0.0;
  if (ratio >= .9) return const Color(0xffff3b30);
  if (ratio >= .7) return const Color(0xffff9500);
  return const Color(0xff34c759);
}

const cloudEntries = <(String, String, CloudPlatform?)>[
  ('quark', '夸克网盘', CloudPlatform.quark),
  ('123', '123网盘', CloudPlatform.pan123),
  ('guangya', '光鸭云盘', CloudPlatform.guangya),
  ('baidu', '百度网盘', CloudPlatform.baidu),
  ('ali', '阿里云盘', CloudPlatform.aliyun),
  ('weiyun', '腾讯微云', CloudPlatform.weiyun),
  ('xunlei', '迅雷网盘', CloudPlatform.xunlei),
  ('uc', 'UC网盘', CloudPlatform.uc),
  ('yidong', '移动网盘', CloudPlatform.c139),
  ('tianyi', '天翼网盘', CloudPlatform.tianyi),
  ('115', '115网盘', CloudPlatform.pan115),
  ('wopan', '中国联通云盘', CloudPlatform.wopan),
  ('lanzous', '蓝奏云优享版', CloudPlatform.ilanzou),
  ('lanzous', '蓝奏云', CloudPlatform.lanzou),
  ('ctfile', '城通网盘', CloudPlatform.ctfile),
  ('feijipan', '小飞机网盘', CloudPlatform.feijipan),
  ('pikpak', 'PikPak网盘', CloudPlatform.pikpak),
  ('github', 'GitHub', CloudPlatform.github),
];

class CloudPage extends StatelessWidget {
  const CloudPage(this.services, {super.key, this.onParseShare});
  final AppServices services;
  final VoidCallback? onParseShare;
  Future<void> _parseLanzou(BuildContext context) async {
    if (!allowCloudAction(context, services.control, CloudPlatform.lanzou)) {
      return;
    }
    if (onParseShare != null) {
      onParseShare!();
      message(context, '支持不登录解析');
    } else {
      await Navigator.push<void>(
        context,
        MaterialPageRoute(
          builder: (_) => PageFrame(title: '蓝奏云解析', child: ParsePage(services)),
        ),
      );
    }
  }

  Future<void> _open(BuildContext context, CloudPlatform? platform) async {
    if (platform == null) {
      message(context, '该网盘暂未开放');
      return;
    }
    if (!allowCloudAction(context, services.control, platform)) return;
    if (!LoginCredentials.stored(
          platform,
          services.vault.credential(platform),
        ) ||
        services.accountNeedsLogin.contains(platform)) {
      await openLogin(context, services, platform);
      if (platform != CloudPlatform.lanzou &&
              platform != CloudPlatform.github ||
          !context.mounted ||
          !LoginCredentials.stored(
            platform,
            services.vault.credential(platform),
          ) ||
          services.accountNeedsLogin.contains(platform)) {
        return;
      }
    }
    final session = await busy(
      context,
      () => services.cloud.personal(platform),
      label: '正在打开${platform.shortName}…',
    );
    if (session != null && context.mounted) {
      Navigator.push(
        context,
        MaterialPageRoute<void>(builder: (_) => BrowserPage(services, session)),
      );
    }
  }

  @override
  Widget build(BuildContext context) => AnimatedBuilder(
    animation: services,
    builder: (context, _) => RefreshIndicator(
      onRefresh: services.refreshAccounts,
      child: LayoutBuilder(
        builder: (context, constraints) {
          final wide =
              constraints.maxWidth >= 800 &&
              MediaQuery.textScalerOf(context).scale(15) <= 21;
          final preferences = CloudListPreferences(
            services.store.data['cloudListPreferences'],
            cloudEntries.map((entry) => entry.$3).whereType<CloudPlatform>(),
          );
          final entries = [
            for (final platform in preferences.order)
              if (!preferences.hidden.contains(platform))
                cloudEntries.firstWhere((entry) => entry.$3 == platform),
          ];
          return CustomScrollView(
            key: const PageStorageKey('cloud-list'),
            physics: const AlwaysScrollableScrollPhysics(),
            slivers: [
              if (entries.isEmpty)
                SliverFillRemaining(
                  hasScrollBody: false,
                  child: Center(
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        const Text('暂未显示任何网盘'),
                        const SizedBox(height: 12),
                        OutlinedButton.icon(
                          onPressed: () => Navigator.push<void>(
                            context,
                            MaterialPageRoute(
                              builder: (_) => CloudListSettingsPage(services),
                            ),
                          ),
                          icon: const Icon(CupertinoIcons.slider_horizontal_3),
                          label: const Text('排序与隐藏'),
                        ),
                      ],
                    ),
                  ),
                ),
              if (services.migrationError != null)
                SliverToBoxAdapter(
                  child: Padding(
                    padding: const EdgeInsets.all(16),
                    child: Text(
                      services.migrationError!,
                      style: TextStyle(
                        color: Theme.of(context).colorScheme.error,
                        fontSize: 12,
                      ),
                    ),
                  ),
                ),
              SliverPadding(
                padding: EdgeInsets.fromLTRB(
                  16,
                  4,
                  16,
                  16 + MediaQuery.paddingOf(context).bottom,
                ),
                sliver: wide
                    ? SliverGrid(
                        delegate: SliverChildBuilderDelegate(
                          (context, index) => _card(context, entries[index]),
                          childCount: entries.length,
                        ),
                        gridDelegate:
                            const SliverGridDelegateWithFixedCrossAxisCount(
                              crossAxisCount: 2,
                              mainAxisSpacing: 12,
                              crossAxisSpacing: 16,
                              mainAxisExtent: 86,
                            ),
                      )
                    : SliverList.separated(
                        itemCount: entries.length,
                        separatorBuilder: (_, _) => const SizedBox(height: 8),
                        itemBuilder: (context, index) =>
                            _card(context, entries[index]),
                      ),
              ),
            ],
          );
        },
      ),
    ),
  );
  Widget _card(BuildContext context, (String, String, CloudPlatform?) entry) {
    final platform = entry.$3;
    return AppContextMenu<String>(
      key: ValueKey('cloud-context-${platform?.key ?? entry.$1}'),
      identity: (
        platform,
        platform == null ? null : services.vault.activeAccountId(platform),
      ),
      actions: () {
        final stored =
            platform != null &&
            LoginCredentials.stored(
              platform,
              services.vault.credential(platform),
            );
        return [
          const AppMenuAction(
            value: 'open',
            label: '打开',
            icon: CupertinoIcons.folder_open,
          ),
          if (platform != null && platform.requiresAccount) ...[
            AppMenuAction(
              value: 'login',
              label: stored ? '重新登录当前账号' : '登录账号',
              icon: CupertinoIcons.person_crop_circle,
            ),
            const AppMenuAction(
              value: 'accounts',
              label: '多账号管理',
              icon: CupertinoIcons.person_2,
            ),
            const AppMenuAction(
              value: 'info',
              label: '账号配置',
              icon: CupertinoIcons.slider_horizontal_3,
            ),
            if (stored) ...[
              AppMenuAction(
                value: 'refresh',
                label: platform == CloudPlatform.github ? '刷新账号信息' : '刷新账号容量',
                icon: CupertinoIcons.refresh,
              ),
              if (platform == CloudPlatform.uc)
                const AppMenuAction(
                  value: 'ucTv',
                  label: 'TV 播放授权',
                  icon: CupertinoIcons.tv,
                ),
              const AppMenuAction(
                value: 'logout',
                label: '退出账号',
                icon: CupertinoIcons.square_arrow_right,
                destructive: true,
              ),
            ],
          ],
        ];
      },
      onSelected: (action) async {
        if (action == 'open') {
          await _open(context, platform);
        } else if (platform != null) {
          await accountMenu(context, services, platform, command: action);
        }
      },
      child: _cardContent(context, entry),
    );
  }

  Widget _cardContent(
    BuildContext context,
    (String, String, CloudPlatform?) entry,
  ) {
    final platform = entry.$3,
        credential = platform == null
            ? null
            : services.vault.credential(platform);
    final active =
        platform != null && LoginCredentials.stored(platform, credential);
    final paused = platform != null && !services.control.cloudEnabled(platform);
    final customName = platform == null
        ? ''
        : services.vault
                  .profiles(platform)
                  .where((a) => a.active)
                  .firstOrNull
                  ?.customName ??
              '';
    final account = services.accounts[platform],
        quota =
            active &&
            !paused &&
            (services.accounts[platform]?.total ?? 0) > 0 &&
            !services.accountErrors.containsKey(platform);
    return Container(
      decoration: BoxDecoration(
        color: backgroundSurface(context),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: border(context), width: .6),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: .085),
            blurRadius: 10,
            offset: const Offset(0, 3),
          ),
        ],
      ),
      child: Material(
        color: Colors.transparent,
        borderRadius: BorderRadius.circular(12),
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: () => _open(context, platform),
          onLongPress: platform == null || !platform.requiresAccount
              ? null
              : () => accountMenu(context, services, platform),
          child: ConstrainedBox(
            constraints: const BoxConstraints(minHeight: 64),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 11),
              child: Row(
                children: [
                  PlatformMark(icon: entry.$1),
                  const SizedBox(width: 14),
                  Expanded(
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Row(
                          children: [
                            Expanded(
                              child: Text(
                                entry.$2,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: TextStyle(
                                  fontSize: 15,
                                  fontWeight: FontWeight.w700,
                                  color: platform == null || paused
                                      ? secondary(context)
                                      : null,
                                ),
                              ),
                            ),
                            if (platform == null || paused)
                              Container(
                                padding: const EdgeInsets.symmetric(
                                  horizontal: 8,
                                  vertical: 1,
                                ),
                                decoration: BoxDecoration(
                                  color: fill(context),
                                  borderRadius: BorderRadius.circular(4),
                                ),
                                child: Text(
                                  paused ? '暂停服务' : '暂未开放',
                                  style: TextStyle(
                                    fontSize: 10,
                                    color: secondary(context),
                                  ),
                                ),
                              ),
                          ],
                        ),
                        const SizedBox(height: 3),
                        if (customName.isNotEmpty)
                          Padding(
                            padding: const EdgeInsets.only(bottom: 3),
                            child: Text(
                              customName,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: TextStyle(
                                fontSize: 12,
                                color: themeAccent(context),
                              ),
                            ),
                          ),
                        if (paused)
                          Text(
                            services.control.config
                                .cloud(platform)
                                .reason(platform),
                            key: ValueKey('cloud-disabled-${platform.name}'),
                            maxLines: 2,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                              fontSize: 12,
                              color: secondary(context),
                            ),
                          )
                        else if (quota) ...[
                          Text.rich(
                            TextSpan(
                              children: [
                                TextSpan(
                                  text: formatBytes(account!.used),
                                  style: TextStyle(
                                    color: quotaColor(
                                      account.used,
                                      account.total,
                                    ),
                                  ),
                                ),
                                TextSpan(
                                  text: ' / ${formatBytes(account.total)}',
                                  style: TextStyle(color: secondary(context)),
                                ),
                              ],
                            ),
                            style: const TextStyle(fontSize: 12),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                          const SizedBox(height: 5),
                          ClipRRect(
                            borderRadius: BorderRadius.circular(3),
                            child: LinearProgressIndicator(
                              value: (account.used / account.total).clamp(0, 1),
                              minHeight: 3,
                              key: ValueKey('quota-${platform.key}'),
                              color: quotaColor(account.used, account.total),
                              semanticsLabel: '存储空间占用百分比',
                              semanticsValue:
                                  '${(account.used / account.total * 100).clamp(0, 100).round()}',
                              backgroundColor: fill(context),
                            ),
                          ),
                        ] else if (active &&
                            services.accountErrors.containsKey(platform) &&
                            !services.accountLoading.contains(platform))
                          InkWell(
                            key: ValueKey('quota-retry-${platform.key}'),
                            onTap: () =>
                                services.accountNeedsLogin.contains(platform)
                                ? openLogin(context, services, platform)
                                : services.refreshAccount(platform),
                            child: Padding(
                              padding: const EdgeInsets.symmetric(vertical: 4),
                              child: Row(
                                children: [
                                  Icon(
                                    CupertinoIcons.arrow_clockwise,
                                    size: 13,
                                    color: themeAccent(context),
                                  ),
                                  const SizedBox(width: 4),
                                  Expanded(
                                    child: Text(
                                      services.accountErrors[platform]!,
                                      maxLines: 2,
                                      overflow: TextOverflow.ellipsis,
                                      style: TextStyle(
                                        fontSize: 12,
                                        color: themeAccent(context),
                                      ),
                                    ),
                                  ),
                                ],
                              ),
                            ),
                          )
                        else
                          Text(
                            active
                                ? services.accountLoading.contains(platform)
                                      ? '正在读取容量…'
                                      : services.accountErrors[platform] ??
                                            account?.nickname ??
                                            credential?.field('nickname') ??
                                            '已登录'
                                : '未登录',
                            style: TextStyle(
                              fontSize: 13,
                              color: secondary(context),
                            ),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                      ],
                    ),
                  ),
                  if (platform == CloudPlatform.lanzou)
                    IconButton(
                      tooltip: '${entry.$2}解析',
                      onPressed: () => _parseLanzou(context),
                      icon: Icon(
                        CupertinoIcons.link,
                        size: 17,
                        color: themeAccent(context),
                      ),
                    ),
                  IconButton(
                    tooltip: '${entry.$2}账号操作',
                    visualDensity: VisualDensity.compact,
                    constraints: const BoxConstraints(
                      minWidth: 36,
                      minHeight: 40,
                    ),
                    icon: Icon(
                      CupertinoIcons.ellipsis,
                      size: 21,
                      color: secondary(context),
                    ),
                    onPressed: () => platform == null
                        ? message(context, '该网盘暂未开放')
                        : active
                        ? accountMenu(context, services, platform)
                        : openLogin(context, services, platform),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class CloudListSettingsPage extends StatefulWidget {
  const CloudListSettingsPage(this.services, {super.key});
  final AppServices services;

  @override
  State<CloudListSettingsPage> createState() => _CloudListSettingsPageState();
}

class _CloudListSettingsPageState extends State<CloudListSettingsPage> {
  late CloudListPreferences _preferences;
  bool _saving = false;

  Iterable<CloudPlatform> get _defaults =>
      cloudEntries.map((entry) => entry.$3).whereType<CloudPlatform>();

  @override
  void initState() {
    super.initState();
    _preferences = CloudListPreferences(
      widget.services.store.data['cloudListPreferences'],
      _defaults,
    );
  }

  void _reorder(int oldIndex, int newIndex) {
    if (_saving) return;
    setState(() {
      if (newIndex > oldIndex) newIndex--;
      final platform = _preferences.order.removeAt(oldIndex);
      _preferences.order.insert(newIndex, platform);
    });
  }

  Future<void> _save() async {
    setState(() => _saving = true);
    try {
      await widget.services.store.put(
        'cloudListPreferences',
        _preferences.toJson(),
      );
      if (mounted) {
        setState(() => _saving = false);
        Navigator.pop(context);
      }
    } catch (error) {
      if (mounted) {
        setState(() => _saving = false);
        message(context, errorText(error));
      }
    }
  }

  @override
  Widget build(BuildContext context) => PopScope(
    canPop: !_saving,
    child: Scaffold(
      appBar: AppBar(
        title: const Text('排序与隐藏'),
        actions: [
          TextButton(
            onPressed: _saving ? null : _save,
            child: Text(_saving ? '保存中' : '完成'),
          ),
          const SizedBox(width: 8),
        ],
      ),
      body: SafeArea(
        top: false,
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 720),
            child: Column(
              children: [
                Padding(
                  padding: const EdgeInsets.fromLTRB(20, 8, 12, 8),
                  child: Row(
                    children: [
                      const Expanded(child: Text('拖动右侧手柄排序，关闭开关隐藏。点击完成保存。')),
                      TextButton(
                        onPressed: _saving
                            ? null
                            : () => setState(() {
                                _preferences = CloudListPreferences(
                                  null,
                                  _defaults,
                                );
                              }),
                        child: const Text('恢复默认'),
                      ),
                    ],
                  ),
                ),
                Expanded(
                  child: ReorderableListView.builder(
                    buildDefaultDragHandles: false,
                    padding: const EdgeInsets.fromLTRB(12, 0, 12, 16),
                    itemCount: _preferences.order.length,
                    onReorder: _reorder,
                    itemBuilder: (context, index) {
                      final platform = _preferences.order[index];
                      final entry = cloudEntries.firstWhere(
                        (entry) => entry.$3 == platform,
                      );
                      final visible = !_preferences.hidden.contains(platform);
                      return Semantics(
                        key: ValueKey('cloud-layout-${platform.name}'),
                        customSemanticsActions: {
                          if (index > 0 && !_saving)
                            const CustomSemanticsAction(label: '上移'): () =>
                                _reorder(index, index - 1),
                          if (index < _preferences.order.length - 1 && !_saving)
                            const CustomSemanticsAction(label: '下移'): () =>
                                _reorder(index, index + 2),
                        },
                        child: Card(
                          elevation: 0,
                          margin: const EdgeInsets.only(bottom: 8),
                          child: Padding(
                            padding: const EdgeInsets.only(
                              left: 14,
                              top: 6,
                              bottom: 6,
                            ),
                            child: Row(
                              children: [
                                PlatformMark(icon: entry.$1),
                                const SizedBox(width: 12),
                                Expanded(
                                  child: Text(
                                    entry.$2,
                                    style: TextStyle(
                                      color: visible
                                          ? null
                                          : Theme.of(context).disabledColor,
                                    ),
                                  ),
                                ),
                                AppSwitch(
                                  key: ValueKey(
                                    'cloud-visible-${platform.name}',
                                  ),
                                  value: visible,
                                  onChanged: _saving
                                      ? null
                                      : (value) => setState(() {
                                          if (value) {
                                            _preferences.hidden.remove(
                                              platform,
                                            );
                                          } else {
                                            _preferences.hidden.add(platform);
                                          }
                                        }),
                                ),
                                ReorderableDragStartListener(
                                  index: index,
                                  enabled: !_saving,
                                  child: const Tooltip(
                                    message: '拖动排序',
                                    child: SizedBox(
                                      width: 48,
                                      height: 48,
                                      child: Icon(
                                        CupertinoIcons.line_horizontal_3,
                                        size: 22,
                                      ),
                                    ),
                                  ),
                                ),
                              ],
                            ),
                          ),
                        ),
                      );
                    },
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    ),
  );
}
