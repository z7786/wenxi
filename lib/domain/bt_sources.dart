import '../core/json.dart';

class BtSources {
  const BtSources({
    required this.connected,
    required this.known,
    required this.seeders,
    required this.webseeds,
    required this.trackers,
    required this.uploadLimit,
    required this.sessionReused,
  });
  final int connected, known, seeders, webseeds, trackers, uploadLimit;
  final bool sessionReused;
  factory BtSources.fromJson(Json value) => BtSources(
    connected: value.integer('connected').clamp(0, 100000),
    known: value.integer('known').clamp(0, 100000),
    seeders: value.integer('seeders').clamp(0, 100000),
    webseeds: value.integer('webseeds').clamp(0, 100000),
    trackers: value.integer('trackers').clamp(0, 100000),
    uploadLimit: value.integer('uploadLimit').clamp(0, 1 << 50),
    sessionReused: value.boolean('sessionReused'),
  );
  @override
  bool operator ==(Object other) =>
      other is BtSources &&
      connected == other.connected &&
      known == other.known &&
      seeders == other.seeders &&
      webseeds == other.webseeds &&
      trackers == other.trackers &&
      uploadLimit == other.uploadLimit &&
      sessionReused == other.sessionReused;
  @override
  int get hashCode => Object.hash(
    connected,
    known,
    seeders,
    webseeds,
    trackers,
    uploadLimit,
    sessionReused,
  );
}
