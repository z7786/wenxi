import 'dart:async';
import 'dart:io';
import 'package:file_selector/file_selector.dart';
import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:path/path.dart' as p;
import '../app_services.dart';
import '../core/json.dart';
import '../core/natural_name.dart';
import '../core/operation_progress.dart';
import '../data/http.dart';
import '../data/resource_pool_preview.dart';
import '../data/cloud_search.dart';
import '../data/cloud_search_history.dart';
import '../domain/cloud_search_options.dart';
import '../domain/models.dart';
import '../domain/aliyun_share.dart';
import '../domain/baidu_share_route.dart';
import '../domain/public_share_route.dart';
import '../domain/github.dart';
import '../domain/settings.dart';
import '../domain/cloud_file_time.dart';
import '../diagnostics/app_log.dart';
import 'app_popup_menu.dart';
import 'app_context_menu.dart';
import 'account_cookie.dart';
import 'account_info_page.dart';
import 'cloud_accounts_page.dart';
import 'common.dart';
import 'baidu_download_prompt.dart';
import 'baidu_share_route_picker.dart';
import 'parser_site_picker.dart';
import '../data/parser_rules/hub.dart';
import 'cloud_thumbnail.dart';
import 'cloud_search_page.dart';
import '../upload/upload_task.dart';
import 'login_page.dart';
import 'preview_page.dart';
import 'cloud_favorites_page.dart';
import 'loading_indicator.dart';
import 'cloud_upload_drop_target.dart';
import 'uc_video_download.dart';

class BrowserPage extends StatefulWidget {
  const BrowserPage(
    this.services,
    this.session, {
    super.key,
    this.picking = false,
    this.excludedFolders = const {},
    this.initialItems,
    this.initialTrail,
    this.highlightedFileId,
    this.searchPage = false,
    this.popAtInitialDirectory = false,
    this.onDestinationPicked,
    this.poolPreview,
  });
  final AppServices services;
  final ResourcePoolPreview? poolPreview;
  final BrowseSession session;
  final bool picking;
  final Set<String> excludedFolders;
  final List<CloudFile>? initialItems;
  final List<(String, String)>? initialTrail;
  final String? highlightedFileId;
  final bool searchPage;
  final bool popAtInitialDirectory;
  final void Function(BrowseSession, List<(String, String)>)?
  onDestinationPicked;
  @override
  State<BrowserPage> createState() => _BrowserPageState();
}

class _BrowserPageState extends State<BrowserPage> {
  late BrowseSession session = widget.services.cloud.bindSession(
    widget.session,
  );
  late final stack = <(String, String)>[
    ...widget.initialTrail ?? [(session.rootId, '全部文件')],
  ];
  late int? accountRevision;
  late String? highlight = widget.highlightedFileId;
  late List<CloudFile> items = List.of(widget.initialItems ?? const []);
  late DateTime _timeReference;
  // CloudFile is immutable. Reuse pinyin keys across selection/menu rebuilds;
  // weak keys let discarded directory and search results leave memory.
  final _nameKeys = Expando<NaturalName>();
  final selected = <String>{}, search = TextEditingController();
  final _progress = OperationProgress();
  late final CloudDirectorySearch _deepSearch;
  bool _searchResults = false;
  int _searchGeneration = 0;
  Timer? _searchPaint;
  bool _searchEntireDrive = true;
  CloudSearchCategory _searchCategory = CloudSearchCategory.all;
  late final _searchHistory = CloudSearchHistory(widget.services.store);
  bool get _includeSubfolders => widget.searchPage;
  List<(String, String)> get _searchTrail =>
      _searchEntireDrive ? [(session.rootId, '全部文件')] : List.of(stack);
  List<CloudFile> get _sourceItems =>
      _searchResults ? _deepSearch.hits.map((hit) => hit.file).toList() : items;
  CloudSearchHit? _hit(CloudFile file) =>
      _searchResults ? _deepSearch.hitFor(file) : null;
  String _fileKey(CloudFile file) => _hit(file)?.key ?? file.id;
  List<(String, String)> _trailFor(CloudFile file) =>
      _hit(file)?.trail ?? stack;
  late bool loading = !widget.searchPage && widget.initialItems == null;
  bool changingAccount = false, pickingUpload = false;
  bool _selectionMode = false;
  bool get _selecting => _selectionMode || selected.isNotEmpty;
  CloudConnector get _provider =>
      widget.services.cloud.connector(session.platform);
  bool get _canUpload => _provider.canUploadTo(session, stack.last.$1);
  bool get _canDropUpload =>
      CloudUploadDropTarget.supported &&
      !widget.picking &&
      !widget.searchPage &&
      !_searchResults &&
      !loading &&
      !changingAccount &&
      !pickingUpload &&
      error.isEmpty &&
      _available &&
      _canUpload &&
      widget.services.cloud.sessionCredential(session) != null &&
      accountRevision ==
          widget.services.cloud.sessionCredential(session)?.updatedAt;
  bool get _canCreateFolder =>
      _provider.canCreateFolderIn(session, stack.last.$1);
  BrowserDisplaySettings get _display =>
      widget.services.settings.browserDisplayFor(session.platform);
  String get view => widget.searchPage ? 'list' : _display.view;
  String get sort => _display.sort;
  bool get ascending => _display.ascending;
  String error = '';
  int generation = 0;
  RequestScope? request;
  StreamSubscription<UploadTask>? _uploadChanges;
  Timer? _uploadRefresh;
  (BrowseSession, List<(String, String)>)? _pickedDestination;
  late bool _available = widget.services.control.cloudEnabled(session.platform);
  @override
  void initState() {
    super.initState();
    _timeReference = widget.services.clock();
    accountRevision = widget.services.cloud
        .sessionCredential(session)
        ?.updatedAt;
    _deepSearch = CloudDirectorySearch(
      read: widget.services.cloud.list,
      directoryId: widget.services.cloud.directoryId,
      validate: (captured) {
        require(identical(captured, session), '账号或目录已变化，请重新搜索');
        _checkAccount();
      },
    )..addListener(_searchChanged);
    if (widget.initialItems != null) {
      _deepSearch.remember(session, stack.last.$1, items);
    }
    if (highlight != null) {
      search.text =
          items.where((f) => f.id == highlight).firstOrNull?.name ?? '';
    }
    widget.services.control.addListener(_controlChanged);
    widget.services.store.addListener(_profileChanged);
    widget.services.parserRules.addListener(_parserRulesChanged);
    _uploadChanges = widget.services.uploads.completions.stream.listen((task) {
      if (!mounted ||
          task.session.platform != session.platform ||
          task.session.accountId != session.accountId ||
          task.session.personalSpaceId != session.personalSpaceId ||
          (!_searchResults && task.parent != stack.last.$1)) {
        return;
      }
      _uploadRefresh?.cancel();
      _uploadRefresh = Timer(const Duration(milliseconds: 400), () {
        if (mounted &&
            (_searchResults || task.parent == stack.last.$1) &&
            task.session.accountId == session.accountId) {
          unawaited(_refresh(preserveSelection: true));
        }
      });
    });
    if (!widget.searchPage && widget.initialItems == null) _load();
  }

  @override
  void dispose() {
    widget.services.parserRules.removeListener(_parserRulesChanged);
    widget.services.control.removeListener(_controlChanged);
    widget.services.store.removeListener(_profileChanged);
    _uploadChanges?.cancel();
    _uploadRefresh?.cancel();
    _searchPaint?.cancel();
    _deepSearch.dispose();
    request?.cancel();
    _progress.dispose();
    search.dispose();
    super.dispose();
  }

  void _parserRulesChanged() {
    if (mounted) setState(() {});
  }

  void _controlChanged() {
    final available = widget.services.control.cloudEnabled(session.platform);
    if (!mounted) return;
    if (available == _available) {
      if (!available) setState(() {});
      return;
    }
    _available = available;
    if (available) {
      if (widget.searchPage) {
        setState(() {});
      } else {
        unawaited(_load());
      }
    } else {
      _resetSearch(clearCache: true);
      request?.cancel();
      _progress.close(cancelled: true);
      generation++;
      setState(() {
        loading = false;
        selected.clear();
        _selectionMode = false;
      });
    }
  }

  void _profileChanged() {
    if ((_searchResults || widget.searchPage) &&
        accountRevision !=
            widget.services.cloud.sessionCredential(session)?.updatedAt) {
      _resetSearch(clearCache: true);
      error = '账号已变化，请重新打开文件列表';
    }
    if (mounted) setState(() {});
  }

  void _searchChanged() {
    if (!mounted || !_searchResults) return;
    if (!_deepSearch.running) {
      _searchPaint?.cancel();
      _searchPaint = null;
      setState(() {});
    } else {
      _searchPaint ??= Timer(const Duration(milliseconds: 80), () {
        _searchPaint = null;
        if (mounted && _searchResults) setState(() {});
      });
    }
  }

  void _resetSearch({bool clearCache = false}) {
    _searchGeneration++;
    _searchResults = false;
    _searchPaint?.cancel();
    _searchPaint = null;
    _deepSearch.clear();
    if (clearCache) _deepSearch.clearCache();
    selected.clear();
    _selectionMode = false;
  }

  void _editSearch() => setState(() {
    if (_searchResults) _resetSearch();
    highlight = null;
  });

  Future<void> _changeSearchScope(bool entireDrive) async {
    if (_searchEntireDrive == entireDrive) return;
    final restart = _searchResults;
    setState(() {
      _resetSearch();
      highlight = null;
      _searchEntireDrive = entireDrive;
    });
    if (restart) await _startSearch();
  }

  Future<void> _changeSearchCategory(CloudSearchCategory category) async {
    if (_searchCategory == category) return;
    setState(() {
      _resetSearch();
      _searchCategory = category;
    });
    await _startSearch();
  }

  void _clearSearch() => setState(() {
    _resetSearch();
    _searchCategory = CloudSearchCategory.all;
    search.clear();
    highlight = null;
  });

  Future<void> _rememberSearch(String term) async {
    try {
      await _searchHistory.remember(session, term);
    } catch (_) {
      if (mounted) message(context, '搜索历史保存失败');
    }
  }

  Future<void> _clearSearchHistory() async {
    if (!await confirm(context, '清空搜索历史', '清空当前账号的搜索记录？', action: '清空') ||
        !mounted) {
      return;
    }
    await busy(context, () => _searchHistory.clear(session));
  }

  Future<void> _openSearch() async {
    if (!allowCloudAction(context, widget.services.control, session.platform)) {
      return;
    }
    try {
      _checkAccount();
    } catch (failure) {
      message(context, errorText(failure));
      return;
    }
    await Navigator.push<void>(
      context,
      MaterialPageRoute(
        builder: (_) => CloudSearchPage(
          widget.services,
          session,
          currentTrail: List.of(stack),
          currentItems: loading || error.isNotEmpty ? null : List.of(items),
          poolPreview: widget.poolPreview,
        ),
      ),
    );
    if (mounted) await _refresh(preserveSelection: true);
  }

  Future<void> _openSearchDirectory(CloudFile file) async {
    final trail = [
      ..._trailFor(file),
      (widget.services.cloud.directoryId(session, file), file.name),
    ];
    final current = _searchGeneration;
    _deepSearch.stop();
    await Navigator.push<void>(
      context,
      MaterialPageRoute(
        builder: (_) => BrowserPage(
          widget.services,
          session,
          initialTrail: trail,
          poolPreview: widget.poolPreview,
          popAtInitialDirectory: true,
        ),
      ),
    );
    if (!mounted) return;
    _deepSearch.clearCache();
    if (_searchResults && current == _searchGeneration) await _refresh();
  }

