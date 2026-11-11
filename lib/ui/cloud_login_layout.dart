import 'package:flutter/material.dart';
import '../domain/models.dart';
import 'common.dart';

/// Shared presentation for native cloud login forms; callers own login state.
class CloudLoginLayout extends StatelessWidget {
  const CloudLoginLayout({
    super.key,
    required this.platform,
    required this.method,
    required this.children,
    this.formKey,
    this.subtitle = '便捷访问你的云端文件',
  });

  final CloudPlatform platform;
  final String method, subtitle;
  final List<Widget> children;
  final GlobalKey<FormState>? formKey;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context), colors = theme.colorScheme;
    OutlineInputBorder outline(Color color, [double width = 1]) =>
        OutlineInputBorder(
          borderRadius: BorderRadius.circular(14),
          borderSide: BorderSide(color: color, width: width),
        );
    return Theme(
      data: theme.copyWith(
        inputDecorationTheme: theme.inputDecorationTheme.copyWith(
          filled: true,
          fillColor: Color.alphaBlend(
            colors.surfaceContainerLow.withValues(alpha: .35),
            colors.surface,
          ),
          floatingLabelBehavior: FloatingLabelBehavior.auto,
          contentPadding: const EdgeInsets.symmetric(
            horizontal: 16,
            vertical: 18,
          ),
          labelStyle: TextStyle(color: colors.onSurfaceVariant, fontSize: 16),
          floatingLabelStyle: TextStyle(color: colors.primary, fontSize: 16),
          hintStyle: TextStyle(color: colors.onSurfaceVariant, fontSize: 14),
          prefixIconColor: colors.onSurfaceVariant,
          prefixIconConstraints: const BoxConstraints(
            minWidth: 54,
            minHeight: 24,
          ),
          border: outline(colors.outlineVariant),
          enabledBorder: outline(colors.outlineVariant),
          disabledBorder: outline(colors.outlineVariant.withValues(alpha: .55)),
          focusedBorder: outline(colors.primary, 1.6),
          errorBorder: outline(colors.error),
          focusedErrorBorder: outline(colors.error, 1.6),
          errorMaxLines: 3,
        ),
        filledButtonTheme: FilledButtonThemeData(
          style: FilledButton.styleFrom(
            minimumSize: const Size.fromHeight(56),
            padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 16),
            textStyle: theme.textTheme.labelLarge!.copyWith(
              fontSize: 18,
              fontWeight: FontWeight.w600,
            ),
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(14),
            ),
          ),
        ),
      ),
      child: LayoutBuilder(
        builder: (context, constraints) {
          final compact = constraints.maxHeight < 600;
          final contents = Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Center(
                child: PlatformMark(
                  platform: platform,
                  size: compact ? 56 : 64,
                ),
              ),
              const SizedBox(height: 18),
              Text(
                '欢迎登录${platform.label}',
                textAlign: TextAlign.center,
                style: theme.textTheme.headlineSmall!.copyWith(
                  color: colors.onSurface,
                  fontSize: 26,
                  fontWeight: FontWeight.w700,
                  height: 1.35,
                ),
              ),
              const SizedBox(height: 9),
              Text(
                subtitle,
                textAlign: TextAlign.center,
                style: TextStyle(color: colors.onSurfaceVariant, fontSize: 15),
              ),
              SizedBox(height: compact ? 28 : 38),
              Row(
                children: [
                  Container(
                    width: 4,
                    height: 18,
                    decoration: BoxDecoration(
                      color: colors.primary,
                      borderRadius: BorderRadius.circular(4),
                    ),
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Text(
                      method,
                      style: const TextStyle(
                        fontSize: 18,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 24),
              ...children,
            ],
          );
          return SizedBox(
            width: double.infinity,
            height: constraints.hasBoundedHeight ? constraints.maxHeight : null,
            child: SingleChildScrollView(
              keyboardDismissBehavior: ScrollViewKeyboardDismissBehavior.onDrag,
              padding: EdgeInsets.fromLTRB(22, compact ? 24 : 38, 22, 32),
              child: Center(
                child: ConstrainedBox(
                  constraints: const BoxConstraints(maxWidth: 440),
                  child: AutofillGroup(
                    onDisposeAction: AutofillContextAction.cancel,
                    child: formKey == null
                        ? contents
                        : Form(key: formKey, child: contents),
                  ),
                ),
              ),
            ),
          );
        },
      ),
    );
  }
}

