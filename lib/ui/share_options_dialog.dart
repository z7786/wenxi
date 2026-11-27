import 'package:flutter/material.dart';
import '../domain/models.dart';

class ShareRequest {
  const ShareRequest(this.options, {required this.individual});
  final ShareOptions options;
  final bool individual;
}

class ShareOptionsDialog extends StatefulWidget {
  const ShareOptionsDialog(this.files, this.platform, {super.key});
  final List<CloudFile> files;
  final CloudPlatform platform;
  @override
  State<ShareOptionsDialog> createState() => _ShareOptionsDialogState();
}

class _ShareOptionsDialogState extends State<ShareOptionsDialog> {
  late final title = TextEditingController(
    text: widget.files.length == 1
        ? widget.files.first.name
        : '${widget.files.first.name} 等 ${widget.files.length} 项',
  );
  final passcode = TextEditingController();
  bool get usesDefaultShare =>
      {CloudPlatform.lanzou, CloudPlatform.ctfile}.contains(widget.platform);
  late int days = usesDefaultShare ? 0 : 7;
  late bool individual = widget.files.length > 1 && usesDefaultShare;
  @override
  void dispose() {
    title.dispose();
    passcode.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
    title: const Text('创建分享'),
    content: SizedBox(
      width: 380,
      child: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (widget.files.length > 1) ...[
              DropdownButtonFormField<bool>(
                isExpanded: true,
                initialValue: individual,
                decoration: const InputDecoration(labelText: '分享方式'),
                items: [
                  if (!usesDefaultShare)
                    const DropdownMenuItem(
                      value: false,
                      child: Text('合并分享（一个链接）'),
                    ),
                  const DropdownMenuItem(
                    value: true,
                    child: Text('单文件批量分享（多个链接）'),
                  ),
                ],
                onChanged: usesDefaultShare
                    ? null
                    : (value) => setState(() => individual = value ?? false),
              ),
              const SizedBox(height: 16),
            ],
            if (individual)
              const Text('每个文件或文件夹分别生成分享链接，标题使用各自名称。')
            else
              TextField(
                controller: title,
                decoration: const InputDecoration(labelText: '分享标题'),
              ),
            const SizedBox(height: 16),
            DropdownButtonFormField<int>(
              isExpanded: true,
              initialValue: days,
              decoration: const InputDecoration(labelText: '有效期'),
              items: [
                if (!usesDefaultShare) ...[
                  const DropdownMenuItem(value: 1, child: Text('1 天')),
                  const DropdownMenuItem(value: 7, child: Text('7 天')),
                  if (widget.platform != CloudPlatform.tianyi)
                    const DropdownMenuItem(value: 30, child: Text('30 天')),
                ],
                const DropdownMenuItem(value: 0, child: Text('永久')),
              ],
              onChanged: usesDefaultShare ? null : (v) => days = v ?? 7,
            ),
            const SizedBox(height: 16),
            if (widget.platform == CloudPlatform.ctfile)
              const Text('提取码沿用城通账号的默认设置，可在官网修改。一次可分享一个文件或文件夹。')
            else if (widget.platform == CloudPlatform.c139)
              const Text('提取码由移动云盘自动生成')
            else if (widget.platform == CloudPlatform.tianyi)
              const Text('访问码由天翼云盘自动生成')
            else
              TextField(
                controller: passcode,
                decoration: InputDecoration(
                  labelText: widget.platform == CloudPlatform.baidu
                      ? '提取码（留空自动生成）'
                      : '提取码（可选）',
                  helperText: widget.platform == CloudPlatform.baidu
                      ? '4 位字母或数字'
                      : null,
                ),
              ),
          ],
        ),
      ),
    ),
    actions: [
      TextButton(
        onPressed: () => Navigator.pop(context),
        child: const Text('取消'),
      ),
      TextButton(
        onPressed: () => Navigator.pop(
          context,
          ShareRequest(
            ShareOptions(
              title.text.trim(),
              expiryDays: days == 0 ? null : days,
              passcode: passcode.text.trim().isEmpty
                  ? null
                  : passcode.text.trim(),
            ),
            individual: individual,
          ),
        ),
        child: const Text('创建'),
      ),
    ],
  );
}