  Future<void> _startSearch({bool refresh = false}) async {
    if (!_includeSubfolders ||
        changingAccount ||
        search.text.trim().isEmpty &&
            _searchCategory == CloudSearchCategory.all) {
      return;
    }
    FocusScope.of(context).unfocus();
    unawaited(_rememberSearch(search.text));
    request?.cancel();
    _progress.close(cancelled: true);
    generation++;
    final current = ++_searchGeneration, captured = session;
    setState(() {
      _searchResults = true;
      _timeReference = widget.services.clock();
      selected.clear();
      _selectionMode = false;
      loading = false;
      error = '';
    });
    await _deepSearch.start(
      captured,
      _searchTrail,
      search.text,
      refresh: refresh,
      matches: _searchCategory == CloudSearchCategory.all
          ? null
          : _searchCategory.matches,
    );
    if (!mounted || current != _searchGeneration || session != captured) return;
    final fresh = _deepSearch.cached(captured, stack.last.$1);
    if (fresh != null) setState(() => items = List.of(fresh));
  }

  Future<void> _refresh({bool preserveSelection = false}) async {
    if (_searchResults && _includeSubfolders) {
      await _startSearch(refresh: true);
    } else if (!widget.searchPage) {
      await _load(preserveSelection: preserveSelection);
    }
  }

  Future<void> _locate(CloudFile file) async {
    final hit = _hit(file);
    if (hit == null) return;
    final current = _searchGeneration;
    _deepSearch.stop();
    await Navigator.push<void>(
      context,
      MaterialPageRoute(
        builder: (_) => BrowserPage(
          widget.services,
          session,
          initialTrail: hit.trail,
          poolPreview: widget.poolPreview,
          highlightedFileId: file.id,
          popAtInitialDirectory: widget.searchPage,
        ),
      ),
    );
    if (!mounted) return;
    // Re-read on return: the opened directory may have changed the file.
    _deepSearch.clearCache();
    if (_searchResults && current == _searchGeneration) await _refresh();
  }

  void _checkAccount() {
    widget.services.control.checkCloud(session.platform);
    require(
      accountRevision ==
          widget.services.cloud.sessionCredential(session)?.updatedAt,
      '账号已变化，请重新打开文件列表',
    );
  }

  Credential? get _thumbnailCredential {
    final current = widget.services.cloud.sessionCredential(session);
    return current?.updatedAt == accountRevision ? current : null;
  }

  Future<void> _load({bool preserveSelection = false}) async {
    final previousSelection = preserveSelection
        ? Set<String>.of(selected)
        : <String>{};
    _resetSearch(clearCache: true);
    request?.cancel();
    final current = ++generation,
        scope = request = RequestScope(),
        parent = stack.last.$1;
    setState(() {
      loading = !preserveSelection;
      error = '';
      if (!preserveSelection) {
        selected.clear();
        _selectionMode = false;
      }
    });
    try {
      _checkAccount();
      final files = await scope.run(
        () => _progress.run(() => widget.services.cloud.list(session, parent)),
      );
      _checkAccount();
      if (!mounted || current != generation) return;
      _progress.close();
      setState(() {
        items = files;
        _timeReference = widget.services.clock();
        _deepSearch.remember(session, parent, files);
        if (highlight != null) {
          final target = files
              .where((file) => file.id == highlight)
              .firstOrNull;
          search.text = target?.name ?? '';
          if (target == null) highlight = null;
        }
        loading = false;
        if (preserveSelection) {
          selected.addAll(
            previousSelection.where((id) => files.any((file) => file.id == id)),
          );
          _selectionMode = selected.isNotEmpty;
        }
      });
    } catch (e) {
      if (!mounted || current != generation) return;
      _progress.close();
      setState(() {
        loading = false;
        error = errorText(e);
        items = [];
      });
      if (e is ParserPasswordRequired) {
        final grant = await showParserPasswordDialog(
          context,
          widget.services.parserRules,
          e.siteId,
          resolveUcPassword:
              widget.services.cloud.publicPasswords.fromUcCommand,
        );
        if (grant != null && mounted && current == generation) {
          _setParserPasswordGrant(grant);
          await _load(preserveSelection: preserveSelection);
        }
      }
    }
  }

  void _enter(CloudFile file) {
    if (!allowCloudAction(context, widget.services.control, session.platform)) {
      return;
    }
    if (widget.searchPage) {
      unawaited(_openSearchDirectory(file));
      return;
    }
    final trail = List<(String, String)>.of(_trailFor(file));
    stack
      ..clear()
      ..addAll(trail)
      ..add((widget.services.cloud.directoryId(session, file), file.name));
    highlight = null;
    search.clear();
    _load();
  }

  List<CloudFile> get displayed {
    final display = _display,
        sort = display.sort,
        ascending = display.ascending;
    final query = _includeSubfolders && !_searchResults
        ? ''
        : search.text.trim().toLowerCase();
    final result = _sourceItems
        .where(
          (f) =>
              f.name.toLowerCase().contains(query) &&
              (!widget.picking ||
                  f.isDirectory &&
                      !widget.excludedFolders.contains(
                        widget.services.cloud.directoryId(session, f),
                      )),
        )
        .toList();
    final dates = sort == 'date'
        ? {
            for (final file in result)
              file: cloudFileSortDate(
                file.modifiedAt,
                reference: _timeReference,
              ),
          }
        : <CloudFile, DateTime?>{};
    final names = sort == 'size'
        ? <CloudFile, NaturalName>{}
        : {
            for (final file in result)
              file: _nameKeys[file] ??= NaturalName(file.name),
          };
    final positions = {for (final (index, file) in result.indexed) file: index};
    result.sort((a, b) {
      if (a.isDirectory != b.isDirectory) return a.isDirectory ? -1 : 1;
      if (sort == 'date' && (dates[a] == null) != (dates[b] == null)) {
        return dates[a] == null ? 1 : -1;
      }
      final order = switch (sort) {
        'size' => a.size.compareTo(b.size),
        'date' =>
          dates[a]?.compareTo(dates[b]!) ?? names[a]!.compareTo(names[b]!),
        _ => names[a]!.compareTo(names[b]!),
      };
      // Keep equivalent names (e.g. 第1集 and 第01集) in their source order.
      if (order == 0) return positions[a]!.compareTo(positions[b]!);
      return ascending ? order : -order;
    });
    return result;
  }

  Future<void> _download(List<CloudFile> files) async {
    if (PublicShareRoute.uses(session)) {
      final ready = await withParserPassword<bool>(
        context,
        widget.services.parserRules,
        (_) async {
          await widget.services.cloud.ensureParserPassword(session);
          return true;
        },
        initialGrant: session.meta('parserPasswordGrant'),
        onGranted: _setParserPasswordGrant,
        label: '正在准备解析密码…',
        resolveUcPassword: widget.services.cloud.publicPasswords.fromUcCommand,
      );
      if (ready != true || !mounted) return;
    }
    if (_searchResults) {
      final directories = files
          .where((file) => file.isDirectory)
          .map((file) => widget.services.cloud.directoryId(session, file))
          .toSet();
      files = files
          .where(
            (file) =>
                !(_hit(
                      file,
                    )?.trail.any((entry) => directories.contains(entry.$1)) ??
                    false),
          )
          .toList();
    }
    if (files.any((file) => !_provider.canDownloadFile(session, file))) {
      message(context, '请进入代码目录或发布附件列表选择下载，也可下载仓库源码 ZIP');
      return;
    }
    if (!await confirmBaiduDownload(
          context,
          widget.services,
          session.platform,
          session: session,
        ) ||
        !mounted) {
      return;
    }
    final added = await busy<int>(context, () async {
      _checkAccount();
      final collected = await widget.services.cloud.collect(session, files);
      _checkAccount();
      if (collected.isEmpty) return 0;
      final specs = <DownloadSpec>[];
      for (final item in collected) {
        if (specs.isNotEmpty && specs.length % 128 == 0) {
          await RequestScope.wait(Duration.zero);
          _checkAccount();
        }
        specs.add(
          widget.services.cloud
              .planDownload(session, item.$1)
              .copyWith(relativePath: item.$2),
        );
      }
      final ids = await widget.services.downloads.enqueueAll(specs);
      return ids.length;
    }, label: '正在添加下载任务…');
    if (mounted && added != null && added > 0) {
      _finishSelection();
      message(
        context,
        '已添加 $added 个下载任务',
        onTap: widget.services.requestDownloadManager,
      );
    }
  }

  Future<String?> _destination(List<CloudFile> files) async {
    _pickedDestination = null;
    final personal = await busy(
      context,
      () => session.platform == CloudPlatform.github
          ? Future.value(
              BrowseSession(
                platform: session.platform,
                mode: session.mode,
                title:
                    '${GitHubLocation.parse(files.first.id).repository} · ${GitHubLocation.parse(files.first.id).ref}',
                rootId: GitHubLocation.parse(
                  files.first.id,
                ).copy(kind: GitHubNodeKind.code, path: '').id,
                metadata: session.metadata,
              ),
            )
          : session.mode == BrowseMode.personal
          ? widget.services.cloud.reopenSpace(session)
          : widget.services.cloud.personal(
              session.platform,
              accountId: session.accountId,
            ),
      label: '读取目标目录…',
    );
    if (personal == null || !mounted) return null;
    return Navigator.push<String>(
      context,
      MaterialPageRoute(
        builder: (_) => BrowserPage(
          widget.services,
          personal,
          picking: true,
          onDestinationPicked: (target, trail) {
            _pickedDestination = (target, List.of(trail));
          },
          excludedFolders: session.mode == BrowseMode.personal
              ? files
                    .where((f) => f.isDirectory)
                    .map((f) => widget.services.cloud.directoryId(session, f))
                    .toSet()
              : {},
        ),
      ),
    );
  }

