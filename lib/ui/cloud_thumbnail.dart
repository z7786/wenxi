import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import '../domain/models.dart';
import 'common.dart';
import 'cloud_thumbnail_image.dart';

/// Provider previews use memory caching and narrowly scoped authentication.
class CloudThumbnail extends StatelessWidget {
  const CloudThumbnail(
    this.file,
    this.platform, {
    super.key,
    this.width = 44,
    this.height = 44,
    this.large = false,
    this.credential,
  });

  final CloudFile file;
  final CloudPlatform platform;
  final double width, height;
  final bool large;
  final Credential? credential;

  @override
  Widget build(BuildContext context) {
    final kind = fileKind(file.name, directory: file.isDirectory);
    final media =
        kind == FileKind.image ||
        kind == FileKind.video ||
        !file.isDirectory &&
            {
              'heic',
              'heif',
              'tif',
              'tiff',
            }.contains(file.name.split('.').last.toLowerCase());
    final raw = file.thumbnailUrl.trim();
    final uri = Uri.tryParse(raw.startsWith('//') ? 'https:$raw' : raw);
    final valid =
        media &&
        uri != null &&
        uri.host.isNotEmpty &&
        uri.userInfo.isEmpty &&
        {'http', 'https'}.contains(uri.scheme);
    final placeholder = ColoredBox(
      color: fill(context),
      child: Center(
        child: FileGlyph(
          file.name,
          directory: file.isDirectory,
          size: large ? 52 : 28,
        ),
      ),
    );
    final referer = switch (platform) {
      CloudPlatform.webdav => '',
      CloudPlatform.github => '',
      CloudPlatform.pikpak => 'https://mypikpak.com/',
      CloudPlatform.feijipan => 'https://www.feijipan.com/',
      CloudPlatform.ctfile => 'https://www.ctfile.com/',
      CloudPlatform.pan115 => 'https://115.com/',
      CloudPlatform.baidu => 'https://pan.baidu.com/',
      CloudPlatform.quark => 'https://pan.quark.cn/',
      CloudPlatform.uc => 'https://drive.uc.cn/',
      CloudPlatform.xunlei => 'https://pan.xunlei.com/',
      CloudPlatform.pan123 => 'https://www.123pan.com/',
      CloudPlatform.guangya => 'https://www.guangyapan.com/',
      CloudPlatform.aliyun => 'https://www.alipan.com/',
      CloudPlatform.c139 => 'https://yun.139.com/',
      CloudPlatform.tianyi => 'https://cloud.189.cn/',
      CloudPlatform.lanzou => '',
      CloudPlatform.ilanzou => 'https://www.ilanzou.com/',
      CloudPlatform.weiyun => 'https://www.weiyun.com/',
      CloudPlatform.wopan => 'https://pan.wo.cn/',
    };
    final ratio = MediaQuery.devicePixelRatioOf(context);
    return ExcludeSemantics(
      child: ClipRRect(
        borderRadius: BorderRadius.circular(large ? 10 : 8),
        child: SizedBox(
          width: width,
          height: height,
          child: Stack(
            fit: StackFit.expand,
            children: [
              if (valid)
                Image(
                  image: ResizeImage(
                    credential != null &&
                            CloudThumbnailImage.requiresAccount(uri, platform)
                        ? CloudThumbnailImage(uri, platform, credential!)
                        : NetworkImage(
                            uri.toString(),
                            headers: {
                              'User-Agent': 'Mozilla/5.0',
                              if (referer.isNotEmpty) 'Referer': referer,
                            },
                          ),
                    width: (width * ratio).ceil().clamp(44, 640),
                    height: (height * ratio).ceil().clamp(44, 640),
                    policy: ResizeImagePolicy.fit,
                  ),
                  fit: BoxFit.cover,
                  filterQuality: FilterQuality.low,
                  frameBuilder: (_, child, frame, synchronous) =>
                      synchronous || frame != null ? child : placeholder,
                  errorBuilder: (_, _, _) => placeholder,
                )
              else
                placeholder,
              if (kind == FileKind.video)
                Positioned(
                  right: large ? 7 : 3,
                  bottom: large ? 7 : 3,
                  child: Container(
                    padding: EdgeInsets.all(large ? 5 : 3),
                    decoration: BoxDecoration(
                      color: Colors.black.withValues(alpha: .5),
                      borderRadius: BorderRadius.circular(6),
                    ),
                    child: Icon(
                      CupertinoIcons.play_fill,
                      color: Colors.white,
                      size: large ? 12 : 8,
                    ),
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }
}
