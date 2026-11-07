import '../core/json.dart';
import '../domain/models.dart';
import 'lan_models.dart';

/// Retains the sender's address and immutable file identity across receiver
/// restarts. The local forwarding URL itself is rebuilt for each download run.
class LanDownloadRoute {
  static const kind = 'lan-transfer';

  static bool owns(DownloadSpec spec) =>
      spec.profile == 'lan' && spec.source?.str('kind') == kind;

  static Json source(
    Uri origin,
    LanManifest manifest,
    LanFileEntry file, {
    String peerId = '',
  }) => {
    'kind': kind,
    'origin': lanAddress(origin.toString()).origin,
    'token': manifest.token,
    'file': file.toJson(),
    if (peerId.isNotEmpty) 'peerId': peerId,
    if (manifest.expiresAt != null)
      'expiresAt': manifest.expiresAt!.millisecondsSinceEpoch,
  };
}
