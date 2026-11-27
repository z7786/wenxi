import 'dart:convert';
import 'package:crypto/crypto.dart';
import '../../core/crypto_box.dart';
import '../../core/json.dart';
import '../../domain/models.dart';
import '../../platform/quark_transfer_device.dart';
import '../http.dart';
import '../http_retry.dart';

/// A confirmed failure permits the existing web route to take over.
class QuarkMobileUnavailable extends AppException {
  const QuarkMobileUnavailable(this.stage, {this.code, this.status})
    : super('夸克移动转存暂不可用');
  final String stage;
  final int? code, status;
}

/// An accepted/possibly accepted save must never be submitted a second time.
class QuarkMobilePending extends AppException {
  const QuarkMobilePending() : super('夸克已提交转存，结果暂未确认，请稍后刷新目标目录；未重复提交');
}

/// Key4 wire format verified against the supplied native/Python vectors.
/// Account credentials are decoded in memory and never written to the vault.
class QuarkMobileAuth {
  QuarkMobileAuth._(this._ticket, this._uid, this._nickname);
  final String _ticket, _uid, _nickname;
  static final _key = _hex('35656533663237333437343566373337');
  static final _iv = _hex('35656533663237333437343566373337');
  static List<int> _hex(String text) => [
    for (var i = 0; i < text.length; i += 2)
      int.parse(text.substring(i, i + 2), radix: 16),
  ];

  static String _encrypt(String plain) => base64Encode([
    0,
    4,
    if (plain.isNotEmpty)
      ...CryptoBox.aesCbc(true, utf8.encode(plain), _key, _iv),
  ]);

  factory QuarkMobileAuth.fromKps(String value) {
    try {
      // Decoding exactly once also supports an escaped official response.
      final wire = base64Decode(Uri.decodeComponent(value));
      if (wire.length < 18 ||
          wire[0] != 0 ||
          wire[1] != 4 ||
          (wire.length - 2) % 16 != 0) {
        throw const FormatException();
      }
      final plain = utf8.decode(
        CryptoBox.aesCbc(false, wire.sublist(2), _key, _iv),
      );
      final uidAt = plain.indexOf('&uid=', 6);
      final nicknameAt = uidAt < 0
          ? -1
          : plain.indexOf('&nickname=', uidAt + 5);
      if (!plain.startsWith('token=') ||
          uidAt <= 6 ||
          nicknameAt <= uidAt + 5) {
        throw const FormatException();
      }
      return QuarkMobileAuth._(
        plain.substring(6, uidAt),
        plain.substring(uidAt + 5, nicknameAt),
        plain.substring(nicknameAt + 10),
      );
    } catch (_) {
      // Crypto exceptions can embed input material; expose no raw values.
      throw const QuarkMobileUnavailable('mobilekps');
    }
  }

  Map<String, String> sign(int milliseconds) {
    final stamp = '$milliseconds';
    if (!RegExp(r'^[0-9]{6,}$').hasMatch(stamp)) {
      throw const QuarkMobileUnavailable('timestamp');
    }
    final digest = md5
        .convert(
          utf8.encode(
            '${stamp.substring(0, 5)}$_ticket$_uid$_nickname${stamp[stamp.length - 1]}',
          ),
        )
        .toString()
        .toUpperCase();
    return {
      'kps': _encrypt('token=$_ticket&uid=$_uid&nickname=$_nickname'),
      'sign': _encrypt(digest),
      'vcode': stamp,
    };
  }
}

/// Only share token/detail/save/task use the mobile host. Personal directories
/// and cleanup retain their existing PC interfaces and cookie refresh policy.
class QuarkMobileTransfer {
  QuarkMobileTransfer(
    this.http, {
    required this.webHeaders,
    required this.checkpoint,
    required this.device,
    int Function()? now,
    this.taskDelay = const Duration(milliseconds: 750),
  }) : now = now ?? (() => DateTime.now().millisecondsSinceEpoch);
  final JsonHttp http;
  final Map<String, String> Function() webHeaders;
  final void Function() checkpoint;
  final int Function() now;
  final Duration taskDelay;
  final QuarkTransferDevice device;
  static const _profile = {
    'entry': 'default_clouddrive',
    '_t_group': '0:_s_vp:1',
    'fr': 'android',
    'pf': '3300',
    'bi': '35937',
    've': QuarkTransferDeviceInfo.clientVersion,
    'kt': '4',
    'pr': QuarkTransferDeviceInfo.product,
    'sv': 'release',
    'dt': 'phone',
    'data_from': 'ucapi',
    'app': 'clouddrive',
    'kkkk': '1',
  };

