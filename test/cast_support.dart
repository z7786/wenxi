import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:xml/xml.dart';
import 'package:asterlink/playback/cast/cast_platform.dart';
import 'package:asterlink/playback/cast/dlna.dart';

class TestCastPlatform extends CastPlatform {
  final events = <String>[];
  Future<void>? networkBarrier, activeBarrier;
  @override
  Future<void> network(bool enabled) async {
    events.add('network:$enabled');
    if (enabled) await networkBarrier;
  }

  @override
  Future<void> active(bool enabled) async {
    events.add('active:$enabled');
    if (enabled) await activeBarrier;
  }
}

class TestTv {
  TestTv({this.host = '127.0.0.1'});
  final String host;
  late HttpServer server;
  RawDatagramSocket? ssdp;
  final events = <String>[];
  final requests =
      <({String name, Map<String, String> args, HttpHeaders headers})>[];
  final faults = <String, int>{};
  final barriers = <String, Future<void>>{};
  final _tasks = <Future<void>>{};
  int descriptions = 0;
  String media = '', metadata = '', transport = 'STOPPED';
  String? trackOverride;
  Duration position = Duration.zero, duration = const Duration(minutes: 10);
  double volume = 35;
  bool malformed = false;
  Uri get location => Uri.parse('http://$host:${server.port}/device/root.xml');
  String get description =>
      '<root xmlns="urn:schemas-upnp-org:device-1-0">'
      '<device><deviceType>urn:schemas-upnp-org:device:MediaRenderer:1</deviceType>'
      '<friendlyName>客厅 &amp; 电视</friendlyName><modelName>Test Renderer</modelName>'
      '<UDN>uuid:test-tv</UDN><serviceList>'
      '<service><serviceType>urn:schemas-upnp-org:service:AVTransport:2</serviceType>'
      '<controlURL>../transport</controlURL></service>'
      '<service><serviceType>urn:schemas-upnp-org:service:RenderingControl:1</serviceType>'
      '<controlURL>/render</controlURL></service>'
      '</serviceList></device></root>';
  CastDevice get device => CastDevice.parse(description, location)!;
  Future<void> start() async {
    server = await HttpServer.bind(InternetAddress(host), 0);
    server.listen((request) {
      final task = _handle(request);
      _tasks.add(task);
      unawaited(task.whenComplete(() => _tasks.remove(task)));
    });
  }

  Future<void> startSsdp() async {
    final socket = ssdp = await RawDatagramSocket.bind(
      InternetAddress.loopbackIPv4,
      0,
    );
    socket.writeEventsEnabled = false;
    socket.listen((event) {
      if (event != RawSocketEvent.read) return;
      Datagram? packet;
      while ((packet = socket.receive()) != null) {
        events.add('ssdp:${ascii.decode(packet!.data)}');
        final bytes = ascii.encode(
          'HTTP/1.1 200 OK\r\nLOCATION: $location\r\n'
          'ST: urn:schemas-upnp-org:device:MediaRenderer:1\r\nUSN: uuid:test-tv\r\n\r\n',
        );
        // A TV normally replies to multiple search targets; deduplicate them.
        socket.send(bytes, packet.address, packet.port);
        socket.send(bytes, packet.address, packet.port);
      }
    });
  }

  Future<void> _handle(HttpRequest request) async {
    try {
      if (request.method == 'GET') {
        descriptions++;
        await barriers['description'];
        request.response.write(description);
        return;
      }
      final doc = XmlDocument.parse(await utf8.decoder.bind(request).join());
      final action = doc.descendants
          .whereType<XmlElement>()
          .firstWhere((node) => node.name.local == 'Body')
          .childElements
          .single;
      final name = action.name.local;
      final args = {
        for (final e in action.childElements) e.name.local: e.innerText,
      };
      requests.add((name: name, args: args, headers: request.headers));
      events.add(name);
      if (name == 'SetAVTransportURI') {
        media = args['CurrentURI']!;
        metadata = args['CurrentURIMetaData']!;
        position = Duration.zero;
      }
      await barriers[name];
      if (malformed) {
        request.response.write('invalid xml');
        return;
      }
      final fault = faults[name];
      if (fault != null) {
        request.response.statusCode = 500;
        request.response.write(
          '<s:Envelope xmlns:s="http://schemas.xmlsoap.org/soap/envelope/">'
          '<s:Body><s:Fault><detail><UPnPError xmlns="urn:schemas-upnp-org:control-1-0">'
          '<errorCode>$fault</errorCode><errorDescription>test failure</errorDescription>'
          '</UPnPError></detail></s:Fault></s:Body></s:Envelope>',
        );
        return;
      }
      final result = <String, String>{};
      switch (name) {
        case 'Play':
          transport = 'PLAYING';
        case 'Pause':
          transport = 'PAUSED_PLAYBACK';
        case 'Stop':
          transport = 'STOPPED';
        case 'Seek':
          position = parseCastTime(args['Target'])!;
        case 'SetVolume':
          volume = double.parse(args['DesiredVolume']!);
        case 'GetVolume':
          result['CurrentVolume'] = volume.round().toString();
        case 'GetTransportInfo':
          result.addAll({
            'CurrentTransportState': transport,
            'CurrentTransportStatus': 'OK',
          });
        case 'GetPositionInfo':
          result.addAll({
            'TrackURI': trackOverride ?? media,
            'TrackDuration': castTime(duration),
            'RelTime': castTime(position),
          });
      }
      request.response.headers.contentType = ContentType(
        'text',
        'xml',
        charset: 'utf-8',
      );
      request.response.write(
        '<s:Envelope xmlns:s="http://schemas.xmlsoap.org/soap/envelope/">'
        '<s:Body><u:${name}Response xmlns:u="${action.namespaceUri}">'
        '${result.entries.map((e) => '<${e.key}>${xmlText(e.value)}</${e.key}>').join()}'
        '</u:${name}Response></s:Body></s:Envelope>',
      );
    } finally {
      try {
        await request.response.close();
      } catch (_) {}
    }
  }

  Future<void> close() async {
    ssdp?.close();
    await server.close(force: true);
    await Future.wait(_tasks.toList());
  }
}

Future<void> castEventually(bool Function() condition) async {
  final watch = Stopwatch()..start();
  while (!condition()) {
    if (watch.elapsed > const Duration(seconds: 5)) {
      throw StateError('Casting condition timed out');
    }
    await Future<void>.delayed(const Duration(milliseconds: 5));
  }
}
