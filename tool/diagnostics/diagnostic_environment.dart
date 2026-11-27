import 'dart:io';

/// Private diagnostics must never activate just because a developer directory exists.
Directory requireDiagnosticBackend() {
  if (Platform.environment['ASTERLINK_DIAGNOSTICS'] != '1') {
    throw StateError(
      'Run explicitly with py -3 tool/verify.py diagnostic <test path>.',
    );
  }
  final path = Platform.environment['ASTERLINK_BACKEND_ROOT']?.trim();
  if (path == null || path.isEmpty) {
    throw StateError('Set ASTERLINK_BACKEND_ROOT to the private fixture root.');
  }
  final root = Directory(path);
  if (!root.isAbsolute || !root.existsSync()) {
    throw StateError(
      'ASTERLINK_BACKEND_ROOT must be an existing absolute directory.',
    );
  }
  if (!Directory('${root.path}/src/configs/client_search').existsSync()) {
    throw StateError(
      'The private fixture root must contain src/configs/client_search.',
    );
  }
  return root;
}

void requireDiagnosticRuntime() {
  if (Platform.environment['ASTERLINK_DIAGNOSTICS'] != '1') {
    throw StateError('Use the diagnostic verification scope explicitly.');
  }
  final library = Platform.environment['ASTERLINK_JS_LIBRARY'];
  if (library == null || library.isEmpty || !File(library).existsSync()) {
    throw StateError('Set ASTERLINK_JS_LIBRARY to the native JS library.');
  }
}

void requireLiveDiagnostic(String flag) {
  if (Platform.environment['ASTERLINK_DIAGNOSTICS'] != '1' ||
      Platform.environment[flag] != '1') {
    throw StateError(
      'This network diagnostic requires $flag=1 and the diagnostic command.',
    );
  }
}
