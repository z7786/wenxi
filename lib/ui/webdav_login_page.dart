import 'package:flutter/material.dart';
import '../app_services.dart';
import '../core/json.dart';
import '../data/providers/webdav.dart';
import '../domain/models.dart';
import '../domain/webdav.dart';
import 'app_switch.dart';
import 'cloud_login_layout.dart';
import 'common.dart';

class WebDavLoginPage extends StatefulWidget {
  const WebDavLoginPage(this.services, {super.key, this.accountId});
  final AppServices services;
  final String? accountId;
  @override
  State<WebDavLoginPage> createState() => _WebDavLoginPageState();
}

class _WebDavLoginPageState extends State<WebDavLoginPage> {
  final _url = TextEditingController(),
      _username = TextEditingController(),
      _password = TextEditingController();
  bool _remember = false,
      _visible = false,
      _working = false,
      _completed = false;
  String _error = '';
  WebDavConnector get connector =>
      widget.services.cloud.connector(CloudPlatform.webdav) as WebDavConnector;

  @override
  void initState() {
    super.initState();
    final credential = widget.services.vault.credentialFor(
      CloudPlatform.webdav,
      widget.accountId,
    );
    final legacy = widget.services.store.data.obj('backupWebDav');
    _url.text = credential?.primary ?? legacy.str('url');
    _username.text = credential?.field('username') ?? legacy.str('username');
    _remember = credential?.field('rememberPassword') == 'true';
    if (_remember) _password.text = credential!.field('password');
  }

  @override
  void dispose() {
    if (!_completed) widget.services.login.invalidate(CloudPlatform.webdav);
    _url.dispose();
    _username.dispose();
    _password.dispose();
    super.dispose();
  }

  Credential _candidate() => WebDavLocation.credential(
    url: _url.text,
    username: _username.text,
    password: _password.text,
    rememberPassword: _remember,
  );

  Future<void> _connect() async {
    if (_working) return;
    FocusScope.of(context).unfocus();
    setState(() {
      _working = true;
      _error = '';
    });
    Credential? candidate;
    try {
      candidate = _candidate();
      final credentials = candidate;
      final secret = _password.text;
      await widget.services.login.submit(
        CloudPlatform.webdav,
        (_) => connector.connect(credentials, secret),
        accountId: widget.accountId,
      );
      _completed = true;
      if (mounted) Navigator.pop(context);
    } catch (error) {
      if (mounted) setState(() => _error = errorText(error));
    } finally {
      if (candidate != null) {
        connector.finishConnection(candidate, saved: _completed);
      }
      if (mounted) setState(() => _working = false);
    }
  }

  Future<void> _test() async {
    if (_working) return;
    FocusScope.of(context).unfocus();
    setState(() {
      _working = true;
      _error = '';
    });
    try {
      final candidate = _candidate();
      final secret = _password.text;
      final passed = await busy(context, () async {
        await connector.client.test(
          WebDavLocation(candidate.primary),
          username: candidate.field('username'),
          password: secret,
        );
        return true;
      }, label: '正在测试目录读写与删除…');
      if (passed == true && mounted) message(context, '目录读写、回读和删除测试通过');
    } catch (error) {
      if (mounted) setState(() => _error = errorText(error));
    } finally {
      if (mounted) setState(() => _working = false);
    }
  }

  @override
  Widget build(BuildContext context) => PageFrame(
    title: 'WebDAV 连接',
    child: CloudLoginLayout(
      platform: CloudPlatform.webdav,
      method: '服务器连接',
      subtitle: '浏览文件，也可用来备份与恢复',
      children: [
        TextField(
          key: const Key('webdav-url'),
          controller: _url,
          enabled: !_working,
          keyboardType: TextInputType.url,
          autocorrect: false,
          textInputAction: TextInputAction.next,
          decoration: const InputDecoration(
            labelText: 'WebDAV 目录地址',
            hintText: 'https://example.com/dav/',
          ),
        ),
        const SizedBox(height: 16),
        TextField(
          key: const Key('webdav-username'),
          controller: _username,
          enabled: !_working,
          autocorrect: false,
          textInputAction: TextInputAction.next,
          decoration: const InputDecoration(
            labelText: '用户名',
            helperText: '无需认证的服务器可留空',
          ),
        ),
        const SizedBox(height: 16),
        TextField(
          key: const Key('webdav-password'),
          controller: _password,
          enabled: !_working,
          obscureText: !_visible,
          enableSuggestions: false,
          autocorrect: false,
          textInputAction: TextInputAction.done,
          onSubmitted: (_) => _connect(),
          decoration: InputDecoration(
            labelText: 'WebDAV 登录密码',
            suffixIcon: IconButton(
              tooltip: _visible ? '隐藏登录密码' : '显示登录密码',
              onPressed: _working
                  ? null
                  : () => setState(() => _visible = !_visible),
              icon: Icon(
                _visible
                    ? Icons.visibility_off_outlined
                    : Icons.visibility_outlined,
              ),
            ),
          ),
        ),
        const SizedBox(height: 12),
        ListTile(
          contentPadding: EdgeInsets.zero,
          title: const Text('记住登录密码'),
          subtitle: Text(
            _remember ? '密码将以明文保存在本机；备份账号时可加密导出' : '密码仅在本次运行中使用，重启后需重新输入',
          ),
          onTap: _working ? null : () => setState(() => _remember = !_remember),
          trailing: AppSwitch(
            key: const Key('webdav-remember'),
            value: _remember,
            onChanged: _working ? null : (v) => setState(() => _remember = v),
          ),
        ),
        if (_error.isNotEmpty)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 12),
            child: Text(
              _error,
              style: TextStyle(color: Theme.of(context).colorScheme.error),
            ),
          ),
        const SizedBox(height: 12),
        FilledButton(
          onPressed: _working ? null : _connect,
          child: Text(_working ? '正在连接…' : '连接并保存'),
        ),
        const SizedBox(height: 8),
        TextButton.icon(
          onPressed: _working ? null : _test,
          icon: const Icon(Icons.fact_check_outlined, size: 18),
          label: const Text('测试目录读写'),
        ),
        const SizedBox(height: 16),
        Text(
          '填写已经存在的最终目录地址。只读账号也能浏览和恢复备份；登录密码与备份加密密码分别设置。',
          style: TextStyle(
            color: secondary(context),
            fontSize: 13,
            height: 1.5,
          ),
        ),
      ],
    ),
  );
}
