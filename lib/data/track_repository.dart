import 'package:sqflite/sqflite.dart';

import '../core/models/track.dart';

enum TrackSort { title, artist, album, dateAdded, duration, mostPlayed }

class UpsertResult {
  const UpsertResult({required this.added, required this.changed, required this.removed, required this.restored});

  final int added;
  final int changed;
  final int removed;
  final int restored;
}

class TrackRepository {
  TrackRepository(this._db);

  final Database _db;

  int get _now => DateTime.now().millisecondsSinceEpoch;

  /// Synchronises the library with a full discovery result. Idempotent:
  ///  * new sources are inserted as pending;
  ///  * sources whose fingerprint changed are re-queued for metadata + analysis;
  ///  * sources no longer discovered are hidden (available = 0) but their
  ///    history, favourites and overrides are kept in case they come back.
  Future<UpsertResult> syncDiscovered(List<DiscoveredAudio> found) => _db.transaction((txn) async {
        final existing = {
          for (final r in await txn.query('tracks', columns: ['id', 'source_id', 'uri', 'fingerprint', 'available']))
            r['source_id'] as String: r,
        };
        var added = 0, changed = 0, restored = 0;
        final seen = <String>{};
        for (final d in found) {
          if (!seen.add(d.sourceId)) continue; // duplicate within the same discovery
          final row = existing[d.sourceId];
          if (row == null) {
            await txn.insert('tracks', {
              'source_id': d.sourceId,
              'source_type': d.sourceType,
              'uri': d.uri,
              'filename': d.displayName,
              'folder': d.folder,
              'title': d.title?.trim().isNotEmpty == true ? d.title!.trim() : _stripExtension(d.displayName),
              'artist': d.artist,
              'album': d.album,
              'genre': d.genre,
              'duration_ms': d.durationMs ?? 0,
              'size_bytes': d.sizeBytes,
              'source_modified_ms': d.modifiedMs,
              'fingerprint': d.fingerprint,
              'added_ms': _now,
            }, conflictAlgorithm: ConflictAlgorithm.ignore);
            added++;
            continue;
          }
          final updates = <String, Object?>{};
          if ((row['available'] as int) == 0) {
            updates['available'] = 1;
            restored++;
          }
          // App container paths (iOS) can move between installs; follow them.
          if (row['uri'] != d.uri) updates['uri'] = d.uri;
          if (row['fingerprint'] != d.fingerprint) {
            updates.addAll({
              'uri': d.uri,
              'filename': d.displayName,
              'folder': d.folder,
              'size_bytes': d.sizeBytes,
              'source_modified_ms': d.modifiedMs,
              'fingerprint': d.fingerprint,
              if (d.durationMs != null) 'duration_ms': d.durationMs,
              'analysis_status': AnalysisStatus.pending,
            });
            changed++;
          }
          if (updates.isNotEmpty) {
            await txn.update('tracks', updates, where: 'id = ?', whereArgs: [row['id']]);
          }
        }
        var removed = 0;
        for (final e in existing.entries) {
          if (!seen.contains(e.key) && (e.value['available'] as int) == 1) {
            await txn.update('tracks', {'available': 0}, where: 'id = ?', whereArgs: [e.value['id']]);
            removed++;
          }
        }
        return UpsertResult(added: added, changed: changed, removed: removed, restored: restored);
      });

  static String _stripExtension(String name) {
    final i = name.lastIndexOf('.');
    return i > 0 ? name.substring(0, i) : name;
  }

  Future<List<Track>> needingMetadata() async => (await _db.query('tracks',
          where: 'available = 1 AND (metadata_fingerprint IS NULL OR metadata_fingerprint != fingerprint)'))
      .map(Track.fromRow)
      .toList();

  Future<void> applyMetadata(int id, TrackMetadata m, String fingerprint) => _db.update(
        'tracks',
        {
          if (m.title?.trim().isNotEmpty == true) 'title': m.title!.trim(),
          if (m.artist?.trim().isNotEmpty == true) 'artist': m.artist!.trim(),
          if (m.album?.trim().isNotEmpty == true) 'album': m.album!.trim(),
          if (m.albumArtist?.trim().isNotEmpty == true) 'album_artist': m.albumArtist!.trim(),
          if (m.genre?.trim().isNotEmpty == true) 'genre': m.genre!.trim(),
          if (m.durationMs != null && m.durationMs! > 0) 'duration_ms': m.durationMs,
          if (m.artworkPath != null) 'artwork_path': m.artworkPath,
          'metadata_fingerprint': fingerprint,
        },
        where: 'id = ?',
        whereArgs: [id],
      );

