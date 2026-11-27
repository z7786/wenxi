import 'dart:async';
import 'dart:math';
import 'package:asterlink/core/json.dart';
import 'package:asterlink/data/http.dart';
import 'package:asterlink/data/providers/lanzou.dart';
import 'package:asterlink/domain/links.dart';
import 'package:asterlink/domain/models.dart';
import 'support.dart';

const lanzouTestUrl = 'https://author.lanzouu.com/iExample123';
const lanzouTestFinal =
    'https://cdn.example/file?sign=a%2bb&key=1&key=2&pid=opaque';
const lanzouTestPage = '''<!doctype html><html><body>
<div class="n_box_3fn">Example &amp; 1.zip</div>
<div class="n_filesize">大小：1.5 M</div>
<iframe name="download" src="/fn?ticket=fixture&amp;version=2"></iframe>
</body></html>''';
const lanzouTestFrame = r'''<html><body><script>
var wp_sign = 'opaque-sign';
var ajaxdata = 'a&b+=?';
$.ajax({
  url:'/ajaxm.php?file=42',
  data:{'action':'downprocess','sign':wp_sign,'websignkey':ajaxdata,'signs':ajaxdata,'websign':'','kd':1,'ves':1}
});
</script></body></html>''';
const lanzouTestPasswordPage = r'''<html><body>
<div class='n_box_3fn'>Private.zip</div><div class='n_filesize'>大小：4 B</div>
<script>
var isngis = 'old'; var isngis = 'password-sign'; var isngis = '';
function down_p(){
//data:{'action':'downprocess','sign':'commented-decoy','p':pwd},
$.ajax({ url: '/ajaxfile.php?file=43',
data:{'action':'downprocess','sign':isngis,'p':pwd,'kd':1}
}); }
</script></body></html>''';
const lanzouTestChallenge =
    '''<html><script>var arg1='0123456789abcdef0123456789abcdef01234567';</script></html>''';

class LanzouTestHttp extends FakeHttp {
  LanzouTestHttp(super.respond);
  final redirects = <bool>[];
  final peeks = <(String, int, bool)>[];
  @override
  Future<HttpResult> request(
    String method,
    String url, {
    Object? body,
    Map<String, String> headers = const {},
    bool followRedirects = true,
    String? contentType,
  }) {
    redirects.add(followRedirects);
    return super.request(
      method,
      url,
      body: body,
      headers: headers,
      followRedirects: followRedirects,
      contentType: contentType,
    );
  }

  @override
  Future<HttpResult> peek(
    String url,
    Map<String, String> headers, {
    int maxBytes = 8192,
    bool followRedirects = true,
  }) {
    peeks.add((url, maxBytes, followRedirects));
    return super.peek(
      url,
      headers,
      maxBytes: maxBytes,
      followRedirects: followRedirects,
    );
  }
}

class LanzouFixture {
  LanzouFixture({Future<void> Function(Duration)? delay, Random? random}) {
    http = LanzouTestHttp(respond);
    connector = LanzouConnector(
      http,
      clock: () => now,
      delay: delay,
      random: random,
    );
  }
  DateTime now = DateTime.utc(2026, 9, 14);
  late final LanzouTestHttp http;
  late final LanzouConnector connector;
  String page = lanzouTestPage, frame = lanzouTestFrame;
  int exactSize = 1234567;
  Json result = {
    'zt': 1,
    'dom': 'https://download.lanzouj.com',
    'url': 'ticket?pid=opaque&key=1&key=2',
    'inf': 'Example & 1.zip',
  };
  FutureOr<HttpResult?> Function(RecordedRequest)? override;
  ParsedLink link([String? code]) =>
      LinkParser.parse(lanzouTestUrl).single.withPasscode(code ?? '');
  Future<HttpResult> respond(RecordedRequest request) async {
    final response = await override?.call(request);
    if (response != null) return response;
    if (request.uri.host == 'cdn.example') {
      return HttpResult(200, '', {
        'content-type': ['application/octet-stream'],
        'content-length': ['$exactSize'],
      });
    }
    if (request.uri.path.startsWith('/file/')) {
      return const HttpResult(302, '', {
        'location': [lanzouTestFinal],
      });
    }
    if (request.uri.path == '/fn') return HttpResult(200, frame);
    if (request.method == 'POST') return jsonResponse(result);
    return HttpResult(200, page, {
      'set-cookie': [
        'share_session=anonymous; Domain=lanzouu.com; Path=/; Secure',
        'foreign=blocked; Domain=cdn.example; Path=/; Secure',
      ],
    });
  }

  Future<BrowseSession> open([String? code]) =>
      connector.openShare(link(code), null);
  Future<DownloadSpec> download(BrowseSession session) async =>
      connector.download(
        session,
        (await connector.list(session, session.rootId, null)).single,
        null,
      );
}
