import 'dart:async';
import 'dart:math' as math;
import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:flutter_markdown_plus/flutter_markdown_plus.dart';
import 'package:markdown/markdown.dart' as md;
import '../domain/remote_control.dart';
import 'common.dart';
import 'remote_links.dart';

class AnnouncementMarkdown extends StatelessWidget {
  const AnnouncementMarkdown(
    this.content, {
    super.key,
    this.linkLauncher,
    this.imageWidth,
  });
  final String content;
  final RemoteLinkLauncher? linkLauncher;
  // Dialogs measure intrinsic height; avoid a LayoutBuilder in that subtree.
  final double? imageWidth;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final body = theme.textTheme.bodyMedium!.copyWith(
      fontSize: 15,
      height: 1.8,
      color: theme.colorScheme.onSurface,
    );
    TextStyle heading(double size) => body.copyWith(
      fontSize: size,
      height: 1.45,
      fontWeight: FontWeight.w600,
    );
    Widget markdown(double width) => MarkdownBody(
      data: content,
      selectable: true,
      softLineBreak: true,
      extensionSet: md.ExtensionSet.gitHubFlavored,
      styleSheet: MarkdownStyleSheet.fromTheme(theme).copyWith(
        p: body,
        h1: heading(24),
        h2: heading(21),
        h3: heading(18),
        h4: heading(16),
        h5: heading(15),
        h6: heading(15),
        h1Padding: const EdgeInsets.only(top: 10, bottom: 4),
        h2Padding: const EdgeInsets.only(top: 8, bottom: 2),
        h3Padding: const EdgeInsets.only(top: 6),
        a: TextStyle(
          color: theme.colorScheme.primary,
          decoration: TextDecoration.underline,
          decorationColor: theme.colorScheme.primary.withValues(alpha: .4),
        ),
        blockSpacing: 14,
        listIndent: 24,
        listBullet: body,
        blockquote: body.copyWith(color: theme.colorScheme.onSurfaceVariant),
        blockquotePadding: const EdgeInsets.fromLTRB(16, 12, 14, 12),
        blockquoteDecoration: BoxDecoration(
          color: fill(context),
          border: Border(
            left: BorderSide(color: themeAccent(context), width: 3),
          ),
        ),
        code: body.copyWith(
          fontFamily: 'monospace',
          fontSize: 13,
          height: 1.65,
          backgroundColor: fill(context),
        ),
        codeblockPadding: const EdgeInsets.all(14),
        codeblockDecoration: BoxDecoration(
          color: fill(context),
          borderRadius: BorderRadius.circular(10),
        ),
        horizontalRuleDecoration: BoxDecoration(
          border: Border(top: BorderSide(color: border(context))),
        ),
        tableHead: body.copyWith(fontWeight: FontWeight.w600),
        tableBody: body,
        tableColumnWidth: const IntrinsicColumnWidth(),
        tableCellsPadding: const EdgeInsets.symmetric(
          horizontal: 12,
          vertical: 8,
        ),
        tableBorder: TableBorder.all(color: border(context)),
        tableHeadCellsDecoration: BoxDecoration(color: fill(context)),
        textScaler: MediaQuery.textScalerOf(context),
      ),
      onTapLink: (_, href, _) {
        Uri? url;
        try {
          url = httpsUri(href ?? '');
        } on FormatException {
          message(context, '公告链接仅支持有效的 HTTPS 地址');
          return;
        }
        unawaited(openRemoteLink(context, url, launcher: linkLauncher));
      },
      // Override the package's file/asset image support for remote notices.
      // These requests are independent of all cloud-account sessions.
      imageBuilder: (uri, title, alt) => _AnnouncementImage(
        uri: uri,
        alt: alt ?? title ?? '',
        width: math.min(width, 752),
      ),
    );
    if (imageWidth case final width?) return markdown(width);
    return LayoutBuilder(
      builder: (context, constraints) => markdown(constraints.maxWidth),
    );
  }
}

class _AnnouncementImage extends StatelessWidget {
  const _AnnouncementImage({
    required this.uri,
    required this.alt,
    required this.width,
  });
  final Uri uri;
  final String alt;
  final double width;

  @override
  Widget build(BuildContext context) {
    Uri safe;
    try {
      safe = httpsUri(uri.toString());
    } on FormatException {
      return _fallback(context, '仅支持 HTTPS 图片');
    }
    return ClipRRect(
      borderRadius: BorderRadius.circular(10),
      child: ConstrainedBox(
        constraints: BoxConstraints(maxWidth: width, maxHeight: 420),
        child: Image.network(
          safe.toString(),
          width: width,
          fit: BoxFit.contain,
          semanticLabel: alt.isEmpty ? '公告图片' : alt,
          cacheWidth: math
              .min(width * MediaQuery.devicePixelRatioOf(context), 1600)
              .round(),
          frameBuilder: (context, child, frame, synchronous) =>
              synchronous || frame != null
              ? child
              : _fallback(context, '图片加载中'),
          errorBuilder: (context, _, _) => _fallback(context, '图片暂时无法加载'),
        ),
      ),
    );
  }

  Widget _fallback(BuildContext context, String label) => Container(
    width: width,
    constraints: const BoxConstraints(minHeight: 112),
    padding: const EdgeInsets.all(18),
    decoration: BoxDecoration(
      color: fill(context),
      borderRadius: BorderRadius.circular(10),
    ),
    child: Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(CupertinoIcons.photo, size: 25, color: secondary(context)),
        const SizedBox(height: 8),
        Text(
          label,
          textAlign: TextAlign.center,
          style: TextStyle(fontSize: 13, color: secondary(context)),
        ),
        if (alt.trim().isNotEmpty) ...[
          const SizedBox(height: 4),
          Text(
            alt.trim(),
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
            textAlign: TextAlign.center,
            style: TextStyle(fontSize: 12, color: secondary(context)),
          ),
        ],
      ],
    ),
  );
}
