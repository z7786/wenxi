import 'package:flutter/material.dart';
import 'app_switch.dart';
import '../app_services.dart';
import 'common.dart';

class ExperimentalFeaturesPage extends StatelessWidget {
  const ExperimentalFeaturesPage(this.services, {super.key});
  final AppServices services;

  Widget _toggle(
    BuildContext context, {
    required String setting,
    required String title,
    required String description,
    required bool value,
  }) => AppSwitchListTile(
    key: ValueKey(setting),
    contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
    title: Text(
      title,
      style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w500),
    ),
    subtitle: Text(
      description,
      style: TextStyle(fontSize: 12, height: 1.5, color: secondary(context)),
    ),
    value: value,
    onChanged: (enabled) async {
      try {
        await services.updateSettings({setting: enabled});
      } catch (error) {
        if (context.mounted) message(context, errorText(error));
      }
    },
  );

  Widget _cloud(
    BuildContext context, {
    required String title,
    required String guestDescription,
    required String guestSetting,
    required bool guestEnabled,
    bool? authenticatedEnabled,
    bool guestDefaultOn = false,
  }) => Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      Padding(
        padding: const EdgeInsets.only(left: 4, bottom: 10),
        child: Text(
          title,
          style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w600),
        ),
      ),
      Material(
        color: Theme.of(context).colorScheme.surface,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(16),
          side: BorderSide(color: border(context), width: .7),
        ),
        clipBehavior: Clip.antiAlias,
        child: Column(
          children: [
            _toggle(
              context,
              setting: guestSetting,
              title: '游客下载',
              description: guestDefaultOn
                  ? '$guestDescription已登录时优先使用账号解析下载。此开关默认开启，账号下载失败后允许尝试游客下载；关闭后仅使用账号下载。未登录时仍自动使用游客下载。'
                  : '$guestDescription未登录对应网盘时自动使用；登录后开启此项才会优先尝试游客下载。',
              value: guestEnabled,
            ),
            if (authenticatedEnabled != null) ...[
              Divider(
                height: 1,
                thickness: .6,
                indent: 16,
                endIndent: 16,
                color: border(context),
              ),
              _toggle(
                context,
                setting: 'quarkAuthenticatedDirectDownload',
                title: '突破文件大小限制',
                description:
                    '需要登录夸克账号。默认正常转存下载；检测到网盘空间不足时，自动为当前下载尝试免转存，无需手动开启。'
                    '开启后优先使用免转存下载，接口不可用时尝试正常下载。'
                    '此开关不改变视频播放路线；分享播放遇到网盘空间不足时也会自动尝试免转存播放。',
                value: authenticatedEnabled,
              ),
            ],
          ],
        ),
      ),
    ],
  );

  @override
  Widget build(BuildContext context) => PageFrame(
    title: '实验性功能',
    child: ConstrainedBox(
      constraints: const BoxConstraints(maxWidth: 720),
      child: AnimatedBuilder(
        animation: services.store,
        builder: (context, _) {
          final settings = services.settings;
          return ListView(
            padding: const EdgeInsets.fromLTRB(18, 20, 18, 28),
            children: [
              _cloud(
                context,
                title: '夸克网盘',
                guestDescription: '单个文件不能超过 50 MB。',
                guestSetting: 'quarkGuestDirectDownload',
                guestEnabled: settings.quarkGuestDirectDownload,
                authenticatedEnabled: settings.quarkAuthenticatedDirectDownload,
              ),
              const SizedBox(height: 24),
              _cloud(
                context,
                title: 'UC 网盘',
                guestDescription: '无需登录，游客下载不限制文件大小。',
                guestSetting: 'ucGuestDirectDownload',
                guestEnabled: settings.ucGuestDirectDownload,
                guestDefaultOn: true,
              ),
            ],
          );
        },
      ),
    ),
  );
}