  Future<Json> _call(
    QuarkMobileAuth auth,
    QuarkTransferDeviceInfo deviceInfo,
    String path,
    String stage, {
    Json? body,
    Map<String, String> extra = const {},
    bool mutation = false,
  }) async {
    checkpoint();
    final url = Uri.https('drive-m.quark.cn', '/1/clouddrive/$path', {
      ..._profile,
      ...deviceInfo.parameters,
      ...extra,
      ...auth.sign(now()),
    }).toString();
    final headers = {
      'Accept': 'application/json',
      'User-Agent': deviceInfo.userAgent,
      'Content-Type': 'application/json; charset=utf-8',
    };
    late HttpResult response;
    try {
      response = await (mutation ? http.mutationRequest : http.readRequest)(
        body == null ? 'GET' : 'POST',
        url,
        body: body == null ? null : encoded(body),
        headers: headers,
        contentType: body == null ? null : 'application/json; charset=utf-8',
        followRedirects: false,
      );
    } catch (error) {
      checkpoint();
      if (mutation && !(error is HttpRequestFailure && error.requestNotSent)) {
        throw const QuarkMobilePending();
      }
      throw QuarkMobileUnavailable(stage);
    }
    checkpoint();
    Json object;
    try {
      object = response.json;
    } on AppException {
      if (mutation) throw const QuarkMobilePending();
      throw QuarkMobileUnavailable(stage, status: response.status);
    }
    final code = object.integer('code', -1);
    if (!response.successful || object.integer('status') != 200 || code != 0) {
      // A structured business rejection means no task was accepted; transient
      // gateway errors without a business code leave the save outcome unknown.
      if (mutation && (code <= 0 || response.status >= 500)) {
        throw const QuarkMobilePending();
      }
      throw QuarkMobileUnavailable(
        stage,
        code: code,
        status: object.integer('status', response.status),
      );
    }
    if (object['data'] is! Map) {
      if (mutation) throw const QuarkMobilePending();
      throw QuarkMobileUnavailable(stage);
    }
    return object.obj('data');
  }

  Future<QuarkMobileAuth> _auth() async {
    checkpoint();
    try {
      final response = await http.get(
        'https://pan.quark.cn/account/info?fr=pc&platform=pc',
        webHeaders(),
      );
      checkpoint();
      final info = response.json;
      if (!response.successful || !info.boolean('success')) {
        throw const QuarkMobileUnavailable('account');
      }
      final mobilekps = info.obj('data').str('mobilekps');
      if (mobilekps.isEmpty || mobilekps.length > 32768) {
        throw const QuarkMobileUnavailable('mobilekps');
      }
      return QuarkMobileAuth.fromKps(mobilekps);
    } catch (error) {
      checkpoint();
      if (error is QuarkMobileUnavailable) rethrow;
      throw const QuarkMobileUnavailable('account');
    }
  }

