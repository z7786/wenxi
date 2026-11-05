import 'dart:convert';
import 'package:flutter/material.dart';
import '../app_services.dart';
import '../data/http.dart';
import '../domain/github_acceleration.dart';
import '../download/native_http_probe.dart';
import 'common.dart';

class GitHubAccelerationPage extends StatefulWidget {
  const GitHubAccelerationPage(this.services, {super.key, this.testConnection});
  final AppServices services;
  final Future<void> Function(GitHubAcceleration)? testConnection;

  @override
  State<GitHubAccelerationPage> createState() => _GitHubAccelerationPageState();
}

class _GitHubAccelerationPageState extends State<GitHubAccelerationPage> {
  bool _saving = false, _testing = false, _testPassed = false;
  String? _result;
  RequestScope? _testScope;
  int _testRevision = 0;

  Future<void> _select(String mode, {String? customUrl}) async {
    if (_saving) return;
    _testScope?.cancel();
    _testRevision++;
    setState(() {
      _saving = true;
      _testing = false;
      _result = null;
    });
    try {
      await widget.services.updateSettings({
        'githubAcceleration': GitHubAcceleration(
          mode: mode,
          customUrl:
              customUrl ??
              widget.services.settings.githubAcceleration.customUrl,
        ).toJson(),
      });
    } catch (error) {
      if (mounted) message(context, errorText(error));
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  Future<void> _custom() async {
    final value = await askText(
      context,
      '自定义 GitHub 加速地址',
      initial: widget.services.settings.githubAcceleration.customUrl,
      hint: 'https://ghproxy.net/',
    );
    if (value == null || !mounted) return;
    try {
      await _select(
        'custom',
        customUrl: GitHubAcceleration.normalizePrefix(value),
      );
    } catch (error) {
      if (mounted) message(context, errorText(error));
    }
  }

  Future<void> _test() async {
    final revision = ++_testRevision;
    final settings = widget.services.settings.githubAcceleration;
    final scope = _testScope = RequestScope();
    final watch = Stopwatch()..start();
    var stage = '文件下载';
    var rangeSupported = true;
    setState(() {
      _testing = true;
      _result = null;
    });
    try {
      await scope
          .run(() async {
            if (widget.testConnection case final test?) {
              await test(settings);
            } else {
              await NativeHttpProbe(widget.services.engine).request(
                settings.urlFor(GitHubAcceleration.testUrl),
                const {'User-Agent': 'AsterLink-GitHub/1.0'},
                readLimit: 4096,
                validate: (bytes) =>
                    utf8.decode(bytes).trim() == 'Hello World!',
              );
              stage = '分段';
              final range = await NativeHttpProbe(widget.services.engine).request(
                settings.urlFor(GitHubAcceleration.rangeTestUrl),
                const {'User-Agent': 'AsterLink-GitHub/1.0'},
                readLimit: 1024,
                sampleOnly: true,
                validate: (bytes) => utf8
                    .decode(bytes, allowMalformed: true)
                    // COPYING starts with a blank line before its license text.
                    .trimLeft()
                    .startsWith('Note that the only valid version of the GPL'),
              );
              rangeSupported = range['code'] == 206;
            }
          })
          .timeout(const Duration(seconds: 65));
      if (mounted && revision == _testRevision) {
        setState(() {
          _testPassed = true;
          _result = rangeSupported
              ? '连接成功，文件下载及分段校验通过（${watch.elapsedMilliseconds} ms）'
              : '连接成功，文件可下载；当前地址未返回分段响应（${watch.elapsedMilliseconds} ms）';
        });
      }
    } catch (error) {
      if (mounted && revision == _testRevision) {
        setState(() {
          _testPassed = false;
          _result = stage == '分段'
              ? '文件下载校验通过，但分段测试失败：${errorText(error)}。可切换地址后重试。'
              : '${errorText(error)}。当前地址文件下载测试失败，可切换地址后重试。';
        });
      }
    } finally {
      scope.cancel();
      if (mounted && revision == _testRevision) {
        setState(() => _testing = false);
      }
    }
  }

  Widget _option(
    GitHubAcceleration settings,
    String mode,
    String title,
    String subtitle,
  ) {
    final selected = settings.mode == mode;
    return Semantics(
      checked: selected,
      inMutuallyExclusiveGroup: true,
      child: ListTile(
        key: ValueKey('github-acceleration-$mode'),
        enabled: !_saving,
        selected: selected,
        leading: Icon(
          selected ? Icons.radio_button_checked : Icons.radio_button_off,
        ),
        title: Text(title, style: const TextStyle(fontSize: 14)),
        subtitle: Text(
          subtitle,
          style: const TextStyle(fontSize: 12, height: 1.5),
        ),
        trailing: mode == 'custom'
            ? const Icon(Icons.edit_outlined, size: 18)
            : null,
        onTap: mode == 'custom' ? _custom : () => _select(mode),
      ),
    );
  }

  @override
  void dispose() {
    _testScope?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => PageFrame(
    title: 'GitHub 加速',
    child: ConstrainedBox(
      constraints: const BoxConstraints(maxWidth: 720),
      child: AnimatedBuilder(
        animation: widget.services.store,
        builder: (context, _) {
          final settings = widget.services.settings.githubAcceleration;
          return ListView(
            padding: const EdgeInsets.fromLTRB(18, 20, 18, 28),
            children: [
              Text(
                '用于 GitHub 公开文件、源码压缩包和应用更新安装包。切换后，新下载和下次继续下载时生效。镜像连接或文件范围异常时，会尝试直连及备用镜像。',
                style: TextStyle(
                  fontSize: 13,
                  height: 1.6,
                  color: secondary(context),
                ),
              ),
              const SizedBox(height: 16),
              Material(
                color: backgroundSurface(context),
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(16),
                  side: BorderSide(color: border(context), width: .7),
                ),
                clipBehavior: Clip.antiAlias,
                child: Column(
                  children: [
                    _option(settings, 'direct', '直连', '直接从 GitHub 下载'),
                    for (final entry in GitHubAcceleration.presets.entries)
                      _option(settings, entry.key, entry.key, entry.value),
                    _option(
                      settings,
                      'custom',
                      '自定义代理',
                      settings.customUrl.isEmpty
                          ? '填写自己的加速地址'
                          : settings.customUrl,
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 12),
              Text(
                '自定义地址使用“加速地址/完整 GitHub 链接”的格式。公开代理可用性随网络变化，可用下方按钮测试。私有下载链接和账号请求保持直连。',
                style: TextStyle(
                  fontSize: 12,
                  height: 1.6,
                  color: secondary(context),
                ),
              ),
              const SizedBox(height: 20),
              Align(
                alignment: Alignment.centerLeft,
                child: OutlinedButton.icon(
                  key: const Key('github-acceleration-test'),
                  onPressed: _testing || _saving ? null : _test,
                  icon: _testing
                      ? const SizedBox.square(
                          dimension: 16,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : const Icon(Icons.network_check, size: 20),
                  label: Text(_testing ? '正在测试…' : '测试当前连接'),
                ),
              ),
              if (_result != null)
                Padding(
                  padding: const EdgeInsets.only(top: 12),
                  child: Text(
                    _result!,
                    key: const Key('github-acceleration-result'),
                    style: TextStyle(
                      fontSize: 13,
                      height: 1.5,
                      color: _testPassed
                          ? themeAccent(context)
                          : Theme.of(context).colorScheme.error,
                    ),
                  ),
                ),
            ],
          );
        },
      ),
    ),
  );
}
