import 'dart:io';
import 'package:asterlink/playback/playback_state.dart';

/// Settings belong to the media, while native readers hold independent leases.
/// A failed native close must keep every subtitle that it may still be reading.
class PlaybackSelection {
  PlaybackSelection(this.key);
  final String key;
  AudioTrack? audio;
  SubtitleTrack? subtitle;
  double audioDelay = 0, subtitleDelay = 0;
  int subtitleRevision = 0;
  String? cloudSubtitleId;
  final files = <File>[];
  int _references = 1;

  void retain() => _references++;

  Future<void> release() async {
    if (--_references != 0) return;
    for (final file in files) {
      try {
        if (await file.exists()) await file.delete();
      } on FileSystemException {
        // A later cache cleanup can retry an unavailable private file.
      }
    }
    files.clear();
  }

  AudioTrack? audioFor(Tracks tracks) {
    final selected = audio;
    if (selected == null || {'auto', 'no'}.contains(selected.id)) {
      return selected;
    }
    return _match(tracks.audio, selected.id, selected.title, selected.language);
  }

  SubtitleTrack? subtitleFor(Tracks tracks) {
    final selected = subtitle;
    if (selected == null ||
        selected.uri ||
        selected.data ||
        {'auto', 'no'}.contains(selected.id)) {
      return selected;
    }
    return _match(
      tracks.subtitle,
      selected.id,
      selected.title,
      selected.language,
    );
  }

  T? _match<T>(List<T> tracks, String id, String? title, String? language) {
    String trackId(T t) => t is AudioTrack ? t.id : (t as SubtitleTrack).id;
    String? trackTitle(T t) =>
        t is AudioTrack ? t.title : (t as SubtitleTrack).title;
    String? trackLanguage(T t) =>
        t is AudioTrack ? t.language : (t as SubtitleTrack).language;
    bool sameMetadata(T t) =>
        trackTitle(t) == title && trackLanguage(t) == language;
    final real = tracks.where((t) => !{'auto', 'no'}.contains(trackId(t)));
    return real.where((t) => trackId(t) == id && sameMetadata(t)).firstOrNull ??
        (title != null || language != null
            ? real.where(sameMetadata).firstOrNull
            : real.where((t) => trackId(t) == id).firstOrNull);
  }
}