  /// Tracks that need (re)analysis with [modelVersion]: new, changed, queued
  /// for reclassification, waiting for a model, or analysed by another version.
  Future<List<Track>> needingAnalysis(String modelVersion) async => (await _db.query(
        'tracks',
        where: '''available = 1 AND (
            analysis_status IN ('${AnalysisStatus.pending}', '${AnalysisStatus.processing}', '${AnalysisStatus.awaitingModel}')
            OR (analysis_status = '${AnalysisStatus.done}' AND (model_version IS NOT ? OR analyzed_fingerprint IS NOT fingerprint))
          )''',
        whereArgs: [modelVersion],
        orderBy: 'added_ms DESC',
      ))
          .map(Track.fromRow)
          .toList();

  Future<void> setStatus(int id, String status) =>
      _db.update('tracks', {'analysis_status': status}, where: 'id = ?', whereArgs: [id]);

  /// Without a model, pending tracks wait rather than fail.
  Future<int> markAwaitingModel() => _db.update('tracks', {'analysis_status': AnalysisStatus.awaitingModel},
      where: "available = 1 AND analysis_status IN ('${AnalysisStatus.pending}', '${AnalysisStatus.processing}')");

  Future<List<Track>> all({
    TrackSort sort = TrackSort.title,
    String? query,
    bool favoritesOnly = false,
    String? categoryId,
  }) async {
    final where = <String>['t.available = 1'];
    final args = <Object?>[];
    if (favoritesOnly) where.add('t.favorite = 1');
    if (query != null && query.trim().isNotEmpty) {
      final q = '%${query.trim().toLowerCase()}%';
      where.add('(LOWER(t.title) LIKE ? OR LOWER(t.artist) LIKE ? OR LOWER(t.album) LIKE ? OR LOWER(t.filename) LIKE ?)');
      args.addAll([q, q, q, q]);
    }
    if (categoryId != null) {
      where.add('EXISTS (SELECT 1 FROM track_categories c WHERE c.track_id = t.id AND c.category_id = ?)');
      args.add(categoryId);
    }
    final order = switch (sort) {
      TrackSort.title => 't.title COLLATE NOCASE',
      TrackSort.artist => 't.artist COLLATE NOCASE, t.album COLLATE NOCASE, t.title COLLATE NOCASE',
      TrackSort.album => 't.album COLLATE NOCASE, t.title COLLATE NOCASE',
      TrackSort.dateAdded => 't.added_ms DESC',
      TrackSort.duration => 't.duration_ms DESC',
      TrackSort.mostPlayed => 't.play_count DESC, t.last_played_ms DESC',
    };
    final rows = await _db.rawQuery('SELECT t.* FROM tracks t WHERE ${where.join(' AND ')} ORDER BY $order', args);
    return rows.map(Track.fromRow).toList();
  }

  Future<Track?> byId(int id) async {
    final r = await _db.query('tracks', where: 'id = ?', whereArgs: [id]);
    return r.isEmpty ? null : Track.fromRow(r.first);
  }

  Future<List<Track>> byIds(List<int> ids) async {
    if (ids.isEmpty) return const [];
    final r = await _db.query('tracks', where: 'id IN (${List.filled(ids.length, '?').join(',')})', whereArgs: ids);
    final map = {for (final t in r.map(Track.fromRow)) t.id: t};
    return [for (final id in ids) ?map[id]];
  }

  Future<List<Track>> recentlyAdded({int limit = 20}) async =>
      (await _db.query('tracks', where: 'available = 1', orderBy: 'added_ms DESC', limit: limit)).map(Track.fromRow).toList();

  Future<List<Track>> recentlyPlayed({int limit = 20}) async => (await _db.query('tracks',
          where: 'available = 1 AND last_played_ms IS NOT NULL', orderBy: 'last_played_ms DESC', limit: limit))
      .map(Track.fromRow)
      .toList();

