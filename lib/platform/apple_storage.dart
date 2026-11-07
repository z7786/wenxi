import 'dart:io';
import 'package:flutter/services.dart';
import '../core/json.dart';
import '../data/state_store.dart';

class AppleStorage {
  const AppleStorage({
    bool? enabled,
    MethodChannel channel = const MethodChannel('com.asterlink.app/native'),
  }) : _enabled = enabled,
       _channel = channel;
  final bool? _enabled;
  final MethodChannel _channel;
  bool get enabled => _enabled ?? (Platform.isIOS || Platform.isMacOS);

  Future<({String id, bool hardLinks})?> volume(String path) async {
    if (!enabled) return null;
    try {
      final value = asJson(
        await _channel.invokeMethod<Object?>('storageVolume', {'path': path}),
      );
      final id = value.str('id');
      if (id.isEmpty) return null;
      return (id: 'apple:$id', hardLinks: value.boolean('hardLinks'));
    } on MissingPluginException {
      return null;
    } on PlatformException {
      return null;
    }
  }

  Future<bool> link(String source, String target) async {
    if (!enabled) return false;
    try {
      return await _channel.invokeMethod<bool>('createHardLink', {
            'source': source,
            'target': target,
          }) ??
          false;
    } on MissingPluginException {
      return false;
    } on PlatformException {
      return false;
    }
  }
}

/// iOS restores access before resolving persisted paths. The provider or app
/// container may have moved since the directory was originally selected.
Future<String> resolveAppleDirectory(String path) async {
  if (!Platform.isIOS) return path;
  return await const MethodChannel(
        'com.asterlink.app/native',
      ).invokeMethod<String>('resolveDirectory', {'path': path}) ??
      path;
}

String remapApplePath(String value, Map<String, String> mappings) {
  final original = value;
  final prefixes = mappings.keys.toList()
    ..sort((a, b) => b.length.compareTo(a.length));
  final visited = <String>{};
  for (var step = 0; step < prefixes.length; step++) {
    visited.add(value);
    final oldPath = prefixes
        .where((prefix) => value == prefix || value.startsWith('$prefix/'))
        .firstOrNull;
    if (oldPath == null) break;
    final next = '${mappings[oldPath]}${value.substring(oldPath.length)}';
    if (visited.contains(next)) return original;
    value = next;
  }
  return value;
}

/// The first adapted build can recover paths saved before a home-directory
/// marker existed. Only known iOS container roots and storage fields qualify.
Map<String, String> appleStorageMappings(
  Object? response,
  Iterable<String> paths,
) {
  final value = asJson(response);
  final mappings = strings(value['paths']);
  final home = value.str('home');
  final container = RegExp(
    r'^(/(?:private/)?var/mobile/Containers/Data/Application/'
    r'[0-9A-Fa-f]{8}(?:-[0-9A-Fa-f]{4}){3}-[0-9A-Fa-f]{12})'
    r'(?:/(?:Documents|Library|tmp)(?:/|$)|$)',
  );
  if (container.firstMatch(home)?.group(1) == home) {
    for (final path in paths) {
      final oldHome = container.firstMatch(path)?.group(1);
      if (oldHome != null && oldHome != home) mappings[oldHome] = home;
    }
  }
  return mappings;
}

/// Preserve queue and account data when iOS changes its sandbox path on update.
/// Only absolute storage paths are rewritten, never links or credentials.
Future<void> restoreAppleStorage(
  StateStore store, {
  bool? ios,
  MethodChannel channel = const MethodChannel('com.asterlink.app/native'),
}) async {
  if (!(ios ?? Platform.isIOS)) return;
  final data = store.data;
  final mappings = appleStorageMappings(
    await channel.invokeMethod<Object?>('restoreStorage'),
    [
      data.obj('settings').str('destination'),
      data.str('lanDestination'),
      for (final task in data.list('tasks')) ...[
        task.str('destination'),
        task.str('savedPath'),
      ],
      for (final task in data.list('uploadTasks')) ...[
        task.str('path'),
        task.obj('folder').str('location'),
        for (final file in task.obj('folder').list('files'))
          file.str('location'),
      ],
      ...strings(data['downloadCacheRoots']).values,
    ],
  );
  if (mappings.isEmpty) return;
  await store.change((draft) {
    void path(Json item, String key) {
      final value = item[key];
      if (value is String && value.startsWith('/')) {
        item[key] = remapApplePath(value, mappings);
      }
    }

    final settings = draft.obj('settings');
    path(settings, 'destination');
    draft['settings'] = settings;
    path(draft, 'lanDestination');
    final tasks = draft.list('tasks');
    for (final task in tasks) {
      path(task, 'destination');
      path(task, 'savedPath');
    }
    if (draft.containsKey('tasks')) draft['tasks'] = tasks;
    final uploads = draft.list('uploadTasks');
    for (final task in uploads) {
      path(task, 'path');
      if (task['folder'] is Map) {
        final folder = task.obj('folder');
        path(folder, 'location');
        final files = folder.list('files');
        for (final file in files) {
          path(file, 'location');
        }
        folder['files'] = files;
        task['folder'] = folder;
      }
    }
    if (draft.containsKey('uploadTasks')) draft['uploadTasks'] = uploads;
    final roots = draft.obj('downloadCacheRoots');
    for (final key in roots.keys.toList()) {
      path(roots, key);
    }
    if (draft.containsKey('downloadCacheRoots')) {
      draft['downloadCacheRoots'] = roots;
    }
  });
}
