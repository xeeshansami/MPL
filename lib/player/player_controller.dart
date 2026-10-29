import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:audio_session/audio_session.dart';
import 'package:flutter/foundation.dart';
import 'package:just_audio/just_audio.dart';
import 'package:just_audio_background/just_audio_background.dart';

import '../core/models/track.dart';
import '../data/catalog_repositories.dart';
import '../data/track_repository.dart';

/// Playback, queue and session persistence. Background playback and
/// lock-screen controls come from just_audio_background (MediaItem tags).
class PlayerController extends ChangeNotifier {
  PlayerController(this._tracks, this._settings) {
    if (Platform.isAndroid) {
      equalizer = AndroidEqualizer();
      loudness = AndroidLoudnessEnhancer();
    }
    player = AudioPlayer(
      audioPipeline: Platform.isAndroid ? AudioPipeline(androidAudioEffects: [loudness!, equalizer!]) : null,
    );
    _subs.addAll([
      player.currentIndexStream.listen(_onIndex),
      player.playerStateStream.listen((s) {
        if (s.processingState == ProcessingState.completed && _sleepAtTrackEnd) {
          _sleepAtTrackEnd = false;
          sleepDeadline = null;
        }
        if (!s.playing) unawaited(_persist());
        notifyListeners();
      }),
      player.shuffleModeEnabledStream.listen((_) => notifyListeners()),
      player.loopModeStream.listen((_) => notifyListeners()),
    ]);
  }

  final TrackRepository _tracks;
  final SettingsRepository _settings;
  late final AudioPlayer player;
  AndroidEqualizer? equalizer;
  AndroidLoudnessEnhancer? loudness;
  final _subs = <StreamSubscription<Object?>>[];

  List<Track> queue = [];
  int? _lastRecordedIndex;

  Track? get current {
    final i = player.currentIndex;
    return (i == null || i < 0 || i >= queue.length) ? null : queue[i];
  }

  bool get equalizerSupported => equalizer != null;

  Future<void> init() async {
    final session = await AudioSession.instance;
    await session.configure(const AudioSessionConfiguration.music());
    await _restore();
  }

  static AudioSource sourceFor(Track t) {
    final uri = t.uri.startsWith('content://') || t.uri.startsWith('file://') ? Uri.parse(t.uri) : Uri.file(t.uri);
    return AudioSource.uri(
      uri,
      tag: MediaItem(
        id: '${t.id}',
        title: t.title,
        artist: t.displayArtist,
        album: t.album,
        duration: t.durationMs > 0 ? t.duration : null,
        artUri: t.artworkPath == null ? null : Uri.file(t.artworkPath!),
      ),
    );
  }

  Future<void> playTracks(List<Track> tracks, {int start = 0, bool shuffle = false}) async {
    if (tracks.isEmpty) return;
    queue = List.of(tracks);
    _lastRecordedIndex = null;
    await player.setShuffleModeEnabled(shuffle);
    await player.setAudioSources([for (final t in queue) sourceFor(t)], initialIndex: shuffle ? null : start);
    if (shuffle) await player.shuffle();
    notifyListeners();
    unawaited(player.play());
  }

  Future<void> playNext(Track t) async {
    if (queue.isEmpty) return playTracks([t]);
    final at = (player.currentIndex ?? -1) + 1;
    queue.insert(at, t);
    await player.insertAudioSource(at, sourceFor(t));
    notifyListeners();
  }

  Future<void> addToQueue(List<Track> tracks) async {
    if (queue.isEmpty) return playTracks(tracks);
    queue.addAll(tracks);
    await player.addAudioSources([for (final t in tracks) sourceFor(t)]);
    notifyListeners();
  }

  Future<void> removeAt(int index) async {
    if (index < 0 || index >= queue.length) return;
    queue.removeAt(index);
    await player.removeAudioSourceAt(index);
    notifyListeners();
  }

  Future<void> move(int from, int to) async {
    if (from == to) return;
    final t = queue.removeAt(from);
    queue.insert(to, t);
    await player.moveAudioSource(from, to);
    notifyListeners();
  }

  Future<void> togglePlay() => player.playing ? player.pause() : player.play();

  Future<void> next() => player.seekToNext();

  Future<void> previous() async {
    if (player.position > const Duration(seconds: 3) || !player.hasPrevious) {
      await player.seek(Duration.zero);
    } else {
      await player.seekToPrevious();
    }
  }

