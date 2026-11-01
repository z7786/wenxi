import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:xml/xml.dart';
import 'package:asterlink/core/json.dart';
import 'package:asterlink/domain/models.dart';
import 'package:asterlink/lan/lan_models.dart' show isLanAddress;
import 'package:asterlink/playback/cast/cast_discovery.dart';
import 'package:asterlink/playback/cast/cast_session.dart';
import 'package:asterlink/playback/cast/dlna.dart';
import 'cast_support.dart';

void main() {
  test(
    'SSDP validates status, sender, LAN location and case-insensitive headers',
    () {
      final sender = InternetAddress('192.168.1.8');
      Uri? parse(String text) => castLocation(latin1.encode(text), sender);
      const good =
          'HTTP/1.1 200 OK\r\nlOcAtIoN: http://192.168.1.8:1234/root.xml\r\n\r\n';
      expect(parse(good)?.port, 1234);
      expect(parse(good.replaceFirst('200', '500')), isNull);
      expect(parse(good.replaceFirst('192.168.1.8', '8.8.8.8')), isNull);
      expect(parse(good.replaceFirst('192.168.1.8', '192.168.1.9')), isNull);
      expect(parse(good.replaceFirst('http://', 'http://secret@')), isNull);
      expect(parse(good.replaceFirst('http:', 'file:')), isNull);
      expect(parse('x' * 20000), isNull);
    },
  );

  test(
    'description resolves namespaced service v2 paths and rejects external endpoints',
    () async {
      final tv = TestTv();
      await tv.start();
      addTearDown(tv.close);
      final device = tv.device;
      expect(device.name, '客厅 & 电视');
      expect(device.transport.type, endsWith(':2'));
      expect(device.transport.control.path, '/transport');
      expect(device.rendering!.control.path, '/render');
      expect(
        CastDevice.parse(
          tv.description.replaceAll('AVTransport', 'ContentDirectory'),
          tv.location,
        ),
        isNull,
      );
      expect(
        CastDevice.parse(
          tv.description.replaceFirst('../transport', 'http://8.8.8.8/action'),
          tv.location,
        ),
        isNull,
      );
      expect(
        () => CastDevice.parse(
          tv.description.replaceFirst(
            '<device>',
            '<URLBase>http://8.8.8.8/</URLBase><device>',
          ),
          tv.location,
        ),
        throwsA(isA<AppException>()),
      );
    },
  );

  test(
    'real SSDP search discovers and deduplicates a TV, then releases network lock',
    () async {
      final tv = TestTv();
      await tv.start();
      await tv.startSsdp();
      addTearDown(tv.close);
      final platform = TestCastPlatform();
      final discovery = CastDiscovery(
        platform: platform,
        addresses: () async => [InternetAddress.loopbackIPv4],
        searchAddress: InternetAddress.loopbackIPv4,
        searchPort: tv.ssdp!.port,
        scanDuration: const Duration(milliseconds: 400),
      );
      addTearDown(discovery.dispose);
      await discovery.scan();
      expect(discovery.error, isEmpty);
      expect(discovery.devices.single.name, '客厅 & 电视');
      expect(tv.descriptions, 1);
      expect(tv.events.any((e) => e.contains('MAN: "ssdp:discover"')), isTrue);
      expect(platform.events, ['network:true', 'network:false']);
    },
  );

  test(
    'closing discovery during native lock acquisition prevents late sockets',
    () async {
      final barrier = Completer<void>();
      final platform = TestCastPlatform()..networkBarrier = barrier.future;
      final discovery = CastDiscovery(platform: platform);
      final pending = discovery.scan();
      discovery.dispose();
      barrier.complete();
      await pending;
      expect(platform.events, ['network:true', 'network:false']);
    },
  );

  test(
    'SOAP encodes DIDL, media URL and Unicode title; controls use instance zero',
    () async {
      final tv = TestTv();
      await tv.start();
      addTearDown(tv.close);
      final client = DlnaClient();
      addTearDown(client.close);
      final device = (await client.describe(tv.location))!;
      const url = 'http://192.168.1.2:52382/session/video?a=1&b=2';
      await client.setMedia(
        device,
        url,
        '电影 <第一集> & "4K"',
        'video/mp4',
        const Duration(minutes: 90),
      );
      expect(tv.media, url);
      final metadata = XmlDocument.parse(tv.metadata);
      String value(String name) => metadata.descendants
          .whereType<XmlElement>()
          .firstWhere((e) => e.name.local == name)
          .innerText;
      expect(value('title'), '电影 <第一集> & "4K"');
      expect(value('res'), url);
      expect(tv.requests.single.args['InstanceID'], '0');
      expect(
        tv.requests.single.headers.value('SOAPAction'),
        '"urn:schemas-upnp-org:service:AVTransport:2#SetAVTransportURI"',
      );
      await client.transport(device, 'Play', {'Speed': '1'});
      await client.transport(device, 'Seek', {
        'Unit': 'REL_TIME',
        'Target': '0:12:34',
      });
      expect(tv.position, const Duration(minutes: 12, seconds: 34));
      await client.transport(device, 'Pause');
      expect(tv.transport, 'PAUSED_PLAYBACK');
      tv.faults['Play'] = 714;
      await expectLater(
        client.transport(device, 'Play', {'Speed': '1'}),
        throwsA(
          isA<CastSoapException>().having(
            (e) => e.message,
            'message',
            contains('视频格式'),
          ),
        ),
      );
      tv.malformed = true;
      await expectLater(
        client.transport(device, 'GetTransportInfo'),
        throwsA(isA<AppException>()),
      );
    },
  );

  test(
    'session polls TV progress/volume and gracefully handles unsupported Seek',
    () async {
      final tv = TestTv();
      await tv.start();
      addTearDown(tv.close);
      final platform = TestCastPlatform();
      tv.faults['Seek'] = 710;
      final session = CastSession(
        tv.device,
        const DownloadSpec(
          url: 'https://example.invalid/video.mp4',
          fileName: 'movie.mp4',
        ),
        platform: platform,
        pollInterval: const Duration(days: 1),
      );
      addTearDown(session.close);
      await session.start(
        title: 'Movie',
        position: const Duration(seconds: 40),
        duration: tv.duration,
      );
      await castEventually(() => session.volumeSupported);
      expect(session.seekSupported, isFalse);
      expect(session.warning, contains('从头播放'));
      expect(session.state.position, Duration.zero);
      expect(session.state.volume, 35);
      tv.trackOverride = 'NOT_IMPLEMENTED';
      await session.refresh();
      expect(session.transportReplaced, isFalse);
      tv.trackOverride = null;
      await session.setVolume(60);
      expect(tv.volume, 60);
      tv.position = const Duration(seconds: 90);
      await session.refresh();
      expect(session.state.position, tv.position);
      expect(
        tv.requests.every((r) => r.headers.value('Cookie') == null),
        isTrue,
      );
      expect(Uri.parse(tv.media).port, isNot(tv.server.port));
      await session.close();
      expect(tv.events.last, 'Stop');
      expect(platform.events, ['active:true', 'active:false']);
    },
  );

  test(
    'failed state polling becomes a recoverable connection error; replacement is not stopped',
    () async {
      final tv = TestTv();
      await tv.start();
      addTearDown(tv.close);
      final session = CastSession(
        tv.device,
        const DownloadSpec(
          url: 'https://example.invalid/video.mp4',
          fileName: 'movie.mp4',
        ),
        pollInterval: const Duration(days: 1),
      );
      addTearDown(session.close);
      await session.start(
        title: 'Movie',
        position: Duration.zero,
        duration: tv.duration,
      );
      await castEventually(() => session.volumeSupported);
      tv.faults['GetTransportInfo'] = 501;
      for (var i = 0; i < 3; i++) {
        await session.refresh();
      }
      expect(session.error, contains('连接中断'));
      tv.faults.clear();
      await session.refresh();
      expect(session.error, isEmpty);
      expect(session.state.playing, isTrue);
      tv.media = 'http://192.168.1.4/somebody-else.mp4';
      await session.refresh();
      expect(session.transportReplaced, isTrue);
      await session.close();
      expect(tv.events.where((e) => e == 'Stop'), isEmpty);
    },
  );

  test(
    'time parser rejects unavailable and invalid values without resetting progress',
    () {
      expect(parseCastTime('NOT_IMPLEMENTED'), isNull);
      expect(parseCastTime('0:99:12'), isNull);
      expect(
        parseCastTime('12:34:56.123'),
        const Duration(hours: 12, minutes: 34, seconds: 56),
      );
      expect(castTime(const Duration(hours: 2, seconds: 8)), '2:00:08');
    },
  );

  test(
    'LAN handoff advertises the routed interface instead of loopback',
    () async {
      final addresses = [
        for (final nic in await NetworkInterface.list(
          type: InternetAddressType.IPv4,
        ))
          for (final address in nic.addresses)
            if (!address.isLoopback && isLanAddress(address.address)) address,
      ];
      if (addresses.isEmpty) {
        markTestSkipped('No LAN interface on test host');
        return;
      }
      final address = addresses.first;
      final tv = TestTv(host: address.address);
      await tv.start();
      addTearDown(tv.close);
      final session = CastSession(
        tv.device,
        const DownloadSpec(
          url: 'https://example.invalid/video.mp4',
          fileName: 'video.mp4',
        ),
      );
      addTearDown(session.close);
      await session.start(
        title: 'LAN movie',
        position: Duration.zero,
        duration: tv.duration,
      );
      expect(Uri.parse(tv.media).host, address.address);
      expect(InternetAddress(Uri.parse(tv.media).host).isLoopback, isFalse);
    },
  );
}
