import 'package:html/parser.dart' as html;

final _htmlEntity = RegExp(
  r'&(?:#[0-9]+|#[xX][0-9a-fA-F]+|[A-Za-z][A-Za-z0-9]*);',
);

/// Decode complete character references once, preserving literal markup and
/// ordinary ampersands. This is for display; file operations retain the raw name.
String unescapeDisplayName(String name) =>
    name.replaceAllMapped(_htmlEntity, (match) {
      final reference = match[0]!;
      final parser = html.HtmlParser(reference);
      final fragment = parser.parseFragment();
      // Unknown references can share a prefix with a valid HTML entity.
      // Keep these and invalid code points intact instead of decoding a prefix.
      return parser.errors.isEmpty ? fragment.text ?? reference : reference;
    });
