import 'dart:async';
import 'dart:convert';
import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import '../core/json.dart';
import '../data/state_store.dart';
import '../diagnostics/app_log.dart';
import '../domain/links.dart';
import '../domain/models.dart';
import '../domain/settings.dart';

class ClipboardLinkSuggestion {
  ClipboardLinkSuggestion._(this.links)
    : fingerprint = sha256
          .convert(
            utf8.encode(
              jsonEncode([
                for (final link in links) [link.url, link.passcode ?? ''],
              ]),
            ),
          )
          .toString();

  final List<ParsedLink> links;
  final String fingerprint;
  String get text => links
      .map(
        (link) =>
            '${link.url}${link.passcode?.isNotEmpty == true ? '\n提取码：${link.passcode}' : ''}',
      )
      .join('\n\n');
  String get label => links.length > 1
      ? '${links.length} 个分享或下载链接'
      : switch (links.single.kind) {
          LinkKind.cloudShare =>
            '${links.single.platform!.shortName}分享链接${links.single.platform!.supportsShareParsing ? '' : '（暂不支持分享解析）'}',
          LinkKind.unsupportedCloud =>
            '${links.single.unsupportedPlatform?.shortName ?? '网盘'}分享链接（暂未接入）',
          LinkKind.magnet => '磁力链接',
          LinkKind.ed2k => 'ED2K 文件链接',
          _ => '种子链接',
        };

  static final _magnet = RegExp(
    r'^magnet:\?xt=urn:btih:(?:[a-f0-9]{40}|[a-z2-7]{32})(?:[&#]|$)',
    caseSensitive: false,
  );

  static ClipboardLinkSuggestion? fromText(String? text) {
    // Clipboard text may be unrelated private data or a very large document.
    // Retain only supported links and their associated extraction codes.
    if (text == null || text.isEmpty || text.length > 64 * 1024) return null;
    final links = LinkParser.parse(text)
        .where(
          (link) => switch (link.kind) {
            LinkKind.cloudShare || LinkKind.torrent || LinkKind.ed2k => true,
            LinkKind.unsupportedCloud => link.shareId != null,
            LinkKind.magnet => _magnet.hasMatch(link.url),
            LinkKind.direct => false,
          },
        )
        .take(21)
        .toList(growable: false);
    return links.isEmpty || links.length > 20
        ? null
        : ClipboardLinkSuggestion._(List.unmodifiable(links));
  }
}

/// Activated by visible application windows only. No background polling,
/// automatic network requests, or storage of clipboard contents.
class ClipboardLinks extends ChangeNotifier {
  ClipboardLinks(this.store, {Future<String?> Function()? read})
    : _read = read ?? _readSystem {
    _enabled = AppSettings.fromJson(
      store.data.obj('settings'),
    ).clipboardRecognition;
    store.addListener(_settingsChanged);
  }

  static const _handledKey = 'clipboardRecognitionLastHandled';
  final StateStore store;
  final Future<String?> Function() _read;
  final _handled = <String>{};
  ClipboardLinkSuggestion? _suggestion;
  ClipboardLinkSuggestion? get suggestion => _suggestion;
  Timer? _timer;
  bool _enabled = true, _foreground = false, _reading = false;
  bool _checkAgain = false, _disposed = false;
  int _generation = 0;

  static Future<String?> _readSystem() async =>
      (await Clipboard.getData(Clipboard.kTextPlain))?.text;

  bool get _canRead => !_disposed && _foreground && _enabled;

  void setForeground(bool value) {
    if (_disposed) return;
    if (_foreground != value) {
      _foreground = value;
      _generation++;
    }
    _timer?.cancel();
    _timer = null;
    if (_canRead) _schedule();
  }

  void _schedule() {
    _timer?.cancel();
    _timer = Timer(const Duration(milliseconds: 350), () {
      _timer = null;
      unawaited(check());
    });
  }

  void _settingsChanged() {
    if (_disposed) return;
    final enabled = AppSettings.fromJson(
      store.data.obj('settings'),
    ).clipboardRecognition;
    if (_enabled == enabled) return;
    _enabled = enabled;
    _generation++;
    _timer?.cancel();
    _timer = null;
    if (enabled && _foreground) _schedule();
    if (!enabled) _publish(null);
  }

  Future<void> check() async {
    _timer?.cancel();
    _timer = null;
    if (!_canRead) return;
    if (_reading) {
      _checkAgain = true;
      return;
    }
    _reading = true;
    final generation = _generation;
    try {
      final text = await _read();
      if (!_canRead || generation != _generation) return;
      final candidate = ClipboardLinkSuggestion.fromText(text);
      final handled =
          candidate != null &&
          (_handled.contains(candidate.fingerprint) ||
              store.data.str(_handledKey) == candidate.fingerprint);
      _publish(handled ? null : candidate);
    } catch (_) {
      // A denied or unavailable platform clipboard must not interrupt the UI.
      if (_canRead && generation == _generation) _publish(null);
    } finally {
      _reading = false;
      if (_checkAgain) {
        _checkAgain = false;
        if (_canRead) _schedule();
      }
    }
  }

  void _publish(ClipboardLinkSuggestion? value) {
    if (_disposed || value?.fingerprint == _suggestion?.fingerprint) return;
    _suggestion = value;
    notifyListeners();
  }

  Future<void> acknowledge(ClipboardLinkSuggestion value) async {
    if (_disposed) return;
    _handled.remove(value.fingerprint);
    _handled.add(value.fingerprint);
    if (_handled.length > 32) _handled.remove(_handled.first);
    if (_suggestion?.fingerprint == value.fingerprint) _publish(null);
    try {
      // Persist only the digest of the last explicit use/ignore action.
      await store.put(_handledKey, value.fingerprint);
    } catch (_) {
      DiagnosticLog.event('clipboard.preference_save_failed');
    }
  }

  Future<void> acknowledgeText(String text) async {
    final value = ClipboardLinkSuggestion.fromText(text);
    if (value != null) await acknowledge(value);
  }

  @override
  void dispose() {
    _disposed = true;
    _generation++;
    _timer?.cancel();
    store.removeListener(_settingsChanged);
    _suggestion = null;
    _handled.clear();
    super.dispose();
  }
}
