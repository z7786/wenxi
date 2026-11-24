// Run with flutter test tool/login_web_scripts_test.dart; Node.js is required.
import 'dart:convert';
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:asterlink/domain/aliyun_web_password.dart';
import 'package:asterlink/domain/auth.dart';
import 'package:asterlink/domain/models.dart';
import 'package:asterlink/domain/weiyun_web_login.dart';
import 'package:asterlink/domain/tianyi_web_login.dart';
import 'package:asterlink/ui/login_webview.dart';

void main() {
  test(
    'Production browser scripts pass the isolated JavaScript regressions',
    () async {
      final directory = await Directory.systemTemp.createTemp(
        'asterlink-login-scripts-',
      );
      final attempt = AliyunWebPassword('fixture-user', ' fixture-password ');
      try {
        final fixture = File('${directory.path}/scripts.json');
        await fixture.writeAsString(
          jsonEncode({
            'id': attempt.id,
            'bootstrap': attempt.bootstrapScript,
            'status': attempt.statusScript,
            'submission': attempt.takeSubmissionScript(),
            'viewport': desktopLoginViewportScript,
            'weiyun': {
              'bootstrap': WeiyunWebLogin.bootstrapScript,
              'read': WeiyunWebLogin.readScript,
            },
            'tianyi': {
              'bootstrap': TianyiWebLogin.bootstrapScript,
              'read': TianyiWebLogin.readScript,
              'form': TianyiWebLogin.formScript,
            },
            for (final platform in [
              CloudPlatform.ilanzou,
              CloudPlatform.wopan,
              CloudPlatform.xunlei,
              CloudPlatform.pikpak,
            ])
              platform.name: {
                'read': WebLoginTarget.targets[platform]!.readStorageScript,
                'clear': WebLoginTarget.targets[platform]!.clearStorageScript,
                'prepare': WebLoginTarget.targets[platform]!
                    .prepareStorageScript('fixture-login-session'),
                'nextSession': WebLoginTarget.targets[platform]!
                    .prepareStorageScript('fixture-next-session'),
              },
          }),
        );
        final result = await Process.run('node', [
          File('tool/login-web-scripts.test.cjs').absolute.path,
          fixture.path,
        ]);
        expect(
          result.exitCode,
          0,
          reason: '${result.stdout}\n${result.stderr}',
        );
        // Keep the individual JavaScript results in the verification log.
        stdout.write(result.stdout);
      } finally {
        attempt.clear();
        await directory.delete(recursive: true);
      }
    },
  );
}
