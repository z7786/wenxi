import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:qr_flutter/qr_flutter.dart';

import '../app_services.dart';
import '../core/json.dart';
import '../lan/lan_browser_receiver.dart';
import '../platform/completed_file_actions.dart';
import '../platform/file_access.dart';
import 'common.dart';
import 'download_location_picker.dart';
import 'transfer_widgets.dart';

class LanBrowserPanel extends StatelessWidget {
  const LanBrowserPanel(this.services, {super.key, required this.address});
  final AppServices services;
  final String address;

  Future<void> _copy(BuildContext context, String text) async {
    try {
      await Clipboard.setData(ClipboardData(text: text));
      if (context.mounted) message(context, '已复制网页地址');
    } catch (_) {
      if (context.mounted) message(context, '复制失败，请重试');
    }
  }

  @override
  Widget build(BuildContext context) {
    final lan = services.lan;
    final url = lan.browserUrl(address).toString();
    return Container(
      key: const Key('lan-browser-panel'),
      margin: const EdgeInsets.only(bottom: 12),
      padding: const EdgeInsets.all(18),
      decoration: BoxDecoration(
        color: Theme.of(context).colorScheme.surface,
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: border(context)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Icon(Icons.language_rounded, color: themeAccent(context)),
              const SizedBox(width: 10),
              const Expanded(
                child: Text(
                  '浏览器传文件',
                  style: TextStyle(fontSize: 17, fontWeight: FontWeight.w600),
                ),
              ),
              if (lan.browserConnections > 0)
                Text(
                  '${lan.browserConnections} 个连接',
                  style: TextStyle(fontSize: 12, color: secondary(context)),
                ),
            ],
          ),
          const SizedBox(height: 12),
          Text(
            '在同一网络的浏览器打开下面的地址，输入本机连接码，即可上传和下载文件。',
            style: TextStyle(
              fontSize: 13,
              height: 1.6,
              color: secondary(context),
            ),
          ),
          const SizedBox(height: 8),
          Row(
            children: [
              Expanded(
                child: SelectableText(
                  url,
                  key: const Key('lan-browser-address'),
                  style: const TextStyle(fontSize: 13),
                ),
              ),
              IconButton(
                key: const Key('lan-browser-copy'),
                tooltip: '复制网页地址',
                onPressed: () => _copy(context, url),
                icon: const Icon(CupertinoIcons.doc_on_doc, size: 18),
              ),
            ],
          ),
          const SizedBox(height: 6),
          OutlinedButton.icon(
            key: const Key('lan-browser-qr'),
            onPressed: () => showModalBottomSheet<void>(
              context: context,
              showDragHandle: true,
              isScrollControlled: true,
              builder: (_) => _LanBrowserQr(services, address: address),
            ),
            icon: const Icon(CupertinoIcons.qrcode, size: 19),
            label: const Text('显示网页二维码'),
          ),
          if (lan.browserReceiver != null) ...[
            const SizedBox(height: 8),
            TextButton.icon(
              key: const Key('lan-browser-receipts'),
              onPressed: () => Navigator.push<void>(
                context,
                MaterialPageRoute(
                  builder: (_) => LanBrowserReceiptsPage(services),
                ),
              ),
              icon: const Icon(CupertinoIcons.arrow_down_doc, size: 18),
              label: Text('网页接收记录 · ${lan.browserReceiver!.records.length} 项'),
            ),
          ],
        ],
      ),
    );
  }
}

class _LanBrowserQr extends StatelessWidget {
  const _LanBrowserQr(this.services, {required this.address});
  final AppServices services;
  final String address;

  @override
  Widget build(BuildContext context) => SafeArea(
    child: SingleChildScrollView(
      padding: const EdgeInsets.fromLTRB(24, 8, 24, 28),
      child: AnimatedBuilder(
        animation: services.lan,
        builder: (context, _) {
          final lan = services.lan,
              valid =
                  services.lan.running &&
                  services.lan.addresses.contains(address);
          return Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Text(
                '浏览器扫码传文件',
                style: TextStyle(fontSize: 19, fontWeight: FontWeight.w600),
              ),
              const SizedBox(height: 18),
              if (valid) ...[
                QrImageView(
                  key: const Key('lan-browser-qr-image'),
                  data: lan.browserUrl(address).toString(),
                  size: 220,
                  padding: const EdgeInsets.all(12),
                  backgroundColor: Colors.white,
                  errorCorrectionLevel: QrErrorCorrectLevel.M,
                  semanticsLabel: '网页互传地址二维码',
                ),
                const SizedBox(height: 12),
                SelectableText(
                  lan.browserUrl(address).toString(),
                  textAlign: TextAlign.center,
                ),
                const SizedBox(height: 16),
                Text(
                  '打开网页后输入连接码 ${lan.connectionCode}',
                  style: const TextStyle(
                    fontSize: 16,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                const SizedBox(height: 8),
                Text(
                  '使用系统相机或浏览器扫码打开。两台设备需连接同一网络。',
                  textAlign: TextAlign.center,
                  style: TextStyle(
                    fontSize: 13,
                    height: 1.6,
                    color: secondary(context),
                  ),
                ),
              ] else
                const Text('网页地址已失效，请重新开启互联并查看当前地址。'),
              const SizedBox(height: 16),
              TextButton(
                onPressed: () => Navigator.pop(context),
                child: const Text('关闭'),
              ),
            ],
          );
        },
      ),
    ),
  );
}

