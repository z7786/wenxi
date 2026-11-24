import 'package:flutter_test/flutter_test.dart';
import 'package:asterlink/core/json.dart';
import 'package:asterlink/lan/lan_qr.dart';

void main() {
  const device = '11111111111111111111111111111111';
  final address = Uri.parse('http://192.168.1.8:53124');
  final connection = LanConnectionQr(
    address: address,
    deviceId: device,
    code: '001234',
  );

  test(
    'Connection QR preserves the selected address, port and leading zeros',
    () {
      final decoded =
          LanQrTarget.parse(' ${connection.encode()}\n') as LanConnectionQr;
      expect(decoded.address, address);
      expect(decoded.deviceId, device);
      expect(decoded.code, '001234');
    },
  );

  test('Existing browser file QR remains a file invitation', () {
    final url = 'http://10.1.1.9:52381/s/$device';
    final decoded = LanQrTarget.parse(url) as LanShareQr;
    expect(decoded.address.toString(), url);
  });

  test(
    'Shared and link-local IPv4 addresses work in connection and file QR',
    () {
      for (final host in ['100.64.12.5', '100.127.255.254', '169.254.12.5']) {
        final base = Uri(scheme: 'http', host: host, port: 53124);
        final qr = LanConnectionQr(
          address: base,
          deviceId: device,
          code: '001234',
        );
        expect(
          (LanQrTarget.parse(qr.encode()) as LanConnectionQr).address,
          base,
        );
        final url = base.replace(path: '/s/$device');
        expect((LanQrTarget.parse(url.toString()) as LanShareQr).address, url);
      }
    },
  );

  test(
    'Unrelated, ambiguous and malformed QR contents are rejected locally',
    () {
      final valid = Uri.parse(connection.encode());
      for (final value in [
        '',
        '普通消息',
        'https://example.com/s/$device',
        'http://8.8.8.8/s/$device',
        'http://localhost/s/$device',
        'http://name:pass@192.168.1.8/s/$device',
        'http://192.168.1.8/v1/pair',
        'http://192.168.1.8/s/invalid',
        'http://192.168.1.8/s/$device?other=value',
        'http://192.168.1.8/s/$device#other',
        'wenxi://lan/wrong?${valid.query}',
        'wenxi://user@lan/connect?${valid.query}',
        'wenxi://lan:80/connect?${valid.query}',
        '${connection.encode()}&code=654321',
        '${connection.encode()}#extra',
        valid
            .replace(queryParameters: {...valid.queryParameters, 'v': '2'})
            .toString(),
        valid
            .replace(queryParameters: {...valid.queryParameters}..remove('id'))
            .toString(),
        valid
            .replace(
              queryParameters: {...valid.queryParameters, 'id': 'invalid'},
            )
            .toString(),
        valid
            .replace(
              queryParameters: {...valid.queryParameters, 'code': '12345'},
            )
            .toString(),
        valid
            .replace(
              queryParameters: {
                ...valid.queryParameters,
                'address': 'https://192.168.1.8',
              },
            )
            .toString(),
        valid
            .replace(
              queryParameters: {
                ...valid.queryParameters,
                'address': 'http://192.168.1.8/v1/pair',
              },
            )
            .toString(),
        List.filled(2049, 'x').join(),
      ]) {
        expect(
          () => LanQrTarget.parse(value),
          throwsA(isA<AppException>()),
          reason: value,
        );
      }
    },
  );
}
