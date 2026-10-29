import 'package:sqflite/sqflite.dart';

import '../core/models/category.dart';
import '../core/models/track.dart';
import 'category_resolver.dart';

/// Maintains the automatic (virtual) AI playlists.
///
/// Final membership (`track_categories`) is always derived from two inputs:
///  * the latest AI decision (`ai_assignments`, `tracks.needs_review`), and
///  * user corrections (`category_overrides`), which take precedence:
///    - any `include` override → the track belongs to exactly its included
///      categories, whatever the AI says now or later;
///    - `exclude` overrides remove a category from the AI decision.
/// Re-running analysis only replaces the AI decision, so corrections survive
/// rescans until [resetOverrides] is called. Rows reference tracks by id;
/// original files are never touched.
class AIPlaylistManager {
  AIPlaylistManager(this._db);

  final Database _db;

  int get _now => DateTime.now().millisecondsSinceEpoch;

  /// Stores a new AI decision for [trackId] and refreshes its playlists.
  Future<void> applyResolution(
    int trackId,
    Resolution r, {
    required String modelVersion,
    required String analyzedFingerprint,
  }) =>
      _db.transaction((txn) async {
        await txn.delete('track_predictions', where: 'track_id = ?', whereArgs: [trackId]);
        await txn.delete('ai_assignments', where: 'track_id = ?', whereArgs: [trackId]);
        final b = txn.batch();
        r.scores.forEach((label, score) {
          b.insert('track_predictions', {'track_id': trackId, 'label': label, 'score': score});
        });
        for (final a in r.assignments) {
          b.insert('ai_assignments', {
            'track_id': trackId,
            'category_id': a.categoryId,
            'confidence': a.confidence,
            'tier': a.tier,
          });
        }
        await b.commit(noResult: true);
        await txn.update(
          'tracks',
          {
            'analysis_status': AnalysisStatus.done,
            'analysis_error': null,
            'model_version': modelVersion,
            'analyzed_fingerprint': analyzedFingerprint,
            'analyzed_ms': _now,
            'needs_review': r.needsReview ? 1 : 0,
            'evidence_json': r.evidenceJson,
          },
          where: 'id = ?',
          whereArgs: [trackId],
        );
        await _recompute(txn, trackId);
      });

  Future<void> markFailed(int trackId, String error) => _db.update(
        'tracks',
        {'analysis_status': AnalysisStatus.failed, 'analysis_error': error, 'analyzed_ms': _now},
        where: 'id = ?',
        whereArgs: [trackId],
      );

  /// User picks the exact categories for a track (empty set = clear includes).
  Future<void> setUserCategories(int trackId, Set<String> categoryIds) => _db.transaction((txn) async {
        await txn.delete('category_overrides', where: 'track_id = ?', whereArgs: [trackId]);
        for (final c in categoryIds.where((c) => c != CategoryIds.needsReview)) {
          await txn.insert('category_overrides',
              {'track_id': trackId, 'category_id': c, 'mode': 'include', 'created_ms': _now});
        }
        await _recompute(txn, trackId);
      });

  /// Removes one AI-assigned category without pinning the others.
  Future<void> excludeCategory(int trackId, String categoryId) => _db.transaction((txn) async {
        await txn.delete('category_overrides',
            where: 'track_id = ? AND category_id = ?', whereArgs: [trackId, categoryId]);
        await txn.insert('category_overrides',
            {'track_id': trackId, 'category_id': categoryId, 'mode': 'exclude', 'created_ms': _now});
        await _recompute(txn, trackId);
      });

  /// Accepts the current AI categories as user-confirmed.
  Future<void> confirmCurrent(int trackId) async {
    final rows = await _db.query('track_categories',
        columns: ['category_id'], where: 'track_id = ? AND category_id != ?', whereArgs: [trackId, CategoryIds.needsReview]);
    if (rows.isEmpty) return;
    await setUserCategories(trackId, {for (final r in rows) r['category_id'] as String});
  }

  Future<void> resetOverrides(int trackId) => _db.transaction((txn) async {
        await txn.delete('category_overrides', where: 'track_id = ?', whereArgs: [trackId]);
        await _recompute(txn, trackId);
      });

  Future<bool> hasOverrides(int trackId) async =>
      (await _db.query('category_overrides', where: 'track_id = ?', whereArgs: [trackId], limit: 1)).isNotEmpty;

  /// Re-derives every track's playlists, e.g. after categories are enabled/disabled.
  Future<void> recomputeAll() => _db.transaction((txn) async {
        final ids = await txn.query('tracks', columns: ['id']);
        for (final r in ids) {
          await _recompute(txn, r['id'] as int);
        }
      });

  /// Queues tracks for analysis again; user overrides are kept.
  Future<int> markForReclassification({List<int>? trackIds}) {
    final values = {'analysis_status': AnalysisStatus.pending, 'analysis_error': null};
    if (trackIds == null) return _db.update('tracks', values, where: 'available = 1');
    return _db.update('tracks', values,
        where: 'id IN (${List.filled(trackIds.length, '?').join(',')})', whereArgs: trackIds);
  }

  Future<void> _recompute(Transaction txn, int trackId) async {
    final track = await txn.query('tracks',
        columns: ['needs_review', 'analysis_status'], where: 'id = ?', whereArgs: [trackId]);
    if (track.isEmpty) return;
    final enabled = {
      for (final r in await txn.query('categories', columns: ['id'], where: 'enabled = 1')) r['id'] as String,
    };
    final overrides = await txn.query('category_overrides', where: 'track_id = ?', whereArgs: [trackId]);
    final includes = {for (final o in overrides) if (o['mode'] == 'include') o['category_id'] as String};
    final excludes = {for (final o in overrides) if (o['mode'] == 'exclude') o['category_id'] as String};

    final rows = <Map<String, Object?>>[];
    if (includes.isNotEmpty) {
      for (final c in includes) {
        rows.add({'category_id': c, 'confidence': null, 'tier': AssignmentTier.user, 'origin': 'user'});
      }
    } else {
      final ai = await txn.query('ai_assignments', where: 'track_id = ?', whereArgs: [trackId]);
      var droppedByDisable = false;
      for (final a in ai) {
        final c = a['category_id'] as String;
        if (excludes.contains(c)) continue;
        if (!enabled.contains(c)) {
          droppedByDisable = true;
          continue;
        }
        rows.add({
          'category_id': c,
          'confidence': a['confidence'],
          'tier': a['tier'],
          'origin': a['tier'] == AssignmentTier.workflow ? 'workflow' : 'ai',
        });
      }
      if (rows.isEmpty && droppedByDisable && enabled.contains(CategoryIds.other)) {
        rows.add({'category_id': CategoryIds.other, 'confidence': null, 'tier': AssignmentTier.workflow, 'origin': 'workflow'});
      }
      final analyzed = track.first['analysis_status'] == AnalysisStatus.done;
      if (analyzed && (track.first['needs_review'] as int) == 1 && !excludes.contains(CategoryIds.needsReview)) {
        rows.add({'category_id': CategoryIds.needsReview, 'confidence': null, 'tier': AssignmentTier.workflow, 'origin': 'workflow'});
      }
    }

    await txn.delete('track_categories', where: 'track_id = ?', whereArgs: [trackId]);
    for (final r in rows) {
      await txn.insert('track_categories', {...r, 'track_id': trackId});
    }
  }
}
