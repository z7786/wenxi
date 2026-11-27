import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:asterlink/platform/native_engine.dart';
import 'package:asterlink/platform/executable_path.dart';

class _EarlyReplyProcess extends Fake implements Process {
  final output = StreamController<List<int>>();
  final exited = Completer<int>();
  late final sink = _DelayedFlushSink(this);
  int closeRequests = 0;
  bool killed = false;

  @override
  Stream<List<int>> get stdout => output.stream;
  @override
  Stream<List<int>> get stderr => const Stream.empty();
  @override
  IOSink get stdin => sink;
  @override
  Future<int> get exitCode => exited.future;
  @override
  bool kill([ProcessSignal signal = ProcessSignal.sigterm]) {
    killed = true;
    if (!exited.isCompleted) exited.complete(0);
    unawaited(output.close());
    return true;
  }

  void respond(Object? line) {
    final frame = jsonDecode('$line') as Map<String, dynamic>;
    if (frame['method'] == 'close') {
      closeRequests++;
      sink.hold = true;
    }
    output.add(utf8.encode('${jsonEncode({'seq': frame['seq']})}\n'));
  }
}

class _DelayedFlushSink extends Fake implements IOSink {
  _DelayedFlushSink(this.process);
  final _EarlyReplyProcess process;
  final entered = Completer<void>(), resume = Completer<void>();
  bool hold = false, flushing = false, closed = false;

  @override
  void writeln([Object? object = '']) => process.respond(object);
  @override
  Future<void> flush() async {
    if (hold) {
      flushing = true;
      entered.complete();
      await resume.future;
      flushing = false;
    }
  }

  @override
  Future<void> close() async {
    if (flushing) throw StateError('StreamSink is bound to a stream');
    closed = true;
  }
}

void main() {
  test(
    'creating and closing an unused helper does not resolve its path',
    () async {
      var reads = 0;
      final transport = DesktopGopeedTransport.lazy(
        executable: () {
          reads++;
          throw StateError('path missing');
        },
      );
      expect(reads, 0);
      expect(transport.connected, isFalse);
      await transport.dispose();
      expect(reads, 0);
    },
  );

  test(
    'a failed path resolution can retry without recreating services',
    () async {
      var reads = 0;
      final process = _EarlyReplyProcess();
      final transport = DesktopGopeedTransport.lazy(
        executable: () {
          if (++reads == 1) throw StateError('temporary path failure');
          return applicationExecutablePath();
        },
        launchProcess: (_) async => process,
      );
      await expectLater(transport.call('open'), throwsStateError);
      expect(transport.connected, isFalse);
      await transport.call('open');
      expect(transport.connected, isTrue);
      expect(reads, 2);
      expect(transport.executable, applicationExecutablePath());
      expect(reads, 2);
      final closing = transport.dispose();
      await process.sink.entered.future;
      process.sink.resume.complete();
      await closing;
      expect(process.killed, isTrue);
    },
  );

  test(
    'Helper disposal drains a flush after an early reply and closes only once',
    () async {
      final process = _EarlyReplyProcess();
      final transport = DesktopGopeedTransport(
        executable: Platform.resolvedExecutable,
        launchProcess: (_) async => process,
      );
      await transport.call('open');
      final closing = transport.dispose();
      final duplicate = transport.dispose();
      expect(identical(closing, duplicate), isTrue);
      await process.sink.entered.future;
      await Future<void>.delayed(Duration.zero);
      expect(process.sink.closed, isFalse);
      expect(process.killed, isFalse);
      process.sink.resume.complete();
      await closing;
      await duplicate;
      expect(process.closeRequests, 1);
      expect(process.sink.closed, isTrue);
      expect(process.killed, isTrue);
      expect(transport.connected, isFalse);
    },
  );
}
