import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:asterlink/domain/remote_control.dart';
import 'package:asterlink/ui/remote_links.dart';

void main() {
  const ticket = 'weixin://dl/business/?t=example-ticket_123';
  const plain =
      'weixin://dl/business/?appid=wx1234567890abcdef&path=pages/index/index';

  test('Only HTTPS and official mini-program button schemes are accepted', () {
    for (final value in [
      'https://example.test/notice',
      'https://wxaurl.cn/example-ticket',
      'https://wxmpurl.cn/example-ticket?cq=from%3Dnotice',
      ticket,
      '$ticket&cq=from%3Dnotice%26tab%3D2',
      plain,
      '$plain&query=from%3Dnotice&env_version=release',
    ]) {
      expect(announcementButtonUri(value).toString(), value);
    }
    expect(isWeChatMiniProgramLink(Uri.parse(ticket)), isTrue);
    expect(
      isWeChatMiniProgramLink(Uri.parse('https://wxmpurl.cn/example')),
      isTrue,
    );
    expect(
      isWeChatMiniProgramLink(
        Uri.parse('https://wxmpurl.cn.evil.test/example'),
      ),
      isFalse,
    );
    // The additional scheme applies only to announcement buttons.
    expect(() => httpsUri(ticket), throwsFormatException);
  });

  test(
    'Other protocols, arbitrary WeChat actions and malformed targets fail',
    () {
      for (final value in [
        '',
        'http://example.test/notice',
        'https://user:pass@example.test/',
        'javascript:alert(1)',
        'intent://dl/business/#Intent;scheme=weixin;end',
        'file:///C:/private',
        'weixin://',
        'weixin://dl/scan/?t=x',
        'weixin://evil/business/?t=x',
        'weixin://dl/business?t=x',
        'weixin://user@dl/business/?t=x',
        'weixin://dl:443/business/?t=x',
        'weixin://dl/business/?t=x#',
        'weixin://dl/business/?t=x#fragment',
        'weixin://dl/business/?t=',
        'weixin://dl/business/?t=a&t=b',
        'weixin://dl/business/?t=x&url=https://evil.test',
        'weixin://dl/business/?t=%00',
        'weixin://dl/business/?t=foo%20bar',
        'weixin://dl/business/?t=x&cq=${'a' * 257}',
        '$plain&query=${'a' * 513}',
        '$plain&env_version=unknown',
        '$plain&path=other',
        'weixin://dl/business/?appid=original_id&path=pages/index',
        'weixin://dl/business/?appid=wx1234567890abcdef',
        'weixin://dl/business/?appid=wx1234567890abcdef&path=pages/index%3Fa%3D1',
        '$ticket&appid=wx1234567890abcdef',
      ]) {
        expect(
          () => announcementButtonUri(value),
          throwsFormatException,
          reason: value,
        );
      }
    },
  );

  Future<BuildContext> host(WidgetTester tester) async {
    late BuildContext context;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Builder(
            builder: (current) {
              context = current;
              return const SizedBox();
            },
          ),
        ),
      ),
    );
    return context;
  }

  testWidgets('Announcement dispatches the exact scheme; updates reject it', (
    tester,
  ) async {
    final context = await host(tester);
    final opened = <Uri>[];
    Future<bool> launcher(Uri uri) async {
      opened.add(uri);
      return true;
    }

    final url = Uri.parse(ticket);
    expect(opened, isEmpty);
    await openAnnouncementLink(context, url, launcher: launcher);
    expect(opened, [url]);
    await openRemoteLink(context, url, launcher: launcher);
    await tester.pump();
    expect(opened, [url]);
    expect(find.text('无法打开链接，请检查系统默认浏览器'), findsOneWidget);
  });

  for (final throws in [false, true]) {
    testWidgets('WeChat launch failure shows an actionable message ($throws)', (
      tester,
    ) async {
      final context = await host(tester);
      await openAnnouncementLink(
        context,
        Uri.parse(ticket),
        launcher: (_) async {
          if (throws) throw StateError('No handler');
          return false;
        },
      );
      await tester.pump();
      expect(find.text('无法打开微信小程序，请检查微信是否安装、链接是否有效'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });
  }
}
