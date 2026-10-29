import 'package:path/path.dart' as p;
import 'package:sqflite/sqflite.dart';

import '../models/category.dart';

/// SQLite schema for the library, AI classifications and user data.
///
/// Organisation is purely virtual: rows reference audio by URI and the
/// original files are never moved, renamed, copied or deleted.
class AppDatabase {
  AppDatabase._(this.db);

  final Database db;

  static const int schemaVersion = 1;

  static Future<AppDatabase> open({String? path, DatabaseFactory? factory}) async {
    final f = factory ?? databaseFactory;
    final dbPath = path ?? p.join(await f.getDatabasesPath(), 'mpl_library.db');
    final db = await f.openDatabase(
      dbPath,
      options: OpenDatabaseOptions(
        version: schemaVersion,
        onConfigure: (db) => db.execute('PRAGMA foreign_keys = ON'),
        onCreate: (db, _) => _create(db),
      ),
    );
    return AppDatabase._(db);
  }

  Future<void> close() => db.close();

  static Future<void> _create(Database db) async {
    final b = db.batch();
    b.execute('''
      CREATE TABLE tracks(
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        source_id TEXT NOT NULL UNIQUE,
        source_type TEXT NOT NULL,
        uri TEXT NOT NULL,
        filename TEXT NOT NULL,
        folder TEXT,
        title TEXT NOT NULL,
        artist TEXT,
        album TEXT,
        album_artist TEXT,
        genre TEXT,
        duration_ms INTEGER NOT NULL DEFAULT 0,
        size_bytes INTEGER,
        source_modified_ms INTEGER,
        fingerprint TEXT NOT NULL,
        metadata_fingerprint TEXT,
        artwork_path TEXT,
        available INTEGER NOT NULL DEFAULT 1,
        favorite INTEGER NOT NULL DEFAULT 0,
        play_count INTEGER NOT NULL DEFAULT 0,
        last_played_ms INTEGER,
        added_ms INTEGER NOT NULL,
        analysis_status TEXT NOT NULL DEFAULT 'pending',
        analysis_error TEXT,
        analyzed_fingerprint TEXT,
        model_version TEXT,
        analyzed_ms INTEGER,
        needs_review INTEGER NOT NULL DEFAULT 0,
        evidence_json TEXT
      )''');
    b.execute('CREATE INDEX idx_tracks_status ON tracks(available, analysis_status)');
    // Calibrated model scores from the latest analysis, one row per model label.
    b.execute('''
      CREATE TABLE track_predictions(
        track_id INTEGER NOT NULL REFERENCES tracks(id) ON DELETE CASCADE,
        label TEXT NOT NULL,
        score REAL NOT NULL,
        PRIMARY KEY(track_id, label)
      )''');
    // What the AI decided, before user overrides are applied.
    b.execute('''
      CREATE TABLE ai_assignments(
        track_id INTEGER NOT NULL REFERENCES tracks(id) ON DELETE CASCADE,
        category_id TEXT NOT NULL,
        confidence REAL,
        tier TEXT NOT NULL,
        PRIMARY KEY(track_id, category_id)
      )''');
    // User corrections. They take precedence over every future AI prediction
    // until explicitly reset.
    b.execute('''
      CREATE TABLE category_overrides(
        track_id INTEGER NOT NULL REFERENCES tracks(id) ON DELETE CASCADE,
        category_id TEXT NOT NULL,
        mode TEXT NOT NULL CHECK(mode IN ('include','exclude')),
        created_ms INTEGER NOT NULL,
        PRIMARY KEY(track_id, category_id)
      )''');
    // Materialised virtual AI playlists = AI assignments + overrides.
    b.execute('''
      CREATE TABLE track_categories(
        track_id INTEGER NOT NULL REFERENCES tracks(id) ON DELETE CASCADE,
        category_id TEXT NOT NULL,
        confidence REAL,
        tier TEXT NOT NULL,
        origin TEXT NOT NULL,
        PRIMARY KEY(track_id, category_id)
      )''');
    b.execute('CREATE INDEX idx_track_categories_cat ON track_categories(category_id)');
    b.execute('''
      CREATE TABLE categories(
        id TEXT PRIMARY KEY,
        name TEXT NOT NULL,
        description TEXT NOT NULL,
        enabled INTEGER NOT NULL DEFAULT 1,
        sort_order INTEGER NOT NULL,
        keywords TEXT NOT NULL DEFAULT '[]',
        builtin INTEGER NOT NULL DEFAULT 1
      )''');
    b.execute('''
      CREATE TABLE playlists(
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        name TEXT NOT NULL,
        created_ms INTEGER NOT NULL,
        updated_ms INTEGER NOT NULL
      )''');
    b.execute('''
      CREATE TABLE playlist_items(
        playlist_id INTEGER NOT NULL REFERENCES playlists(id) ON DELETE CASCADE,
        track_id INTEGER NOT NULL REFERENCES tracks(id) ON DELETE CASCADE,
        position INTEGER NOT NULL,
        added_ms INTEGER NOT NULL,
        PRIMARY KEY(playlist_id, track_id)
      )''');
    b.execute('''
      CREATE TABLE play_history(
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        track_id INTEGER NOT NULL REFERENCES tracks(id) ON DELETE CASCADE,
        played_ms INTEGER NOT NULL
      )''');
    b.execute('''
      CREATE TABLE library_sources(
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        type TEXT NOT NULL,
        uri TEXT NOT NULL UNIQUE,
        label TEXT,
        added_ms INTEGER NOT NULL
      )''');
    b.execute('CREATE TABLE settings(key TEXT PRIMARY KEY, value TEXT)');
    for (final (i, c) in CategoryDefaults.all.indexed) {
      b.insert('categories', {...c.toRow(), 'sort_order': i});
    }
    await b.commit(noResult: true);
  }
}
