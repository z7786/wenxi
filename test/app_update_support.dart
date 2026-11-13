import 'dart:async';
import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:asterlink/data/app_update_service.dart';
import 'package:asterlink/data/cleanup_outbox.dart';
import 'package:asterlink/data/cloud_repository.dart';
import 'package:asterlink/data/http.dart';
import 'package:asterlink/data/state_store.dart';
import 'package:asterlink/domain/downloads.dart';
import 'package:asterlink/domain/models.dart';
import 'package:asterlink/domain/remote_control.dart';
import 'package:asterlink/download/download_manager.dart';
import 'package:asterlink/platform/app_update_installer.dart';
import 'package:asterlink/platform/windows_actions.dart';
import 'package:asterlink/platform/quark_transfer_device.dart';
import 'support.dart';

class UpdateDownloads extends ChangeNotifier implements DownloadManager {
  final records = <DownloadTask>[];
  int created = 0, resumed = 0;
  @override
  List<DownloadTask> get tasks => records.reversed.toList();
  @override
  DownloadTask? task(String id) => records.where((t) => t.id == id).firstOrNull;
  @override
  Future<String> enqueue(DownloadSpec spec, {int? connections}) async {
    final id = 'update-${++created}';
    records.add(
      DownloadTask(id: id, spec: spec, createdAt: created, total: 1024),
    );
    notifyListeners();
    return id;
  }

  void change(String id, Map<String, dynamic> fields) {
    final index = records.indexWhere((t) => t.id == id);
    records[index] = records[index].update(fields);
    notifyListeners();
  }

  @override
  Future<void> pause(String id) async => change(id, {'status': 'paused'});
  @override
  Future<void> resume(String id) async {
    resumed++;
    change(id, {'status': 'pending', 'error': ''});
  }

  @override
  Future<void> delete(String id, {bool deleteFile = false}) async {
    records.removeWhere((t) => t.id == id);
    notifyListeners();
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class UpdateConnector extends CloudConnector {
  @override
  final platform = CloudPlatform.lanzou;
  ParsedLink? opened;
  Completer<void>? pending;
  Object? failure;
  List<CloudFile> entries = [
    const CloudFile(id: 'file', name: 'app.apk', size: 1024),
  ];
  @override
  Future<BrowseSession> openShare(
    ParsedLink link,
    Credential? credential,
  ) async {
    opened = link;
    if (failure != null) throw failure!;
    await pending?.future;
    return BrowseSession(
      platform: platform,
      mode: BrowseMode.share,
      title: 'update',
      rootId: 'root',
    );
  }

  @override
  Future<List<CloudFile>> list(
    BrowseSession s,
    String parent,
    Credential? c,
  ) async => entries;
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class UpdateInstaller extends AppUpdateInstaller {
  UpdateInstaller(String platform)
    : super(platform: platform, windows: WindowsActions(supported: false));
  int preparations = 0, opens = 0;
  Completer<void>? pending;
  Object? failure;
  @override
  Future<String> prepare(DownloadTask task, RemoteUpdate update) async {
    preparations++;
    await pending?.future;
    if (failure != null) throw failure!;
    return task.savedPath!;
  }

  @override
  Future<void> open(String path, String name) async {
    opens++;
  }
}

class UpdateFixture {
  UpdateFixture({
    this.platform = 'android',
    JsonHttp? transport,
    QuarkTransferDevice? quarkTransferDevice,
  }) {
    final http = transport ?? FakeHttp();
    cleanups = CleanupOutbox(store, http);
    cloud = CloudRepository(
      http,
      Vault(store),
      cleanups,
      quarkTransferDevice: quarkTransferDevice,
    );
    cloud.connectors[CloudPlatform.lanzou] = connector;
    installer = UpdateInstaller(platform);
    service = AppUpdateService(
      platform: platform,
      cloud: cloud,
      downloads: downloads,
      files: files,
      installer: installer,
      currentUpdate: () => current,
      inForeground: () => foreground,
      openDownloads: () => navigations++,
    );
  }
  final String platform;
  final store = StateStore.memory();
  final downloads = UpdateDownloads();
  final connector = UpdateConnector();
  final files = FakeFiles(Directory('unused-update-fixture'));
  late final CleanupOutbox cleanups;
  late final CloudRepository cloud;
  late final UpdateInstaller installer;
  late final AppUpdateService service;
  bool foreground = true;
  int navigations = 0;
  RemoteUpdate? current = RemoteUpdate(
    '1.2.0',
    120,
    Uri.parse('https://share.feijipan.com/s/browser'),
    '',
    inAppDownloadUrl: Uri.parse('https://wwanc.lanzouq.com/iabc123'),
    inAppPasscode: '1234',
  );
  void complete() => downloads.change(downloads.tasks.first.id, {
    'status': 'completed',
    'downloaded': 1024,
    'savedPath': '/saved/app.apk',
  });
  void close() {
    service.close();
    downloads.dispose();
    cleanups.progress.close();
    store.dispose();
  }
}
