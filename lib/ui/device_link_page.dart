import 'dart:async';
import 'package:flutter/cupertino.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:qr_flutter/qr_flutter.dart';
import '../app_services.dart';
import '../core/json.dart';
import '../data/http.dart';
import '../domain/downloads.dart';
import '../domain/links.dart';
import '../lan/lan_models.dart';
import '../lan/lan_qr.dart';
import '../lan/lan_service.dart';
import '../platform/qr_scanner.dart';
import 'common.dart';

class DeviceLinkPage extends StatefulWidget {
  const DeviceLinkPage(
    this.services, {
    super.key,
    this.initialText = '',
    this.initialDownload,
    this.autoStart,
  });
  final AppServices services;
  final String initialText;
  final DownloadTask? initialDownload;
  final bool? autoStart;
  @override
  State<DeviceLinkPage> createState() => _DeviceLinkPageState();
}

class _DeviceLinkPageState extends State<DeviceLinkPage> {
  LanService get lan => widget.services.lan;
  int _tab = 0;
  bool _busy = false;
  String _phase = '', _error = '', _address = '';
  RequestScope? _operation;
  bool _initialDownloadHandled = false;
  late String _messageDraft = widget.initialText;

  bool get _desktop => switch (defaultTargetPlatform) {
    TargetPlatform.windows ||
    TargetPlatform.macOS ||
    TargetPlatform.linux => true,
    _ => false,
  };
  bool get _autoStart => widget.autoStart ?? _desktop;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      if (!mounted) return;
      if (lan.running || _autoStart) await _start();
    });
  }

  Future<void> _start() async {
    if (!lan.running) {
      final started = await _run(() async {
        await lan.start();
        return true;
      }, '正在开启设备互联…');
      if (started != true) return;
    }
    final path = widget.initialDownload?.savedPath;
    if (mounted && lan.running && path != null && !_initialDownloadHandled) {
      _initialDownloadHandled = true;
      await _makeShare([path]);
    }
  }

  @override
  void dispose() {
    _operation?.cancel();
    super.dispose();
  }

  Future<T?> _run<T>(Future<T> Function() action, String label) async {
    if (_busy || !mounted) return null;
    final scope = RequestScope();
    _operation = scope;
    setState(() {
      _busy = true;
      _phase = label;
      _error = '';
    });
    try {
      return await scope.run(action);
    } catch (error) {
      if (mounted && !scope.token.isCancelled) {
        setState(
          () => _error = error is PlatformException
              ? error.message ?? '文件操作失败，请重试'
              : errorText(error),
        );
      }
      return null;
    } finally {
      if (_operation == scope) _operation = null;
      if (mounted) {
        setState(() {
          _busy = false;
          _phase = '';
        });
      }
    }
  }

  Future<String?> _input(
    String title,
    String hint, {
    String initial = '',
    bool pin = false,
    int lines = 1,
    String action = '确定',
  }) => showDialog<String>(
    context: context,
    barrierDismissible: lines == 1,
    builder: (_) => _LanInputDialog(
      title: title,
      hint: hint,
      initial: initial,
      pin: pin,
      lines: lines,
      action: action,
    ),
  );

  Future<void> _copy(String text) async {
    try {
      await Clipboard.setData(ClipboardData(text: text));
      if (mounted) message(context, '已复制');
    } catch (_) {
      if (mounted) message(context, '复制失败，请重试');
    }
  }

  Future<int?> _lifetime() => showModalBottomSheet<int>(
    context: context,
    showDragHandle: true,
    builder: (context) => SafeArea(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Padding(
            padding: EdgeInsets.all(12),
            child: Text(
              '分享有效期',
              style: TextStyle(fontSize: 18, fontWeight: FontWeight.w600),
            ),
          ),
          for (final option in const [
            (15, '15 分钟'),
            (60, '1 小时'),
            (240, '4 小时'),
            (0, '直到关闭分享或退出应用'),
          ])
            ListTile(
              title: Text(option.$2),
              leading: const Icon(CupertinoIcons.clock),
              onTap: () => Navigator.pop(context, option.$1),
            ),
        ],
      ),
    ),
  );

  Future<void> _pickFiles({bool folder = false}) async {
    final target = await _chooseFileTarget();
    if (target == null || !mounted) return;
    final locations = await _run(() async {
      if (!folder) return lan.files.pickFiles();
      final path = await widget.services.files.chooseDirectory();
      return [?path];
    }, '正在选择文件…');
    if (!mounted || locations == null || locations.isEmpty) return;
    await _makeShare(locations, folder: folder, recipient: target.peer);
  }

  Future<void> _makeShare(
    List<String> locations, {
    bool folder = false,
    LanPeer? recipient,
  }) async {
    final minutes = await _lifetime();
    if (minutes == null || !mounted) return;
    final share = await _run(() async {
      final selection = await lan.files.scan(locations, folder: folder);
      return lan.createShare(
        selection,
        lifetime: minutes == 0 ? null : Duration(minutes: minutes),
        preparing: (done, total) {
          if (mounted) setState(() => _phase = '正在准备分享 ${done + 1}/$total…');
        },
      );
    }, '正在准备分享…');
    if (share == null || !mounted) return;
    setState(() => _tab = 1);
    if (recipient == null) {
      await _showShare(share);
    } else {
      await _sendShare(share, target: recipient);
    }
  }

  Future<({LanPeer? peer})?> _chooseFileTarget() =>
      showModalBottomSheet<({LanPeer? peer})>(
        context: context,
        showDragHandle: true,
        builder: (context) => SafeArea(
          child: AnimatedBuilder(
            animation: lan,
            builder: (context, _) {
              final peers = lan.running
                  ? lan.peers.where(lan.connected).toList()
                  : <LanPeer>[];
              return ListView(
                key: const Key('lan-file-recipient'),
                shrinkWrap: true,
                children: [
                  const ListTile(
                    title: Text(
                      '选择接收设备',
                      style: TextStyle(fontWeight: FontWeight.w600),
                    ),
                    subtitle: Text('选择已连接设备后，再选择要发送的文件'),
                  ),
                  if (peers.isEmpty)
                    const Padding(
                      padding: EdgeInsets.fromLTRB(24, 8, 24, 20),
                      child: Text('暂无已连接设备，请先扫码或输入连接码连接。'),
                    ),
                  for (final peer in peers)
                    ListTile(
                      key: ValueKey('lan-file-recipient-${peer.id}'),
                      leading: Icon(
                        Icons.devices_rounded,
                        color: themeAccent(context),
                      ),
                      title: Text(peer.name),
                      subtitle: Text('${peer.address} · 已连接'),
                      trailing: const Icon(
                        CupertinoIcons.chevron_right,
                        size: 18,
                      ),
                      onTap: () => Navigator.pop(context, (peer: peer)),
                    ),
                  const Divider(indent: 20, endIndent: 20),
                  ListTile(
                    key: const Key('lan-file-share-link'),
                    leading: const Icon(CupertinoIcons.qrcode),
                    title: const Text('生成分享链接 / 二维码'),
                    subtitle: const Text('无需连接设备，单个文件可用浏览器接收'),
                    onTap: () => Navigator.pop(context, (peer: null)),
                  ),
                  const SizedBox(height: 12),
                ],
              );
            },
          ),
        ),
      );

  Future<void> _downloaded() async {
    final tasks = widget.services.downloads.tasks
        .where(
          (t) =>
              t.status == DownloadStatus.completed &&
              t.savedPath != null &&
              !t.spec.isTorrent,
        )
        .toList();
    final selected = await showModalBottomSheet<DownloadTask>(
      context: context,
      showDragHandle: true,
      isScrollControlled: true,
      builder: (context) => SafeArea(
        child: SizedBox(
          height: MediaQuery.sizeOf(context).height * .65,
          child: Column(
            children: [
              const Padding(
                padding: EdgeInsets.all(16),
                child: Text(
                  '分享已下载文件',
                  style: TextStyle(fontSize: 18, fontWeight: FontWeight.w600),
                ),
              ),
              Expanded(
                child: tasks.isEmpty
                    ? const Center(child: Text('暂无已下载文件，可先选择本机文件'))
                    : ListView.builder(
                        itemCount: tasks.length,
                        itemBuilder: (context, index) {
                          final task = tasks[index];
                          return ListTile(
                            leading: const Icon(CupertinoIcons.doc),
                            title: Text(
                              task.spec.fileName,
                              maxLines: 2,
                              overflow: TextOverflow.ellipsis,
                            ),
                            subtitle: Text(formatBytes(task.total)),
                            onTap: () => Navigator.pop(context, task),
                          );
                        },
                      ),
              ),
            ],
          ),
        ),
      ),
    );
    if (selected != null && mounted) await _makeShare([selected.savedPath!]);
  }

  Future<bool> _connect(LanPeer peer) async {
    peer = lan.peers.firstWhere(
      (value) => value.id == peer.id,
      orElse: () => peer,
    );
    if (lan.connected(peer)) return true;
    final code = await _input(
      '连接 ${peer.name}',
      '输入对方设备的 6 位连接码',
      pin: true,
      action: '连接',
    );
    if (code == null || !mounted) return false;
    return await _run(() async {
          await lan.connect(peer, code);
          return true;
        }, '正在连接设备…') ==
        true;
  }

  Future<void> _byCode() async {
    final peer = lan.peers.length == 1 ? lan.peers.single : await _choosePeer();
    if (peer == null || !mounted) return;
    await _peer(peer);
  }

  Future<void> _byAddress() async {
    final value = await _input(
      '输入设备地址',
      'http://192.168.1.8:52381',
      action: '查找',
    );
    if (value == null || !mounted) return;
    final peer = await _run(() => lan.findDevice(value), '正在查找设备…');
    if (peer != null && mounted && await _connect(peer) && mounted) {
      await _peer(peer);
    }
  }

  Future<void> _byShareLink() async {
    final value = await _input('打开分享链接', '粘贴文析助手设备互联分享链接', action: '查看文件');
    if (value != null && mounted) await _receive(value);
  }

  Future<void> _scan() async {
    final target = await _run(() async {
      final value = await scanLanQr();
      return value == null ? null : LanQrTarget.parse(value);
    }, '正在扫码…');
    if (target == null || !mounted) return;
    switch (target) {
      case LanConnectionQr():
        final peer = await _run(() => lan.connectQr(target), '正在连接设备…');
        if (peer != null && mounted) {
          setState(() => _tab = 0);
          await _peer(peer);
        }
      case LanShareQr():
        await _receive(target.address.toString());
    }
  }

  Future<void> _showConnectionQr() => showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    showDragHandle: true,
    builder: (_) => _LanConnectionQrSheet(lan, initialAddress: _address),
  );

  Future<LanPeer?> _choosePeer({bool connectedOnly = false}) async {
    final peers = lan.peers
        .where((peer) => !connectedOnly || lan.running && lan.connected(peer))
        .toList();
    if (peers.isEmpty) {
      message(
        context,
        connectedOnly ? '暂无已连接设备，请先扫码或输入连接码连接' : '未发现设备，请先开启双方互联；也可输入对方显示的设备地址',
      );
      return null;
    }
    return showModalBottomSheet<LanPeer>(
      context: context,
      showDragHandle: true,
      builder: (context) => SafeArea(
        child: ListView(
          shrinkWrap: true,
          children: [
            const ListTile(
              title: Text(
                '选择接收设备',
                style: TextStyle(fontWeight: FontWeight.w600),
              ),
            ),
            for (final peer in peers)
              ListTile(
                leading: const Icon(Icons.devices_rounded),
                title: Text(peer.name),
                subtitle: Text(peer.address),
                onTap: () => Navigator.pop(context, peer),
              ),
          ],
        ),
      ),
    );
  }

  Future<void> _sendMessage([LanPeer? target]) async {
    final chosen = target ?? await _choosePeer();
    if (chosen == null || !mounted || !await _connect(chosen) || !mounted) {
      return;
    }
    final peer = lan.peers.firstWhere(
      (value) => value.id == chosen.id,
      orElse: () => chosen,
    );
    final value = await _input(
      '发送消息给 ${peer.name}',
      '输入文字、网址或网盘分享文案，支持多行内容',
      initial: _messageDraft,
      lines: 4,
      action: '发送',
    );
    if (value == null || !mounted) return;
    _messageDraft = value;
    final sent = await _run(() async {
      await lan.sendMessage(peer, value);
      return true;
    }, '正在发送消息…');
    if (sent == true && mounted) {
      _messageDraft = '';
      setState(() => _tab = 2);
      message(context, '消息已送达，可在对方收件箱查看');
    }
  }

  Future<void> _sendShare(LanShare share, {LanPeer? target}) async {
    final peer = target ?? await _choosePeer(connectedOnly: true);
    if (peer == null || !mounted) return;
    final sent = await _run(() async {
      require(lan.running && lan.connected(peer), '设备连接已失效，请重新连接后在“我的分享”中发送');
      await lan.sendShare(peer, share);
      return true;
    }, '正在发送文件邀请…');
    if (sent == true && mounted) {
      message(context, '已发送给 ${peer.name}，请在对方收件箱确认接收');
    }
  }

  Future<void> _peer(LanPeer peer) async {
    if (!await _connect(peer) || !mounted) return;
    peer = lan.peers.firstWhere(
      (value) => value.id == peer.id,
      orElse: () => peer,
    );
    final action = await showModalBottomSheet<String>(
      context: context,
      showDragHandle: true,
      builder: (context) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              leading: Icon(Icons.devices_rounded, color: themeAccent(context)),
              title: Text(peer.name),
              subtitle: Text(peer.address),
            ),
            ListTile(
              leading: const Icon(CupertinoIcons.folder),
              title: const Text('查看对方分享的文件'),
              onTap: () => Navigator.pop(context, 'files'),
            ),
            ListTile(
              leading: const Icon(CupertinoIcons.chat_bubble_text),
              title: const Text('发送消息'),
              subtitle: const Text('文字、网址或网盘分享文案'),
              onTap: () => Navigator.pop(context, 'message'),
            ),
          ],
        ),
      ),
    );
    if (!mounted) return;
    if (action == 'message') {
      await _sendMessage(peer);
      return;
    }
    if (action != 'files') return;
    final shares = await _run(() => lan.remoteShares(peer), '正在读取分享列表…');
    if (shares == null || !mounted) return;
    final token = await showModalBottomSheet<String>(
      context: context,
      showDragHandle: true,
      builder: (context) => SafeArea(
        child: ListView(
          shrinkWrap: true,
          children: [
            ListTile(title: Text('${peer.name}的分享')),
            if (shares.isEmpty)
              const Padding(
                padding: EdgeInsets.all(24),
                child: Text('对方还没有分享文件。让对方点击“发送文件”或“发送文件夹”。'),
              ),
            for (final share in shares)
              ListTile(
                leading: const Icon(CupertinoIcons.folder),
                title: Text(share.name),
                subtitle: Text(
                  '${share.fileCount} 个文件 · ${formatBytes(share.size)}',
                ),
                trailing: const Icon(CupertinoIcons.arrow_down_circle),
                onTap: () => Navigator.pop(context, share.token),
              ),
          ],
        ),
      ),
    );
    if (token != null && mounted) {
      await _receive(peer.base.replace(path: '/s/$token').toString());
    }
  }

  Future<bool> _receive(String address, {LanInboxItem? item}) async {
    final manifest = await _run(() async {
      final result = await lan.readShare(address);
      if (item != null) await lan.markRead(item);
      return result;
    }, '正在读取文件信息…');
    if (manifest == null || !mounted) return false;
    await Navigator.push<void>(
      context,
      MaterialPageRoute(
        builder: (_) =>
            _LanReceivePage(widget.services, manifest, lanAddress(address)),
      ),
    );
    return true;
  }

  Future<void> _incoming(LanInboxItem item) async {
    if (item.kind == 'share') {
      await _receive(item.value, item: item);
      return;
    }
    final ready = await _run(() async {
      await lan.markRead(item);
      return true;
    }, '正在打开消息…');
    if (ready != true || !mounted) return;
    if (item.kind == 'link') {
      Navigator.pop(context, item.value);
      return;
    }
    final action = await showDialog<String>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: Text(item.sender),
        scrollable: true,
        content: SizedBox(
          width: 440,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                formatDate(item.createdAt),
                style: TextStyle(color: secondary(context), fontSize: 12),
              ),
              const SizedBox(height: 12),
              SelectableText(item.value, key: const Key('lan-message-content')),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext),
            child: const Text('关闭'),
          ),
          TextButton.icon(
            onPressed: () => _copy(item.value),
            icon: const Icon(CupertinoIcons.doc_on_doc, size: 17),
            label: const Text('复制消息'),
          ),
          if (LinkParser.parse(item.value).isNotEmpty)
            TextButton(
              onPressed: () => Navigator.pop(dialogContext, 'parse'),
              child: const Text('解析链接'),
            ),
          if (lan.senderOf(item) != null && lan.running)
            FilledButton(
              onPressed: () => Navigator.pop(dialogContext, 'reply'),
              child: const Text('回复'),
            ),
        ],
      ),
    );
    if (!mounted) return;
    if (action == 'parse') {
      Navigator.pop(context, item.value);
    } else if (action == 'reply') {
      await _reply(item);
    }
  }

  Future<void> _reply(LanInboxItem item) async {
    final peer = lan.senderOf(item);
    if (peer == null) return;
    final ready = await _run(() async {
      await lan.markRead(item);
      return true;
    }, '正在打开消息…');
    if (ready == true && mounted) await _sendMessage(peer);
  }

  Future<void> _showShare(LanShare share) async {
    await Navigator.push<void>(
      context,
      MaterialPageRoute(
        builder: (_) => _LanSharePage(
          lan,
          share,
          initialAddress: _address,
          onSend: () async {
            Navigator.pop(context);
            await _sendShare(share);
          },
        ),
      ),
    );
  }

  Widget _card(Widget child, {Color? color}) => Container(
    margin: const EdgeInsets.only(bottom: 12),
    padding: const EdgeInsets.all(18),
    decoration: BoxDecoration(
      color: color ?? Theme.of(context).colorScheme.surface,
      borderRadius: BorderRadius.circular(20),
      border: Border.all(color: border(context)),
    ),
    child: child,
  );

  Widget _action(
    String label,
    String detail,
    IconData icon,
    VoidCallback action,
  ) => Material(
    color: Theme.of(context).colorScheme.surface,
    shape: RoundedRectangleBorder(
      borderRadius: BorderRadius.circular(18),
      side: BorderSide(color: border(context)),
    ),
    clipBehavior: Clip.antiAlias,
    child: InkWell(
      onTap: _busy ? null : action,
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Icon(icon, color: themeAccent(context), size: 24),
            const SizedBox(height: 8),
            Text(
              label,
              style: const TextStyle(fontWeight: FontWeight.w600, fontSize: 15),
            ),
            const SizedBox(height: 5),
            Text(
              detail,
              style: TextStyle(fontSize: 12, color: secondary(context)),
            ),
          ],
        ),
      ),
    ),
  );

  Widget _status() {
    if (!lan.running) {
      return _card(
        Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Icon(Icons.devices_rounded, size: 38, color: themeAccent(context)),
            const SizedBox(height: 14),
            const Text(
              '手机和电脑，连在一起',
              textAlign: TextAlign.center,
              style: TextStyle(fontSize: 20, fontWeight: FontWeight.w600),
            ),
            const SizedBox(height: 8),
            Text(
              '两台设备连接同一 Wi-Fi，开启后即可互传文字、链接和文件。',
              textAlign: TextAlign.center,
              style: TextStyle(color: secondary(context), height: 1.6),
            ),
            const SizedBox(height: 18),
            FilledButton.icon(
              key: const Key('lan-enable'),
              onPressed: _busy ? null : _start,
              icon: const Icon(Icons.wifi_rounded),
              label: const Text('开启设备互联'),
            ),
            if (canScanQr) ...[
              const SizedBox(height: 8),
              OutlinedButton.icon(
                key: const Key('lan-scan-qr'),
                onPressed: _busy ? null : _scan,
                icon: const Icon(CupertinoIcons.qrcode_viewfinder, size: 20),
                label: const Text('扫码连接'),
              ),
            ],
          ],
        ),
      );
    }
    if (!lan.addresses.contains(_address)) {
      _address = lan.addresses.firstOrNull ?? '';
    }
    return _card(
      Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Container(
                padding: const EdgeInsets.all(10),
                decoration: BoxDecoration(
                  color: themeAccent(context).withValues(alpha: .10),
                  borderRadius: BorderRadius.circular(14),
                ),
                child: Icon(Icons.devices_rounded, color: themeAccent(context)),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      lan.name,
                      style: const TextStyle(
                        fontSize: 17,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    Text(
                      '已开启 · ${lan.peers.length} 台附近设备',
                      style: TextStyle(fontSize: 12, color: secondary(context)),
                    ),
                  ],
                ),
              ),
              IconButton(
                tooltip: '修改设备名称',
                icon: const Icon(CupertinoIcons.pencil, size: 20),
                onPressed: _busy
                    ? null
                    : () async {
                        final value = await _input(
                          '设备名称',
                          '给这台设备起个名字',
                          initial: lan.name,
                        );
                        if (value != null) {
                          await _run(() => lan.rename(value), '正在保存…');
                        }
                      },
              ),
            ],
          ),
          const SizedBox(height: 17),
          _connectionPanel(),
        ],
      ),
    );
  }

  Widget _connectionDetails() => Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      Text('本机连接码', style: TextStyle(fontSize: 12, color: secondary(context))),
      Row(
        children: [
          Expanded(
            child: FittedBox(
              fit: BoxFit.scaleDown,
              alignment: Alignment.centerLeft,
              child: Text(
                lan.connectionCode,
                key: const Key('lan-local-code'),
                style: const TextStyle(
                  fontSize: 32,
                  fontWeight: FontWeight.w700,
                  letterSpacing: 7,
                ),
              ),
            ),
          ),
          IconButton(
            tooltip: '复制连接码',
            onPressed: () => _copy(lan.connectionCode),
            icon: const Icon(CupertinoIcons.doc_on_doc, size: 19),
          ),
        ],
      ),
      const SizedBox(height: 6),
      Row(
        children: [
          Expanded(
            child: lan.addresses.length > 1
                ? DropdownButtonHideUnderline(
                    child: DropdownButton<String>(
                      key: const Key('lan-device-address'),
                      value: _address,
                      isExpanded: true,
                      style: Theme.of(context).textTheme.bodySmall?.copyWith(
                        fontSize: 12,
                        color: secondary(context),
                      ),
                      items: [
                        for (final value in lan.addresses)
                          DropdownMenuItem(
                            value: value,
                            child: Text(
                              lan.base(value).toString(),
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                            ),
                          ),
                      ],
                      onChanged: (value) {
                        if (value != null) setState(() => _address = value);
                      },
                    ),
                  )
                : Text(
                    _address.isEmpty
                        ? '网络连接已断开'
                        : lan.base(_address).toString(),
                    style: TextStyle(fontSize: 12, color: secondary(context)),
                    overflow: TextOverflow.ellipsis,
                  ),
          ),
          IconButton(
            tooltip: '复制设备地址',
            onPressed: _address.isEmpty
                ? null
                : () => _copy(lan.base(_address).toString()),
            icon: const Icon(CupertinoIcons.link, size: 18),
          ),
        ],
      ),
      if (_desktop)
        Text(
          '另一台设备可输入连接码，或在文析助手中扫码连接。',
          style: TextStyle(
            fontSize: 12,
            color: secondary(context),
            height: 1.5,
          ),
        ),
      if (defaultTargetPlatform == TargetPlatform.windows)
        TextButton.icon(
          key: const Key('lan-allow-incoming'),
          onPressed: _busy
              ? null
              : () async {
                  final allowed = await _run(() async {
                    await lan.allowIncomingConnections();
                    return true;
                  }, '正在允许局域网连接…');
                  if (allowed == true && mounted) {
                    message(context, '已允许本应用的局域网连接，请在手机端重新连接');
                  }
                },
          icon: const Icon(Icons.wifi_rounded, size: 17),
          label: const Text('允许手机连接'),
        ),
    ],
  );

  Widget _connectionPanel() {
    if (!_desktop) {
      return Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _connectionDetails(),
          const SizedBox(height: 8),
          OutlinedButton.icon(
            key: const Key('lan-show-qr'),
            onPressed: _busy || _address.isEmpty ? null : _showConnectionQr,
            icon: const Icon(CupertinoIcons.qrcode, size: 20),
            label: const Text('显示连接二维码'),
          ),
        ],
      );
    }
    if (_address.isEmpty) return _connectionDetails();
    final qr = SizedBox(
      width: 176,
      child: Semantics(
        button: true,
        label: '点击放大连接二维码',
        child: Tooltip(
          message: '点击放大连接二维码',
          child: Material(
            color: Colors.transparent,
            child: InkWell(
              key: const Key('lan-show-qr'),
              onTap: _showConnectionQr,
              borderRadius: BorderRadius.circular(16),
              child: Padding(
                padding: const EdgeInsets.all(6),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    ClipRRect(
                      borderRadius: BorderRadius.circular(12),
                      child: QrImageView(
                        key: const Key('lan-inline-qr'),
                        data: lan.connectionQr(_address),
                        size: 164,
                        padding: const EdgeInsets.all(10),
                        backgroundColor: Colors.white,
                        errorCorrectionLevel: QrErrorCorrectLevel.M,
                        semanticsLabel: '扫描连接这台设备',
                      ),
                    ),
                    const SizedBox(height: 8),
                    Text(
                      '点击放大',
                      style: TextStyle(fontSize: 12, color: secondary(context)),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
    return LayoutBuilder(
      builder: (context, bounds) => bounds.maxWidth >= 440
          ? Row(
              children: [
                Expanded(child: _connectionDetails()),
                const SizedBox(width: 20),
                qr,
              ],
            )
          : Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                _connectionDetails(),
                const SizedBox(height: 14),
                Center(child: qr),
              ],
            ),
    );
  }

  @override
  Widget build(BuildContext context) => PageFrame(
    title: '设备互联',
    actions: [
      AnimatedBuilder(
        animation: lan,
        builder: (context, _) => IconButton(
          key: const Key('lan-power'),
          tooltip: '关闭设备互联',
          color: CupertinoColors.systemRed.resolveFrom(context),
          disabledColor: CupertinoColors.systemRed
              .resolveFrom(context)
              .withValues(alpha: .35),
          icon: const Icon(CupertinoIcons.power),
          onPressed: _busy || !lan.running
              ? null
              : () async {
                  if (await confirm(context, '关闭设备互联', '文件分享会结束，正在接收的传输会中断。')) {
                    await _run(lan.stop, '正在关闭…');
                  }
                },
        ),
      ),
    ],
    child: AnimatedBuilder(
      animation: Listenable.merge([lan, widget.services.downloads]),
      builder: (context, _) => Align(
        alignment: Alignment.topCenter,
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 760),
          child: ListView(
            key: const Key('device-link-page'),
            padding: const EdgeInsets.all(16),
            children: [
              _status(),
              if (defaultTargetPlatform == TargetPlatform.iOS)
                Padding(
                  padding: const EdgeInsets.fromLTRB(4, 0, 4, 12),
                  child: Text(
                    '设备互传期间请保持应用在前台；锁屏或切后台后，iOS 可能中断连接。',
                    style: TextStyle(fontSize: 12, color: secondary(context)),
                  ),
                ),
              if (_busy)
                _card(
                  Row(
                    children: [
                      const SizedBox(
                        width: 20,
                        height: 20,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      ),
                      const SizedBox(width: 12),
                      Expanded(child: Text(_phase)),
                      TextButton(
                        onPressed: () => _operation?.cancel(),
                        child: const Text('取消'),
                      ),
                    ],
                  ),
                ),
              if (_error.isNotEmpty)
                _card(
                  Text(
                    _error,
                    style: TextStyle(
                      color: Theme.of(context).colorScheme.error,
                    ),
                  ),
                ),
              LayoutBuilder(
                builder: (context, bounds) {
                  final columns = bounds.maxWidth >= 600 ? 4 : 2;
                  final width =
                      (bounds.maxWidth - 10 * (columns - 1)) / columns;
                  return Wrap(
                    spacing: 10,
                    runSpacing: 10,
                    children: [
                      SizedBox(
                        width: width,
                        child: _action(
                          '发送文件',
                          '发送给已连接设备',
                          CupertinoIcons.paperplane,
                          () => _pickFiles(),
                        ),
                      ),
                      SizedBox(
                        width: width,
                        child: _action(
                          '发送文件夹',
                          '保留目录结构',
                          CupertinoIcons.folder,
                          () => _pickFiles(folder: true),
                        ),
                      ),
                      SizedBox(
                        width: width,
                        child: _action(
                          '分享已下载',
                          '生成链接与二维码',
                          CupertinoIcons.qrcode,
                          _downloaded,
                        ),
                      ),
                      SizedBox(
                        key: const Key('lan-send-message'),
                        width: width,
                        child: _action(
                          '发送消息',
                          '文字和链接都能发送',
                          CupertinoIcons.chat_bubble_text,
                          _sendMessage,
                        ),
                      ),
                    ],
                  );
                },
              ),
              const SizedBox(height: 14),
              Wrap(
                spacing: 8,
                children: [
                  if (canScanQr && lan.running)
                    TextButton.icon(
                      key: const Key('lan-scan-qr'),
                      onPressed: _busy ? null : _scan,
                      icon: const Icon(
                        CupertinoIcons.qrcode_viewfinder,
                        size: 19,
                      ),
                      label: const Text('扫码连接'),
                    ),
                  TextButton.icon(
                    key: const Key('lan-connect-code'),
                    onPressed: _busy ? null : _byCode,
                    icon: const Icon(Icons.dialpad_rounded, size: 17),
                    label: const Text('输入连接码'),
                  ),
                  TextButton.icon(
                    onPressed: _busy ? null : _byAddress,
                    icon: const Icon(Icons.lan_outlined, size: 17),
                    label: const Text('输入设备地址'),
                  ),
                  TextButton.icon(
                    onPressed: _busy ? null : _byShareLink,
                    icon: const Icon(CupertinoIcons.link, size: 17),
                    label: const Text('打开分享链接'),
                  ),
                ],
              ),
              const SizedBox(height: 14),
              CupertinoSlidingSegmentedControl<int>(
                groupValue: _tab,
                backgroundColor: fill(context),
                thumbColor: Theme.of(context).colorScheme.surface,
                children: {
                  for (final item in [
                    (0, '附近设备'),
                    (1, '我的分享'),
                    (2, lan.unread > 0 ? '收件箱 ${lan.unread}' : '收件箱'),
                  ])
                    item.$1: Padding(
                      padding: const EdgeInsets.symmetric(vertical: 7),
                      child: Text(
                        item.$2,
                        style: const TextStyle(fontSize: 13),
                      ),
                    ),
                },
                onValueChanged: (value) {
                  if (value != null) setState(() => _tab = value);
                },
              ),
              const SizedBox(height: 16),
              if (_tab == 0) ...[
                Row(
                  children: [
                    const Expanded(
                      child: Text(
                        '同一局域网内的设备',
                        style: TextStyle(fontWeight: FontWeight.w600),
                      ),
                    ),
                    IconButton(
                      tooltip: '刷新附近设备',
                      onPressed: _busy
                          ? null
                          : () => _run(lan.refreshDevices, '正在刷新设备…'),
                      icon: const Icon(
                        CupertinoIcons.arrow_clockwise,
                        size: 20,
                      ),
                    ),
                  ],
                ),
                if (lan.networkHint.isNotEmpty)
                  Padding(
                    padding: const EdgeInsets.only(bottom: 12),
                    child: Text(
                      lan.networkHint,
                      style: TextStyle(color: secondary(context), height: 1.5),
                    ),
                  ),
                if (lan.peers.isEmpty)
                  _card(
                    Text(
                      lan.running
                          ? '在另一台设备上开启“设备互联”。未发现设备时，可手动输入对方显示的地址。'
                          : '开启设备互联后，将在这里发现附近的设备。',
                      style: TextStyle(color: secondary(context), height: 1.7),
                    ),
                  ),
                for (final peer in lan.peers)
                  _card(
                    ListTile(
                      contentPadding: EdgeInsets.zero,
                      leading: Icon(
                        Icons.devices_rounded,
                        color: themeAccent(context),
                      ),
                      title: Text(peer.name),
                      subtitle: Text(
                        '${peer.address}${lan.connected(peer) ? ' · 已连接' : ''}',
                      ),
                      trailing: const Icon(
                        CupertinoIcons.chevron_right,
                        size: 18,
                      ),
                      onTap: _busy ? null : () => _peer(peer),
                    ),
                  ),
              ],
              if (_tab == 1) ...[
                if (lan.shares.isEmpty)
                  _card(const Text('选择文件后，可以在这里查看、发送或结束分享。')),
                for (final share in lan.shares)
                  _card(
                    Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          share.manifest.name,
                          style: const TextStyle(fontWeight: FontWeight.w600),
                        ),
                        const SizedBox(height: 7),
                        Text(
                          '${share.manifest.files.length} 个文件 · ${formatBytes(share.manifest.size)}',
                          style: TextStyle(
                            fontSize: 12,
                            color: secondary(context),
                          ),
                        ),
                        const SizedBox(height: 7),
                        Text(
                          share.draining
                              ? '已停止新接收'
                              : share.responses.isNotEmpty
                              ? '正在发送 · 已传输 ${formatBytes(share.transferred)}'
                              : '等待接收',
                          style: TextStyle(
                            color: themeAccent(context),
                            fontSize: 13,
                          ),
                        ),
                        const SizedBox(height: 8),
                        Wrap(
                          spacing: 8,
                          children: [
                            TextButton.icon(
                              onPressed: () => _showShare(share),
                              icon: const Icon(CupertinoIcons.qrcode, size: 17),
                              label: const Text('查看分享'),
                            ),
                            TextButton.icon(
                              onPressed: _busy ? null : () => _sendShare(share),
                              icon: const Icon(
                                CupertinoIcons.paperplane,
                                size: 17,
                              ),
                              label: const Text('发送给设备'),
                            ),
                          ],
                        ),
                      ],
                    ),
                  ),
                if (widget.services.downloads.tasks.any(
                  (t) => t.spec.profile == 'lan' && t.active,
                ))
                  ListTile(
                    leading: const Icon(CupertinoIcons.arrow_down_circle),
                    title: const Text('正在接收文件'),
                    subtitle: const Text('在下载管理中查看进度、暂停或继续'),
                    trailing: const Icon(
                      CupertinoIcons.chevron_right,
                      size: 18,
                    ),
                    onTap: widget.services.requestDownloadManager,
                  ),
              ],
              if (_tab == 2) ...[
                Row(
                  children: [
                    const Expanded(
                      child: Text(
                        '收到的消息',
                        style: TextStyle(fontWeight: FontWeight.w600),
                      ),
                    ),
                    FilledButton.tonalIcon(
                      key: const Key('lan-inbox-send'),
                      onPressed: _busy || !lan.running ? null : _sendMessage,
                      icon: const Icon(CupertinoIcons.square_pencil, size: 17),
                      label: const Text('发送消息'),
                    ),
                  ],
                ),
                const SizedBox(height: 12),
                if (!lan.running)
                  Padding(
                    padding: const EdgeInsets.only(bottom: 12),
                    child: Text(
                      '可以查看历史消息。开启设备互联后，即可继续收发。',
                      style: TextStyle(color: secondary(context)),
                    ),
                  ),
                if (lan.inbox.isEmpty)
                  _card(const Text('收到的文字、网址、网盘链接和文件邀请会显示在这里。')),
                for (final item in lan.inbox)
                  _card(
                    Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Row(
                          children: [
                            Expanded(
                              child: Text(
                                item.sender,
                                style: const TextStyle(
                                  fontWeight: FontWeight.w600,
                                ),
                              ),
                            ),
                            if (!item.read)
                              Padding(
                                padding: EdgeInsets.only(right: 8),
                                child: Icon(
                                  Icons.circle,
                                  color: themeAccent(context),
                                  size: 7,
                                ),
                              ),
                            IconButton(
                              tooltip: '删除消息',
                              onPressed: _busy
                                  ? null
                                  : () => _run(
                                      () => lan.markRead(item, remove: true),
                                      '正在删除消息…',
                                    ),
                              icon: const Icon(CupertinoIcons.trash, size: 17),
                            ),
                          ],
                        ),
                        Text(
                          '${item.kind == 'share'
                              ? '文件邀请'
                              : item.kind == 'link'
                              ? '网盘链接'
                              : '文字消息'} · ${formatDate(item.createdAt)}',
                          style: TextStyle(
                            color: secondary(context),
                            fontSize: 12,
                          ),
                        ),
                        const SizedBox(height: 6),
                        Text(
                          item.kind == 'share' ? '邀请你接收文件' : item.value,
                          maxLines: 4,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            color: secondary(context),
                            height: 1.5,
                          ),
                        ),
                        const SizedBox(height: 10),
                        Wrap(
                          spacing: 8,
                          runSpacing: 4,
                          children: [
                            FilledButton.tonalIcon(
                              onPressed: _busy ? null : () => _incoming(item),
                              icon: Icon(
                                item.kind == 'share'
                                    ? CupertinoIcons.folder
                                    : item.kind == 'link'
                                    ? CupertinoIcons.link
                                    : CupertinoIcons.chat_bubble_text,
                                size: 17,
                              ),
                              label: Text(
                                item.kind == 'share'
                                    ? '查看并接收'
                                    : item.kind == 'link'
                                    ? '解析链接'
                                    : '查看消息',
                              ),
                            ),
                            if (item.kind != 'share')
                              TextButton.icon(
                                onPressed: () => _copy(item.value),
                                icon: const Icon(
                                  CupertinoIcons.doc_on_doc,
                                  size: 17,
                                ),
                                label: const Text('复制'),
                              ),
                            if (lan.running && lan.senderOf(item) != null)
                              TextButton.icon(
                                onPressed: _busy ? null : () => _reply(item),
                                icon: const Icon(
                                  CupertinoIcons.reply,
                                  size: 17,
                                ),
                                label: const Text('回复'),
                              ),
                          ],
                        ),
                      ],
                    ),
                  ),
              ],
              const SizedBox(height: 18),
              Text(
                '离开此页后仍可传输。分享结束或发送端退出应用后，接收方将无法继续获取文件。',
                style: TextStyle(
                  fontSize: 12,
                  height: 1.6,
                  color: secondary(context),
                ),
              ),
              const SizedBox(height: 16),
            ],
          ),
        ),
      ),
    ),
  );
}

