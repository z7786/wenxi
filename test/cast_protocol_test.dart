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

class _SeekRetryClient extends DlnaClient {
  int seeks = 0;
  @override
  Future<Map<String, String>> transport(
    CastDevice device,
    String actionName, [
    Map<String, String> args = const {},
  ]) async {
    if (actionName == 'Seek') {
      seeks++;
      throw CastSoapException('fixture seek failure', seeks == 1 ? 701 : 710);
    }
    return super.transport(device, actionName, args);
  }
}

void main() {
  test(
    'cast endpoints accept local IPv6 and CGNAT while rejecting public and credential URLs',
    () {
      for (final host in [
        '::1',
        'fd12::8',
        'fe80::8',
        '100.64.0.8',
        '100.127.255.8',
      ]) {
        expect(
          castEndpoint(Uri(scheme: 'http', host: host, path: '/device.xml')),
          isTrue,
        );
      }
      for (final host in ['2001:4860:4860::8888', '8.8.8.8', '100.128.0.8']) {
        expect(
          castEndpoint(Uri(scheme: 'http', host: host, path: '/device.xml')),
          isFalse,
        );
      }
      expect(castEndpoint(Uri.parse('http://secret@192.168.1.8/')), isFalse);
    },
  );
  Future<CastSession> sessionFor(
    TestTv tv, {
    Duration position = Duration.zero,
    bool playing = true,
    Duration connectionGrace = const Duration(seconds: 45),
  }) async {
    final session = CastSession(
      tv.device,
      const DownloadSpec(
        url: 'https://example.invalid/video.mp4',
        fileName: 'movie.mp4',
        expectedSize: 1024,
      ),
      platform: TestCastPlatform(),
      prepareSource: false,
      pollInterval: const Duration(days: 1),
      connectionGrace: connectionGrace,
      seekConfirmationTimeout: Duration.zero,
    );
    addTearDown(session.close);
    await session.start(
      title: 'movie',
      position: position,
      duration: tv.duration,
      playWhenReady: playing,
    );
    await session.refresh();
    return session;
  }

  test(
    'mid-film stopped/empty media zero does not erase progress, deliberate seek zero does',
    () async {
      final tv = TestTv();
      await tv.start();
      addTearDown(tv.close);
      final session = await sessionFor(tv);
      tv.position = const Duration(seconds: 173);
      await session.refresh();
      for (final status in ['STOPPED', 'NO_MEDIA_PRESENT', 'TRANSITIONING']) {
        tv.transport = status;
        tv.position = Duration.zero;
        await session.refresh();
        expect(session.bookmarkState.position, const Duration(seconds: 173));
        expect(session.state.completed, isFalse);
      }
      await session.seek(Duration.zero);
      tv.transport = 'PLAYING';
      await session.refresh();
      expect(session.bookmarkState.position, Duration.zero);
    },
  );

  test(
    'TV clock reset near completion supports NO_MEDIA_PRESENT and a missed poll',
    () async {
      final tv = TestTv();
      await tv.start();
      addTearDown(tv.close);
      final session = await sessionFor(tv);
      tv.position = tv.duration - const Duration(seconds: 7);
      await session.refresh();
      tv.transport = 'NO_MEDIA_PRESENT';
      tv.position = Duration.zero;
      await session.refresh();
      expect(session.state.completed, isTrue);
      expect(session.playWhenReady, isTrue);
      expect(session.bookmarkState.position, tv.duration);
    },
  );

  test(
    'paused handoff retries temporary 701 and does not lose paused intent',
    () async {
      final tv = TestTv();
      await tv.start();
      addTearDown(tv.close);
      tv.faultSequences['Pause'] = [701, 0];
      final session = await sessionFor(
        tv,
        position: const Duration(seconds: 42),
        playing: false,
      );
      expect(session.connected, isTrue);
      expect(tv.events.where((e) => e == 'Pause'), hasLength(2));
      expect(session.state.playing, isFalse);
      expect(session.bookmarkState.position, const Duration(seconds: 42));
    },
  );

  test(
    'ignored Seek retries once and preserves original bookmark while showing actual position',
    () async {
      final tv = TestTv();
      await tv.start();
      addTearDown(tv.close);
      tv.ignoreSeek = true;
      final session = await sessionFor(
        tv,
        position: const Duration(seconds: 173),
      );
      await session.refresh();
      await session.refresh();
      expect(tv.events.where((e) => e == 'Seek'), hasLength(2));
      expect(session.warning, contains('原进度已保留'));
      expect(session.state.position, Duration.zero);
      expect(session.bookmarkState.position, const Duration(seconds: 173));
      tv.position = const Duration(seconds: 180);
      await session.refresh();
      expect(session.bookmarkState.position, tv.position);
    },
  );

  test(
    'Seek fault other than 701 keeps a working TV session and original bookmark',
    () async {
      final tv = TestTv();
      await tv.start();
      addTearDown(tv.close);
      tv.faults['Seek'] = 501;
      final session = await sessionFor(
        tv,
        position: const Duration(seconds: 173),
      );
      expect(session.connected, isTrue);
      expect(session.state.position, Duration.zero);
      expect(session.bookmarkState.position, const Duration(seconds: 173));
      expect(session.warning, contains('原进度已保留'));
    },
  );

  test(
    'TV query/fragment rewrite preserves transport ownership but different path does not',
    () async {
      final tv = TestTv();
      await tv.start();
      addTearDown(tv.close);
      final session = await sessionFor(tv);
      tv.trackOverride = '${tv.media}?tv=probe#play';
      await session.refresh();
      expect(session.transportReplaced, isFalse);
      tv.trackOverride = '${tv.media}/other';
      await session.refresh();
      expect(session.transportReplaced, isTrue);
    },
  );

  test(
    'repeated SOAP 501 degrades telemetry without disabling working TV controls',
    () async {
      final tv = TestTv();
      await tv.start();
      addTearDown(tv.close);
      final session = await sessionFor(tv);
      tv.faults['GetTransportInfo'] = 501;
      for (var i = 0; i < 4; i++) {
        await session.refresh();
      }
      expect(session.connectionLost, isFalse);
      expect(session.warning, contains('回传播放状态'));
      await session.pause();
      expect(tv.transport, 'PAUSED_PLAYBACK');
      await session.play();
      expect(tv.transport, 'PLAYING');
    },
  );

  test(
    'real poll failures eventually abandon the session and preserve its bookmark',
    () async {
      final tv = TestTv();
      await tv.start();
      addTearDown(tv.close);
      final session = await sessionFor(tv, connectionGrace: Duration.zero);
      tv.position = const Duration(seconds: 173);
      await session.refresh();
      tv.malformed = true;
      for (var i = 0; i < 3; i++) {
        await session.refresh();
      }
      expect(session.connectionAbandoned, isTrue);
      expect(session.bookmarkState.position, const Duration(seconds: 173));
      expect(session.error, contains('投屏已结束'));
    },
  );
  test(
    'manual television description works without multicast discovery',
    () async {
      final tv = TestTv();
      await tv.start();
      addTearDown(tv.close);
      final discovery = CastDiscovery();
      addTearDown(discovery.dispose);
      final device = await discovery.addAddress(tv.location.toString());
      expect(device.name, '客厅 & 电视');
      expect(discovery.devices.single.id, device.id);
      expect(tv.descriptions, 1);
    },
  );
  test(
    'manual IP connection discovers a television with unicast SSDP',
    () async {
      final tv = TestTv();
      await tv.start();
      await tv.startSsdp();
      addTearDown(tv.close);
      final discovery = CastDiscovery();
      addTearDown(discovery.dispose);
      await discovery.addAddress('127.0.0.1:${tv.ssdp!.port}');
      expect(discovery.devices.single.description, tv.location);
      expect(tv.descriptions, 1);
      expect(tv.events.any((e) => e.startsWith('ssdp:M-SEARCH')), isTrue);
    },
  );
  test(
    'manual connection rejects non-LAN input and closes pending requests',
    () async {
      final discovery = CastDiscovery();
      for (final address in [
        'https://example.com/root.xml',
        'http://user@192.168.1.8/root.xml',
        'file:///root.xml',
        'http://8.8.8.8/root.xml',
      ]) {
        await expectLater(
          discovery.addAddress(address),
          throwsA(isA<AppException>()),
        );
      }
      final tv = TestTv();
      await tv.start();
      final barrier = Completer<void>();
      tv.barriers['description'] = barrier.future;
      final pending = discovery.addAddress(tv.location.toString());
      final failed = expectLater(pending, throwsA(isA<AppException>()));
      await castEventually(() => tv.descriptions > 0);
      discovery.dispose();
      await failed.timeout(const Duration(seconds: 2));
      expect(discovery.devices, isEmpty);
      barrier.complete();
      await tv.close();
    },
  );
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
        size: 123456,
      );
      expect(tv.media, url);
      final metadata = XmlDocument.parse(tv.metadata);
      String value(String name) => metadata.descendants
          .whereType<XmlElement>()
          .firstWhere((e) => e.name.local == name)
          .innerText;
      expect(value('title'), '电影 <第一集> & "4K"');
      expect(value('res'), url);
      final resource = metadata.descendants.whereType<XmlElement>().firstWhere(
        (e) => e.name.local == 'res',
      );
      expect(resource.getAttribute('size'), '123456');
      expect(resource.getAttribute('protocolInfo'), contains('DLNA.ORG_OP=01'));
      expect(tv.requests.single.headers.value('transfer-encoding'), isNull);
      expect(tv.requests.single.headers.contentLength, greaterThan(0));
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
        prepareSource: false,
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
    'unsupported Seek after the TV readiness retry disables further seek controls',
    () async {
      final tv = TestTv();
      await tv.start();
      addTearDown(tv.close);
      final client = _SeekRetryClient();
      final session = CastSession(
        tv.device,
        const DownloadSpec(
          url: 'https://example.invalid/video.mp4',
          fileName: 'movie.mp4',
        ),
        client: client,
        platform: TestCastPlatform(),
        prepareSource: false,
        pollInterval: const Duration(days: 1),
      );
      addTearDown(session.close);
      await session.start(
        title: 'Movie',
        position: const Duration(seconds: 40),
        duration: tv.duration,
      );
      expect(client.seeks, 2);
      expect(session.connected, isTrue);
      expect(session.seekSupported, isFalse);
      expect(session.warning, contains('不支持拖动进度'));
      expect(session.state.position, Duration.zero);
      await expectLater(
        session.seek(const Duration(seconds: 20)),
        throwsA(isA<AppException>()),
      );
      expect(client.seeks, 2);
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
        prepareSource: false,
        pollInterval: const Duration(days: 1),
        platform: TestCastPlatform(),
      );
      addTearDown(session.close);
      await session.start(
        title: 'Movie',
        position: Duration.zero,
        duration: tv.duration,
      );
      await castEventually(() => session.volumeSupported);
      tv.malformed = true;
      for (var i = 0; i < 3; i++) {
        await session.refresh();
      }
      expect(session.error, contains('连接中断'));
      expect(session.connectionLost, isTrue);
      expect(session.playWhenReady, isTrue);
      tv.malformed = false;
      await session.refresh();
      expect(session.error, isEmpty);
      expect(session.connectionLost, isFalse);
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
        prepareSource: false,
        platform: TestCastPlatform(),
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
