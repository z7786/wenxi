import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';
import '../domain/remote_control.dart';
import 'common.dart';

typedef RemoteLinkLauncher = Future<bool> Function(Uri url);

Future<void> openRemoteLink(
  BuildContext context,
  Uri url, {
  RemoteLinkLauncher? launcher,
}) => _openLink(context, url, launcher: launcher);

Future<void> openAnnouncementLink(
  BuildContext context,
  Uri url, {
  RemoteLinkLauncher? launcher,
}) => _openLink(context, url, launcher: launcher, announcement: true);

Future<void> _openLink(
  BuildContext context,
  Uri url, {
  RemoteLinkLauncher? launcher,
  bool announcement = false,
}) async {
  final miniProgram = announcement && isWeChatMiniProgramLink(url);
  final failure = miniProgram
      ? '无法打开微信小程序，请检查微信是否安装、链接是否有效'
      : '无法打开链接，请检查系统默认浏览器';
  try {
    final safe = announcement
        ? announcementButtonUri(url.toString())
        : httpsUri(url.toString());
    final opened = launcher != null
        ? await launcher(safe)
        : await launchUrl(safe, mode: LaunchMode.externalApplication);
    if (!opened && context.mounted) message(context, failure);
  } catch (_) {
    if (context.mounted) message(context, failure);
  }
}