class _LanConnectionQrSheet extends StatefulWidget {
  const _LanConnectionQrSheet(this.lan, {required this.initialAddress});
  final LanService lan;
  final String initialAddress;

  @override
  State<_LanConnectionQrSheet> createState() => _LanConnectionQrSheetState();
}

class _LanConnectionQrSheetState extends State<_LanConnectionQrSheet> {
  late String _address = widget.initialAddress;

  @override
  Widget build(BuildContext context) => SafeArea(
    child: ConstrainedBox(
      constraints: BoxConstraints(
        maxHeight: MediaQuery.sizeOf(context).height * .85,
      ),
      child: SingleChildScrollView(
        padding: const EdgeInsets.fromLTRB(24, 8, 24, 24),
        child: Align(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 420),
            child: AnimatedBuilder(
              animation: widget.lan,
              builder: (context, _) {
                final lan = widget.lan;
                if (!lan.addresses.contains(_address)) {
                  _address = lan.addresses.firstOrNull ?? '';
                }
                final available = lan.running && _address.isNotEmpty;
                return Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    const Text(
                      '本机连接二维码',
                      textAlign: TextAlign.center,
                      style: TextStyle(
                        fontSize: 20,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    const SizedBox(height: 10),
                    Text(
                      lan.name,
                      textAlign: TextAlign.center,
                      style: TextStyle(color: secondary(context)),
                    ),
                    const SizedBox(height: 20),
                    if (available) ...[
                      LayoutBuilder(
                        builder: (context, bounds) => Center(
                          child: ClipRRect(
                            borderRadius: BorderRadius.circular(16),
                            child: QrImageView(
                              key: const Key('lan-connection-qr'),
                              data: lan.connectionQr(_address),
                              size: bounds.maxWidth < 240
                                  ? bounds.maxWidth
                                  : 240,
                              padding: const EdgeInsets.all(18),
                              backgroundColor: Colors.white,
                              errorCorrectionLevel: QrErrorCorrectLevel.M,
                              semanticsLabel: '扫描连接这台设备',
                            ),
                          ),
                        ),
                      ),
                      const SizedBox(height: 16),
                      Text(
                        '连接码 ${lan.connectionCode}',
                        textAlign: TextAlign.center,
                        style: const TextStyle(fontWeight: FontWeight.w600),
                      ),
                      if (lan.addresses.length > 1)
                        DropdownButton<String>(
                          key: const Key('lan-qr-address'),
                          value: _address,
                          isExpanded: true,
                          items: [
                            for (final address in lan.addresses)
                              DropdownMenuItem(
                                value: address,
                                child: Text(
                                  lan.base(address).toString(),
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                ),
                              ),
                          ],
                          onChanged: (value) {
                            if (value != null) setState(() => _address = value);
                          },
                        )
                      else
                        Padding(
                          padding: const EdgeInsets.only(top: 10),
                          child: Text(
                            lan.base(_address).toString(),
                            textAlign: TextAlign.center,
                          ),
                        ),
                      const SizedBox(height: 12),
                      Text(
                        '在另一台手机的“设备互联”中点击“扫码连接”。\n两台设备需连接同一 Wi-Fi，关闭互联后二维码失效。',
                        textAlign: TextAlign.center,
                        style: TextStyle(
                          color: secondary(context),
                          height: 1.6,
                        ),
                      ),
                    ] else
                      const Text(
                        '连接二维码已失效，请开启设备互联并连接局域网后重试。',
                        textAlign: TextAlign.center,
                      ),
                    const SizedBox(height: 20),
                    TextButton(
                      onPressed: () => Navigator.pop(context),
                      child: const Text('关闭'),
                    ),
                  ],
                );
              },
            ),
          ),
        ),
      ),
    ),
  );
}

