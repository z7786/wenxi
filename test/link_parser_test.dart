import 'package:flutter_test/flutter_test.dart';
import 'package:asterlink/domain/links.dart';
import 'package:asterlink/domain/models.dart';

void main() {
  for (final (url, platform) in [
    ('https://www.alipan.com/s/Ali123', CloudPlatform.aliyun),
    ('https://www.aliyundrive.com/s/Ali123', CloudPlatform.aliyun),
    ('https://www.guangyapan.com/s/Guangya123', CloudPlatform.guangya),
  ]) {
    test('$url is a supported share and upgrades its saved history', () {
      final link = LinkParser.parse('$url 提取码：a123').single;
      expect(link.kind, LinkKind.cloudShare);
      expect(link.platform, platform);
      expect(link.shareId, url.split('/').last);
      expect(link.passcode, 'a123');
      expect(link.unsupportedPlatform, isNull);
      final restored = ParsedLink.fromJson({
        ...link.toJson(),
        'platform': null,
        'kind': 'unsupportedCloud',
        'unsupportedPlatform': platform.name,
      });
      expect(restored.kind, LinkKind.cloudShare);
      expect(restored.platform, platform);
      expect(restored.passcode, 'a123');
      expect(restored.id, link.id);
    });
  }

  test(
    'Recognizes pasted prose, omitted schemes and an adjacent code label',
    () {
      final link = LinkParser.parse(
        '我分享了「旅行视频」：pan.quark.cn/s/Abc123提取码：a1B2，复制后打开。',
      ).single;
      expect(link.url, 'https://pan.quark.cn/s/Abc123');
      expect(link.platform, CloudPlatform.quark);
      expect(link.passcode, 'a1B2');
      expect(link.source, contains('旅行视频'));
    },
  );
  test(
    'Reads embedded query, percent-encoded codes and supported fragments',
    () {
      for (final (url, code) in [
        ('https://pan.baidu.com/s/1AbCd?pwd=%61%31B2', 'a1B2'),
        ('https://www.123pan.com/s/Abc-Def#q123', 'q123'),
        ('https://drive.uc.cn/s/Abcd#pwd=u321', 'u321'),
        ('https://pan.quark.cn/s/Abcd?code=q123', 'q123'),
        ('https://yun.139.com/shareweb/#/w/i/Abc_ID?passcode=m123', 'm123'),
      ]) {
        expect(LinkParser.parse('$url 提取码：wrong').single.passcode, code);
      }
    },
  );
  test('Tianyi share code is not an embedded extraction password', () {
    final share = LinkParser.parse(
      'https://cloud.189.cn/web/share?code=Ab1234',
    ).single;
    expect(share.platform, CloudPlatform.tianyi);
    expect(share.shareId, 'Ab1234');
    expect(share.passcode, isNull);

    final protected = LinkParser.parse(
      'https://cloud.189.cn/web/share?code=Ab1234&accessCode=aB12',
    ).single;
    expect(protected.passcode, 'aB12');
  });
  test('Tianyi H5 copied links separate encoded access-code labels', () {
    const prefix = 'https://h5.cloud.189.cn/share.html#/t/jy6R3u3YvQB3';
    const suffix = '%EF%BC%88%E8%AE%BF%E9%97%AE%E7%A0%81%EF%BC%9Am6h5%EF%BC%89';
    final link = LinkParser.parse('$prefix$suffix').single;
    expect(link.kind, LinkKind.cloudShare);
    expect(link.platform, CloudPlatform.tianyi);
    expect(link.shareId, 'jy6R3u3YvQB3');
    expect(link.passcode, 'm6h5');
    expect(link.url, prefix);
    expect(
      LinkParser.shareId(CloudPlatform.tianyi, '$prefix$suffix'),
      link.shareId,
    );
    expect(link.source, '$prefix$suffix');
    final corrected = LinkParser.parse(
      link.withPasscode('new1').textForCopy,
    ).single;
    expect(corrected.shareId, link.shareId);
    expect(corrected.passcode, 'new1');
    expect(corrected.url, prefix);
  });
  test('Tianyi encoded copy labels work across official share routes', () {
    for (final prefix in [
      'https://h5.cloud.189.cn/share.html#/t/jy6R3u3YvQB3',
      'https://cloud.189.cn/t/jy6R3u3YvQB3',
      'https://cloud.189.cn/web/share?code=jy6R3u3YvQB3',
    ]) {
      for (final suffix in [
        '（访问码：m6h5）',
        Uri.encodeComponent('（访问码：m6h5）'),
        Uri.encodeComponent('(访问码: m6h5)'),
        '（${Uri.encodeComponent('访问码：m6h5')}）',
        '${Uri.encodeComponent('（')}访问码：m6h5${Uri.encodeComponent('）')}',
      ]) {
        final link = LinkParser.parse('$prefix$suffix').single;
        expect(link.shareId, 'jy6R3u3YvQB3', reason: suffix);
        expect(link.passcode, 'm6h5', reason: suffix);
        expect(link.url, prefix, reason: suffix);
      }
    }
  });
  test(
    'Tianyi copied labels keep Markdown, query precedence and code ownership',
    () {
      const first = 'https://h5.cloud.189.cn/share.html#/t/First123';
      const second = 'https://cloud.189.cn/t/Second456';
      final suffix = Uri.encodeComponent('（访问码：m6h5）');
      final markdown = LinkParser.parse(
        '[$first$suffix]($first$suffix)',
      ).single;
      expect(markdown.shareId, 'First123');
      expect(markdown.passcode, 'm6h5');
      final links = LinkParser.parse(
        '$first$suffix\n$second${Uri.encodeComponent('（访问码：s456）')}',
      );
      expect(links.map((link) => link.passcode), ['m6h5', 's456']);
      final query = LinkParser.parse(
        '$first?accessCode=aB12$suffix 提取码：c789',
      ).single;
      expect(query.url, '$first?accessCode=aB12');
      expect(query.passcode, 'aB12');
      final corrected = LinkParser.parse('$first$suffix\n访问码：n123').single;
      expect(corrected.passcode, 'n123');
      final duplicate = LinkParser.parse('$first\n$first$suffix');
      expect(duplicate, hasLength(1));
      expect(duplicate.single.passcode, 'm6h5');
    },
  );
  test(
    'Encoded Tianyi labels cannot rewrite other URLs or invent share routes',
    () {
      final suffix = Uri.encodeComponent('（访问码：m6h5）');
      for (final url in [
        'https://example.test/file$suffix',
        'https://h5.cloud.189.cn.evil.test/share.html#/t/First123$suffix',
        'https://h5.cloud.189.cn/login?redirect=${Uri.encodeComponent('/t/First123')}$suffix',
      ]) {
        final link = LinkParser.parse(url).single;
        expect(link.kind, LinkKind.direct);
        expect(link.passcode, isNull);
        expect(link.url, url);
      }
      for (final parameter in ['redirect', 'note']) {
        final url =
            'https://h5.cloud.189.cn/share.html#/t/First123?$parameter=$suffix';
        final link = LinkParser.parse(url).single;
        expect(link.shareId, 'First123');
        expect(link.passcode, isNull);
        expect(link.url, url);
      }
      for (final label in ['（访问码：abc）', '（访问码：abcde）', '（其他：m6h5）']) {
        final url =
            'https://h5.cloud.189.cn/share.html#/t/First123${Uri.encodeComponent(label)}';
        final link = LinkParser.parse(url).single;
        expect(link.kind, LinkKind.direct);
        expect(link.passcode, isNull);
        expect(link.url, url);
      }
      const signed = 'https://example.test/视频%2f.mp4?sig=a%2b&key=1&key=2';
      expect(LinkParser.parse(signed).single.url, signed);
    },
  );
  test('Lanzou labels allow 1 to 12 characters; other clouds require four', () {
    for (final code in ['A', '123', 'a1B2', 'Ab1234567890']) {
      expect(
        LinkParser.parse(
          '密码为【$code】\nhttps://www.lanzouj.com/iAbcd',
        ).single.passcode,
        code,
      );
      expect(
        LinkParser.parse(
          'https://www.lanzouj.com/iAbcd\npwd: $code',
        ).single.passcode,
        code,
      );
    }
    expect(
      LinkParser.parse(
        'https://pan.quark.cn/s/Abcd 提取码：Ab12345678901',
      ).single.passcode,
      isNull,
    );
    expect(
      LinkParser.parse('提取码：https://pan.quark.cn/s/Abcd').single.passcode,
      isNull,
    );
  });
  test('Each multiline trailing code belongs to its own share', () {
    final links = LinkParser.parse(
      'https://pan.quark.cn/s/First\n提取码：q123\n\nhttps://drive.uc.cn/s/Second\n访问码：u123\nhttps://pan.baidu.com/s/1Third',
    );
    expect(links.map((l) => l.passcode), ['q123', 'u123', null]);
  });
  test('Leading codes, same-line codes and blank blocks do not cross shares', () {
    final leading = LinkParser.parse(
      '提取码：aaaa\nhttps://pan.quark.cn/s/First\n密码：bbbb\nhttps://drive.uc.cn/s/Second',
    );
    expect(leading.map((l) => l.passcode), ['aaaa', 'bbbb']);
    final separated = LinkParser.parse(
      'https://pan.quark.cn/s/First\n\n提取码：bbbb\nhttps://drive.uc.cn/s/Second',
    );
    expect(separated.map((l) => l.passcode), [null, 'bbbb']);
    final inline = LinkParser.parse(
      'https://pan.quark.cn/s/First 提取码：aaaa\n访问码：bbbb https://drive.uc.cn/s/Second',
    );
    expect(inline.map((l) => l.passcode), ['aaaa', 'bbbb']);
  });
  test('Duplicate normalization keeps a later recognized code', () {
    final links = LinkParser.parse(
      'https://pan.quark.cn/s/Abcd\nhttps://PAN.QUARK.CN/s/Abcd 提取码：a1b2',
    );
    expect(links, hasLength(1));
    expect(links.single.passcode, 'a1b2');
  });
  test('Signed bytes and Unicode paths of direct files remain intact', () {
    const url = 'HTTPS://Example.COM/旅行%2fY%2Fz?b=2&a=%2b+%20&a=3';
    final link = LinkParser.parse('文件：$url').single;
    expect(link.url, 'https://example.com/旅行%2fY%2Fz?b=2&a=%2b+%20&a=3');
    expect(link.kind, LinkKind.direct);
    expect(
      LinkParser.parse('example.com/file.mp4').single.url,
      'https://example.com/file.mp4',
    );
  });
  test('Codes never get stolen from direct URL query parameters', () {
    final links = LinkParser.parse(
      'https://pan.quark.cn/s/Abcd\nhttps://example.com/file?pwd=abcd',
    );
    expect(links.first.passcode, isNull);
    expect(links.last.passcode, isNull);
  });
  test(
    'A manual passcode replaces the embedded value without rewriting the signed URL',
    () {
      final link = LinkParser.parse(
        'https://pan.baidu.com/s/1Abcd?pwd=old1',
      ).single;
      expect(link.withPasscode('new1').passcode, 'new1');
      expect(link.withPasscode('new1').url, link.url);
      expect(link.withPasscode('').passcode, isNull);
    },
  );
}