  Future<void> _operate(String action, List<CloudFile> files) async {
    if (files.isEmpty) return;
    if (!allowCloudAction(context, widget.services.control, session.platform)) {
      return;
    }
    _deepSearch.stop();
    final connector = widget.services.cloud.connector(session.platform);
    if (action == 'locate') {
      await _locate(files.first);
      return;
    }
    final allowed = switch (action) {
      'rename' => files.every((f) => connector.canRenameFile(session, f)),
      'delete' => files.every((f) => connector.canDeleteFile(session, f)),
      'move' => files.every((f) => connector.canMoveFile(session, f)),
      _ => true,
    };
    if (!allowed) {
      message(context, '当前项目只读，请选择可管理的文件');
      return;
    }
    if (action == 'favorite') {
      final saved = await busy(context, () async {
        _checkAccount();
        return widget.services.favorites.toggle(
          session,
          files.first,
          _trailFor(files.first),
        );
      });
      if (mounted && saved != null) {
        setState(() {});
        message(context, saved ? '已添加到网盘收藏' : '已取消收藏');
      }
      return;
    }
    if (action == 'download') {
      await _download(files);
      return;
    }
    if (action == 'uc-playable') {
      _checkAccount();
      await downloadUcPlayable(
        context,
        widget.services,
        session: session,
        file: files.single,
      );
      return;
    }
    if (action == 'preview') {
      _checkAccount();
      _deepSearch.stop();
      await Navigator.push<void>(
        context,
        MaterialPageRoute(
          builder: (_) => PreviewPage(
            widget.services,
            session,
            files.first,
            poolPreview: widget.poolPreview,
            sourceFolders: _trailFor(
              files.first,
            ).skip(1).map((part) => part.$2).toList(),
            playlist: displayed,
            parentFolders: {
              for (final file in {...displayed, files.first})
                file.id: _trailFor(file).last.$1,
            },
          ),
        ),
      );
      return;
    }
    if (action == 'copy') {
      await busy(context, () async {
        _checkAccount();
        final spec = await widget.services.cloud.prepare(session, files.first);
        await widget.services.copyText(spec.url);
        await widget.services.cleanups.release(spec.cleanup);
        // Copied temporary links stay valid until the next application start.
        if (mounted) message(context, '下载链接已复制；临时链接请及时使用');
      });
      return;
    }
    String? target, name;
    ShareOptions? options;
    if (action == 'rename') {
      name = await askText(context, '重命名', initial: files.first.name);
      if (name == null || name.trim().isEmpty || !mounted) return;
    }
    if (action == 'move' || action == 'save') {
      target = await _destination(files);
      if (target == null || !mounted) return;
    }
    if (action == 'delete') {
      if (!await confirm(
            context,
            session.platform == CloudPlatform.github
                ? '删除 GitHub 文件'
                : '删除网盘文件',
            '${session.platform == CloudPlatform.github ? '代码文件会从当前分支删除；发布附件会被永久删除。\n' : ''}确认删除选中的 ${files.length} 项？\n${files.take(3).map((f) => f.name).join('\n')}',
            action: '删除',
            destructive: true,
          ) ||
          !mounted) {
        return;
      }
    }
    if (action == 'share') {
      options = await showDialog<ShareOptions>(
        context: context,
        builder: (_) => _ShareOptionsDialog(files, session.platform),
      );
      if (options == null || !mounted) return;
    }
    final result = await busy<Object>(
      context,
      () => widget.services.cloud.withSession(session, () async {
        _checkAccount();
        final c = widget.services.cloud.credential(session.platform);
        switch (action) {
          case 'rename':
            require(
              name!.trim().isNotEmpty &&
                  !RegExp(r'[/\\\x00-\x1f]').hasMatch(name),
              '文件名不能包含路径分隔符',
            );
            await connector.rename(session, files.first, name.trim(), c);
          case 'move':
            await connector.move(session, files, target!, c);
          case 'delete':
            await connector.delete(session, files, c);
          case 'save':
            await OperationProgress.step(
              OperationStage.transfer,
              () => widget.services.cloud.saveShare(session, files, target!),
            );
          case 'share':
            return connector.createShare(session, files, options!, c);
        }
        return true;
      }),
    );
    if (!mounted) return;
    if (result is ShareCreation) {
      await showDialog<void>(
        context: context,
        builder: (context) => AlertDialog(
          title: const Text('分享已创建'),
          content: SelectableText(result.text),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('关闭'),
            ),
            TextButton(
              onPressed: () async {
                await widget.services.copyText(result.text);
                if (context.mounted) Navigator.pop(context);
              },
              child: const Text('复制分享'),
            ),
          ],
        ),
      );
    } else if (result == true) {
      final destination = _pickedDestination;
      if (action == 'save' &&
          AliyunShareLink.isFastTransfer(session) &&
          destination != null) {
        message(context, '快传转存完成，可在目标目录中浏览和下载');
        await Navigator.push<void>(
          context,
          MaterialPageRoute(
            builder: (_) => BrowserPage(
              widget.services,
              destination.$1,
              initialTrail: destination.$2,
              popAtInitialDirectory: true,
            ),
          ),
        );
        return;
      }
      message(context, action == 'save' ? '转存完成' : '操作完成');
      await _refresh();
    }
  }

  Future<void> _menu(CloudFile file) async {
    final action = await showModalBottomSheet<String>(
      context: context,
      showDragHandle: true,
      builder: (context) => SafeArea(
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              ListTile(
                leading: FileGlyph(file.name, directory: file.isDirectory),
                title: Text(file.name, maxLines: 2),
                subtitle: _fileMetadata(file),
              ),
              if (_hit(file) != null)
                ListTile(
                  leading: const Icon(CupertinoIcons.folder),
                  title: const Text('打开所在文件夹'),
                  onTap: () => Navigator.pop(context, 'locate'),
                ),
              if (!file.isDirectory)
                ListTile(
                  leading: const Icon(CupertinoIcons.eye),
                  title: const Text('预览 / 文件详情'),
                  onTap: () => Navigator.pop(context, 'preview'),
                ),
              ListTile(
                leading: Icon(
                  widget.services.favorites.contains(session, file)
                      ? CupertinoIcons.star_fill
                      : CupertinoIcons.star,
                  color: const Color(0xffe6a23c),
                ),
                title: Text(
                  widget.services.favorites.contains(session, file)
                      ? '取消收藏'
                      : '收藏',
                ),
                onTap: () => Navigator.pop(context, 'favorite'),
              ),
              if (_provider.canDownloadFile(session, file))
                ListTile(
                  leading: const Icon(CupertinoIcons.arrow_down_circle),
                  title: const Text('下载'),
                  onTap: () => Navigator.pop(context, 'download'),
                ),
              if (canDownloadUcPlayable(session, file))
                ListTile(
                  leading: const Icon(CupertinoIcons.film),
                  title: const Text('下载可播放版本'),
                  subtitle: const Text('先查看画质和大小，再确认下载'),
                  onTap: () => Navigator.pop(context, 'uc-playable'),
                ),
              if (!file.isDirectory)
                ListTile(
                  leading: const Icon(CupertinoIcons.link),
                  title: const Text('复制下载链接'),
                  onTap: () => Navigator.pop(context, 'copy'),
                ),
              if (session.mode == BrowseMode.share &&
                  session.platform != CloudPlatform.lanzou &&
                  session.platform != CloudPlatform.ctfile &&
                  session.platform.requiresAccount &&
                  session.platform.supportsSharing)
                ListTile(
                  leading: const Icon(CupertinoIcons.folder_badge_plus),
                  title: const Text('转存到我的网盘'),
                  onTap: () => Navigator.pop(context, 'save'),
                )
              else if (session.canManageFiles) ...[
                if (_provider.canRenameFile(session, file))
                  ListTile(
                    leading: const Icon(CupertinoIcons.pencil),
                    title: const Text('重命名'),
                    onTap: () => Navigator.pop(context, 'rename'),
                  ),
                if (_provider.canMoveFile(session, file))
                  ListTile(
                    leading: const Icon(CupertinoIcons.folder),
                    title: const Text('移动'),
                    onTap: () => Navigator.pop(context, 'move'),
                  ),
                if (session.platform.supportsSharing)
                  ListTile(
                    leading: const Icon(CupertinoIcons.share),
                    title: const Text('创建分享'),
                    onTap: () => Navigator.pop(context, 'share'),
                  ),
                if (_provider.canDeleteFile(session, file))
                  ListTile(
                    leading: const Icon(
                      CupertinoIcons.trash,
                      color: Colors.red,
                    ),
                    title: const Text(
                      '删除',
                      style: TextStyle(color: Colors.red),
                    ),
                    onTap: () => Navigator.pop(context, 'delete'),
                  ),
              ],
            ],
          ),
        ),
      ),
    );
    if (action != null && mounted) await _operate(action, [file]);
  }

  List<CloudFile> _contextFiles(CloudFile file) =>
      selected.contains(_fileKey(file)) && selected.length > 1
      ? _sourceItems.where((f) => selected.contains(_fileKey(f))).toList()
      : [file];

  List<AppMenuAction<String>> _fileContextActions(CloudFile file) {
    if (loading ||
        changingAccount ||
        !_available ||
        !_sourceItems.any((f) => _fileKey(f) == _fileKey(file))) {
      return [];
    }
    final files = _contextFiles(file);
    final single = files.length == 1;
    final count = single ? '' : '（${files.length} 项）';
    final canSave =
        session.mode == BrowseMode.share &&
        session.platform != CloudPlatform.lanzou &&
        session.platform != CloudPlatform.ctfile &&
        session.platform.requiresAccount &&
        session.platform.supportsSharing;
    return [
      if (single && file.isDirectory)
        const AppMenuAction(
          value: 'open',
          label: '打开文件夹',
          icon: CupertinoIcons.folder_open,
        ),
      if (single && !file.isDirectory)
        const AppMenuAction(
          value: 'preview',
          label: '预览 / 文件详情',
          icon: CupertinoIcons.eye,
        ),
      if (single && _hit(file) != null)
        const AppMenuAction(
          value: 'locate',
          label: '打开所在文件夹',
          icon: CupertinoIcons.folder,
        ),
      if (files.every((f) => _provider.canDownloadFile(session, f)))
        AppMenuAction(
          value: 'download',
          label: '下载$count',
          icon: CupertinoIcons.arrow_down_circle,
        ),
      if (single && canDownloadUcPlayable(session, file))
        const AppMenuAction(
          value: 'uc-playable',
          label: '下载可播放版本',
          icon: CupertinoIcons.film,
        ),
      if (single && !file.isDirectory)
        const AppMenuAction(
          value: 'copy',
          label: '复制下载链接',
          icon: CupertinoIcons.link,
        ),
      if (single) ...[
        const AppMenuAction(
          value: 'copy-name',
          label: '复制文件名',
          icon: CupertinoIcons.doc_on_doc,
        ),
        AppMenuAction(
          value: 'favorite',
          label: widget.services.favorites.contains(session, file)
              ? '取消收藏'
              : '收藏',
          icon: CupertinoIcons.star,
        ),
      ],
      if (canSave)
        AppMenuAction(
          value: 'save',
          label: '转存到我的网盘$count',
          icon: CupertinoIcons.folder_badge_plus,
        )
      else if (session.canManageFiles) ...[
        if (single && _provider.canRenameFile(session, file))
          const AppMenuAction(
            value: 'rename',
            label: '重命名',
            icon: CupertinoIcons.pencil,
          ),
        if (files.every((f) => _provider.canMoveFile(session, f)))
          AppMenuAction(
            value: 'move',
            label: '移动$count',
            icon: CupertinoIcons.folder,
          ),
        if (session.platform.supportsSharing)
          AppMenuAction(
            value: 'share',
            label: '创建分享$count',
            icon: CupertinoIcons.share,
          ),
        if (files.every((f) => _provider.canDeleteFile(session, f)))
          AppMenuAction(
            value: 'delete',
            label: '删除$count',
            icon: CupertinoIcons.trash,
            destructive: true,
          ),
      ],
      AppMenuAction(
        value: 'select',
        label: selected.contains(_fileKey(file)) ? '取消选择此项' : '选择此项',
        icon: CupertinoIcons.checkmark_circle,
      ),
      if (_selecting)
        const AppMenuAction(
          value: 'clear-selection',
          label: '退出多选',
          icon: CupertinoIcons.xmark_circle,
        ),
    ];
  }

  Future<void> _fileContextAction(CloudFile file, String action) async {
    switch (action) {
      case 'open':
        if (AliyunShareLink.isFastTransfer(session)) {
          await _operate('save', items);
        } else {
          _enter(file);
        }
      case 'copy-name':
        await widget.services.copyText(file.name);
        if (mounted) message(context, '文件名已复制');
      case 'select':
        _toggle(file);
      case 'clear-selection':
        _finishSelection();
      default:
        await _operate(action, _contextFiles(file));
    }
  }

  Object _fileContextIdentity(CloudFile file) => (
    session,
    accountRevision,
    stack.last.$1,
    _fileKey(file),
    selected.contains(_fileKey(file))
        ? (selected.toList()..sort()).join('\u0000')
        : '',
  );

  Widget _folderContextMenu(Widget child) => AppContextMenu<String>(
    enabled: !widget.picking && !loading && !changingAccount,
    identity: (session, accountRevision, stack.last.$1),
    actions: () => [
      const AppMenuAction(
        value: 'refresh',
        label: '刷新',
        icon: CupertinoIcons.refresh,
      ),
      if (!widget.searchPage && !_searchResults && _available) ...[
        if (_canUpload)
          AppMenuAction(
            value: 'upload',
            label: '上传文件',
            icon: CupertinoIcons.arrow_up_doc,
            enabled: !pickingUpload,
          ),
        if (_canCreateFolder)
          const AppMenuAction(
            value: 'new-folder',
            label: '新建文件夹',
            icon: CupertinoIcons.folder_badge_plus,
          ),
      ],
      if (displayed.isNotEmpty)
        AppMenuAction(
          value: 'select-all',
          label: _allVisibleSelected(displayed) ? '取消全选' : '全选',
          icon: CupertinoIcons.checkmark_circle,
        ),
      if (_selecting)
        const AppMenuAction(
          value: 'clear-selection',
          label: '退出多选',
          icon: CupertinoIcons.xmark_circle,
        ),
    ],
    onSelected: (action) async {
      switch (action) {
        case 'refresh':
          await _refresh();
        case 'upload':
          await _upload();
        case 'new-folder':
          await _newFolder();
        case 'select-all':
          _toggleAllVisible(displayed);
        case 'clear-selection':
          _finishSelection();
      }
    },
    child: child,
  );

  Future<void> _newFolder() async {
    if (!allowCloudAction(context, widget.services.control, session.platform)) {
      return;
    }
    if (!_canCreateFolder) return;
    final name = await askText(
      context,
      '新建文件夹',
      hint: session.platform == CloudPlatform.github
          ? '文件夹名称（保留 .gitkeep 占位文件）'
          : '文件夹名称',
    );
    if (name == null || name.trim().isEmpty || !mounted) return;
    final result = await busy(context, () async {
      _checkAccount();
      return widget.services.cloud.createFolder(
        session,
        stack.last.$1,
        name.trim(),
      );
    });
    if (result != null && mounted) await _refresh();
  }

  Future<List<XFile>> _droppedUploadFiles(List<XFile> dropped) async {
    final paths = <String>{}, files = <XFile>[];
    for (final file in dropped) {
      require(file.path.isNotEmpty && p.isAbsolute(file.path), '请从资源管理器拖入本地文件');
      final type = await FileSystemEntity.type(file.path);
      require(type != FileSystemEntityType.directory, '暂不支持拖拽文件夹，请选择文件夹内的文件');
      require(type == FileSystemEntityType.file, '无法读取拖入的文件，请检查文件是否存在及访问权限');
      if (paths.add(p.normalize(file.path).toLowerCase())) files.add(file);
    }
    return files;
  }

  Future<void> _upload({List<XFile>? droppedFiles}) async {
    if (droppedFiles != null &&
        (!_canDropUpload || !(ModalRoute.isCurrentOf(context) ?? true))) {
      return;
    }
    if (pickingUpload || !_canUpload) return;
    if (!allowCloudAction(context, widget.services.control, session.platform)) {
      return;
    }
    final (parent, folderName) = stack.last;
    final activeSession = session;
    final revision = accountRevision;
    final source = droppedFiles == null ? 'pick' : 'drop';
    setState(() => pickingUpload = true);
    try {
      _checkAccount();
      DiagnosticLog.event(
        'upload.$source.start',
        fields: {'platform': activeSession.platform.key},
      );
      final List<XFile>? files;
      if (droppedFiles != null) {
        files = await _droppedUploadFiles(droppedFiles);
      } else {
        files = await busy(context, () async {
          try {
            return await openFiles();
          } catch (error, stack) {
            DiagnosticLog.error(
              'upload.pick.failed',
              error,
              stack,
              fields: {'platform': activeSession.platform.key},
            );
            throw const AppException('无法读取所选文件，请重新选择，并检查文件权限和可用空间');
          }
        }, label: '正在读取所选文件…');
      }
      if (!mounted || files == null || files.isEmpty) return;
      DiagnosticLog.event(
        'upload.$source.ready',
        fields: {'platform': activeSession.platform.key, 'count': files.length},
      );
      if (!identical(session, activeSession) || accountRevision != revision) {
        throw const AppException('账号或网盘已变化，请重新选择上传文件');
      }
      _checkAccount();
      final ids = await widget.services.uploads.enqueue(
        activeSession,
        parent,
        folderName,
        files,
      );
      if (mounted && ids.isNotEmpty) {
        message(
          context,
          '已添加 ${ids.length} 个上传任务，可离开页面 · 查看',
          onTap: widget.services.requestUploadManager,
        );
      }
    } catch (error) {
      if (mounted) message(context, errorText(error));
    } finally {
      if (mounted) setState(() => pickingUpload = false);
    }
  }

  Future<void> _accountAction(String action, {String? sourceAccountId}) async {
    if (changingAccount) return;
    final owner =
        sourceAccountId ??
        session.accountId ??
        widget.services.vault.activeAccountId(session.platform);
    if (action == 'info') {
      await openCloudAccountInfo(
        context,
        widget.services.vault,
        session.platform,
        owner,
      );
      return;
    }
    if (action == 'copyLogin') {
      await copyCloudAccountLoginInfo(
        context,
        widget.services.vault,
        session.platform,
        owner,
      );
      return;
    }
    if (action == 'accounts') {
      await Navigator.push<void>(
        context,
        MaterialPageRoute(
          builder: (_) =>
              CloudAccountsPage(widget.services, platform: session.platform),
        ),
      );
      return;
    }
    if (!allowCloudAction(context, widget.services.control, session.platform)) {
      return;
    }
    setState(() => changingAccount = true);
    try {
      if (action == 'login') {
        await _login();
      } else if (action == 'add') {
        final before = widget.services.vault.activeAccountId(session.platform);
        await openLogin(
          context,
          widget.services,
          session.platform,
          addAccount: true,
        );
        if (!mounted) return;
        final owner = widget.services.vault.activeAccountId(session.platform);
        if (owner != null && owner != before) await _switchAccount(owner);
      } else if (action.startsWith('account:')) {
        final owner = action.substring('account:'.length);
        if (owner != session.accountId ||
            widget.services.vault
                    .credentialFor(session.platform, owner)
                    ?.updatedAt !=
                accountRevision) {
          await _switchAccount(owner);
        }
      }
    } finally {
      if (mounted) setState(() => changingAccount = false);
    }
  }

  Widget _accountMenu() => AnimatedBuilder(
    animation: widget.services.store,
    builder: (context, _) {
      final vault = widget.services.vault;
      final owner =
          session.accountId ?? vault.activeAccountId(session.platform);
      final credential = vault.credentialFor(session.platform, owner);
      final info = savedAccountLoginInfo(vault, session.platform, owner);
      return IgnorePointer(
        ignoring: changingAccount,
        child: AppPopupMenuButton<String>(
          key: const Key('browser-account-menu'),
          tooltip: '切换或更新账号',
          label: '账号',
          icon: CupertinoIcons.person_crop_circle,
          onSelected: (action) =>
              _accountAction(action, sourceAccountId: owner),
          actions: [
            const AppMenuAction(
              value: 'info',
              label: '账号配置',
              icon: CupertinoIcons.slider_horizontal_3,
            ),
            if (credential != null)
              AppMenuAction(
                value: 'copyLogin',
                label: info.copyLabel,
                icon: CupertinoIcons.doc_on_doc,
              ),
            for (final account in vault.profiles(session.platform))
              AppMenuAction(
                value: 'account:${account.id}',
                label: account.name,
                icon: CupertinoIcons.person,
                selected: account.id == session.accountId,
              ),
            const AppMenuAction(
              value: 'login',
              label: '更新当前账号',
              icon: CupertinoIcons.arrow_clockwise,
            ),
            const AppMenuAction(
              value: 'add',
              label: '添加账号',
              icon: CupertinoIcons.person_badge_plus,
            ),
            const AppMenuAction(
              value: 'accounts',
              label: '多账号管理',
              icon: CupertinoIcons.person_2,
            ),
          ],
        ),
      );
    },
  );

  Future<(BrowseSession, List<CloudFile>, int?)> _readAccountSession(
    String owner, {
    bool keepSpace = false,
  }) async {
    final previous = session.withAccount(owner);
    final value = await widget.services.cloud.withSession(previous, () async {
      if (previous.mode == BrowseMode.share) {
        final link = previous.sourceLink;
        require(link != null, '原分享信息缺失，请返回首页重新解析');
        return widget.services.cloud.share(
          link!,
          baiduRoute: BaiduShareRoute.fromSession(previous),
          parserSiteId: previous.meta('parserSiteId').isEmpty
              ? null
              : previous.meta('parserSiteId'),
          parserPasswordGrant: previous.meta('parserPasswordGrant'),
        );
      }
      return keepSpace
          ? widget.services.cloud.reopenSpace(previous)
          : widget.services.cloud.personal(previous.platform, accountId: owner);
    });
    final files = await widget.services.cloud.list(value, value.rootId);
    RequestScope.checkpoint();
    return (
      value,
      files,
      widget.services.cloud.sessionCredential(value)?.updatedAt,
    );
  }

  Future<void> _switchAccount(String owner) async {
    final previous = session;
    final result = await busy(
      context,
      () => _readAccountSession(owner, keepSpace: owner == session.accountId),
      label: '正在切换账号…',
    );
    if (result == null || !mounted || session != previous) return;
    if (widget.services.cloud.sessionCredential(result.$1)?.updatedAt !=
        result.$3) {
      message(context, '账号信息已变化，请重新切换');
      return;
    }
    try {
      await widget.services.switchCloudAccount(session.platform, owner);
      if (!mounted) return;
      await _replaceSession(result.$1, initialItems: result.$2);
    } catch (error) {
      if (mounted) message(context, errorText(error));
    }
  }

  Future<void> _switchBaiduRoute(
    BaiduShareRoute route, {
    String? parserSiteId,
  }) async {
    if (changingAccount ||
        (route == BaiduShareRoute.publicParser) ==
                PublicShareRoute.uses(session) &&
            (parserSiteId == null ||
                parserSiteId == session.meta('parserSiteId'))) {
      return;
    }
    setState(() => changingAccount = true);
    try {
      if (route == BaiduShareRoute.publicParser) {
        widget.services.parserRules.checkPublicParsing(session.platform);
      }
      if (route == BaiduShareRoute.account &&
          (session.platform == CloudPlatform.baidu ||
              session.platform.shareRequiresAccount) &&
          widget.services.cloud.sessionCredential(session) == null) {
        await _login();
        if (!mounted ||
            widget.services.cloud.sessionCredential(session) == null) {
          return;
        }
      }
      final previous = session, link = session.sourceLink;
      if (link == null || !mounted) return;
      if (route == BaiduShareRoute.publicParser && parserSiteId == null) {
        parserSiteId = (await widget.services.parserRules.forNewShare(
          platform: session.platform,
        ))?.id;
      }
      if (!mounted) return;
      final result = await withParserPassword<(BrowseSession, List<CloudFile>)>(
        context,
        widget.services.parserRules,
        (grant) => widget.services.cloud.withSession(previous, () async {
          _checkAccount();
          final next = await widget.services.cloud.share(
            link,
            baiduRoute: route,
            parserSiteId: parserSiteId,
            parserPasswordGrant: grant,
          );
          final files = await widget.services.cloud.list(next, next.rootId);
          _checkAccount();
          return (next, files);
        }),
        label: '正在切换解析方式…',
        resolveUcPassword: widget.services.cloud.publicPasswords.fromUcCommand,
      );
      if (result != null && mounted && session == previous) {
        if (session.platform != CloudPlatform.baidu) {
          await widget.services.parserRules.preferPublic(
            session.platform,
            route == BaiduShareRoute.publicParser,
          );
          if (!mounted) return;
        }
        await _replaceSession(result.$1, initialItems: result.$2);
      }
    } catch (error) {
      if (mounted) message(context, errorText(error));
    } finally {
      if (mounted) setState(() => changingAccount = false);
    }
  }

  void _setParserPasswordGrant(String grant) {
    setState(
      () => session = BrowseSession(
        platform: session.platform,
        mode: session.mode,
        title: session.title,
        rootId: session.rootId,
        sourceLink: session.sourceLink,
        metadata: {...session.metadata, 'parserPasswordGrant': grant},
      ),
    );
  }

  Future<void> _login() async {
    final before = widget.services.cloud.sessionCredential(session)?.updatedAt;
    await openLogin(
      context,
      widget.services,
      session.platform,
      accountId: session.accountId?.isNotEmpty == true
          ? session.accountId
          : null,
    );
    if (!mounted) return;
    final owner = session.accountId?.isNotEmpty == true
        ? session.accountId!
        : widget.services.vault.activeAccountId(session.platform);
    if (owner == null ||
        widget.services.vault
                .credentialFor(session.platform, owner)
                ?.updatedAt ==
            before) {
      return;
    }
    final result = await busy(
      context,
      () => _readAccountSession(owner, keepSpace: true),
      label: '正在更新账号并读取文件…',
    );
    if (result != null && mounted) {
      await _replaceSession(result.$1, initialItems: result.$2);
    }
  }

  Future<void> _replaceSession(
    BrowseSession value, {
    List<CloudFile>? initialItems,
  }) async {
    _resetSearch(clearCache: true);
    request?.cancel();
    generation++;
    setState(() {
      session = value;
      accountRevision = widget.services.cloud
          .sessionCredential(value)
          ?.updatedAt;
      highlight = null;
      stack
        ..clear()
        ..add((session.rootId, '全部文件'));
      search.clear();
      items = List.of(initialItems ?? const []);
      selected.clear();
      _selectionMode = false;
      error = '';
      loading = initialItems == null;
      if (initialItems != null) {
        _deepSearch.remember(session, stack.last.$1, items);
      }
    });
    if (initialItems == null) await _load();
  }

  Future<void> _switchPersonal() async {
    if (!session.isFamily) return;
    final value = await busy(context, () async {
      _checkAccount();
      return widget.services.cloud.personal(
        session.platform,
        accountId: session.accountId,
      );
    }, label: '正在切换个人网盘…');
    if (value != null && mounted) await _replaceSession(value);
  }

  Future<void> _chooseFamily() async {
    final spaces = await busy(context, () async {
      _checkAccount();
      return widget.services.cloud.familySpaces(
        session.platform,
        accountId: session.accountId,
      );
    }, label: '正在读取家庭云…');
    if (spaces == null || !mounted) return;
    if (spaces.isEmpty) {
      message(context, '当前账号还没有家庭云，请先在官方网盘创建或加入家庭');
      return;
    }
    final choice = await showModalBottomSheet<CloudSpace>(
      context: context,
      showDragHandle: true,
      isScrollControlled: true,
      builder: (context) => SafeArea(
        child: ConstrainedBox(
          constraints: BoxConstraints(
            maxHeight: MediaQuery.sizeOf(context).height * .7,
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Padding(
                padding: EdgeInsets.fromLTRB(20, 0, 20, 12),
                child: Text(
                  '选择家庭云',
                  style: TextStyle(fontSize: 17, fontWeight: FontWeight.w600),
                ),
              ),
              Flexible(
                child: ListView.builder(
                  shrinkWrap: true,
                  padding: const EdgeInsets.fromLTRB(12, 0, 12, 16),
                  itemCount: spaces.length,
                  itemBuilder: (context, index) {
                    final space = spaces[index],
                        active = session.familyId == space.id;
                    return ListTile(
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(12),
                      ),
                      selected: active,
                      selectedTileColor: themeAccent(
                        context,
                      ).withValues(alpha: .07),
                      leading: Icon(
                        CupertinoIcons.person_2,
                        color: themeAccent(context),
                      ),
                      title: Text(
                        space.name,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                      ),
                      trailing: active
                          ? Icon(
                              CupertinoIcons.checkmark,
                              color: themeAccent(context),
                              size: 18,
                            )
                          : null,
                      onTap: () => Navigator.pop(context, space),
                    );
                  },
                ),
              ),
            ],
          ),
        ),
      ),
    );
    if (choice == null || !mounted || choice.id == session.familyId) return;
    final value = await busy(context, () async {
      _checkAccount();
      return widget.services.cloud.family(
        session.platform,
        choice.id,
        accountId: session.accountId,
      );
    }, label: '正在切换家庭云…');
    if (value != null && mounted) await _replaceSession(value);
  }

  Future<void> _choosePersonalSpace() async {
    final previous = session;
    final spaces = await busy(context, () async {
      _checkAccount();
      return widget.services.cloud.personalSpaces(
        session.platform,
        accountId: session.accountId,
      );
    }, label: '正在读取存储空间…');
    if (spaces == null || !mounted || session != previous) return;
    final choice = await showModalBottomSheet<CloudSpace>(
      context: context,
      showDragHandle: true,
      builder: (context) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Padding(
              padding: EdgeInsets.all(16),
              child: Text(
                '选择存储空间',
                style: TextStyle(fontSize: 17, fontWeight: FontWeight.w600),
              ),
            ),
            for (final space in spaces)
              ListTile(
                leading: Icon(
                  CupertinoIcons.cloud,
                  color: themeAccent(context),
                ),
                title: Text(space.name),
                selected: space.id == session.personalSpaceId,
                trailing: space.id == session.personalSpaceId
                    ? Icon(
                        CupertinoIcons.checkmark,
                        color: themeAccent(context),
                      )
                    : null,
                onTap: () => Navigator.pop(context, space),
              ),
            const SizedBox(height: 12),
          ],
        ),
      ),
    );
    if (choice == null ||
        !mounted ||
        session != previous ||
        choice.id == session.personalSpaceId) {
      return;
    }
    final value = await busy(context, () async {
      _checkAccount();
      return widget.services.cloud.personal(
        session.platform,
        accountId: session.accountId,
        spaceId: choice.id,
      );
    }, label: '正在切换存储空间…');
    if (value != null && mounted && session == previous) {
      await _replaceSession(value);
    }
  }

  Future<void> _changeView(String value) async {
    if (view == value) return;
    try {
      await widget.services.updateBrowserDisplay(session.platform, view: value);
    } catch (_) {
      if (mounted) message(context, '显示方式保存失败，请重试');
    }
  }

  Future<void> _changeSort(String value) async {
    try {
      await widget.services.updateBrowserDisplay(session.platform, sort: value);
    } catch (_) {
      if (mounted) message(context, '排序方式保存失败，请重试');
    }
  }

  Widget _spaceSelector() => Padding(
    padding: const EdgeInsets.fromLTRB(16, 8, 16, 4),
    child: Container(
      padding: const EdgeInsets.all(4),
      decoration: BoxDecoration(
        color: fill(context),
        borderRadius: BorderRadius.circular(12),
      ),
      child: Row(
        children: [
          for (final family in [false, true])
            Expanded(
              child: Tooltip(
                message: family ? '切换家庭云' : '切换个人网盘',
                child: TextButton(
                  key: ValueKey(family ? 'family-space' : 'personal-space'),
                  style: TextButton.styleFrom(
                    foregroundColor: family == session.isFamily
                        ? themeAccent(context)
                        : secondary(context),
                    backgroundColor: family == session.isFamily
                        ? Theme.of(context).colorScheme.surface
                        : Colors.transparent,
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(9),
                    ),
                    minimumSize: const Size(0, 40),
                    padding: const EdgeInsets.symmetric(
                      horizontal: 12,
                      vertical: 9,
                    ),
                  ),
                  onPressed: family ? _chooseFamily : _switchPersonal,
                  child: Row(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      if (MediaQuery.textScalerOf(context).scale(13) <= 18) ...[
                        Icon(
                          family
                              ? CupertinoIcons.person_2
                              : CupertinoIcons.person,
                          size: 17,
                        ),
                        const SizedBox(width: 8),
                      ],
                      Flexible(
                        child: Text(
                          family
                              ? session.isFamily
                                    ? session.meta('familyName').ifEmpty('家庭云')
                                    : '家庭云'
                              : '个人网盘',
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(
                            fontSize: 13,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                      ),
                      if (family) ...[
                        const SizedBox(width: 6),
                        const Icon(CupertinoIcons.chevron_down, size: 10),
                      ],
                    ],
                  ),
                ),
              ),
            ),
        ],
      ),
    ),
  );

  void _toggle(CloudFile file) => setState(() {
    _selectionMode = true;
    final key = _fileKey(file);
    if (!selected.add(key)) selected.remove(key);
  });

  void _finishSelection() => setState(() {
    selected.clear();
    _selectionMode = false;
  });

  bool _allVisibleSelected(List<CloudFile> files) =>
      files.isNotEmpty &&
      files.every((file) => selected.contains(_fileKey(file)));

  void _toggleAllVisible(List<CloudFile> files) => setState(() {
    _selectionMode = true;
    if (_allVisibleSelected(files)) {
      selected.removeAll(files.map(_fileKey));
    } else {
      selected.addAll(files.map(_fileKey));
    }
  });

  void _open(CloudFile file) {
    if (_selecting && !widget.picking) {
      _toggle(file);
    } else if (AliyunShareLink.isFastTransfer(session)) {
      _operate('save', items);
    } else if (file.isDirectory) {
      _enter(file);
    } else {
      _operate('preview', [file]);
    }
  }

  Widget _fileList(List<CloudFile> files, BoxConstraints constraints) {
    return _folderContextMenu(_fileListContent(files, constraints));
  }

  Widget _fileListContent(List<CloudFile> files, BoxConstraints constraints) {
    final key = ValueKey(
      '${session.platform.name}:${session.mode.name}:${session.familyId}:${session.personalSpaceId}:${stack.last.$1}:$view:${_searchResults ? _searchGeneration : 0}',
    );
    if (view == 'grid' && !widget.picking) {
      final columns = ((constraints.maxWidth - 20) / 180).round().clamp(1, 8);
      final width = (constraints.maxWidth - 32 - (columns - 1) * 12) / columns;
      final mediaHeight = (width - 16) * .72;
      final scaler = MediaQuery.textScalerOf(context);
      final titleHeight = scaler.scale(14) * 1.35 * 2;
      final timeHeight =
          files.any((file) => formatCloudFileTime(file.modifiedAt).isNotEmpty)
          ? scaler.scale(11) * 1.3 * 2 + 4
          : 0.0;
      return GridView.builder(
        key: key,
        physics: const AlwaysScrollableScrollPhysics(),
        padding: const EdgeInsets.fromLTRB(16, 2, 16, 20),
        gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
          crossAxisCount: columns,
          crossAxisSpacing: 12,
          mainAxisSpacing: 12,
          mainAxisExtent:
              mediaHeight +
              titleHeight +
              scaler.scale(11) * 1.3 +
              timeHeight +
              (_searchResults ? scaler.scale(11) * 1.3 * 2 + 4 : 0) +
              30,
        ),
        itemCount: files.length,
        itemBuilder: (context, index) => _gridCard(
          files[index],
          width,
          mediaHeight,
          titleHeight,
          constraints.maxWidth >= 750,
        ),
      );
    }
    return ListView.builder(
      key: key,
      physics: const AlwaysScrollableScrollPhysics(),
      itemCount: files.length,
      itemBuilder: (context, index) =>
          _listRow(files[index], constraints.maxWidth >= 750),
    );
  }

  Widget _listRow(CloudFile file, bool wide) {
    final checked = selected.contains(_fileKey(file));
    return AppContextMenu<String>(
      key: ValueKey('file-context-${_fileKey(file)}'),
      enabled: !widget.picking,
      identity: _fileContextIdentity(file),
      actions: () => _fileContextActions(file),
      onSelected: (action) => _fileContextAction(file, action),
      child: ListTile(
        key: ValueKey('browser-file-${_fileKey(file)}'),
        dense: true,
        minVerticalPadding: 11,
        selected: checked || file.id == highlight,
        selectedTileColor: themeAccent(context).withValues(alpha: .07),
        leading: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            if ((_selecting || wide) && !widget.picking)
              Checkbox(value: checked, onChanged: (_) => _toggle(file)),
            CloudThumbnail(
              file,
              session.platform,
              credential: _thumbnailCredential,
            ),
          ],
        ),
        title: widget.searchPage
            ? CloudSearchFileName(file.name, search.text)
            : Text(
                file.name,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(fontSize: 14),
              ),
        subtitle: _fileMetadata(file),
        trailing: widget.picking
            ? const Icon(CupertinoIcons.chevron_right, size: 14)
            : IconButton(
                tooltip: '${file.name}操作',
                icon: const Icon(CupertinoIcons.ellipsis, size: 20),
                onPressed: () => _menu(file),
              ),
        onLongPress: widget.picking ? null : () => _toggle(file),
        onTap: () => _open(file),
      ),
    );
  }

  Widget _gridCard(
    CloudFile file,
    double width,
    double mediaHeight,
    double titleHeight,
    bool wide,
  ) {
    final checked = selected.contains(_fileKey(file));
    final time = formatCloudFileTime(file.modifiedAt);
    return Semantics(
      key: ValueKey('browser-file-${_fileKey(file)}'),
      selected: checked,
      child: AppContextMenu<String>(
        identity: _fileContextIdentity(file),
        actions: () => _fileContextActions(file),
        onSelected: (action) => _fileContextAction(file, action),
        child: Material(
          color: checked || file.id == highlight
              ? themeAccent(context).withValues(alpha: .07)
              : Theme.of(context).colorScheme.surface,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(14),
            side: BorderSide(
              color: checked
                  ? themeAccent(context)
                  : border(context).withValues(alpha: .7),
            ),
          ),
          clipBehavior: Clip.antiAlias,
          child: InkWell(
            onTap: () => _open(file),
            onLongPress: () => _toggle(file),
            child: Padding(
              padding: const EdgeInsets.all(8),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Stack(
                    children: [
                      CloudThumbnail(
                        file,
                        session.platform,
                        credential: _thumbnailCredential,
                        width: width - 16,
                        height: mediaHeight,
                        large: true,
                      ),
                      if (wide || _selecting)
                        Positioned(
                          left: 2,
                          top: 2,
                          child: Material(
                            color: Theme.of(
                              context,
                            ).colorScheme.surface.withValues(alpha: .92),
                            borderRadius: BorderRadius.circular(8),
                            child: Checkbox(
                              value: checked,
                              visualDensity: VisualDensity.compact,
                              materialTapTargetSize:
                                  MaterialTapTargetSize.shrinkWrap,
                              onChanged: (_) => _toggle(file),
                            ),
                          ),
                        ),
                      Positioned(
                        right: 0,
                        top: 0,
                        child: IconButton(
                          tooltip: '${file.name}操作',
                          icon: Container(
                            width: 28,
                            height: 28,
                            decoration: BoxDecoration(
                              color: Theme.of(
                                context,
                              ).colorScheme.surface.withValues(alpha: .92),
                              borderRadius: BorderRadius.circular(8),
                            ),
                            child: const Icon(
                              CupertinoIcons.ellipsis,
                              size: 18,
                            ),
                          ),
                          onPressed: () => _menu(file),
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 8),
                  SizedBox(
                    height: titleHeight,
                    child: Text(
                      file.name,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(fontSize: 14, height: 1.35),
                    ),
                  ),
                  const SizedBox(height: 4),
                  Text(
                    file.isDirectory ? '文件夹' : formatBytes(file.size),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontSize: 11,
                      height: 1.3,
                      color: secondary(context),
                    ),
                  ),
                  if (time.isNotEmpty) ...[
                    const SizedBox(height: 4),
                    Text(
                      time,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontSize: 11,
                        height: 1.3,
                        color: secondary(context),
                      ),
                    ),
                  ],
                  if (_hit(file) case final hit?) ...[
                    const SizedBox(height: 4),
                    Text(
                      hit.path,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontSize: 11,
                        height: 1.3,
                        color: secondary(context),
                      ),
                    ),
                  ],
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _fileMetadata(CloudFile file) {
    final time = formatCloudFileTime(file.modifiedAt);
    final style = TextStyle(fontSize: 11, color: secondary(context));
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Wrap(
          spacing: 10,
          runSpacing: 2,
          children: [
            Text(
              file.isDirectory ? '文件夹' : formatBytes(file.size),
              style: style,
            ),
            if (time.isNotEmpty) Text(time, style: style),
          ],
        ),
        if (_hit(file) case final hit?)
          Padding(
            padding: const EdgeInsets.only(top: 3),
            child: Text(
              hit.path,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: style,
            ),
          ),
      ],
    );
  }

  Widget _browserToolbar(List<CloudFile> files) => Padding(
    padding: const EdgeInsets.fromLTRB(16, 0, 8, 10),
    child: LayoutBuilder(
      builder: (context, constraints) {
        final field =
            !widget.picking && highlight == null && search.text.isEmpty
            ? CloudSearchEntry(onTap: changingAccount ? null : _openSearch)
            : TextField(
                key: const Key('browser-search-input'),
                controller: search,
                textInputAction: TextInputAction.search,
                onChanged: (_) => _editSearch(),
                onSubmitted: (_) {
                  if (_includeSubfolders) {
                    FocusScope.of(context).unfocus();
                    unawaited(_startSearch());
                  }
                },
                decoration: InputDecoration(
                  hintText: _includeSubfolders ? '搜索文件及子文件夹' : '搜索当前文件夹',
                  prefixIcon: const Icon(CupertinoIcons.search, size: 18),
                  suffixIcon: search.text.isEmpty && !_includeSubfolders
                      ? null
                      : Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            if (search.text.isNotEmpty)
                              IconButton(
                                tooltip: '清除搜索，显示全部文件',
                                icon: const Icon(
                                  CupertinoIcons.xmark_circle_fill,
                                  size: 18,
                                ),
                                onPressed: () => setState(() {
                                  _resetSearch();
                                  search.clear();
                                  highlight = null;
                                }),
                              ),
                            if (_includeSubfolders)
                              IconButton(
                                key: const Key('browser-search-submit'),
                                tooltip: '搜索子文件夹',
                                color: themeAccent(context),
                                icon: const Icon(
                                  CupertinoIcons.arrow_right_circle_fill,
                                ),
                                onPressed:
                                    search.text.trim().isEmpty ||
                                        changingAccount
                                    ? null
                                    : () {
                                        FocusScope.of(context).unfocus();
                                        unawaited(_startSearch());
                                      },
                              ),
                          ],
                        ),
                  isDense: true,
                ),
              );
        final controls = Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            AppPopupMenuButton<String>(
              tooltip: '排序',
              icon: CupertinoIcons.sort_down,
              onSelected: _changeSort,
              actions: [
                for (final option in [
                  ('name', '名称', CupertinoIcons.textformat_abc),
                  ('size', '大小', CupertinoIcons.doc),
                  ('date', '时间', CupertinoIcons.clock),
                ])
                  AppMenuAction(
                    value: option.$1,
                    label: option.$2,
                    icon: option.$3,
                    selected: sort == option.$1,
                    detail: sort == option.$1
                        ? ascending
                              ? '↑ 升序'
                              : '↓ 降序'
                        : null,
                  ),
              ],
            ),
            if (!widget.picking)
              AppPopupMenuButton<String>(
                tooltip: '显示方式',
                icon: view == 'grid'
                    ? CupertinoIcons.square_grid_2x2
                    : CupertinoIcons.list_bullet,
                onSelected: _changeView,
                actions: [
                  AppMenuAction(
                    value: 'list',
                    label: '列表',
                    icon: CupertinoIcons.list_bullet,
                    selected: view == 'list',
                  ),
                  AppMenuAction(
                    value: 'grid',
                    label: '大图标',
                    icon: CupertinoIcons.square_grid_2x2,
                    selected: view == 'grid',
                  ),
                ],
              ),
            if (!widget.picking)
              Padding(
                padding: const EdgeInsets.only(left: 6, right: 8),
                child: Tooltip(
                  message: _selecting ? '取消选择' : '多选文件',
                  child: FilledButton.icon(
                    key: const ValueKey('browser-multi-select'),
                    onPressed: _selecting
                        ? _finishSelection
                        : loading || files.isEmpty
                        ? null
                        : () => setState(() => _selectionMode = true),
                    style: FilledButton.styleFrom(
                      backgroundColor: themeAccent(context),
                      foregroundColor: Colors.white,
                      minimumSize: const Size(0, 40),
                      padding: const EdgeInsets.symmetric(horizontal: 14),
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(12),
                      ),
                    ),
                    icon: Icon(
                      _selecting
                          ? CupertinoIcons.checkmark
                          : CupertinoIcons.checkmark_circle,
                      size: 17,
                    ),
                    label: Text(_selecting ? '完成' : '多选'),
                  ),
                ),
              ),
          ],
        );
        if (constraints.maxWidth < 480 ||
            constraints.maxWidth < 650 &&
                MediaQuery.textScalerOf(context).scale(14) > 18) {
          return Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              field,
              const SizedBox(height: 4),
              Row(
                children: [
                  Expanded(
                    child: Text(
                      '${files.length} 项',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(fontSize: 12, color: secondary(context)),
                    ),
                  ),
                  controls,
                ],
              ),
            ],
          );
        }
        return Row(
          children: [
            Expanded(child: field),
            const SizedBox(width: 8),
            controls,
          ],
        );
      },
    ),
  );

  Widget _searchSummary() {
    final phase = _deepSearch.phase;
    final count = _deepSearch.hits.length;
    if (!_searchResults) {
      return Padding(
        padding: const EdgeInsets.fromLTRB(20, 0, 20, 10),
        child: Align(
          alignment: Alignment.centerLeft,
          child: Text(
            '点击搜索按钮，查找当前文件夹及其子文件夹',
            style: TextStyle(fontSize: 12, color: secondary(context)),
          ),
        ),
      );
    }
    final title = switch (phase) {
      CloudSearchPhase.running => '正在搜索 · 已找到 $count 项',
      CloudSearchPhase.completed => '搜索完成 · 共 $count 项',
      CloudSearchPhase.partial => '部分文件夹未能读取 · 找到 $count 项',
      CloudSearchPhase.stopped => '已停止搜索 · 保留 $count 项',
      CloudSearchPhase.limited => '已到搜索上限 · 找到 $count 项',
      CloudSearchPhase.failed => '搜索中断 · 保留 $count 项',
      CloudSearchPhase.idle => '准备搜索',
    };
    final detail = switch (phase) {
      CloudSearchPhase.limited => '文件较多，请进入更具体的文件夹后搜索',
      CloudSearchPhase.failed => _deepSearch.error,
      CloudSearchPhase.partial =>
        '${_deepSearch.failedFolders} 个文件夹未能读取，结果可能不完整',
      CloudSearchPhase.stopped => '结果可能不完整，可重新搜索',
      _ => '已检查 ${_deepSearch.searchedFolders} 个文件夹',
    };
    return Container(
      key: const Key('browser-search-status'),
      padding: const EdgeInsets.fromLTRB(20, 5, 6, 5),
      child: Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  title,
                  style: const TextStyle(
                    fontSize: 12,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                if (phase != CloudSearchPhase.completed) ...[
                  const SizedBox(height: 3),
                  Text(
                    detail,
                    maxLines: 3,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(fontSize: 11, color: secondary(context)),
                  ),
                ],
              ],
            ),
          ),
          if (_deepSearch.issues.isNotEmpty || _deepSearch.error.isNotEmpty)
            IconButton(
              key: const Key('browser-search-issues'),
              tooltip: '查看搜索问题',
              icon: const Icon(CupertinoIcons.info_circle, size: 19),
              onPressed: _showSearchIssues,
            ),
          IconButton(
            key: const Key('browser-search-action'),
            tooltip: _deepSearch.running ? '停止搜索' : '重新搜索',
            color: themeAccent(context),
            icon: Icon(
              _deepSearch.running
                  ? CupertinoIcons.stop_circle
                  : CupertinoIcons.arrow_clockwise,
              size: 21,
            ),
            onPressed: _deepSearch.running
                ? _deepSearch.stop
                : () => unawaited(_startSearch(refresh: true)),
          ),
          SizedBox(
            width: 38,
            child: AppPopupMenuButton<String>(
              tooltip: '排序',
              icon: CupertinoIcons.sort_down,
              onSelected: _changeSort,
              actions: [
                for (final option in [
                  ('name', '名称', CupertinoIcons.textformat_abc),
                  ('date', '时间', CupertinoIcons.clock),
                  ('size', '大小', CupertinoIcons.doc),
                ])
                  AppMenuAction(
                    value: option.$1,
                    label: option.$2,
                    icon: option.$3,
                    selected: sort == option.$1,
                    detail: sort == option.$1
                        ? ascending
                              ? '↑ 升序'
                              : '↓ 降序'
                        : null,
                  ),
              ],
            ),
          ),
          TextButton(
            key: const Key('browser-multi-select'),
            onPressed: _selecting
                ? _finishSelection
                : displayed.isEmpty
                ? null
                : () => setState(() => _selectionMode = true),
            style: TextButton.styleFrom(
              minimumSize: const Size(40, 40),
              padding: const EdgeInsets.symmetric(horizontal: 9),
            ),
            child: Text(
              _selecting ? '完成' : '多选',
              style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600),
            ),
          ),
        ],
      ),
    );
  }

  Future<void> _showSearchIssues() async {
    final issues = _deepSearch.issues.toList();
    final failure = _deepSearch.error;
    final failedFolders = _deepSearch.failedFolders;
    await showDialog<void>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('搜索未完成的原因'),
        content: SizedBox(
          width: 400,
          child: SingleChildScrollView(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                if (failure.isNotEmpty)
                  Padding(
                    padding: const EdgeInsets.only(bottom: 12),
                    child: Text(failure),
                  ),
                for (final issue in issues)
                  Padding(
                    padding: const EdgeInsets.only(bottom: 12),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(issue.path, style: const TextStyle(fontSize: 13)),
                        const SizedBox(height: 4),
                        Text(
                          issue.message,
                          style: TextStyle(
                            fontSize: 12,
                            color: secondary(context),
                          ),
                        ),
                      ],
                    ),
                  ),
                if (failedFolders > issues.length)
                  Text('另有 ${failedFolders - issues.length} 个文件夹未能读取'),
                const Text('已找到的文件仍可使用，修复网络或登录问题后可重新搜索。'),
              ],
            ),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('关闭'),
          ),
        ],
      ),
    );
  }

  Widget _githubContext() {
    final n = GitHubLocation.tryParse(stack.last.$1);
    if (n == null || n.repo.isEmpty) return const SizedBox.shrink();
    final description = switch (n.kind) {
      GitHubNodeKind.code || GitHubNodeKind.file =>
        '${n.branch ? '分支' : '标签 / 提交'}：${n.ref} · ${_canUpload ? '可编辑' : '只读'}',
      GitHubNodeKind.release || GitHubNodeKind.asset => '发布附件 · ${n.ref}',
      _ => '代码仓库与发布附件',
    };
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 4),
      child: Container(
        width: double.infinity,
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
        decoration: BoxDecoration(
          color: fill(context),
          borderRadius: BorderRadius.circular(12),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              n.repository,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(fontWeight: FontWeight.w600, fontSize: 13),
            ),
            const SizedBox(height: 3),
            Text(
              description,
              style: TextStyle(fontSize: 12, color: secondary(context)),
            ),
            if (_canUpload) ...[
              const SizedBox(height: 3),
              Text(
                n.kind == GitHubNodeKind.release
                    ? '上传到此发布，单个附件最多 2 GiB'
                    : '修改将保存到此分支。代码文件最多 100 MiB，大文件可放到 Releases。',
                style: TextStyle(
                  fontSize: 11,
                  height: 1.4,
                  color: secondary(context),
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }

  Widget _buildSearchPage() {
    final files = displayed;
    final selection = _sourceItems
        .where((file) => selected.contains(_fileKey(file)))
        .toList();
    return PopScope(
      canPop: !_selecting,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop && _selecting) _finishSelection();
      },
      child: CloudSearchLayout(
        platform: session.platform,
        controller: search,
        onChanged: (_) => _editSearch(),
        onSubmit: () => unawaited(_startSearch()),
        onClear: _clearSearch,
        onBack: () {
          Navigator.maybePop(context);
        },
        category: _searchCategory,
        onCategory: (value) => unawaited(_changeSearchCategory(value)),
        entireDrive: _searchEntireDrive,
        onScope: (value) => unawaited(_changeSearchScope(value)),
        currentFolder: stack.last.$2,
        resultHeader: !_searchResults
            ? null
            : Column(
                children: [
                  if (_deepSearch.running)
                    const LinearProgressIndicator(minHeight: 2),
                  _searchSummary(),
                ],
              ),
        footer: !_selecting
            ? null
            : Container(
                decoration: BoxDecoration(
                  color: Theme.of(context).colorScheme.surface,
                  border: Border(
                    top: BorderSide(color: border(context), width: .6),
                  ),
                ),
                padding: const EdgeInsets.symmetric(
                  horizontal: 16,
                  vertical: 8,
                ),
                child: Wrap(
                  alignment: WrapAlignment.spaceBetween,
                  crossAxisAlignment: WrapCrossAlignment.center,
                  spacing: 12,
                  runSpacing: 8,
                  children: [
                    Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        TextButton(
                          onPressed: files.isEmpty
                              ? null
                              : () => _toggleAllVisible(files),
                          child: Text(
                            _allVisibleSelected(files) ? '取消全选' : '全选',
                          ),
                        ),
                        Text(
                          '已选 ${selection.length} 项',
                          style: const TextStyle(fontSize: 12),
                        ),
                      ],
                    ),
                    FilledButton.icon(
                      onPressed:
                          selection.isEmpty ||
                              selection.any(
                                (file) =>
                                    !_provider.canDownloadFile(session, file),
                              )
                          ? null
                          : () => _operate('download', selection),
                      icon: const Icon(CupertinoIcons.arrow_down, size: 17),
                      label: const Text('下载'),
                    ),
                  ],
                ),
              ),
        child: error.isNotEmpty
            ? EmptyPanel(
                '搜索暂不可用',
                error,
                action: TextButton(
                  onPressed: () => Navigator.maybePop(context),
                  child: const Text('返回文件列表'),
                ),
              )
            : !_searchResults
            ? CloudSearchLanding(
                history: _searchHistory.read(session),
                onSearch: (term) {
                  search.text = term;
                  unawaited(_startSearch());
                },
                onClear: () => unawaited(_clearSearchHistory()),
                onRemove: (term) => unawaited(
                  busy(context, () => _searchHistory.remove(session, term)),
                ),
              )
            : files.isEmpty
            ? EmptyPanel(
                _deepSearch.running ? '正在查找文件…' : '暂未找到匹配的文件',
                _deepSearch.running
                    ? '找到的文件会陆续显示在这里'
                    : _deepSearch.phase == CloudSearchPhase.completed
                    ? '试试其他关键词、文件类型或搜索范围'
                    : '结果可能不完整，可以重新搜索或查看搜索问题',
                icon: CupertinoIcons.search,
              )
            : RefreshIndicator(
                onRefresh: _refresh,
                child: LayoutBuilder(
                  builder: (context, constraints) =>
                      _fileList(files, constraints),
                ),
              ),
      ),
    );
  }

  Widget _fastTransferContent() {
    if (loading) return const Center(child: AppLoadingIndicator());
    if (error.isNotEmpty || items.isEmpty) {
      return EmptyPanel(
        '暂时无法打开快传',
        error.ifEmpty('此快传暂未返回可保存的文件'),
        action: TextButton(onPressed: _load, child: const Text('重试')),
      );
    }
    final loggedIn = widget.services.cloud.sessionCredential(session) != null;
    return Center(
      child: SingleChildScrollView(
        padding: const EdgeInsets.all(24),
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 480),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Icon(
                CupertinoIcons.paperplane,
                size: 44,
                color: Theme.of(context).colorScheme.primary,
              ),
              const SizedBox(height: 16),
              Text(
                '阿里云盘快传',
                textAlign: TextAlign.center,
                style: Theme.of(context).textTheme.titleLarge,
              ),
              const SizedBox(height: 16),
              Text(items.single.name, textAlign: TextAlign.center),
              const SizedBox(height: 12),
              Text(
                '快传需整包转存到网盘后，才能查看完整文件、选择下载或播放。'
                '转存完成后会自动打开你选择的目录。',
                textAlign: TextAlign.center,
                style: TextStyle(color: secondary(context)),
              ),
              const SizedBox(height: 24),
              FilledButton.icon(
                key: const Key('aliyun-fast-transfer-save'),
                icon: const Icon(CupertinoIcons.folder_badge_plus),
                label: Text(loggedIn ? '转存全部文件' : '登录并转存全部文件'),
                onPressed: changingAccount
                    ? null
                    : () async {
                        if (!loggedIn) {
                          await _accountAction('login');
                          if (!mounted ||
                              widget.services.cloud.sessionCredential(
                                    session,
                                  ) ==
                                  null) {
                            return;
                          }
                        }
                        await _operate('save', List.of(items));
                      },
              ),
            ],
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    if (!widget.services.control.cloudEnabled(session.platform)) {
      return PageFrame(
        title: session.platform.label,
        actions: [
          if (!widget.picking && session.platform.requiresAccount)
            _accountMenu(),
        ],
        child: EmptyPanel(
          '网盘暂时停用',
          widget.services.control.config
              .cloud(session.platform)
              .reason(session.platform),
          icon: CupertinoIcons.pause_circle,
        ),
      );
    }
    if (widget.searchPage) return _buildSearchPage();
    final files = displayed,
        selection = _sourceItems
            .where((f) => selected.contains(_fileKey(f)))
            .toList();
    return PopScope(
      canPop:
          (stack.length == 1 ||
              widget.popAtInitialDirectory &&
                  stack.length <= (widget.initialTrail?.length ?? 1)) &&
          !_selecting &&
          !_searchResults,
      onPopInvokedWithResult: (didPop, _) {
        if (didPop) return;
        if (_selecting) {
          _finishSelection();
        } else if (_searchResults) {
          setState(() {
            _resetSearch();
            search.clear();
          });
        } else if (stack.length > 1) {
          stack.removeLast();
          _load();
        }
      },
      child: PageFrame(
        title: widget.picking
            ? '选择目标文件夹'
            : session.title.ifEmpty(session.platform.label),
        actions: [
          if (!widget.picking &&
              session.mode == BrowseMode.share &&
              session.sourceLink != null)
            AnimatedBuilder(
              animation: widget.services.store,
              builder: (context, _) {
                final saved = widget.services.favorites.containsShare(session);
                return IconButton(
                  key: const Key('browser-favorite-share'),
                  tooltip: saved ? '取消收藏分享链接' : '收藏分享链接',
                  icon: Icon(
                    saved ? CupertinoIcons.star_fill : CupertinoIcons.star,
                    color: saved ? const Color(0xffe6a23c) : null,
                    size: 21,
                  ),
                  onPressed: () async {
                    final result = await busy(
                      context,
                      () => widget.services.favorites.toggleShare(session),
                    );
                    if (!context.mounted || result == null) return;
                    message(
                      context,
                      result ? '分享链接已收藏，可从首页网盘收藏打开' : '已取消收藏分享链接',
                    );
                  },
                );
              },
            ),
          if (!widget.picking)
            IconButton(
              tooltip: '网盘收藏',
              icon: Icon(
                session.mode == BrowseMode.share
                    ? CupertinoIcons.square_list
                    : CupertinoIcons.star,
                size: 21,
              ),
              onPressed: () => Navigator.push<void>(
                context,
                MaterialPageRoute(
                  builder: (_) => CloudFavoritesPage(
                    widget.services,
                    platform: session.platform,
                    accountId: session.accountId,
                  ),
                ),
              ),
            ),
          if (!widget.picking && session.platform.requiresAccount)
            _accountMenu(),
          IconButton(
            tooltip: '刷新文件',
            onPressed: loading || changingAccount ? null : _refresh,
            icon: const Icon(CupertinoIcons.arrow_clockwise, size: 20),
          ),
          if (_canUpload || _canCreateFolder)
            if (widget.picking && _canCreateFolder)
              IconButton(
                tooltip: '新建文件夹',
                onPressed: _newFolder,
                icon: const Icon(CupertinoIcons.folder_badge_plus, size: 21),
              )
            else if (!widget.picking)
              AppPopupMenuButton<String>(
                key: const Key('browser-add-menu'),
                tooltip: '上传或新建',
                icon: CupertinoIcons.plus,
                onSelected: (action) {
                  if (action == 'upload') {
                    _upload();
                  } else {
                    _newFolder();
                  }
                },
                actions: [
                  if (_canUpload)
                    const AppMenuAction(
                      value: 'upload',
                      label: '上传文件',
                      icon: CupertinoIcons.cloud_upload,
                    ),
                  if (_canCreateFolder)
                    const AppMenuAction(
                      value: 'folder',
                      label: '新建文件夹',
                      icon: CupertinoIcons.folder_badge_plus,
                    ),
                ],
              ),
        ],
        child: AliyunShareLink.isFastTransfer(session)
            ? _fastTransferContent()
            : Column(
                children: [
                  if (!widget.picking &&
                      (session.platform == CloudPlatform.baidu ||
                          widget.services.parserRules.configured &&
                              PublicShareRoute.platforms.contains(
                                session.platform,
                              )) &&
                      (widget.services.parserRules.publicParsingAllowed(
                            session.platform,
                          ) ||
                          PublicShareRoute.uses(session)) &&
                      session.mode == BrowseMode.share &&
                      session.sourceLink != null)
                    Padding(
                      padding: const EdgeInsets.fromLTRB(16, 4, 16, 8),
                      child: Align(
                        alignment: Alignment.centerLeft,
                        child: BaiduShareRoutePicker(
                          platform: session.platform,
                          publicAllowed: widget.services.parserRules
                              .publicParsingAllowed(session.platform),
                          value: PublicShareRoute.uses(session)
                              ? BaiduShareRoute.publicParser
                              : BaiduShareRoute.account,
                          onChanged: loading || changingAccount
                              ? null
                              : _switchBaiduRoute,
                        ),
                      ),
                    ),
                  if (!widget.picking &&
                      session.mode == BrowseMode.share &&
                      PublicShareRoute.uses(session))
                    Align(
                      alignment: Alignment.centerLeft,
                      child: Padding(
                        padding: const EdgeInsets.symmetric(horizontal: 16),
                        child: ParserSitePicker(
                          services: widget.services,
                          platform: session.platform,
                          siteId: session.meta('parserSiteId').isEmpty
                              ? null
                              : session.meta('parserSiteId'),
                          enabled: !loading && !changingAccount,
                          onPasswordReady: _setParserPasswordGrant,
                          onSelected: (id) => _switchBaiduRoute(
                            BaiduShareRoute.publicParser,
                            parserSiteId: id,
                          ),
                        ),
                      ),
                    ),
                  if (session.platform == CloudPlatform.github)
                    _githubContext(),
                  if (!widget.picking &&
                      session.mode == BrowseMode.personal &&
                      session.platform.supportsFamilyCloud)
                    _spaceSelector(),
                  if (session.mode == BrowseMode.personal &&
                      session.platform.supportsPersonalSpaces)
                    Padding(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 16,
                        vertical: 4,
                      ),
                      child: Align(
                        alignment: Alignment.centerLeft,
                        child: TextButton.icon(
                          key: const ValueKey('personal-space-selector'),
                          onPressed: changingAccount
                              ? null
                              : _choosePersonalSpace,
                          icon: const Icon(CupertinoIcons.cloud, size: 18),
                          label: Text(
                            '${session.meta('driveName').ifEmpty('存储空间')} ▾',
                          ),
                        ),
                      ),
                    ),
                  SizedBox(
                    height: 42,
                    child: ListView(
                      scrollDirection: Axis.horizontal,
                      padding: const EdgeInsets.symmetric(horizontal: 10),
                      children: [
                        for (var i = 0; i < stack.length; i++)
                          Row(
                            children: [
                              if (i > 0)
                                Icon(
                                  CupertinoIcons.chevron_right,
                                  size: 11,
                                  color: secondary(context),
                                ),
                              TextButton(
                                onPressed: i == stack.length - 1
                                    ? null
                                    : () {
                                        stack.removeRange(i + 1, stack.length);
                                        _load();
                                      },
                                child: Text(
                                  stack[i].$2,
                                  style: const TextStyle(fontSize: 12),
                                ),
                              ),
                            ],
                          ),
                      ],
                    ),
                  ),
                  _browserToolbar(files),
                  if (_includeSubfolders && search.text.trim().isNotEmpty)
                    _searchSummary(),
                  if (_selecting && !widget.picking)
                    Container(
                      color: fill(context),
                      child: SingleChildScrollView(
                        scrollDirection: Axis.horizontal,
                        child: Row(
                          children: [
                            TextButton(
                              onPressed: files.isEmpty
                                  ? null
                                  : () => _toggleAllVisible(files),
                              child: Text(
                                _allVisibleSelected(files) ? '取消全选' : '全选',
                              ),
                            ),
                            Text(
                              '已选 ${selection.length} 项',
                              style: const TextStyle(fontSize: 12),
                            ),
                            const SizedBox(width: 8),
                            TextButton(
                              onPressed:
                                  selection.isEmpty ||
                                      selection.any(
                                        (f) => !_provider.canDownloadFile(
                                          session,
                                          f,
                                        ),
                                      )
                                  ? null
                                  : () => _operate('download', selection),
                              child: const Text('下载'),
                            ),
                            if (!_searchResults &&
                                session.mode == BrowseMode.share &&
                                session.platform != CloudPlatform.lanzou &&
                                session.platform != CloudPlatform.ctfile &&
                                session.platform.requiresAccount &&
                                session.platform.supportsSharing)
                              TextButton(
                                onPressed: selection.isEmpty
                                    ? null
                                    : () => _operate('save', selection),
                                child: const Text('转存'),
                              )
                            else if (!_searchResults &&
                                session.canManageFiles) ...[
                              if (selection.every(
                                (f) => _provider.canMoveFile(session, f),
                              ))
                                TextButton(
                                  onPressed: selection.isEmpty
                                      ? null
                                      : () => _operate('move', selection),
                                  child: const Text('移动'),
                                ),
                              if (session.platform.supportsSharing)
                                TextButton(
                                  onPressed: selection.isEmpty
                                      ? null
                                      : () => _operate('share', selection),
                                  child: const Text('分享'),
                                ),
                              if (selection.every(
                                (f) => _provider.canDeleteFile(session, f),
                              ))
                                TextButton(
                                  onPressed: selection.isEmpty
                                      ? null
                                      : () => _operate('delete', selection),
                                  child: const Text(
                                    '删除',
                                    style: TextStyle(color: Colors.red),
                                  ),
                                ),
                            ],
                          ],
                        ),
                      ),
                    ),
                  Expanded(
                    child: CloudUploadDropTarget(
                      enabled: _canDropUpload,
                      folderName: stack.last.$2,
                      onFilesDropped: (files) =>
                          unawaited(_upload(droppedFiles: files)),
                      child: loading
                          ? Center(
                              child: SingleChildScrollView(
                                padding: const EdgeInsets.all(24),
                                child: ConstrainedBox(
                                  constraints: const BoxConstraints(
                                    maxWidth: 360,
                                  ),
                                  child: Column(
                                    mainAxisSize: MainAxisSize.min,
                                    children: [
                                      const AppLoadingIndicator(size: 40),
                                      const SizedBox(height: 16),
                                      ValueListenableBuilder<
                                        List<OperationStep>
                                      >(
                                        valueListenable: _progress,
                                        builder: (context, steps, _) {
                                          final read = steps
                                              .where(
                                                (step) =>
                                                    step.stage ==
                                                    OperationStage.readFiles,
                                              )
                                              .lastOrNull;
                                          final label =
                                              read?.waitingForRetry == true
                                              ? '请求较频繁，正在等待重试…'
                                              : '正在加载网盘文件…';
                                          final count = read?.itemsRead;
                                          return Text(
                                            count == null
                                                ? label
                                                : '$label\n已读取 $count 项',
                                            textAlign: TextAlign.center,
                                            style: TextStyle(
                                              fontSize: 14,
                                              height: 1.5,
                                              color: secondary(context),
                                            ),
                                          );
                                        },
                                      ),
                                    ],
                                  ),
                                ),
                              ),
                            )
                          : error.isNotEmpty
                          ? EmptyPanel(
                              '文件列表读取失败',
                              error,
                              action: TextButton(
                                onPressed: _load,
                                child: const Text('重试'),
                              ),
                            )
                          : files.isEmpty
                          ? _folderContextMenu(
                              EmptyPanel(
                                _searchResults
                                    ? _deepSearch.running
                                          ? '正在搜索子文件夹…'
                                          : '暂未找到匹配的文件'
                                    : search.text.isEmpty
                                    ? '文件夹为空'
                                    : '没有匹配的文件',
                                _searchResults
                                    ? _deepSearch.phase ==
                                              CloudSearchPhase.completed
                                          ? '试试其他文件名或关键词'
                                          : '结果可能不完整，可重新搜索或查看未能读取的文件夹'
                                    : widget.picking
                                    ? '可选择当前文件夹作为目标'
                                    : _canDropUpload
                                    ? '将本地文件拖到这里上传，或点击右上角“+”'
                                    : '下拉刷新文件列表',
                              ),
                            )
                          : RefreshIndicator(
                              onRefresh: _refresh,
                              child: LayoutBuilder(
                                builder: (context, constraints) =>
                                    _fileList(files, constraints),
                              ),
                            ),
                    ),
                  ),
                  if (widget.picking)
                    Padding(
                      padding: const EdgeInsets.all(16),
                      child: SizedBox(
                        width: double.infinity,
                        child: FilledButton(
                          onPressed: loading || error.isNotEmpty
                              ? null
                              : () {
                                  widget.onDestinationPicked?.call(
                                    session,
                                    List.of(stack),
                                  );
                                  Navigator.pop(
                                    context,
                                    widget.services.cloud
                                        .connector(session.platform)
                                        .destinationId(session, stack.last.$1),
                                  );
                                },
                          child: Text('选择“${stack.last.$2}”'),
                        ),
                      ),
                    ),
                ],
              ),
      ),
    );
  }
}

