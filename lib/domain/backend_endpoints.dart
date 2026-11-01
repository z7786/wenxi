/// The parser service now shares the search backend's domain and identity.
/// Exact legacy addresses can survive in cached remote configuration files.
abstract final class BackendEndpoints {
  static const search = 'https://pan.dr7786.top';
  static const parser = search;
  static const legacyParser = 'http://39.102.115.36:5173';

  static String parserUrl(String value) {
    final clean = value.trim();
    final uri = Uri.tryParse(clean);
    if (uri != null &&
        uri.scheme == 'http' &&
        uri.host == '39.102.115.36' &&
        uri.port == 5173 &&
        uri.userInfo.isEmpty &&
        uri.query.isEmpty &&
        uri.fragment.isEmpty &&
        (uri.path.isEmpty || uri.path == '/')) {
      return parser;
    }
    return clean;
  }
}
