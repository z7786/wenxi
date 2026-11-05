import 'package:flutter/material.dart';

int? parsePlayerSkipTime(String input) {
  final value = input.trim().replaceAll('：', ':');
  if (RegExp(r'^\d+$').hasMatch(value)) {
    final seconds = int.tryParse(value);
    return seconds != null && seconds <= 600 ? seconds : null;
  }
  final match = RegExp(r'^(\d{1,2}):(\d{1,2})$').firstMatch(value);
  if (match == null) return null;
  final minutes = int.parse(match[1]!), seconds = int.parse(match[2]!);
  final total = minutes * 60 + seconds;
  return seconds < 60 && total <= 600 ? total : null;
}

class PlayerSkipTimeDialog extends StatefulWidget {
  const PlayerSkipTimeDialog({
    super.key,
    required this.intro,
    required this.seconds,
  });
  final bool intro;
  final int seconds;
  @override
  State<PlayerSkipTimeDialog> createState() => _PlayerSkipTimeDialogState();
}

class _PlayerSkipTimeDialogState extends State<PlayerSkipTimeDialog> {
  late final input = TextEditingController(text: '${widget.seconds}');
  String? error;
  @override
  void dispose() {
    input.dispose();
    super.dispose();
  }

  void _apply() {
    final seconds = parsePlayerSkipTime(input.text);
    if (seconds == null) {
      setState(() => error = '请输入 0–600 秒或分:秒（例如 1:30）');
      return;
    }
    Navigator.pop(context, seconds);
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
    title: Text('自定义${widget.intro ? '片头' : '片尾'}时间'),
    content: SizedBox(
      width: 300,
      child: TextField(
        key: const Key('player-skip-time-input'),
        controller: input,
        autofocus: true,
        keyboardType: TextInputType.datetime,
        textInputAction: TextInputAction.done,
        decoration: InputDecoration(
          labelText: '跳过时长',
          helperText: '0–600 秒，支持分:秒，如 1:30',
          helperMaxLines: 2,
          errorText: error,
          errorMaxLines: 3,
        ),
        onChanged: (_) {
          if (error != null) setState(() => error = null);
        },
        onSubmitted: (_) => _apply(),
      ),
    ),
    actions: [
      TextButton(
        onPressed: () => Navigator.pop(context),
        child: const Text('取消'),
      ),
      FilledButton(
        key: const Key('player-skip-time-apply'),
        onPressed: _apply,
        child: const Text('确定'),
      ),
    ],
  );
}
