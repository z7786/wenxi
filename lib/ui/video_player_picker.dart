import 'package:file_selector/file_selector.dart';
import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:path/path.dart' as p;
import '../data/external_player_history.dart';

/// Selects a desktop player for this manual playback request.
Future<String?> chooseDesktopVideoPlayer(
  BuildContext context,
  ExternalPlayerHistory historyStore, {
  required String platform,
  Future<XFile?> Function()? chooseFile,
  bool Function()? isActive,
}) async {
  final history = platform == 'macos'
      ? historyStore.macos
      : historyStore.windows;
  final saved = history.firstOrNull ?? '';
  if (history.isNotEmpty) {
    final route = DialogRoute<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('选择外部播放器'),
        content: SizedBox(
          width: 380,
          child: ListView(
            shrinkWrap: true,
            children: [
              const Text('选择最近使用的播放器。'),
              const SizedBox(height: 8),
              for (final path in history)
                ListTile(
                  key: ValueKey('external-player-$path'),
                  leading: const Icon(CupertinoIcons.play_rectangle),
                  title: Text(p.basename(path)),
                  subtitle: Text(
                    path,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                  onTap: () => Navigator.pop(context, path),
                ),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('取消'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(context, 'choose'),
            child: const Text('选择其他播放器'),
          ),
        ],
      ),
    );
    final selected = await Navigator.of(context).push(route);
    // Wait until the Flutter modal has released focus before opening the
    // native file dialog. Reentrant dialogs can leave Windows' owner disabled.
    await route.completed;
    if (selected == null || !context.mounted || isActive?.call() == false) {
      return null;
    }
    if (selected != 'choose') return selected;
  }
  if (platform == 'macos' && chooseFile == null) {
    return const MethodChannel(
      'com.asterlink.app/native',
    ).invokeMethod<String>('selectExternalPlayer');
  }
  final selected =
      await (chooseFile?.call() ??
          openFile(
            acceptedTypeGroups: const [
              XTypeGroup(label: '播放器程序', extensions: ['exe']),
            ],
            initialDirectory: saved.isNotEmpty ? p.dirname(saved) : null,
            confirmButtonText: '选择播放器',
          ));
  if (!context.mounted || isActive?.call() == false) return null;
  return selected?.path;
}
