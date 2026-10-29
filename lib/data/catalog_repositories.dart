import 'dart:convert';

import 'package:sqflite/sqflite.dart';

import '../ai/category_resolver.dart';
import '../core/models/category.dart';
import '../core/models/track.dart';

class CategoryRepository {
  CategoryRepository(this._db);

  final Database _db;

  Future<List<AiCategory>> all() async =>
      (await _db.query('categories', orderBy: 'sort_order')).map(AiCategory.fromRow).toList();

  Future<void> update(AiCategory c) =>
      _db.update('categories', {'name': c.name, 'enabled': c.enabled ? 1 : 0, 'keywords': jsonEncode(c.keywords)},
          where: 'id = ?', whereArgs: [c.id]);
}

class UserPlaylist {
  const UserPlaylist({required this.id, required this.name, required this.trackCount});

  final int id;
  final String name;
  final int trackCount;
}

/// User-created playlists. Independent from AI playlists: AI rescans never
/// read or write these tables.
class PlaylistRepository {
  PlaylistRepository(this._db);

  final Database _db;

  int get _now => DateTime.now().millisecondsSinceEpoch;

  Future<List<UserPlaylist>> all() async => [
        for (final r in await _db.rawQuery('''
          SELECT p.id, p.name, COUNT(t.id) AS n FROM playlists p
          LEFT JOIN playlist_items i ON i.playlist_id = p.id
          LEFT JOIN tracks t ON t.id = i.track_id AND t.available = 1
          GROUP BY p.id ORDER BY p.updated_ms DESC'''))
          UserPlaylist(id: r['id'] as int, name: r['name'] as String, trackCount: r['n'] as int),
      ];

  Future<int> create(String name) => _db.insert('playlists', {'name': name, 'created_ms': _now, 'updated_ms': _now});

  Future<void> rename(int id, String name) =>
      _db.update('playlists', {'name': name, 'updated_ms': _now}, where: 'id = ?', whereArgs: [id]);

  Future<void> delete(int id) => _db.delete('playlists', where: 'id = ?', whereArgs: [id]);

  /// Adds tracks at the end; tracks already present are ignored (no duplicates).
  Future<int> addTracks(int playlistId, List<int> trackIds) => _db.transaction((txn) async {
        final maxRow = await txn.rawQuery('SELECT COALESCE(MAX(position), -1) AS m FROM playlist_items WHERE playlist_id = ?', [playlistId]);
        var pos = (maxRow.first['m'] as int) + 1;
        var added = 0;
        for (final id in trackIds) {
          final r = await txn.insert(
            'playlist_items',
            {'playlist_id': playlistId, 'track_id': id, 'position': pos, 'added_ms': _now},
            conflictAlgorithm: ConflictAlgorithm.ignore,
          );
          if (r > 0) {
            pos++;
            added++;
          }
        }
        await txn.update('playlists', {'updated_ms': _now}, where: 'id = ?', whereArgs: [playlistId]);
        return added;
      });

  Future<void> removeTrack(int playlistId, int trackId) =>
      _db.delete('playlist_items', where: 'playlist_id = ? AND track_id = ?', whereArgs: [playlistId, trackId]);

  Future<void> reorder(int playlistId, List<int> orderedTrackIds) => _db.transaction((txn) async {
        for (final (i, id) in orderedTrackIds.indexed) {
          await txn.update('playlist_items', {'position': i},
              where: 'playlist_id = ? AND track_id = ?', whereArgs: [playlistId, id]);
        }
      });

  Future<List<Track>> tracks(int playlistId) async => (await _db.rawQuery('''
        SELECT t.* FROM playlist_items i JOIN tracks t ON t.id = i.track_id
        WHERE i.playlist_id = ? AND t.available = 1 ORDER BY i.position''', [playlistId]))
      .map(Track.fromRow)
      .toList();
}

class LibrarySource {
  const LibrarySource({required this.id, required this.type, required this.uri, this.label});

  final int id;

  /// 'saf_tree' (Android folder) or 'saf_doc' (Android single document).
  final String type;
  final String uri;
  final String? label;
}

class SettingsRepository {
  SettingsRepository(this._db);

  final Database _db;

  Future<String?> get(String key) async {
    final r = await _db.query('settings', where: 'key = ?', whereArgs: [key]);
    return r.isEmpty ? null : r.first['value'] as String?;
  }

  Future<void> set(String key, String? value) =>
      _db.insert('settings', {'key': key, 'value': value}, conflictAlgorithm: ConflictAlgorithm.replace);

  Future<ClassificationPolicy> policy() async {
    final raw = await get('classification_policy');
    if (raw == null) return const ClassificationPolicy();
    return ClassificationPolicy.fromJson(jsonDecode(raw) as Map<String, Object?>);
  }

  Future<void> setPolicy(ClassificationPolicy p) => set('classification_policy', jsonEncode(p.toJson()));

  Future<List<LibrarySource>> sources() async => [
        for (final r in await _db.query('library_sources', orderBy: 'added_ms'))
          LibrarySource(id: r['id'] as int, type: r['type'] as String, uri: r['uri'] as String, label: r['label'] as String?),
      ];

  Future<void> addSource(String type, String uri, {String? label}) => _db.insert(
        'library_sources',
        {'type': type, 'uri': uri, 'label': label, 'added_ms': DateTime.now().millisecondsSinceEpoch},
        conflictAlgorithm: ConflictAlgorithm.ignore,
      );

  Future<void> removeSource(int id) => _db.delete('library_sources', where: 'id = ?', whereArgs: [id]);
}
