import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:asterlink/domain/models.dart';
import 'package:asterlink/playback/external_stream.dart';

void main() {
  test(
    'relay streams many chunks and cancels cleanly on peer disconnect without retaining waits',
    () async {
      final origin = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
      addTearDown(origin.close);
      final sockets = <Socket>[];
      final tasks = <Future<void>>[];
      var upstreamClosed = false, sentBytes = 0;
      origin.listen((socket) {
        sockets.add(socket);
        tasks.add(() async {
          final headers = Completer<void>();
          var input = '';
          final sub = socket.listen(
            (bytes) {
              input += latin1.decode(bytes);
              if (!headers.isCompleted && input.contains('\r\n\r\n')) {
                headers.complete();
              }
            },
            onDone: () => upstreamClosed = true,
            onError: (Object _) => upstreamClosed = true,
          );
          try {
            await headers.future;
            const totalChunks = 40000;
            const chunkSize = 1024;
            socket.add(
              ascii.encode(
                'HTTP/1.1 200 OK\r\n'
                'Content-Type: video/mp4\r\n'
                'Content-Length: ${totalChunks * chunkSize}\r\n'
                'Connection: close\r\n\r\n',
              ),
            );
            final chunk = List<int>.filled(chunkSize, 42);
            for (var i = 0; i < totalChunks && !upstreamClosed; i++) {
              socket.add(chunk);
              sentBytes += chunkSize;
              if (i % 16 == 0) {
                await socket.flush();
                await Future<void>.delayed(const Duration(milliseconds: 1));
              }
            }
          } catch (_) {
            upstreamClosed = true;
          } finally {
            await sub.cancel();
            socket.destroy();
          }
        }());
      });
      addTearDown(() async {
        for (final s in sockets) {
          s.destroy();
        }
        await Future.wait(tasks);
      });

      final stream = ExternalPlaybackStream(
        DownloadSpec(
          url: 'http://127.0.0.1:${origin.port}/many-chunks.mp4',
          fileName: 'many-chunks.mp4',
        ),
      );
      addTearDown(stream.close);
      await stream.start();
      final uri = Uri.parse(stream.url);
      final peer = await Socket.connect(uri.host, uri.port);
      final done = Completer<void>();
      var received = 0;
      peer.listen(
        (bytes) {
          received += bytes.length;
          if (received >= 256 * 1024 && !done.isCompleted) {
            peer.destroy();
            done.complete();
          }
        },
        onDone: () {
          if (!done.isCompleted) done.complete();
        },
        onError: (Object _) {
          if (!done.isCompleted) done.complete();
        },
      );
      peer.write('GET ${uri.path} HTTP/1.1\r\nHost: ${uri.host}\r\n\r\n');
      await peer.flush();
      await done.future.timeout(const Duration(seconds: 5));
      await Future.wait(tasks).timeout(const Duration(seconds: 3));
      expect(received, greaterThanOrEqualTo(256 * 1024));
      expect(upstreamClosed, isTrue);
      expect(sentBytes, lessThan(40000 * 1024));
      await stream.close().timeout(const Duration(seconds: 3));
    },
  );

  test(
    'relay cancels immediately when peer disconnects while waiting for slow upstream headers',
    () async {
      final origin = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
      addTearDown(origin.close);
      final sockets = <Socket>[];
      final tasks = <Future<void>>[];
      final requestArrived = Completer<void>();
      final upstreamClosed = Completer<void>();
      origin.listen((socket) {
        sockets.add(socket);
        tasks.add(() async {
          var input = '';
          final sub = socket.listen(
            (bytes) {
              input += latin1.decode(bytes);
              if (!requestArrived.isCompleted && input.contains('\r\n\r\n')) {
                requestArrived.complete();
              }
            },
            onDone: () {
              if (!upstreamClosed.isCompleted) upstreamClosed.complete();
            },
            onError: (Object _) {
              if (!upstreamClosed.isCompleted) upstreamClosed.complete();
            },
          );
          try {
            await upstreamClosed.future;
          } finally {
            await sub.cancel();
            socket.destroy();
          }
        }());
      });
      addTearDown(() async {
        if (!upstreamClosed.isCompleted) upstreamClosed.complete();
        for (final s in sockets) {
          s.destroy();
        }
        await Future.wait(tasks);
      });
      final stream = ExternalPlaybackStream(
        DownloadSpec(
          url: 'http://127.0.0.1:${origin.port}/slow.mp4',
          fileName: 'slow.mp4',
        ),
      );
      addTearDown(stream.close);
      await stream.start();
      final uri = Uri.parse(stream.url);
      final peer = await Socket.connect(uri.host, uri.port);
      peer.write('GET ${uri.path} HTTP/1.1\r\nHost: ${uri.host}\r\n\r\n');
      await peer.flush();
      await requestArrived.future.timeout(const Duration(seconds: 3));
      peer.destroy();
      await upstreamClosed.future.timeout(const Duration(seconds: 2));
      await Future.wait(tasks).timeout(const Duration(seconds: 2));
      await stream.close().timeout(const Duration(seconds: 2));
    },
  );
}
