// Explicit anonymous preflight: flutter test tool/quark_login_preflight_test.dart.
// Stops before scanning, confirming or exchanging any account credentials.
import 'package:flutter_test/flutter_test.dart';
import 'package:asterlink/data/http.dart';
import 'package:asterlink/data/providers/quark_login.dart';

void main() {
  test(
    'official Quark QR token and unconfirmed polling remain compatible',
    () async {
      final http = DioJsonHttp();
      QuarkQrChallenge? qr;
      try {
        final login = QuarkLoginService(http);
        qr = await login.createQr();
        expect(qr.token.isNotEmpty, isTrue);
        expect(Uri.parse(qr.url).queryParameters['token'] == qr.token, isTrue);
        expect(await login.pollQr(qr), isNull);
        expect(await login.pollQr(qr), isNull);
      } finally {
        qr?.close();
        http.dio.close(force: true);
      }
    },
    timeout: const Timeout(Duration(seconds: 55)),
  );
}
