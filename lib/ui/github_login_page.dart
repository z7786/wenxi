import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import '../app_services.dart';
import '../domain/models.dart';
import 'common.dart';
import 'cloud_login_layout.dart';
import 'remote_control_dialogs.dart';

class GitHubLoginPage extends StatefulWidget {
  const GitHubLoginPage(this.services, {super.key, this.accountId});
  final AppServices services;
  final String? accountId;
  @override
  State<GitHubLoginPage> createState() => _GitHubLoginPageState();
}

class _GitHubLoginPageState extends State<GitHubLoginPage> {
  final _token = TextEditingController();
  bool _visible = false, _working = false, _completed = false;
  String _error = '';
  @override
  void dispose() {
    if (!_completed) widget.services.login.invalidate(CloudPlatform.github);
    _token.dispose();
    super.dispose();
  }

  Future<void> _login() async {
    if (_working) return;
    setState(() {
      _working = true;
      _error = '';
    });
    try {
      await widget.services.login.submitWeb(
        CloudPlatform.github,
        _token.text,
        accountId: widget.accountId,
      );
      _completed = true;
      if (mounted) Navigator.pop(context, true);
    } catch (e) {
      if (mounted) setState(() => _error = errorText(e));
    } finally {
      if (mounted) setState(() => _working = false);
    }
  }

  @override
  Widget build(BuildContext context) => PageFrame(
    title: 'GitHub 登录',
    child: CloudLoginLayout(
      platform: CloudPlatform.github,
      method: '访问令牌登录',
      children: [
        TextField(
          key: const Key('github-token'),
          controller: _token,
          enabled: !_working,
          obscureText: !_visible,
          autocorrect: false,
          enableSuggestions: false,
          keyboardType: TextInputType.visiblePassword,
          textInputAction: TextInputAction.done,
          onSubmitted: (_) => _login(),
          decoration: InputDecoration(
            labelText: '个人访问令牌（Token）',
            hintText: 'github_pat_… 或 ghp_…',
            suffixIcon: IconButton(
              tooltip: _visible ? '隐藏令牌' : '显示令牌',
              onPressed: () => setState(() => _visible = !_visible),
              icon: Icon(
                _visible ? CupertinoIcons.eye_slash : CupertinoIcons.eye,
                size: 20,
              ),
            ),
          ),
        ),
        const SizedBox(height: 12),
        if (_error.isNotEmpty)
          Padding(
            padding: const EdgeInsets.only(bottom: 12),
            child: Text(
              _error,
              style: TextStyle(color: Theme.of(context).colorScheme.error),
            ),
          ),
        FilledButton(
          onPressed: _working ? null : _login,
          child: Text(_working ? '正在验证…' : '验证并登录'),
        ),
        const SizedBox(height: 8),
        TextButton.icon(
          onPressed: _working
              ? null
              : () => openRemoteLink(
                  context,
                  Uri.parse(
                    'https://github.com/settings/personal-access-tokens/new',
                  ),
                ),
          icon: const Icon(CupertinoIcons.arrow_up_right_square, size: 17),
          label: const Text('前往 GitHub 创建令牌'),
        ),
        const SizedBox(height: 18),
        Container(
          padding: const EdgeInsets.all(16),
          decoration: BoxDecoration(
            color: fill(context),
            borderRadius: BorderRadius.circular(16),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text('令牌权限', style: TextStyle(fontWeight: FontWeight.w600)),
              const SizedBox(height: 8),
              Text(
                '选择需要访问的仓库，将 Contents 设为 Read and write，即可管理文件。只浏览下载可设为只读。\n\n修改 .github/workflows 中的文件还需要 Workflows 写入权限。传统令牌可使用 repo 权限。',
                style: TextStyle(
                  fontSize: 13,
                  height: 1.6,
                  color: secondary(context),
                ),
              ),
            ],
          ),
        ),
      ],
    ),
  );
}