  Future<void> jumpTo(int index) async {
    await player.seek(Duration.zero, index: index);
    unawaited(player.play());
  }

  Future<void> toggleShuffle() async {
    final enable = !player.shuffleModeEnabled;
    if (enable) await player.shuffle();
    await player.setShuffleModeEnabled(enable);
  }

  Future<void> cycleRepeat() => player.setLoopMode(switch (player.loopMode) {
        LoopMode.off => LoopMode.all,
        LoopMode.all => LoopMode.one,
        LoopMode.one => LoopMode.off,
      });

  Future<void> setSpeed(double s) async {
    await player.setSpeed(s);
    notifyListeners();
  }

  // ------------------------------------------------------------ favourites

  Future<void> toggleFavorite(Track t) async {
    await _tracks.setFavorite(t.id, !t.favorite);
    final updated = await _tracks.byId(t.id);
    if (updated != null) {
      queue = [for (final q in queue) q.id == t.id ? updated : q];
    }
    notifyListeners();
  }

  // ------------------------------------------------------------ sleep timer

  Timer? _sleepTimer;
  DateTime? sleepDeadline;
  bool _sleepAtTrackEnd = false;
  bool get sleepAtTrackEnd => _sleepAtTrackEnd;

  void setSleepTimer(Duration? d) {
    _sleepTimer?.cancel();
    _sleepTimer = null;
    _sleepAtTrackEnd = false;
    sleepDeadline = null;
    if (d != null) {
      sleepDeadline = DateTime.now().add(d);
      _sleepTimer = Timer(d, () {
        player.pause();
        sleepDeadline = null;
        notifyListeners();
      });
    }
    notifyListeners();
  }

  /// Pause when the current track ends.
  void sleepAfterCurrentTrack() {
    setSleepTimer(null);
    final remaining = (player.duration ?? Duration.zero) - player.position;
    if (remaining <= Duration.zero) return;
    _sleepAtTrackEnd = true;
    sleepDeadline = DateTime.now().add(remaining);
    _sleepTimer = Timer(Duration(microseconds: (remaining.inMicroseconds / player.speed).round()), () {
      player.pause();
      _sleepAtTrackEnd = false;
      sleepDeadline = null;
      notifyListeners();
    });
    notifyListeners();
  }

  // ------------------------------------------------------------ history & persistence

  void _onIndex(int? index) {
    if (index != null && index != _lastRecordedIndex && index < queue.length) {
      _lastRecordedIndex = index;
      unawaited(_tracks.recordPlay(queue[index].id));
      unawaited(_persist());
    }
    notifyListeners();
  }

  Future<void> _persist() async {
    if (queue.isEmpty) return;
    await _settings.set(
      'player_session',
      jsonEncode({
        'ids': [for (final t in queue) t.id],
        'index': player.currentIndex ?? 0,
        'positionMs': player.position.inMilliseconds,
        'speed': player.speed,
      }),
    );
  }

  /// Restores the last queue and position after an app restart (paused).
  Future<void> _restore() async {
    final raw = await _settings.get('player_session');
    if (raw == null) return;
    try {
      final j = jsonDecode(raw) as Map<String, Object?>;
      final ids = (j['ids'] as List).cast<int>();
      final restored = (await _tracks.byIds(ids)).where((t) => t.available).toList();
      if (restored.isEmpty) return;
      final savedIndex = j['index'] as int? ?? 0;
      final savedId = savedIndex < ids.length ? ids[savedIndex] : null;
      final index = restored.indexWhere((t) => t.id == savedId);
      queue = restored;
      _lastRecordedIndex = index < 0 ? 0 : index;
      await player.setAudioSources(
        [for (final t in queue) sourceFor(t)],
        initialIndex: index < 0 ? 0 : index,
        initialPosition: index < 0 ? Duration.zero : Duration(milliseconds: j['positionMs'] as int? ?? 0),
      );
      await player.setSpeed((j['speed'] as num?)?.toDouble() ?? 1.0);
      notifyListeners();
    } catch (_) {
      // A stale session (e.g. files removed) must never block startup.
      queue = [];
    }
  }

  @override
  void dispose() {
    for (final s in _subs) {
      s.cancel();
    }
    _sleepTimer?.cancel();
    player.dispose();
    super.dispose();
  }
}
