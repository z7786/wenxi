import 'dart:async';
import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import '../app_services.dart';
import '../core/json.dart';
import '../data/cloud_command_resolver.dart';
import '../data/http.dart';
import '../diagnostics/app_log.dart';
import '../domain/auth.dart';
import '../domain/models.dart';
import '../domain/c139_passcode.dart';
import 'browser_page.dart';
import 'cloud_command_history_sheet.dart';
import 'common.dart';
import 'login_page.dart';

class CloudCommandPage extends StatefulWidget {
  const CloudCommandPage(
    this.services, {
    super.key,
    this.initialText = '',
    this.resolveCommand,
  });
  final AppServices services;
  final String initialText;
  final Future<ParsedLink> Function(CloudPlatform, String)? resolveCommand;

  @override
  State<CloudCommandPage> createState() => _CloudCommandPageState();
}

class _CloudCommandPageState extends State<CloudCommandPage> {
  late CloudPlatform platform;
  final drafts = <CloudPlatform, TextEditingController>{
    for (final p in CloudCommandResolver.platforms) p: TextEditingController(),
  };
  final focus = FocusNode();
  int generation = 0;
  bool working = false;
  String error = '', stage = '';
  bool loginRequired = false;
  RequestScope? request;
  TextEditingController get input => drafts[platform]!;
  AppServices get services => widget.services;

  @override
  void initState() {
    super.initState();
    final saved = CloudPlatform.fromKey(
      services.store.data.str('commandParsePlatform'),
    );
    platform = CloudCommandResolver.platforms.contains(saved)
        ? saved!
        : CloudPlatform.quark;
    if (C139Passcode.parse(widget.initialText) != null) {
      platform = CloudPlatform.c139;
    }
    input.text = widget.initialText;
  }

  @override
  void dispose() {
    generation++;
    request?.cancel();
    for (final draft in drafts.values) {
      draft.dispose();
    }
    focus.dispose();
    super.dispose();
  }

  bool current(int value) => mounted && value == generation;

  void cancel() {
    generation++;
    request?.cancel();
    request = null;
    setState(() {
      working = false;
      stage = '';
      error = '解析已取消，口令已保留';
    });
  }

  void choose(CloudPlatform value) {
    if (working || platform == value) return;
    focus.unfocus();
    setState(() {
      platform = value;
      error = '';
      loginRequired = false;
    });
    unawaited(
      services.store.put('commandParsePlatform', value.key).catchError((
        Object e,
        StackTrace stack,
      ) {
        DiagnosticLog.error('parse.command_preference_failed', e, stack);
      }),
    );
  }

  void setText(String text) {
    if (working) return;
    input.text = text;
    input.selection = TextSelection.collapsed(offset: text.length);
    setState(() {
      error = '';
      loginRequired = false;
    });
  }

  Future<void> paste() async {
    final selected = platform;
    final value = await Clipboard.getData(Clipboard.kTextPlain);
    if (!mounted || working || platform != selected) return;
    if (value?.text?.isNotEmpty != true) {
      message(context, '剪贴板中没有文本');
      return;
    }
    if (value!.text!.length > CloudCommandResolver.maximumLength) {
      setState(() => error = '分享文案过长，请只复制本次要解析的口令');
      return;
    }
    setText(value.text!);
  }

  Future<void> history() async {
    if (working) return;
    focus.unfocus();
    final entry = await showCloudCommandHistory(context, services);
    if (entry == null || !mounted || working) return;
    choose(entry.platform);
    setText(entry.text);
  }

  Future<void> login() async {
    if (working) return;
    final selected = platform, text = input.text;
    await openLogin(context, services, selected);
    if (mounted &&
        platform == selected &&
        input.text == text &&
        LoginCredentials.stored(
          selected,
          services.vault.credential(selected),
        )) {
      await parse();
    }
  }

