import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'app_switch.dart';
import '../download/download_shutdown.dart';
import 'common.dart';

class DownloadCompletionOption extends StatelessWidget {
  const DownloadCompletionOption(this.controller, {super.key});

  final DownloadShutdown controller;

  @override
  Widget build(BuildContext context) => AnimatedBuilder(
    animation: controller,
    builder: (context, _) {
      final accent = themeAccent(context);
      final colors = Theme.of(context).colorScheme;
      final enabled = controller.enabled;
      final title = Text(
        '下载完成后',
        style: TextStyle(
          fontSize: 13,
          fontWeight: FontWeight.w600,
          color: colors.onSurface,
        ),
      );
      final detail = Text(
        controller.detail,
        style: TextStyle(
          fontSize: 12,
          height: 1.4,
          color: enabled ? accent : secondary(context),
        ),
      );
      final toggle = Semantics(
        label: '下载完成后自动${controller.action.label}',
        child: AppSwitch(
          key: const Key('download-completion-enabled'),
          value: enabled,
          onChanged: controller.executing ? null : controller.setEnabled,
        ),
      );
      final actions =
          CupertinoSlidingSegmentedControl<DownloadCompletionAction>(
            key: const Key('download-completion-action'),
            groupValue: controller.action,
            disabledChildren: controller.executing
                ? DownloadCompletionAction.values.toSet()
                : const {},
            padding: const EdgeInsets.all(4),
            backgroundColor: colors.surfaceContainerHighest.withValues(
              alpha: .65,
            ),
            thumbColor: colors.surface,
            onValueChanged: (action) {
              if (action != null && !controller.executing) {
                controller.setAction(action);
              }
            },
            children: {
              for (final action in DownloadCompletionAction.values)
                action: Padding(
                  key: Key('download-completion-${action.name}'),
                  padding: const EdgeInsets.symmetric(
                    horizontal: 8,
                    vertical: 9,
                  ),
                  child: Row(
                    mainAxisAlignment: MainAxisAlignment.center,
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(
                        action == DownloadCompletionAction.hibernate
                            ? CupertinoIcons.moon
                            : CupertinoIcons.power,
                        size: 15,
                        color: controller.action == action
                            ? accent
                            : secondary(context),
                      ),
                      const SizedBox(width: 6),
                      Text(
                        action.label,
                        style: TextStyle(
                          fontSize: 13,
                          fontWeight: controller.action == action
                              ? FontWeight.w600
                              : FontWeight.w400,
                          color: controller.action == action
                              ? accent
                              : secondary(context),
                        ),
                      ),
                    ],
                  ),
                ),
            },
          );
      return AnimatedContainer(
        key: const Key('download-shutdown-option'),
        duration: MediaQuery.of(context).disableAnimations
            ? Duration.zero
            : const Duration(milliseconds: 160),
        margin: const EdgeInsets.fromLTRB(12, 8, 12, 8),
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
        decoration: BoxDecoration(
          color: enabled
              ? accent.withValues(alpha: .06)
              : colors.surfaceContainerLow.withValues(alpha: .5),
          borderRadius: BorderRadius.circular(12),
          border: Border.all(
            color: enabled ? accent.withValues(alpha: .25) : border(context),
            width: .5,
          ),
        ),
        child: LayoutBuilder(
          builder: (context, constraints) {
            final compact =
                constraints.maxWidth < 560 ||
                MediaQuery.textScalerOf(context).scale(13) > 18;
            if (compact) {
              return Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Row(
                    children: [
                      Expanded(child: title),
                      toggle,
                    ],
                  ),
                  const SizedBox(height: 6),
                  actions,
                  const SizedBox(height: 10),
                  detail,
                ],
              );
            }
            return Row(
              children: [
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisSize: MainAxisSize.min,
                    children: [title, const SizedBox(height: 5), detail],
                  ),
                ),
                const SizedBox(width: 16),
                SizedBox(width: 200, child: actions),
                const SizedBox(width: 12),
                toggle,
              ],
            );
          },
        ),
      );
    },
  );
}