class _ShareOptionsDialog extends StatefulWidget {
  const _ShareOptionsDialog(this.files, this.platform);
  final List<CloudFile> files;
  final CloudPlatform platform;
  @override
  State<_ShareOptionsDialog> createState() => _ShareOptionsDialogState();
}

class _ShareOptionsDialogState extends State<_ShareOptionsDialog> {
  late final title = TextEditingController(
    text: widget.files.length == 1
        ? widget.files.first.name
        : '${widget.files.first.name} 等 ${widget.files.length} 项',
  );
  final passcode = TextEditingController();
  bool get usesDefaultShare =>
      {CloudPlatform.lanzou, CloudPlatform.ctfile}.contains(widget.platform);
  late int days = usesDefaultShare ? 0 : 7;
  @override
  void dispose() {
    title.dispose();
    passcode.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
    title: const Text('创建分享'),
    content: SizedBox(
      width: 380,
      child: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(
              controller: title,
              decoration: const InputDecoration(labelText: '分享标题'),
            ),
            const SizedBox(height: 16),
            DropdownButtonFormField<int>(
              initialValue: days,
              decoration: const InputDecoration(labelText: '有效期'),
              items: [
                if (!usesDefaultShare) ...[
                  const DropdownMenuItem(value: 1, child: Text('1 天')),
                  const DropdownMenuItem(value: 7, child: Text('7 天')),
                  if (widget.platform != CloudPlatform.tianyi)
                    const DropdownMenuItem(value: 30, child: Text('30 天')),
                ],
                const DropdownMenuItem(value: 0, child: Text('永久')),
              ],
              onChanged: usesDefaultShare ? null : (v) => days = v ?? 7,
            ),
            const SizedBox(height: 16),
            if (widget.platform == CloudPlatform.ctfile)
              const Text('提取码沿用城通账号的默认设置，可在官网修改。一次可分享一个文件或文件夹。')
            else if (widget.platform == CloudPlatform.c139)
              const Text('提取码由移动云盘自动生成')
            else if (widget.platform == CloudPlatform.tianyi)
              const Text('访问码由天翼云盘自动生成')
            else
              TextField(
                controller: passcode,
                decoration: const InputDecoration(labelText: '提取码（可选）'),
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
      TextButton(
        onPressed: () => Navigator.pop(
          context,
          ShareOptions(
            title.text.trim(),
            expiryDays: days == 0 ? null : days,
            passcode: passcode.text.trim().isEmpty
                ? null
                : passcode.text.trim(),
          ),
        ),
        child: const Text('创建'),
      ),
    ],
  );
}
