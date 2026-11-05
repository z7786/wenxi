import 'dart:async';
import 'package:asterlink/core/json.dart';
import 'package:asterlink/data/http.dart';
import 'package:asterlink/domain/links.dart';
import 'package:asterlink/domain/models.dart';
import 'lanzou_support.dart';
import 'support.dart';

const lanzouFolderUrl = 'https://author.lanzouu.com/bFolder123';
const lanzouChildUrl = 'https://author.lanzouu.com/bNested456';

String lanzouFolderPage({
  String fid = '321',
  String title = '示例文件夹',
  bool password = false,
  String children = '',
  String paginationScript = '',
}) =>
    '''<html><head><title>蓝奏云</title></head><body>
<div class="user-title">$title</div>
<div class="description">说明中提到输入密码，不代表此文件夹一定设置了密码。</div>
${password ? '<div id="pwdload"><input id="pwd"></div>' : ''}
$children
<script>
var unrelated = '1234567890';
var folder_time = '1789000100'; var folder_key = 'real-folder-sign';
var folder_id = $fid;
// data:{'lx':99,'fid':999,'t':'decoy','k':'decoy'}
\$.ajax({url:'/filemoreajax.php',data:{'lx':2,'fid':folder_id,'pg':pg,
  't':folder_time,'k':folder_key,'pwd':pwd}});
$paginationScript
</script></body></html>''';

class LanzouFolderFixture extends LanzouFixture {
  LanzouFolderFixture({Future<void> Function(Duration)? delay})
    : super(delay: delay ?? ((_) async {})) {
    this.override = (request) async {
      final intercepted = await folderOverride?.call(request);
      if (intercepted != null) return intercepted;
      if (request.method == 'GET' && folders.containsKey(request.uri.path)) {
        return HttpResult(200, folders[request.uri.path]!, {
          'set-cookie': ['folder_session=anonymous; Path=/; Secure'],
        });
      }
      if (request.uri.path == '/filemoreajax.php') {
        final fields = Uri.splitQueryString(request.body as String);
        return jsonResponse(
          pages[fields['fid']]?[int.parse(fields['pg']!)] ?? {'zt': 2},
        );
      }
      return null;
    };
  }

  final folders = <String, String>{
    '/bFolder123': lanzouFolderPage(),
    '/bNested456': lanzouFolderPage(fid: '322', title: '子目录'),
  };
  final pages = <String, Map<int, Json>>{
    '321': {
      1: {
        'zt': 1,
        'text': [
          {
            'id': 'iExample123',
            'name_all': 'Example & 1.zip',
            'size': '1.5 M',
            'time': '2026-09-14',
          },
        ],
      },
    },
    '322': {
      1: {
        'zt': 1,
        'text': [
          {
            'id': 'iNested789',
            'name_all': 'nested.zip',
            'size': '1.5 M',
            'time': '2026-09-13',
          },
        ],
      },
    },
  };
  FutureOr<HttpResult?> Function(RecordedRequest)? folderOverride;

  ParsedLink folderLink([String? code]) =>
      LinkParser.parse(lanzouFolderUrl).single.withPasscode(code ?? '');

  Future<BrowseSession> openFolder([String? code]) =>
      connector.openShare(folderLink(code), null);

  void withChild() {
    folders['/bFolder123'] = lanzouFolderPage(
      children:
          '<div class="mbxfolder"><a href="/bNested456"><div class="filename">'
          '子目录<div class="filesize">目录描述</div></div></a></div>',
    );
  }
}