  Future<List<String>> save(
    BrowseSession session,
    List<CloudFile> files,
    String destination,
  ) => ReadRetryScope.withoutRetries(() async {
    require(files.isNotEmpty, '请选择要转存的文件');
    require(
      session.meta('shareId').isNotEmpty && destination.isNotEmpty,
      '分享或目标目录信息缺失，请重新打开文件列表',
    );
    checkpoint();
    final deviceInfo = await device.read();
    checkpoint();
    if (deviceInfo == null) throw const QuarkMobileUnavailable('device');
    final auth = await _auth();
    final tokenData = await _call(
      auth,
      deviceInfo,
      'share/sharepage/token',
      'token',
      body: {
        'pwd_id': session.meta('shareId'),
        'passcode': session.meta('passcode'),
      },
    );
    final stoken = tokenData.str('stoken');
    if (stoken.isEmpty) throw const QuarkMobileUnavailable('token');
    final parents = files
        .map(
          (f) => f.parentId.isEmpty || f.parentId == session.rootId
              ? '0'
              : f.parentId,
        )
        .toSet();
    if (parents.length != 1) throw const QuarkMobileUnavailable('selection');
    final parent = parents.single;
    final entries = <String, Json>{};
    for (var page = 1; page <= 100; page++) {
      final data = await _call(
        auth,
        deviceInfo,
        'share/sharepage/detail',
        'detail',
        extra: {
          'pwd_id': session.meta('shareId'),
          'stoken': stoken,
          'pdir_fid': parent,
          '_page': '$page',
          '_size': '100',
          '_fetch_total': '1',
          '_sort': 'file_type:asc,file_name:asc',
        },
      );
      if (data['list'] is! List) throw const QuarkMobileUnavailable('detail');
      final batch = objects(data['list']);
      final previous = entries.length;
      for (final item in batch) {
        if (item.str('fid').isNotEmpty) entries[item.str('fid')] = item;
      }
      if (files.every((f) => entries.containsKey(f.id))) break;
      if (batch.length < 100 || entries.length == previous || page == 100) {
        throw const QuarkMobileUnavailable('selection');
      }
    }
    final fresh = <Json>[];
    for (final file in files) {
      final entry = entries[file.id];
      if (entry == null ||
          entry.boolean('dir') != file.isDirectory ||
          entry.str('share_fid_token').isEmpty ||
          (file.size > 0 && entry.integer('size') != file.size)) {
        throw const QuarkMobileUnavailable('selection');
      }
      fresh.add(entry);
    }
    final saved = await _call(
      auth,
      deviceInfo,
      'share/sharepage/save',
      'save',
      mutation: true,
      body: {
        'scene': 'link',
        'pwd_id': session.meta('shareId'),
        'stoken': stoken,
        'pdir_fid': parent == '0' ? '' : parent,
        'to_pdir_fid': destination,
        'save_all': false,
        'fid_list': fresh.map((f) => f.str('fid')).toList(),
        'fid_token_list': fresh.map((f) => f.str('share_fid_token')).toList(),
      },
    );
    final task = saved.str('task_id');
    if (task.isEmpty) throw const QuarkMobilePending();
    for (var attempt = 0; attempt < 20; attempt++) {
      Json data;
      try {
        data = await _call(
          auth,
          deviceInfo,
          'task',
          'task',
          extra: {'task_id': task, 'retry_index': '$attempt'},
        );
      } on QuarkMobileUnavailable catch (error) {
        // These task responses confirm a terminal failure. Auth/network errors
        // cannot establish whether the task finished; keep polling its same ID.
        if (error.code == 32003) {
          rethrow;
        }
        if (attempt == 19) throw const QuarkMobilePending();
        await RequestScope.wait(taskDelay);
        continue;
      }
      if ({3, 4}.contains(data.integer('status')) ||
          {3, 4}.contains(data.integer('task_status'))) {
        throw QuarkMobileUnavailable('task', code: data.integer('code'));
      }
      if (data.integer('status') == 2 ||
          data.integer('task_status') == 2 ||
          data.integer('finished_at') > 0) {
        final savedAs = data.obj('save_as');
        final ids =
            savedAs['save_as_top_fids'] ?? savedAs['save_as_select_top_fids'];
        if (ids is! List || ids.isEmpty) {
          throw const QuarkMobilePending();
        }
        final result = <String>[];
        for (final id in ids) {
          if (id is! String && id is! int) {
            throw const QuarkMobilePending();
          }
          final value = '$id';
          if (value.isEmpty ||
              value == '0' ||
              value.toLowerCase() == 'null' ||
              value.length > 512 ||
              RegExp(r'\s|[\x00-\x1f\x7f]').hasMatch(value)) {
            throw const QuarkMobilePending();
          }
          result.add(value);
        }
        if (result.toSet().length != result.length) {
          throw const QuarkMobilePending();
        }
        return result;
      }
      await RequestScope.wait(taskDelay);
    }
    throw const QuarkMobilePending();
  });
}