class _LanSharePage extends StatefulWidget {
  const _LanSharePage(
    this.lan,
    this.share, {
    required this.onSend,
    this.initialAddress = '',
  });
  final LanService lan;
  final LanShare share;
  final VoidCallback onSend;
  final String initialAddress;
  @override
  State<_LanSharePage> createState() => _LanSharePageState();
}

class _LanSharePageState extends State<_LanSharePage> {
  LanService get lan => widget.lan;
  LanShare get share => widget.share;
  late String _address = widget.initialAddress;
  Future<void> _copy(String value) async {
    try {
      await Clipboard.setData(ClipboardData(text: value));
      if (mounted) message(context, '已复制');
    } catch (_) {
      if (mounted) message(context, '复制失败，请重试');
    }
  }

  @override
  Widget build(BuildContext context) => PageFrame(
    title: '分享文件',
    child: AnimatedBuilder(
      animation: lan,
      builder: (context, _) {
        final ended =
            !lan.running || share.stopped || share.expired(lan.clock());
        if (!lan.addresses.contains(_address)) {
          _address = lan.addresses.firstOrNull ?? '';
        }
        final url = ended || _address.isEmpty
            ? null
            : lan.shareUrl(share, _address).toString();
        return Align(
          alignment: Alignment.topCenter,
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 540),
            child: ListView(
              padding: const EdgeInsets.all(24),
              children: [
                Text(
                  share.manifest.name,
                  textAlign: TextAlign.center,
                  style: const TextStyle(
                    fontSize: 21,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                const SizedBox(height: 8),
                Text(
                  '${share.manifest.files.length} 个文件 · ${formatBytes(share.manifest.size)}',
                  textAlign: TextAlign.center,
                  style: TextStyle(color: secondary(context)),
                ),
                const SizedBox(height: 24),
                if (ended)
                  const Center(child: Text('分享已结束'))
                else if (url == null)
                  const Text(
                    '网络连接已断开，请恢复局域网连接后返回刷新设备地址。',
                    textAlign: TextAlign.center,
                  )
                else if (share.manifest.singleFile && !share.draining) ...[
                  Center(
                    child: ConstrainedBox(
                      constraints: const BoxConstraints(maxWidth: 244),
                      child: Container(
                        padding: const EdgeInsets.all(12),
                        decoration: BoxDecoration(
                          color: Colors.white,
                          borderRadius: BorderRadius.circular(22),
                        ),
                        child: AspectRatio(
                          aspectRatio: 1,
                          child: QrImageView(
                            key: const Key('lan-file-qr'),
                            data: url,
                            backgroundColor: Colors.white,
                            semanticsLabel: '文件下载二维码',
                          ),
                        ),
                      ),
                    ),
                  ),
                  const SizedBox(height: 18),
                  const Text('对方扫描二维码，用浏览器即可下载', textAlign: TextAlign.center),
                  const SizedBox(height: 14),
                ],
                if (url != null && !share.draining) ...[
                  Container(
                    padding: const EdgeInsets.all(16),
                    decoration: BoxDecoration(
                      color: fill(context),
                      borderRadius: BorderRadius.circular(16),
                    ),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          share.manifest.singleFile
                              ? '文件分享链接'
                              : '分享链接 · 用文析助手接收',
                          style: const TextStyle(fontWeight: FontWeight.w600),
                        ),
                        const SizedBox(height: 8),
                        SelectableText(
                          url,
                          key: const Key('lan-share-url'),
                          style: TextStyle(
                            fontSize: 13,
                            height: 1.5,
                            color: secondary(context),
                          ),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(height: 12),
                  FilledButton.icon(
                    onPressed: () => _copy(url),
                    icon: const Icon(CupertinoIcons.link, size: 18),
                    label: const Text('复制分享链接'),
                  ),
                ],
                if (!ended) ...[
                  if (share.draining)
                    const Text(
                      '已停止接受新的接收任务，已开始的任务仍可继续。',
                      textAlign: TextAlign.center,
                    ),
                  if (lan.addresses.length > 1)
                    Padding(
                      padding: const EdgeInsets.only(top: 16),
                      child: DropdownButtonFormField<String>(
                        key: ValueKey(_address),
                        initialValue: _address,
                        decoration: const InputDecoration(
                          labelText: '分享使用的局域网地址',
                        ),
                        items: [
                          for (final value in lan.addresses)
                            DropdownMenuItem(value: value, child: Text(value)),
                        ],
                        onChanged: (value) {
                          if (value != null) setState(() => _address = value);
                        },
                      ),
                    ),
                  const SizedBox(height: 24),
                  const Text('使用文析助手接收', textAlign: TextAlign.center),
                  const SizedBox(height: 9),
                  FittedBox(
                    fit: BoxFit.scaleDown,
                    child: Text(
                      lan.connectionCode,
                      style: const TextStyle(
                        fontSize: 32,
                        fontWeight: FontWeight.w700,
                        letterSpacing: 7,
                      ),
                    ),
                  ),
                  const SizedBox(height: 8),
                  Text(
                    '接收方进入“设备互联”，输入此连接码后选择文件。',
                    textAlign: TextAlign.center,
                    style: TextStyle(color: secondary(context), height: 1.6),
                  ),
                  const SizedBox(height: 16),
                  TextButton.icon(
                    onPressed: share.draining ? null : widget.onSend,
                    icon: const Icon(CupertinoIcons.paperplane, size: 18),
                    label: const Text('发送给已连接设备'),
                  ),
                  const SizedBox(height: 14),
                  Text(
                    share.manifest.expiresAt == null
                        ? '有效期：直到关闭分享或退出应用'
                        : '有效期至 ${formatDate(share.manifest.expiresAt!.millisecondsSinceEpoch)}',
                    textAlign: TextAlign.center,
                    style: TextStyle(fontSize: 12, color: secondary(context)),
                  ),
                  const SizedBox(height: 24),
                  if (share.responses.isNotEmpty && !share.draining)
                    TextButton(
                      onPressed: () =>
                          lan.stopShare(share, afterTransfers: true),
                      child: const Text('停止新接收'),
                    ),
                  TextButton(
                    onPressed: () async {
                      if (await confirm(context, '结束分享', '正在接收的设备将停止获取文件。')) {
                        lan.stopShare(share);
                      }
                    },
                    child: Text(
                      '立即结束分享',
                      style: TextStyle(
                        color: Theme.of(context).colorScheme.error,
                      ),
                    ),
                  ),
                ],
              ],
            ),
          ),
        );
      },
    ),
  );
}

class _LanReceivePage extends StatefulWidget {
  const _LanReceivePage(this.services, this.manifest, this.origin);
  final AppServices services;
  final LanManifest manifest;
  final Uri origin;
  @override
  State<_LanReceivePage> createState() => _LanReceivePageState();
}

class _LanReceivePageState extends State<_LanReceivePage> {
  late String? _destination = switch (widget.services.store.data
      .str('lanDestination')
      .ifEmpty(widget.services.settings.destination ?? '')) {
    '' => null,
    final value => value,
  };
  bool _saving = false, _accepted = false;
  String _error = '';
  Future<void> _choose() async {
    try {
      final path = await widget.services.files.chooseDirectory();
      if (path != null && mounted) setState(() => _destination = path);
    } catch (error) {
      if (mounted) setState(() => _error = errorText(error));
    }
  }

