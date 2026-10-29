import 'dart:async';

import 'package:flutter/foundation.dart';

import '../ai/ai_playlist_manager.dart';
import '../ai/audio_classifier.dart';
import '../ai/audio_feature_extractor.dart';
import '../ai/category_resolver.dart';
import '../ai/metadata_rules.dart';
import '../core/models/category.dart';
import '../core/models/track.dart';
import '../data/catalog_repositories.dart';
import '../data/track_repository.dart';
import 'library_services.dart';

enum ScanPhase { idle, discovering, readingMetadata, analyzing, paused, completed, cancelled, error }

class ScanError {
  const ScanError(this.trackId, this.title, this.message);

  final int? trackId;
  final String title;
  final String message;
}

/// Orchestrates the AI workflow:
/// discovery → metadata → AI inference → confidence policy → SQLite → playlists.
///
/// Incremental: only new, changed, queued or out-of-date (model version)
/// tracks are analysed; a normal launch with an unchanged library does no
/// inference at all.
class LibraryScanner extends ChangeNotifier {
  LibraryScanner({
    required this.discovery,
    required this.metadata,
    required this.extractor,
    required this.classifier,
    required this.tracks,
    required this.categories,
    required this.settings,
    required this.playlists,
    this.resolver = const CategoryResolver(),
    this.interTrackDelay = const Duration(milliseconds: 40),
  });

  final MediaDiscovery discovery;
  final MetadataService metadata;
  final AudioFeatureExtractor extractor;
  final AudioClassifier classifier;
  final TrackRepository tracks;
  final CategoryRepository categories;
  final SettingsRepository settings;
  final AIPlaylistManager playlists;
  final CategoryResolver resolver;

  /// Breathing room between tracks so playback and UI stay smooth.
  final Duration interTrackDelay;

  ScanPhase phase = ScanPhase.idle;
  int discovered = 0;
  int queueTotal = 0;
  int processed = 0;
  String? currentTitle;
  String? message;
  final List<ScanError> errors = [];

  /// Bumped whenever library data changes so screens can refresh.
  final ValueNotifier<int> revision = ValueNotifier(0);

  bool get isRunning =>
      phase == ScanPhase.discovering ||
      phase == ScanPhase.readingMetadata ||
      phase == ScanPhase.analyzing ||
      phase == ScanPhase.paused;

  bool _cancel = false;
  Completer<void>? _resume;
  Future<void>? _running;

  void pause() {
    if (!isRunning || _resume != null) return;
    _resume = Completer<void>();
    phase = ScanPhase.paused;
    notifyListeners();
  }

  void resume() {
    final c = _resume;
    if (c == null) return;
    _resume = null;
    c.complete();
    phase = ScanPhase.analyzing;
    notifyListeners();
  }

  void cancel() {
    if (!isRunning) return;
    _cancel = true;
    resume();
  }

  Future<void> _checkpoint() async {
    if (_resume != null) await _resume!.future;
    if (_cancel) throw const _Cancelled();
  }

  /// Incremental scan. Safe to call repeatedly; concurrent calls join the
  /// running scan.
  Future<void> scan() => _running ??= _run().whenComplete(() => _running = null);

  /// Re-analyses every available track (user overrides are preserved).
  Future<void> reclassifyAll() async {
    await _running;
    await playlists.markForReclassification();
    _bump();
    await scan();
  }

  Future<void> reclassify(List<int> trackIds) async {
    await _running;
    await playlists.markForReclassification(trackIds: trackIds);
    _bump();
    await scan();
  }

  void _bump() => revision.value++;

  void _set(ScanPhase p, {String? msg}) {
    phase = p;
    message = msg;
    notifyListeners();
  }

