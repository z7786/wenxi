# Folder upload

Personal cloud directories with both upload and folder-creation capabilities
show **上传文件夹** in the add menu and desktop context menu. Windows and macOS
also accept mixed file/folder drops. Selecting a folder includes its own name,
subdirectories, regular files, and empty directories. Overlapping dropped
selections are deduplicated. Symbolic links inside the tree are skipped and
reported in the task-added message.

The folder is one durable upload task. The upload queue resolves remote
directories before streaming files through existing provider upload methods.
Existing directories are reused; same-name files are not overwritten. Stored
directory identities are checked on retry, as are completed remote files.
Completed files are skipped when continuing a failed/cancelled/interrupted
folder task; the incomplete file starts again. If a write reached the provider
but its response was lost, the resulting name conflict needs manual inspection.
Cancel leaves already submitted files and directories in the cloud.

Android uses a read-only `ACTION_OPEN_DOCUMENT_TREE` grant, persists access,
queries child metadata once per directory with `DocumentsContract`, and reads
document URIs in bounded chunks. Upload readers are separate from LAN readers,
so stopping device sharing cannot interrupt cloud uploads. Unreadable or still
loading document-provider directories fail selection instead of becoming empty.

iOS uses the existing document picker, security-scoped bookmarks, and
`NSFileCoordinator` reads. App-container moves remap the folder and all local
file references during storage recovery. Desktop platforms use the existing
file selector and filesystem streams. No new dependency or full-folder cache
copy is needed. iOS native behavior still needs validation on an Apple device.

One selection supports at most 10,000 combined file/directory entries and 64
path segments including the selected folder. Shared/read-only locations and
GitHub release assets do not expose folder upload. GitHub code directories use
their existing `.gitkeep` folder creation behavior. Provider file-size, quota,
format, and upload restrictions continue to apply.

Focused checks:

```text
flutter test --no-pub test/upload_folder_test.dart test/upload_sources_test.dart
flutter test --no-pub test/cloud_drop_upload_test.dart test/uploads_page_test.dart
flutter test --no-pub test/upload_manager_test.dart test/cloud_upload_test.dart
flutter test --no-pub test/apple_storage_test.dart test/download_progress_test.dart
```

Android `LanFilesTest` covers SAF directory queries, unreadable children, empty
folders, bounded reads, combined selection limits, and isolated upload readers.