class CloudLoginFieldIcon extends StatelessWidget {
  const CloudLoginFieldIcon(this.icon, {super.key});
  final IconData icon;
  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.only(right: 12),
    child: Container(
      width: 42,
      height: 24,
      decoration: BoxDecoration(
        border: Border(
          right: BorderSide(
            color: Theme.of(context).colorScheme.outlineVariant,
          ),
        ),
      ),
      child: Icon(icon, size: 22),
    ),
  );
}

class CloudLoginCodeAction extends StatelessWidget {
  const CloudLoginCodeAction({super.key, required this.child});
  final Widget child;
  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.only(right: 6),
    child: DecoratedBox(
      decoration: BoxDecoration(
        border: Border(
          left: BorderSide(color: Theme.of(context).colorScheme.outlineVariant),
        ),
      ),
      child: child,
    ),
  );
}

class CloudLoginAgreement extends StatelessWidget {
  const CloudLoginAgreement({
    super.key,
    required this.checkboxKey,
    required this.value,
    required this.onChanged,
    required this.onService,
    required this.onPrivacy,
  });
  final Key checkboxKey;
  final bool value;
  final ValueChanged<bool?>? onChanged;
  final VoidCallback onService, onPrivacy;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.only(top: 6, bottom: 24),
    child: Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SizedBox(
          width: 32,
          height: 40,
          child: Checkbox(
            key: checkboxKey,
            value: value,
            onChanged: onChanged,
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(4),
            ),
          ),
        ),
        const SizedBox(width: 8),
        Expanded(
          child: DefaultTextStyle(
            style: Theme.of(context).textTheme.bodySmall!.copyWith(
              color: secondary(context),
              fontSize: 12,
              height: 1.5,
            ),
            child: Wrap(
              crossAxisAlignment: WrapCrossAlignment.center,
              children: [
                const Text('我已阅读并同意 '),
                _link(context, '《用户协议》', onService),
                const Text(' 和 '),
                _link(context, '《隐私政策》', onPrivacy),
              ],
            ),
          ),
        ),
      ],
    ),
  );

  Widget _link(BuildContext context, String text, VoidCallback callback) =>
      TextButton(
        onPressed: callback,
        style: TextButton.styleFrom(
          minimumSize: const Size(0, 40),
          padding: EdgeInsets.zero,
          textStyle: Theme.of(
            context,
          ).textTheme.labelLarge!.copyWith(fontSize: 12),
          tapTargetSize: MaterialTapTargetSize.shrinkWrap,
        ),
        child: Text(text),
      );
}

class CloudLoginAlternatives extends StatelessWidget {
  const CloudLoginAlternatives({super.key, required this.children});
  final List<Widget> children;

  @override
  Widget build(BuildContext context) {
    if (children.isEmpty) return const SizedBox.shrink();
    final colors = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.only(top: 30),
      child: Column(
        children: [
          Row(
            children: [
              const Expanded(child: Divider()),
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 16),
                child: Text(
                  '其他方式',
                  style: TextStyle(
                    color: colors.onSurfaceVariant,
                    fontSize: 13,
                  ),
                ),
              ),
              const Expanded(child: Divider()),
            ],
          ),
          const SizedBox(height: 22),
          TextButtonTheme(
            data: TextButtonThemeData(
              style: TextButton.styleFrom(
                backgroundColor: colors.surfaceContainerLow,
                foregroundColor: colors.onSurface,
                minimumSize: const Size.fromHeight(52),
                padding: const EdgeInsets.symmetric(
                  horizontal: 12,
                  vertical: 14,
                ),
                textStyle: Theme.of(context).textTheme.labelLarge!.copyWith(
                  fontSize: 14,
                  fontWeight: FontWeight.w500,
                ),
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(14),
                ),
              ),
            ),
            child: LayoutBuilder(
              builder: (context, constraints) {
                final stack =
                    constraints.maxWidth < 300 ||
                    MediaQuery.textScalerOf(context).scale(14) > 18;
                final rows = <Widget>[];
                for (var i = 0; i < children.length;) {
                  if (stack || (i == 0 && children.length.isOdd)) {
                    rows.add(
                      SizedBox(width: double.infinity, child: children[i++]),
                    );
                  } else {
                    rows.add(
                      Row(
                        children: [
                          Expanded(child: children[i++]),
                          const SizedBox(width: 12),
                          Expanded(child: children[i++]),
                        ],
                      ),
                    );
                  }
                  if (i < children.length) rows.add(const SizedBox(height: 12));
                }
                return Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: rows,
                );
              },
            ),
          ),
        ],
      ),
    );
  }
}