  Future<void> _run() async {
    _cancel = false;
    errors.clear();
    processed = 0;
    queueTotal = 0;
    currentTitle = null;
    try {
      _set(ScanPhase.discovering, msg: 'Looking for audio…');
      final found = await discovery.discover();
      discovered = found.length;
      final sync = await tracks.syncDiscovered(found);
      _bump();
      await _checkpoint();

      final needMeta = await tracks.needingMetadata();
      _set(ScanPhase.readingMetadata, msg: 'Reading tags (${needMeta.length})');
      for (final t in needMeta) {
        await _checkpoint();
        currentTitle = t.title;
        notifyListeners();
        try {
          await tracks.applyMetadata(t.id, await metadata.read(t), t.fingerprint);
        } catch (e) {
          // Tags are optional; keep the filename-based title and continue.
          await tracks.applyMetadata(t.id, const TrackMetadata(), t.fingerprint);
        }
      }
      if (needMeta.isNotEmpty) _bump();

      final status = await classifier.initialize();
      if (!status.isReady) {
        await tracks.markAwaitingModel();
        _bump();
        _set(ScanPhase.completed,
            msg: 'Library updated (+${sync.added}, ${sync.changed} changed, ${sync.removed} unavailable). '
                'AI classification unavailable: ${status.reason}');
        return;
      }
      final manifest = status.manifest!;
      final queue = await tracks.needingAnalysis(manifest.modelVersion);
      queueTotal = queue.length;
      _set(ScanPhase.analyzing, msg: queue.isEmpty ? 'Everything is up to date' : 'Analysing audio on device');

      final cats = await categories.all();
      final enabled = {for (final c in cats) if (c.enabled) c.id};
      final rules = MetadataRules(cats);
      final policy = await settings.policy();

      for (final t in queue) {
        await _checkpoint();
        currentTitle = t.title;
        notifyListeners();
        await tracks.setStatus(t.id, AnalysisStatus.processing);
        try {
          final audio = await extractor.extract(t, manifest);
          await _checkpoint();
          final scores = await classifier.predictWindows(audio.windows);
          final resolution = resolver.resolve(
            manifest: manifest,
            windowScores: scores,
            windowLevelsDb: audio.levelsDb,
            metadata: rules.evaluate(
              title: t.title,
              artist: t.artist,
              album: t.album,
              genre: t.genre,
              filename: t.filename,
              folder: t.folder,
            ),
            enabledCategoryIds: enabled,
            policy: policy,
          );
          await playlists.applyResolution(t.id, resolution,
              modelVersion: manifest.modelVersion, analyzedFingerprint: t.fingerprint);
        } on _Cancelled {
          await tracks.setStatus(t.id, AnalysisStatus.pending);
          rethrow;
        } catch (e) {
          await playlists.markFailed(t.id, e.toString());
          errors.add(ScanError(t.id, t.title, e.toString()));
        }
        processed++;
        _bump();
        notifyListeners();
        if (interTrackDelay > Duration.zero) await Future<void>.delayed(interTrackDelay);
      }
      currentTitle = null;
      _set(ScanPhase.completed,
          msg: queue.isEmpty
              ? 'Library up to date (+${sync.added} new, ${sync.removed} unavailable)'
              : 'Analysed $processed track(s)${errors.isEmpty ? '' : ', ${errors.length} failed'}');
    } on _Cancelled {
      currentTitle = null;
      _set(ScanPhase.cancelled, msg: 'Cancelled after $processed track(s); progress is saved');
    } catch (e) {
      currentTitle = null;
      errors.add(ScanError(null, 'Scan', e.toString()));
      _set(ScanPhase.error, msg: 'Scan failed: $e');
    } finally {
      _resume = null;
      _bump();
    }
  }

  /// Re-derives playlists after category configuration changes.
  Future<void> categoriesChanged() async {
    await playlists.recomputeAll();
    _bump();
  }

  /// Convenience for correction UI: ids of categories a user can assign.
  static bool assignable(AiCategory c) => c.enabled && !c.isNeedsReview;
}

class _Cancelled implements Exception {
  const _Cancelled();
}
