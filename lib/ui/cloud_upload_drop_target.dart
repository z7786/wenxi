import 'package:desktop_drop/desktop_drop.dart';
import 'package:file_selector/file_selector.dart';
import 'package:flutter/cupertino.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'common.dart';

/// Accepts desktop files and supported folders while this directory is visible.
class CloudUploadDropTarget extends StatefulWidget {
  const CloudUploadDropTarget({
    super.key,
    required this.enabled,
    required this.folderName,
    required this.onFilesDropped,
    required this.child,
    this.foldersSupported = false,
  });

  static bool get supported =>
      !kIsWeb &&
      (defaultTargetPlatform == TargetPlatform.windows ||
          defaultTargetPlatform == TargetPlatform.macOS);

  final bool enabled;
  final bool foldersSupported;
  final String folderName;
  final ValueChanged<List<XFile>> onFilesDropped;
  final Widget child;

  @override
  State<CloudUploadDropTarget> createState() => _CloudUploadDropTargetState();
}

class _CloudUploadDropTargetState extends State<CloudUploadDropTarget> {
  bool _hovering = false;
  bool get _enabled =>
      widget.enabled && (ModalRoute.isCurrentOf(context) ?? true);

  @override
  void didUpdateWidget(CloudUploadDropTarget oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!widget.enabled) _hovering = false;
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (!_enabled) _hovering = false;
  }

  void _hover(bool value) {
    if (!mounted || _hovering == value || value && !_enabled) return;
    setState(() => _hovering = value);
  }

  @override
  Widget build(BuildContext context) {
    if (!CloudUploadDropTarget.supported) return widget.child;
    final enabled = _enabled;
    final accent = themeAccent(context);
    return DropTarget(
      key: const Key('cloud-upload-drop-target'),
      enable: enabled,
      onDragEntered: (_) => _hover(true),
      onDragUpdated: (_) => _hover(true),
      onDragExited: (_) => _hover(false),
      onDragDone: (details) {
        _hover(false);
        if (_enabled && details.files.isNotEmpty) {
          widget.onFilesDropped(List<XFile>.of(details.files));
        }
      },
      child: Stack(
        fit: StackFit.expand,
        children: [
          widget.child,
          if (enabled && _hovering)
            Positioned.fill(
              child: IgnorePointer(
                child: Container(
                  key: const Key('cloud-upload-drop-overlay'),
                  margin: const EdgeInsets.all(12),
                  decoration: BoxDecoration(
                    color: Theme.of(
                      context,
                    ).colorScheme.surface.withValues(alpha: .96),
                    borderRadius: BorderRadius.circular(16),
                    border: Border.all(color: accent, width: 2),
                  ),
                  child: Center(
                    child: SingleChildScrollView(
                      padding: const EdgeInsets.all(24),
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Icon(
                            CupertinoIcons.cloud_upload,
                            size: 44,
                            color: accent,
                          ),
                          const SizedBox(height: 16),
                          Text(
                            widget.foldersSupported
                                ? '松开鼠标上传文件或文件夹'
                                : '松开鼠标上传文件',
                            textAlign: TextAlign.center,
                            style: TextStyle(
                              fontSize: 18,
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                          const SizedBox(height: 8),
                          Text(
                            '上传到“${widget.folderName}” · ${widget.foldersSupported ? '文件夹保留原目录结构' : '支持多个文件'}',
                            textAlign: TextAlign.center,
                            maxLines: 3,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                              fontSize: 13,
                              color: secondary(context),
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }
}