  Future<void> _receive() async {
    if (_saving || _accepted) return;
    if (_destination == null) await _choose();
    if (_destination == null || !mounted) return;
    setState(() {
      _saving = true;
      _error = '';
    });
    try {
      await widget.services.lan.files.createDirectories(
        _destination!,
        widget.manifest.directories,
      );
      final specs = widget.manifest.downloads(widget.origin);
      await widget.services.store.put('lanDestination', _destination!);
      if (specs.isNotEmpty) {
        await widget.services.downloads.enqueueAll(
          specs,
          destination: _destination,
        );
      }
      _accepted = true;
      if (!mounted) return;
      if (specs.isNotEmpty) {
        widget.services.requestDownloadManager();
      } else {
        message(context, '文件夹已创建');
        Navigator.pop(context);
      }
    } catch (error) {
      if (mounted) setState(() => _error = errorText(error));
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  @override
  Widget build(BuildContext context) => PageFrame(
    title: '接收文件',
    child: CustomScrollView(
      slivers: [
        SliverToBoxAdapter(
          child: Padding(
            padding: const EdgeInsets.all(20),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Text(
                  widget.manifest.name,
                  style: const TextStyle(
                    fontSize: 20,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                const SizedBox(height: 8),
                Text(
                  '${widget.manifest.files.length} 个文件 · ${formatBytes(widget.manifest.size)}',
                ),
                const SizedBox(height: 16),
                ListTile(
                  contentPadding: EdgeInsets.zero,
                  leading: const Icon(CupertinoIcons.folder),
                  title: const Text('保存位置'),
                  subtitle: Text(
                    _destination ?? '选择接收文件的目录',
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                  ),
                  trailing: const Icon(CupertinoIcons.chevron_right, size: 18),
                  onTap: _saving ? null : _choose,
                ),
                if (_error.isNotEmpty)
                  Text(
                    _error,
                    style: TextStyle(
                      color: Theme.of(context).colorScheme.error,
                    ),
                  ),
                FilledButton.icon(
                  key: const Key('lan-receive-all'),
                  onPressed: _saving || _accepted ? null : _receive,
                  icon: const Icon(CupertinoIcons.arrow_down),
                  label: Text(
                    _accepted
                        ? '已添加到下载管理'
                        : _saving
                        ? '正在添加…'
                        : '接收全部文件',
                  ),
                ),
                const SizedBox(height: 8),
                Text(
                  '接收任务会进入下载管理，可暂停、继续和查看进度。',
                  style: TextStyle(
                    fontSize: 12,
                    height: 1.6,
                    color: secondary(context),
                  ),
                ),
              ],
            ),
          ),
        ),
        SliverList.builder(
          itemCount: widget.manifest.files.length,
          itemBuilder: (context, index) {
            final file = widget.manifest.files[index];
            return ListTile(
              leading: const Icon(CupertinoIcons.doc),
              title: Text(file.path, maxLines: 2),
              subtitle: Text(formatBytes(file.size)),
            );
          },
        ),
        if (widget.manifest.files.isEmpty)
          const SliverToBoxAdapter(
            child: Padding(
              padding: EdgeInsets.all(20),
              child: Text('此分享只有空文件夹，接收后会保留目录结构。'),
            ),
          ),
      ],
    ),
  );
}

class _LanInputDialog extends StatefulWidget {
  const _LanInputDialog({
    required this.title,
    required this.hint,
    required this.initial,
    required this.pin,
    required this.lines,
    required this.action,
  });
  final String title, hint, initial, action;
  final bool pin;
  final int lines;
  @override
  State<_LanInputDialog> createState() => _LanInputDialogState();
}

class _LanInputDialogState extends State<_LanInputDialog> {
  late final controller = TextEditingController(text: widget.initial);
  @override
  void dispose() {
    controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
    title: Text(widget.title),
    scrollable: true,
    content: SizedBox(
      width: 400,
      child: TextField(
        key: const Key('lan-dialog-input'),
        controller: controller,
        autofocus: true,
        minLines: widget.lines,
        maxLines: widget.pin ? 1 : widget.lines + 2,
        maxLength: widget.pin
            ? 6
            : widget.lines > 1
            ? lanMaxMessageLength
            : 256,
        keyboardType: widget.pin
            ? TextInputType.number
            : TextInputType.multiline,
        inputFormatters: widget.pin
            ? [FilteringTextInputFormatter.digitsOnly]
            : null,
        decoration: InputDecoration(
          hintText: widget.hint,
          counterText: '',
          suffixIcon: IconButton(
            tooltip: '粘贴',
            icon: const Icon(CupertinoIcons.doc_on_clipboard, size: 19),
            onPressed: () async {
              try {
                final value =
                    (await Clipboard.getData(Clipboard.kTextPlain))?.text ?? '';
                if (mounted) {
                  final digits = value.replaceAll(RegExp(r'\D'), '');
                  controller.text = widget.pin
                      ? digits.substring(0, digits.length.clamp(0, 6))
                      : value;
                }
              } catch (_) {
                /* The user can still type when clipboard access is denied. */
              }
            },
          ),
        ),
      ),
    ),
    actions: [
      TextButton(
        onPressed: () => Navigator.pop(context),
        child: const Text('取消'),
      ),
      FilledButton(
        key: const Key('lan-dialog-confirm'),
        onPressed: () => Navigator.pop(context, controller.text.trim()),
        child: Text(widget.action),
      ),
    ],
  );
}
