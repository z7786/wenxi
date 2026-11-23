import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import '../app_services.dart';
import '../data/http.dart';
import '../domain/download_destination.dart';
import '../domain/models.dart';
import 'app_switch.dart';
import 'common.dart';

export '../domain/download_destination.dart';

final _openPickers = Expando<bool>();

bool get supportsDownloadLocationChoice => switch (defaultTargetPlatform) {
  TargetPlatform.windows ||
  TargetPlatform.macOS ||
  TargetPlatform.linux => true,
  _ => false,
};

Future<DownloadDestinationSelection?> chooseDownloadLocation(
  BuildContext context,
  AppServices services, {
  bool alwaysAsk = false,
}) async {
  if (!context.mounted) return null;
  final initial = DownloadDestinationSelection(services.settings.destination);
  if (!supportsDownloadLocationChoice) return initial;
  if (!alwaysAsk && !services.settings.askDownloadDestination) return initial;
  if (_openPickers[services] == true) return null;
  _openPickers[services] = true;
  var selection = initial;
  var choosing = false;
  try {
    final result = await showDialog<DownloadDestinationSelection>(
      context: context,
      builder: (context) => StatefulBuilder(
        builder: (context, update) => AlertDialog(
          title: const Text('下载保存位置'),
          content: SizedBox(
            width: 440,
            child: SingleChildScrollView(
              child: DownloadLocationField(
                services: services,
                selection: selection,
                onChanged: (value) => update(() => selection = value),
                onChoosing: (value) => update(() => choosing = value),
              ),
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('取消'),
            ),
            FilledButton(
              key: const Key('download-location-confirm'),
              onPressed: choosing
                  ? null
                  : () => Navigator.pop(context, selection),
              child: const Text('开始下载'),
            ),
          ],
        ),
      ),
    );
    return context.mounted ? result : null;
  } finally {
    _openPickers[services] = false;
  }
}

/// Player callbacks use the existing cancellation signal so they do not mark
/// a dismissed directory picker as an added download.
Future<String> enqueueDownloadFromUi(
  BuildContext context,
  AppServices services,
  DownloadSpec source,
) async {
  final location = await chooseDownloadLocation(context, services);
  if (location == null) throw const DownloadConfirmationCancelled();
  RequestScope.checkpoint();
  return services.downloads.enqueue(source, location: location);
}

class DownloadLocationField extends StatefulWidget {
  const DownloadLocationField({
    super.key,
    required this.services,
    required this.selection,
    required this.onChanged,
    this.enabled = true,
    this.compact = false,
    this.onChoosing,
  });
  final AppServices services;
  final DownloadDestinationSelection selection;
  final ValueChanged<DownloadDestinationSelection> onChanged;
  final bool enabled, compact;
  final ValueChanged<bool>? onChoosing;

  @override
  State<DownloadLocationField> createState() => _DownloadLocationFieldState();
}

class _DownloadLocationFieldState extends State<DownloadLocationField> {
  bool _choosing = false;
  String? _error;

  void _select(String? path) => widget.onChanged(
    DownloadDestinationSelection(
      path,
      makeDefault: widget.selection.makeDefault,
    ),
  );

  void _setDefault(bool value) => widget.onChanged(
    DownloadDestinationSelection(widget.selection.path, makeDefault: value),
  );

  Future<void> _browse() async {
    if (_choosing) return;
    setState(() {
      _choosing = true;
      _error = null;
    });
    widget.onChoosing?.call(true);
    try {
      final path = await widget.services.files.chooseDirectory();
      if (mounted && path != null) _select(path);
    } catch (error) {
      if (mounted) setState(() => _error = errorText(error));
    } finally {
      if (mounted) {
        setState(() => _choosing = false);
        widget.onChoosing?.call(false);
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final enabled = widget.enabled && !_choosing;
    final options = <String?>{
      widget.selection.path,
      widget.services.settings.destination,
      ...DownloadDestinationSelection.recent(widget.services.store.data),
      null,
    }.toList();
    Widget directoryChoice() => PopupMenuButton<int>(
      key: const Key('download-location-recent'),
      enabled: enabled,
      tooltip: '默认与最近目录',
      onSelected: (index) => index == -1
          ? _setDefault(!widget.selection.makeDefault)
          : _select(options[index]),
      itemBuilder: (_) => [
        for (var i = 0; i < options.length; i++)
          PopupMenuItem<int>(
            value: i,
            child: Text(
              options[i] == null
                  ? '系统下载目录'
                  : '${options[i]}${options[i] == widget.services.settings.destination ? '（默认）' : ''}',
              maxLines: 3,
              overflow: TextOverflow.ellipsis,
            ),
          ),
        if (widget.compact) ...[
          const PopupMenuDivider(),
          CheckedPopupMenuItem<int>(
            key: const Key('download-location-default'),
            value: -1,
            checked: widget.selection.makeDefault,
            child: const Text('设为默认目录'),
          ),
        ],
      ],
      child: InputDecorator(
        decoration: const InputDecoration(
          labelText: '保存位置',
          suffixIcon: Icon(Icons.arrow_drop_down),
          isDense: true,
        ),
        child: Text(
          widget.selection.path ?? '系统下载目录',
          maxLines: widget.compact ? 1 : 3,
          overflow: TextOverflow.ellipsis,
        ),
      ),
    );
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Expanded(child: directoryChoice()),
            const SizedBox(width: 8),
            IconButton(
              key: const Key('download-location-browse'),
              tooltip: '浏览…',
              onPressed: enabled ? _browse : null,
              icon: const Icon(Icons.folder_open),
            ),
          ],
        ),
        if (!widget.compact)
          AppSwitchListTile(
            key: const Key('download-location-default'),
            contentPadding: EdgeInsets.zero,
            title: const Text('设为默认目录', style: TextStyle(fontSize: 13)),
            value: widget.selection.makeDefault,
            onChanged: enabled ? _setDefault : null,
          ),
        if (_error != null)
          Text(
            _error!,
            style: TextStyle(color: Theme.of(context).colorScheme.error),
          ),
      ],
    );
  }
}
