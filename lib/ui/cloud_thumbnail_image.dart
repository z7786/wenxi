import 'dart:async';
import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' as ui;
import 'package:flutter/foundation.dart';
import 'package:flutter/painting.dart';
import '../domain/models.dart';

/// Account-bound image cache keys and bounded reads for protected thumbnails.
/// Cookies are sent only to the provider's exact HTTPS thumbnail endpoint.
class CloudThumbnailImage extends ImageProvider<CloudThumbnailImage> {
  CloudThumbnailImage(this.uri, this.platform, Credential credential)
    : _cookie = credential.primary,
      _revision = credential.updatedAt;

  final Uri uri;
  final CloudPlatform platform;
  final String _cookie;
  final int _revision;
  static const maxBytes = 2 * 1024 * 1024;

  static bool requiresAccount(Uri uri, CloudPlatform platform) {
    final host = switch (platform) {
      CloudPlatform.quark => 'drive-pc.quark.cn',
      CloudPlatform.uc => 'pc-api.uc.cn',
      _ => '',
    };
    return host.isNotEmpty &&
        uri.scheme == 'https' &&
        uri.host == host &&
        uri.port == 443 &&
        uri.userInfo.isEmpty &&
        {
          '/1/clouddrive/file/thumbnail',
          '/1/clouddrive/file/preview',
          '/1/clouddrive/file/video/thumbnail',
        }.contains(uri.path);
  }

  static HttpClient? _sharedClient;

  static HttpClient _pooledClient() => _sharedClient ??= HttpClient()
    ..connectionTimeout = const Duration(seconds: 12)
    ..maxConnectionsPerHost = 6
    ..idleTimeout = const Duration(seconds: 15);

  Future<Uint8List> loadBytes({HttpClient? client}) async {
    if (!requiresAccount(uri, platform) || _cookie.isEmpty) {
      throw const HttpException('缩略图来源或账号无效');
    }
    final ownsClient = client != null || HttpOverrides.current != null;
    final transport =
        client ??
        (HttpOverrides.current != null ? HttpClient() : _pooledClient());
    if (ownsClient) {
      transport.connectionTimeout = const Duration(seconds: 12);
    }
    var target = uri;
    var authenticated = true;
    try {
      for (var redirects = 0; redirects <= 5; redirects++) {
        final request = await transport.getUrl(target);
        request.followRedirects = false;
        request.headers.set('User-Agent', 'Mozilla/5.0');
        request.headers.set(
          'Referer',
          platform == CloudPlatform.quark
              ? 'https://pan.quark.cn/'
              : 'https://drive.uc.cn/',
        );
        if (authenticated && requiresAccount(target, platform)) {
          request.headers.set('Cookie', _cookie);
        }
        final response = await request.close().timeout(
          const Duration(seconds: 15),
        );
        if ({301, 302, 303, 307, 308}.contains(response.statusCode)) {
          final location = response.headers.value(HttpHeaders.locationHeader);
          await response.listen((_) {}).cancel();
          final next = location == null ? null : target.resolve(location);
          if (next == null ||
              next.scheme != 'https' ||
              next.host.isEmpty ||
              next.userInfo.isNotEmpty ||
              redirects == 5) {
            throw const HttpException('缩略图重定向无效');
          }
          if (next.origin != target.origin) authenticated = false;
          target = next;
          continue;
        }
        if (response.statusCode != 200 && response.statusCode != 206) {
          await response.listen((_) {}).cancel();
          throw HttpException('缩略图读取失败（HTTP ${response.statusCode}）');
        }
        if (response.contentLength > maxBytes) {
          await response.listen((_) {}).cancel();
          throw const HttpException('缩略图过大');
        }
        final bytes = BytesBuilder(copy: false);
        await for (final chunk in response.timeout(
          const Duration(seconds: 15),
        )) {
          if (bytes.length + chunk.length > maxBytes) {
            throw const HttpException('缩略图过大');
          }
          bytes.add(chunk);
        }
        if (bytes.isEmpty) throw const HttpException('缩略图为空');
        return bytes.takeBytes();
      }
      throw const HttpException('缩略图重定向过多');
    } finally {
      if (ownsClient) transport.close(force: true);
    }
  }

  @override
  Future<CloudThumbnailImage> obtainKey(ImageConfiguration configuration) =>
      SynchronousFuture(this);

  @override
  ImageStreamCompleter loadImage(
    CloudThumbnailImage key,
    ImageDecoderCallback decode,
  ) {
    Future<ui.Codec> load() async {
      try {
        return await decode(
          await ui.ImmutableBuffer.fromUint8List(await key.loadBytes()),
        );
      } catch (error, stack) {
        scheduleMicrotask(() => PaintingBinding.instance.imageCache.evict(key));
        Error.throwWithStackTrace(
          HttpException('缩略图读取失败（${error.runtimeType}）'),
          stack,
        );
      }
    }

    return MultiFrameImageStreamCompleter(
      codec: load(),
      scale: 1,
      debugLabel: '${platform.key} thumbnail',
    );
  }

  @override
  bool operator ==(Object other) =>
      other is CloudThumbnailImage &&
      uri == other.uri &&
      platform == other.platform &&
      _revision == other._revision &&
      _cookie == other._cookie;
  @override
  int get hashCode => Object.hash(uri, platform, _revision, _cookie);
  @override
  String toString() => 'CloudThumbnailImage(${platform.key})';
}
