import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import '../data/cloud_favorites.dart';
import 'common.dart';

Future<String?> chooseCloudFavoriteFolder(
  BuildContext context,
  CloudFavorites favorites, {
  String selectedId = '',
  String? resourceName,
  String title = '选择收藏分类',
  String confirmLabel = '确定',
}) async {
  return showDialog<String>(
    context: context,
    builder: (_) => _CloudFavoriteDialog(
      favorites,
      selectedId: selectedId,
      resourceName: resourceName,
      title: title,
      confirmLabel: confirmLabel,
    ),
  );
}

Future<void> editCloudFavorite(
  BuildContext context,
  CloudFavorites favorites,
  CloudFavorite favorite,
) async {
  await showDialog<String>(
    context: context,
    builder: (_) => _CloudFavoriteDialog(
      favorites,
      favorite: favorite,
      selectedId: favorites.folderOf(favorite),
      title: '编辑收藏',
      confirmLabel: '保存',
    ),
  );
}

class _CloudFavoriteDialog extends StatefulWidget {
  const _CloudFavoriteDialog(
    this.favorites, {
    required this.selectedId,
    required this.title,
    required this.confirmLabel,
    this.resourceName,
    this.favorite,
  });

  final CloudFavorites favorites;
  final CloudFavorite? favorite;
  final String selectedId, title, confirmLabel;
  final String? resourceName;

  @override
  State<_CloudFavoriteDialog> createState() => _CloudFavoriteDialogState();
}

class _CloudFavoriteDialogState extends State<_CloudFavoriteDialog> {
  late final _name = TextEditingController(text: widget.favorite?.customName);
  late String _folderId = widget.selectedId;
  bool _working = false, _askingName = false;
  String? _error;

  @override
  void dispose() {
    _name.dispose();
    super.dispose();
  }

  Future<void> _createFolder() async {
    if (_working) return;
    setState(() {
      _working = true;
      _askingName = true;
      _error = null;
    });
    try {
      final name = await askText(context, '新建收藏分类', hint: '1–80 字');
      if (name == null || !mounted) return;
      setState(() => _askingName = false);
      final id = await widget.favorites.createFolder(name);
      if (mounted) setState(() => _folderId = id);
    } catch (error) {
      if (mounted) setState(() => _error = errorText(error));
    } finally {
      if (mounted) {
        setState(() {
          _working = false;
          _askingName = false;
        });
      }
    }
  }

  Future<void> _save() async {
    if (_working) return;
    setState(() {
      _working = true;
      _error = null;
    });
    try {
      if (widget.favorite case final favorite?) {
        await widget.favorites.edit(
          favorite.id,
          name: _name.text,
          folderId: _folderId,
        );
      }
      if (mounted) {
        Navigator.pop(context, _folderId);
      }
    } catch (error) {
      if (mounted) setState(() => _error = errorText(error));
    } finally {
      if (mounted) setState(() => _working = false);
    }
  }

  @override
  Widget build(BuildContext context) => AnimatedBuilder(
    animation: widget.favorites.store,
    builder: (context, _) {
      final folders = widget.favorites.folders;
      final missing =
          _folderId.isNotEmpty && !folders.any((f) => f.id == _folderId);
      return PopScope(
        canPop: !_working,
        child: AlertDialog(
          key: const Key('favorite-details-dialog'),
          title: Text(widget.title),
          scrollable: true,
          content: SizedBox(
            width: 360,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                if (widget.favorite case final favorite?)
                  TextField(
                    key: const Key('favorite-edit-name'),
                    controller: _name,
                    enabled: !_working,
                    decoration: InputDecoration(
                      labelText: '收藏名称',
                      hintText: favorite.file.displayName,
                      helperText: '最多 80 字，留空使用原名称',
                      helperMaxLines: 3,
                    ),
                    onChanged: (_) => setState(() => _error = null),
                  )
                else if (widget.resourceName case final name?)
                  Text(name, maxLines: 2, overflow: TextOverflow.ellipsis),
                const SizedBox(height: 16),
                DropdownButtonFormField<String>(
                  key: ValueKey('favorite-category-select-$_folderId'),
                  initialValue: _folderId,
                  isExpanded: true,
                  menuMaxHeight: 320,
                  decoration: InputDecoration(
                    labelText: '分类',
                    errorText: missing ? '分类已删除，请重新选择' : null,
                  ),
                  items: [
                    for (final folder in [
                      const CloudFavoriteFolder('', '未分类'),
                      ...folders,
                    ])
                      DropdownMenuItem(
                        value: folder.id,
                        child: Text(
                          folder.name,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                    if (missing)
                      DropdownMenuItem(
                        value: _folderId,
                        enabled: false,
                        child: const Text('分类已删除'),
                      ),
                  ],
                  onChanged: _working
                      ? null
                      : (value) => setState(() {
                          _folderId = value ?? '';
                          _error = null;
                        }),
                ),
                Align(
                  alignment: Alignment.centerRight,
                  child: TextButton.icon(
                    key: const Key('favorite-category-create'),
                    onPressed: _working ? null : _createFolder,
                    icon: const Icon(
                      CupertinoIcons.folder_badge_plus,
                      size: 18,
                    ),
                    label: const Text('新建分类'),
                  ),
                ),
                if (_error != null)
                  Text(
                    _error!,
                    style: TextStyle(
                      color: Theme.of(context).colorScheme.error,
                    ),
                  ),
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: _working ? null : () => Navigator.pop(context),
              child: const Text('取消'),
            ),
            TextButton(
              key: const Key('favorite-details-save'),
              onPressed: _working || missing ? null : _save,
              child: _working && !_askingName
                  ? const SizedBox(
                      width: 18,
                      height: 18,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : Text(widget.confirmLabel),
            ),
          ],
        ),
      );
    },
  );
}
