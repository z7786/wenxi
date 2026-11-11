/// Cheap snapshots for the on-screen display. Reading this must not perform
/// native property calls, network requests or walk the proxy's work queue.
class PlaybackScreenInfo {
  const PlaybackScreenInfo({
    this.transport,
    this.receivedBytes,
    this.bytesPerSecond,
    this.videoCodec,
    this.videoFps,
    this.pixelFormat,
    this.hardwareDecoder,
    this.decoderDroppedFrames,
    this.outputDroppedFrames,
    this.bufferSeconds,
  });

  final String? transport, videoCodec, pixelFormat, hardwareDecoder;
  final int? receivedBytes, decoderDroppedFrames, outputDroppedFrames;
  final double? bytesPerSecond, videoFps, bufferSeconds;

  PlaybackScreenInfo withNetworkSpeed(double? speed) => PlaybackScreenInfo(
    transport: 'download',
    bytesPerSecond: speed,
    videoCodec: videoCodec,
    videoFps: videoFps,
    pixelFormat: pixelFormat,
    hardwareDecoder: hardwareDecoder,
    decoderDroppedFrames: decoderDroppedFrames,
    outputDroppedFrames: outputDroppedFrames,
    bufferSeconds: bufferSeconds,
  );
}