  Future<void> setFavorite(int id, bool favorite) =>
      _db.update('tracks', {'favorite': favorite ? 1 : 0}, where: 'id = ?', whereArgs: [id]);

  Future<void> recordPlay(int id) => _db.transaction((txn) async {
        final now = _now;
        await txn.rawUpdate('UPDATE tracks SET play_count = play_count + 1, last_played_ms = ? WHERE id = ?', [now, id]);
        await txn.insert('play_history', {'track_id': id, 'played_ms': now});
      });

  /// Category memberships per track, for the given tracks (or all).
  Future<Map<int, List<CategoryMembership>>> memberships({List<int>? trackIds}) async {
    final rows = trackIds == null
        ? await _db.query('track_categories')
        : await _db.query('track_categories',
            where: 'track_id IN (${List.filled(trackIds.length, '?').join(',')})', whereArgs: trackIds);
    final out = <int, List<CategoryMembership>>{};
    for (final r in rows) {
      final m = CategoryMembership.fromRow(r);
      (out[m.trackId] ??= []).add(m);
    }
    return out;
  }

  Future<Map<String, double>> predictions(int trackId) async => {
        for (final r in await _db.query('track_predictions', where: 'track_id = ?', whereArgs: [trackId], orderBy: 'score DESC'))
          r['label'] as String: (r['score'] as num).toDouble(),
      };

  Future<List<CategoryMembership>> overridesAsMemberships(int trackId) async => [
        for (final r in await _db.query('category_overrides', where: 'track_id = ?', whereArgs: [trackId]))
          CategoryMembership(
            trackId: trackId,
            categoryId: r['category_id'] as String,
            tier: r['mode'] as String,
            origin: 'user',
          ),
      ];

  Future<LibraryStats> stats(String? modelVersion) async {
    final r = await _db.rawQuery('''
      SELECT
        COUNT(*) AS total,
        SUM(CASE WHEN analysis_status = 'done' AND model_version IS ? AND analyzed_fingerprint = fingerprint THEN 1 ELSE 0 END) AS analyzed,
        SUM(CASE WHEN analysis_status = 'failed' THEN 1 ELSE 0 END) AS failed,
        SUM(CASE WHEN needs_review = 1 AND analysis_status = 'done' THEN 1 ELSE 0 END) AS review
      FROM tracks WHERE available = 1''', [modelVersion]);
    final organized = await _db.rawQuery('''
      SELECT COUNT(DISTINCT c.track_id) AS n FROM track_categories c JOIN tracks t ON t.id = c.track_id
      WHERE t.available = 1 AND c.category_id NOT IN ('needs_review')''');
    final provisional = await _db.rawQuery('''
      SELECT COUNT(DISTINCT c.track_id) AS n FROM track_categories c JOIN tracks t ON t.id = c.track_id
      WHERE t.available = 1 AND c.tier = 'provisional' ''');
    final row = r.first;
    return LibraryStats(
      total: (row['total'] as int?) ?? 0,
      analyzed: (row['analyzed'] as int?) ?? 0,
      failed: (row['failed'] as int?) ?? 0,
      needsReview: (row['review'] as int?) ?? 0,
      organized: organized.first['n'] as int,
      provisional: provisional.first['n'] as int,
    );
  }

  Future<Map<String, int>> categoryCounts() async => {
        for (final r in await _db.rawQuery('''
          SELECT c.category_id AS id, COUNT(*) AS n FROM track_categories c
          JOIN tracks t ON t.id = c.track_id WHERE t.available = 1 GROUP BY c.category_id'''))
          r['id'] as String: r['n'] as int,
      };

  Future<List<Track>> failed() async =>
      (await _db.query('tracks', where: "available = 1 AND analysis_status = 'failed'")).map(Track.fromRow).toList();
}

class LibraryStats {
  const LibraryStats({
    this.total = 0,
    this.analyzed = 0,
    this.failed = 0,
    this.needsReview = 0,
    this.organized = 0,
    this.provisional = 0,
  });

  final int total;
  final int analyzed;
  final int failed;
  final int needsReview;
  final int organized;
  final int provisional;

  int get remaining => (total - analyzed - failed).clamp(0, total);
}
