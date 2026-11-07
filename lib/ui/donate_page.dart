import 'package:file_selector/file_selector.dart';
import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import '../diagnostics/app_log.dart';
import '../platform/document_actions.dart';
import 'common.dart';

class DonatePage extends StatefulWidget {
  const DonatePage({super.key, this.saveCode});
  final Future<String?> Function(Uint8List bytes, String name)? saveCode;

  @override
  State<DonatePage> createState() => _DonatePageState();
}

class _DonatePageState extends State<DonatePage> {
  static const _codeAsset = 'assets/support/appreciation-code.png';
  bool _saving = false;

  Future<void> _saveCode() async {
    if (_saving) return;
    setState(() => _saving = true);
    try {
      final data = await rootBundle.load(_codeAsset);
      final bytes = data.buffer.asUint8List(
        data.offsetInBytes,
        data.lengthInBytes,
      );
      const name = '文析助手-赞赏码.png';
      String? saved;
      if (widget.saveCode != null) {
        saved = await widget.saveCode!(bytes, name);
      } else {
        saved = await const DocumentActions().saveBytes(
          bytes,
          name,
          mime: 'image/png',
          acceptedTypeGroups: const [
            XTypeGroup(label: '赞赏码图片', extensions: ['png']),
          ],
        );
      }
      if (mounted) message(context, saved == null ? '已取消保存' : '赞赏码已保存');
    } catch (error, stack) {
      DiagnosticLog.error('support.save_failed', error, stack);
      if (mounted) message(context, '保存未完成，可以重试或截图保存赞赏码');
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  Widget _code() => Center(
    child: SingleChildScrollView(
      padding: const EdgeInsets.all(24),
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 400),
        child: Column(
          children: [
            Text('谢谢你的支持', style: Theme.of(context).textTheme.headlineSmall),
            const SizedBox(height: 24),
            ClipRRect(
              borderRadius: BorderRadius.circular(16),
              child: Image.asset(_codeAsset, semanticLabel: '微信赞赏码'),
            ),
            const SizedBox(height: 18),
            const Text('微信扫一扫，或保存图片后从相册识别。', textAlign: TextAlign.center),
            const SizedBox(height: 8),
            Text('自愿赞赏，感谢每一份心意。', style: TextStyle(color: secondary(context))),
          ],
        ),
      ),
    ),
  );

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('打赏作者')),
      body: SafeArea(bottom: false, child: _code()),
      bottomNavigationBar: SafeArea(
        top: false,
        minimum: const EdgeInsets.fromLTRB(24, 12, 24, 16),
        child: Center(
          heightFactor: 1,
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 400),
            child: SizedBox(
              width: double.infinity,
              child: FilledButton.icon(
                onPressed: _saving ? null : _saveCode,
                icon: const Icon(CupertinoIcons.arrow_down_to_line),
                label: Text(_saving ? '正在保存…' : '保存赞赏码'),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