  Future<void> parse() async {
    if (working) return;
    if (input.text.trim().isEmpty) {
      setState(() => error = '请先粘贴${platform.shortName}口令');
      focus.requestFocus();
      return;
    }
    focus.unfocus();
    final selected = platform, text = input.text, run = ++generation;
    final scope = request = RequestScope();
    void checkpoint() {
      require(current(run) && !scope.token.isCancelled, '解析已取消');
      services.control.checkCloud(selected);
    }

    setState(() {
      working = true;
      error = '';
      loginRequired = false;
      stage = '正在解析${selected.shortName}口令…';
    });
    try {
      checkpoint();
      final link = await scope
          .run(
            () => RequestScope.cancellable(
              (widget.resolveCommand ?? services.cloud.resolveCommand)(
                selected,
                text,
              ),
            ),
          )
          .timeout(
            const Duration(seconds: 25),
            onTimeout: () {
              scope.cancel();
              throw const AppException('口令解析超时，请检查网络后重试');
            },
          );
      checkpoint();
      require(
        link.isCloudShare && link.platform == selected,
        '解析结果与所选网盘不一致，请检查口令',
      );
      if (selected.shareRequiresAccount &&
          !LoginCredentials.stored(
            selected,
            services.vault.credential(selected),
          )) {
        if (!mounted) return;
        final proceed = await showDialog<bool>(
          context: context,
          builder: (context) => AlertDialog(
            title: Text('${selected.shortName}需要登录'),
            content: Text(
              selected == CloudPlatform.c139
                  ? '移动云盘口令需要使用本 App 内登录账号的授权信息。请先登录移动云盘，再继续解析、下载或转存。'
                  : '已解析出口令对应的分享，登录后继续打开文件列表。',
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(context, false),
                child: const Text('取消'),
              ),
              FilledButton(
                onPressed: () => Navigator.pop(context, true),
                child: const Text('去登录'),
              ),
            ],
          ),
        );
        checkpoint();
        if (proceed != true) {
          throw AccountLoginRequired(
            selected == CloudPlatform.c139
                ? '请先在本 App 登录移动云盘后再解析，口令已保留'
                : '尚未完成登录，口令已保留',
          );
        }
        if (!mounted) return;
        await openLogin(context, services, selected);
        checkpoint();
        if (!LoginCredentials.stored(
          selected,
          services.vault.credential(selected),
        )) {
          throw AccountLoginRequired('尚未完成登录，口令已保留');
        }
      }
      final revision = services.vault.credential(selected)?.updatedAt;
      void shareCheckpoint() {
        checkpoint();
        require(
          services.vault.credential(selected)?.updatedAt == revision,
          '账号已变化，请重新解析',
        );
      }

      setState(() => stage = '正在打开分享…');
      final result = await scope
          .run(
            () => RequestScope.cancellable(
              RequestScope.guarded(() async {
                final session = await services.cloud.share(link);
                shareCheckpoint();
                setState(() => stage = '正在读取文件列表…');
                final files = await services.cloud.list(
                  session,
                  session.rootId,
                );
                shareCheckpoint();
                return (session, files);
              }, shareCheckpoint),
            ),
          )
          .timeout(
            const Duration(seconds: 90),
            onTimeout: () {
              scope.cancel();
              throw const AppException('读取分享超时，口令已保留，请重试');
            },
          );
      shareCheckpoint();
      services.rememberInBackground(
        link,
        title: result.$1.title,
        itemCount: result.$2.length,
        commandText: text,
      );
      shareCheckpoint();
      request = null;
      setState(() {
        working = false;
        stage = '';
      });
      if (!mounted) return;
      await Navigator.push<void>(
        context,
        MaterialPageRoute(
          builder: (_) =>
              BrowserPage(services, result.$1, initialItems: result.$2),
        ),
      );
    } catch (e, stack) {
      if (!current(run)) return;
      DiagnosticLog.error(
        'parse.command_failed',
        e,
        stack,
        fields: {'platform': selected.key},
      );
      setState(() {
        error = errorText(e);
        loginRequired = e is AccountLoginRequired;
      });
    } finally {
      if (current(run)) {
        request = null;
        setState(() {
          working = false;
          stage = '';
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final paper = Theme.of(context).colorScheme.surface;
    final help = platform == CloudPlatform.c139
        ? '支持移动云盘文字口令、/*…:/ 口令或完整分享文案。解析、下载和转存使用本 App 内登录的移动云盘账号，请先登录。'
        : '请从${platform.shortName}复制口令或完整分享文案，保留原有内容';
    return PopScope(
      canPop: !working,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop && working) cancel();
      },
      child: Scaffold(
        backgroundColor: fill(context),
        appBar: AppBar(
          title: const Text('口令解析'),
          actions: [
            IconButton(
              key: const Key('command-history'),
              tooltip: '口令历史',
              onPressed: working ? null : history,
              icon: const Icon(CupertinoIcons.clock),
            ),
          ],
        ),
        body: SafeArea(
          child: Center(
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 560),
              child: ListView(
                padding: const EdgeInsets.fromLTRB(20, 24, 20, 28),
                children: [
                  const Text(
                    '选择口令所属网盘',
                    style: TextStyle(fontSize: 14, fontWeight: FontWeight.w500),
                  ),
                  const SizedBox(height: 12),
                  LayoutBuilder(
                    builder: (context, bounds) {
                      final largeText =
                          MediaQuery.textScalerOf(context).scale(14) > 22;
                      return Wrap(
                        spacing: 10,
                        runSpacing: 10,
                        children: [
                          for (final item in CloudCommandResolver.platforms)
                            SizedBox(
                              width: largeText
                                  ? bounds.maxWidth
                                  : (bounds.maxWidth - 10) / 2,
                              child: Semantics(
                                selected: platform == item,
                                button: true,
                                child: Material(
                                  color: platform == item
                                      ? themeAccent(
                                          context,
                                        ).withValues(alpha: .10)
                                      : paper,
                                  shape: RoundedRectangleBorder(
                                    borderRadius: BorderRadius.circular(16),
                                    side: BorderSide(
                                      color: platform == item
                                          ? themeAccent(context)
                                          : Colors.transparent,
                                      width: 1.5,
                                    ),
                                  ),
                                  clipBehavior: Clip.antiAlias,
                                  child: InkWell(
                                    key: ValueKey(
                                      'command-provider-${item.key}',
                                    ),
                                    onTap: working ? null : () => choose(item),
                                    child: Stack(
                                      children: [
                                        Padding(
                                          padding: const EdgeInsets.symmetric(
                                            vertical: 16,
                                            horizontal: 6,
                                          ),
                                          child: Center(
                                            child: Column(
                                              mainAxisSize: MainAxisSize.min,
                                              children: [
                                                PlatformMark(
                                                  platform: item,
                                                  size: 34,
                                                ),
                                                const SizedBox(height: 10),
                                                Text(
                                                  item.label,
                                                  textAlign: TextAlign.center,
                                                  style: const TextStyle(
                                                    fontSize: 14,
                                                  ),
                                                ),
                                              ],
                                            ),
                                          ),
                                        ),
                                        if (platform == item)
                                          Positioned(
                                            top: 7,
                                            right: 7,
                                            child: Icon(
                                              CupertinoIcons
                                                  .checkmark_circle_fill,
                                              size: 16,
                                              color: themeAccent(context),
                                            ),
                                          ),
                                      ],
                                    ),
                                  ),
                                ),
                              ),
                            ),
                        ],
                      );
                    },
                  ),
                  const SizedBox(height: 26),
                  Container(
                    padding: const EdgeInsets.fromLTRB(17, 12, 17, 8),
                    decoration: BoxDecoration(
                      color: paper,
                      borderRadius: BorderRadius.circular(18),
                    ),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        Row(
                          children: [
                            Expanded(
                              child: Text(
                                '${platform.shortName}口令',
                                style: const TextStyle(
                                  fontSize: 15,
                                  fontWeight: FontWeight.w500,
                                ),
                              ),
                            ),
                            TextButton.icon(
                              onPressed: working ? null : paste,
                              icon: const Icon(
                                CupertinoIcons.doc_on_clipboard,
                                size: 16,
                              ),
                              label: const Text('粘贴'),
                            ),
                          ],
                        ),
                        const SizedBox(height: 8),
                        TextField(
                          key: const Key('command-input'),
                          controller: input,
                          focusNode: focus,
                          readOnly: working,
                          minLines: 5,
                          maxLines: 8,
                          maxLength: CloudCommandResolver.maximumLength,
                          style: const TextStyle(fontSize: 16, height: 1.8),
                          onChanged: (_) => setState(() {
                            error = '';
                            loginRequired = false;
                          }),
                          decoration: InputDecoration(
                            hintText:
                                '在这里粘贴${platform.shortName}口令…\n也可以粘贴包含口令的分享文案',
                            hintStyle: TextStyle(
                              color: secondary(context).withValues(alpha: .7),
                            ),
                            border: InputBorder.none,
                            enabledBorder: InputBorder.none,
                            focusedBorder: InputBorder.none,
                            filled: false,
                            counterText: '',
                            contentPadding: EdgeInsets.zero,
                          ),
                        ),
                        Divider(color: border(context)),
                        Align(
                          alignment: Alignment.centerRight,
                          child: Text(
                            '${input.text.length} / ${CloudCommandResolver.maximumLength}',
                            style: TextStyle(
                              fontSize: 12,
                              color: secondary(context),
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                  Padding(
                    padding: const EdgeInsets.fromLTRB(4, 11, 4, 22),
                    child: Text(
                      help,
                      style: TextStyle(
                        fontSize: 12,
                        height: 1.7,
                        color: secondary(context),
                      ),
                    ),
                  ),
                  if (error.isNotEmpty)
                    Padding(
                      padding: const EdgeInsets.only(bottom: 12),
                      child: Text(
                        error,
                        key: const Key('command-error'),
                        style: TextStyle(
                          color: Theme.of(context).colorScheme.error,
                          height: 1.5,
                        ),
                      ),
                    ),
                  if (loginRequired)
                    TextButton(
                      onPressed: working ? null : login,
                      child: const Text('去登录并继续'),
                    ),
                  FilledButton.icon(
                    key: const Key('command-start'),
                    onPressed: working ? null : parse,
                    style: FilledButton.styleFrom(
                      minimumSize: const Size.fromHeight(50),
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(15),
                      ),
                    ),
                    icon: working
                        ? const SizedBox(
                            width: 17,
                            height: 17,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          )
                        : const Icon(Icons.document_scanner_outlined, size: 19),
                    label: Text(working ? stage : '解析口令'),
                  ),
                  if (working)
                    TextButton(onPressed: cancel, child: const Text('取消解析')),
                  const SizedBox(height: 12),
                  Text(
                    '仅解析所选网盘的口令',
                    textAlign: TextAlign.center,
                    style: TextStyle(fontSize: 12, color: secondary(context)),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}