class LanBrowserReceiptsPage extends StatefulWidget {
  const LanBrowserReceiptsPage(this.services, {super.key, this.fileActions});
  final AppServices services;
  final CompletedFileActions? fileActions;
  @override
  State<LanBrowserReceiptsPage> createState() => _LanBrowserReceiptsPageState();
}

class _LanBrowserReceiptsPageState extends State<LanBrowserReceiptsPage> {
  final _operations = <String>{};
  late final _fileActions = widget.fileActions ?? CompletedFileActions();
  String _error = '';
  LanBrowserReceiver get receiver => widget.services.lan.browserReceiver!;

  Future<void> _run(String id, Future<void> Function() action) async {
    if (!_operations.add(id)) return;
    setState(() => _error = '');
    try {
      await action();
    } catch (error) {
      if (mounted) setState(() => _error = errorText(error));
    } finally {
      if (mounted) setState(() => _operations.remove(id));
    }
  }

  Future<void> _open(LanBrowserUpload value) async {
    final path = value.savedPath;
    if (path == null) return;
    if (await widget.services.files.inspect(path) != FileAvailability.present) {
      throw const AppException('文件已移动或无法访问，请检查保存目录');
    }
    if (!mounted) return;
    final box = context.findRenderObject() as RenderBox?;
    final origin = box != null && box.hasSize && !box.size.isEmpty
        ? box.localToGlobal(Offset.zero) & box.size
        : null;
    await _fileActions.openWith(path, value.name, origin: origin);
  }

  @override
  Widget build(BuildContext context) => PageFrame(
    title: '网页接收记录',
    child: AnimatedBuilder(
      animation: receiver,
      builder: (context, _) {
        final records = receiver.records;
        return ListView(
          key: const Key('lan-browser-records'),
          children: [
            Padding(
              padding: const EdgeInsets.all(20),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    '浏览器传来的文件保存后可直接打开；同名文件会自动编号。',
                    style: TextStyle(color: secondary(context), height: 1.6),
                  ),
                  const SizedBox(height: 14),
                  if (supportsDownloadLocationChoice)
                    DownloadLocationField(
                      services: widget.services,
                      compact: true,
                      showDefaultOption: false,
                      selection: DownloadDestinationSelection(
                        widget.services.lanBrowserDestination,
                      ),
                      onChanged: (value) => _run('destination', () async {
                        await widget.services.updateLanBrowserDestination(
                          value.path,
                        );
                        if (mounted) setState(() {});
                      }),
                      enabled: !_operations.contains('destination'),
                    )
                  else
                    Text(
                      '保存位置：${widget.services.settings.destination ?? '系统下载目录'}',
                      style: TextStyle(fontSize: 13, color: secondary(context)),
                    ),
                  const SizedBox(height: 8),
                  Text(
                    '保存位置的修改应用于之后发来的文件。',
                    style: TextStyle(fontSize: 12, color: secondary(context)),
                  ),
                  if (_error.isNotEmpty)
                    Text(
                      _error,
                      style: TextStyle(
                        color: Theme.of(context).colorScheme.error,
                      ),
                    ),
                ],
              ),
            ),
            if (records.isEmpty)
              const Padding(
                padding: EdgeInsets.all(32),
                child: Center(child: Text('暂无网页接收记录')),
              ),
            for (final value in records)
              TransferTaskRow(
                rowKey: ValueKey('lan-browser-record-${value.id}'),
                name: value.name,
                directory: false,
                onTap: value.savedPath == null
                    ? null
                    : () => _run(value.id, () => _open(value)),
                platformMark: Icon(
                  Icons.language,
                  color: secondary(context),
                  size: 15,
                ),
                subtitle: Text(
                  '${value.sender} · ${value.state.label}\n${value.error.isNotEmpty ? value.error : value.savedPath ?? value.path}',
                  maxLines: 3,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: 12,
                    color: value.error.isEmpty
                        ? secondary(context)
                        : Theme.of(context).colorScheme.error,
                  ),
                ),
                progress: value.finished
                    ? const SizedBox.shrink()
                    : Padding(
                        padding: const EdgeInsets.only(top: 6),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            LinearProgressIndicator(
                              value: value.size == 0
                                  ? (value.offset == value.size ? 1 : 0)
                                  : value.offset / value.size,
                            ),
                            const SizedBox(height: 4),
                            Text(
                              '${formatBytes(value.offset)} / ${formatBytes(value.size)}',
                              style: TextStyle(
                                fontSize: 11,
                                color: secondary(context),
                              ),
                            ),
                          ],
                        ),
                      ),
                trailing: Wrap(
                  spacing: 2,
                  children: [
                    if (value.savedPath != null)
                      IconButton(
                        tooltip: '打开文件',
                        onPressed: _operations.contains(value.id)
                            ? null
                            : () => _run(value.id, () => _open(value)),
                        icon: const Icon(CupertinoIcons.doc, size: 18),
                      ),
                    if (value.canSave)
                      IconButton(
                        tooltip: '重试保存',
                        onPressed: () => _run(value.id, () async {
                          receiver.complete(value.owner, value.id);
                        }),
                        icon: const Icon(
                          CupertinoIcons.arrow_clockwise,
                          size: 18,
                        ),
                      ),
                    if (!value.finished)
                      IconButton(
                        tooltip: '取消接收',
                        onPressed: _operations.contains(value.id)
                            ? null
                            : () => _run(
                                value.id,
                                () => receiver.cancel(value.owner, value.id),
                              ),
                        icon: const Icon(CupertinoIcons.xmark, size: 18),
                      ),
                  ],
                ),
              ),
          ],
        );
      },
    ),
  );
}
