# Apple storage, playback and remote configuration

iOS keeps new incomplete downloads in Application Support. Completed files are
published to the user's selected Files directory through `NSFileCoordinator`,
with security-scoped directory access restored from existing bookmarks. Local
app-directory saves may use hard links; external File Providers always receive
an independent file. Writers close before publication completes. Cancellation
removes only the document created by that save and preserves the downloaded
payload. Existing task cache roots remain unchanged so upgrades can resume them.
An iCloud upload indicator reflects the provider's sync state and is distinct
from a completed local download.

iOS playback uses the existing media_kit decoder. The iOS PiP entry, AVKit player
handoff, native video layer and background-audio mode have been removed. Native
capability replies and PiP events cannot enable it. Ordinary playback pauses
when the app enters the background; rotation, system bars, brightness, system
volume and external player support remain. Android and desktop PiP are retained.

Implementation references inspected on GitHub:

- [Nextcloud iOS](https://github.com/nextcloud/ios/blob/d502bbf5cea0ea64e41cac1d3f8d12e5055676cb/File%20Provider%20Extension/FileProviderExtension.swift): security-scoped access and coordinated document import.
- [LocalSend file saver](https://github.com/localsend/localsend/blob/92e133aa43869e94d394fd04fa70c50a0f796a64/packages/localsend_isolates/lib/src/task/server/file_saver.dart): separate cached payloads and final destinations, path validation and preservation of existing files.

`远程配置编辑器.html` and `config/control.example.json` include separate
`updates.android`, `updates.windows`, `updates.ios` and `updates.macos` fields.
Announcements, cloud availability, help and parser configuration remain shared.
Each update uses the installed platform's build number, with independent cache,
validation, expiry and ignore rules. Older configurations that omit Apple update
fields still work. iOS opens the configured download/release page in the browser;
an unsigned test IPA still requires user signing. macOS supports DMG/ZIP updates.

The iOS workflow verifies native file publication and duplicate-name protection
in a simulator, along with authenticated media_kit playback through the production
player page. It checks pause, seek, speed and foreground resumption without
replacing the decoder or texture, and confirms that iOS PiP is disabled. Dart
regressions cover the hidden PiP menu and background pause. iCloud/File Provider
sync and signed device playback require device verification.
