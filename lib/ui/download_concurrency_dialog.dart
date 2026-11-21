import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import '../app_services.dart';
import '../domain/settings.dart';
import 'common.dart';

Future<void> editDownloadConcurrency(
  BuildContext context,
  AppServices services,
) async {
  final value = await showDialog<int>(
    context: context,
    builder: (_) => _ConcurrencyDialog(services.settings.concurrent),
  );
  if (value == null || !context.mounted) return;
  await busy(context, () => services.updateSettings({'concurrent': value}));
}

Future<void> editCrossTransferConcurrency(
  BuildContext context,
  AppServices services,
) async {
  final value = await showDialog<int>(
    context: context,
    builder: (_) => _ConcurrencyDialog(
      services.settings.crossTransferConcurrent,
      crossTransfer: true,
    ),
  );
  if (value == null || !context.mounted) return;
  await busy(
    context,
    () => services.updateSettings({'crossTransferConcurrent': value}),
  );
}

class _ConcurrencyDialog extends StatefulWidget {
  const _ConcurrencyDialog(this.initial, {this.crossTransfer = false});
  final int initial;
  final bool crossTransfer;

  @override
  State<_ConcurrencyDialog> createState() => _ConcurrencyDialogState();
}

class _ConcurrencyDialogState extends State<_ConcurrencyDialog> {
  late final input = TextEditingController(text: '${widget.initial}');
  String? error;
  int get maximum => widget.crossTransfer
      ? AppSettings.maxConcurrentCrossTransfers
      : AppSettings.maxConcurrentDownloads;
  String get prefix => widget.crossTransfer
      ? 'cross-transfer-concurrency'
      : 'download-concurrency';

  void _submit() {
    final value = int.tryParse(input.text.trim());
    if (value == null || value < 1 || value > maximum) {
      setState(() => error = '请输入 1–$maximum 之间的整数');
      return;
    }
    Navigator.pop(context, value);
  }

  @override
  void dispose() {
    input.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
    title: Text(widget.crossTransfer ? '同时处理数' : '同时下载任务数'),
    content: SizedBox(
      width: 400,
      child: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            TextField(
              key: Key('$prefix-input'),
              controller: input,
              keyboardType: TextInputType.number,
              inputFormatters: [FilteringTextInputFormatter.digitsOnly],
              decoration: InputDecoration(
                labelText: widget.crossTransfer ? '同时跨盘传输的文件数' : '同时下载的任务数',
                hintText: '1–$maximum',
                suffixText: '个',
                errorText: error,
              ),
              onSubmitted: (_) => _submit(),
            ),
            const SizedBox(height: 12),
            Wrap(
              spacing: 8,
              runSpacing: 4,
              children: [
                for (final value in [1, 2, 3, 5, 8, 16, 32])
                  if (value <= maximum)
                    ActionChip(
                      label: Text('$value'),
                      onPressed: () {
                        input.text = '$value';
                        setState(() => error = null);
                      },
                    ),
              ],
            ),
            const SizedBox(height: 12),
            Text(
              widget.crossTransfer
                  ? '批量选择的文件也会同时传输，多个批次共用此文件数上限。其余文件排队等待；调低上限后，已开始的文件继续完成。'
                  : '其余任务会排队等待。调低上限时，超出的进行中任务会暂停。',
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
      FilledButton(
        key: Key('$prefix-save'),
        onPressed: _submit,
        child: const Text('保存'),
      ),
    ],
  );
}
