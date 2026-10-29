// End-to-end tests of the organiser pipeline against a real SQLite database
// (sqflite_common_ffi). Audio decoding and inference are replaced by clearly
// labelled TEST DOUBLES: these tests verify the workflow (incremental scans,
// playlist maintenance, override precedence, persistence), NOT model accuracy.
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:mpl/ai/ai_playlist_manager.dart';
import 'package:mpl/ai/audio_classifier.dart';
import 'package:mpl/ai/audio_feature_extractor.dart';
import 'package:mpl/ai/model_manifest.dart';
import 'package:mpl/core/db/app_database.dart';
import 'package:mpl/core/models/category.dart';
import 'package:mpl/core/models/track.dart';
import 'package:mpl/data/catalog_repositories.dart';
import 'package:mpl/data/track_repository.dart';
import 'package:mpl/library/library_scanner.dart';
import 'package:mpl/library/library_services.dart';
import 'package:path/path.dart' as p;
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'helpers.dart';

class FakeDiscovery implements MediaDiscovery {
  List<DiscoveredAudio> items = [];

  @override
  Future<List<DiscoveredAudio>> discover() async => List.of(items);

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class FakeMetadata implements MetadataService {
  final genres = <String, String>{};

  @override
  Future<TrackMetadata> read(Track t) async => TrackMetadata(genre: genres[t.uri]);

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

/// TEST DOUBLE: returns silent-but-"audible" windows and remembers which uri
/// was decoded so [FakeClassifier] can return scripted scores for it.
class FakeExtractor implements AudioFeatureExtractor {
  String? lastUri;
  int calls = 0;
  final failing = <String>{};
  void Function(int call)? onExtract;

  @override
  Future<ExtractedAudio> extract(Track track, ModelManifest m) async {
    calls++;
    onExtract?.call(calls);
    if (failing.contains(track.uri)) throw AudioDecodeException('corrupt file');
    lastUri = track.uri;
    return ExtractedAudio(
      windows: List.generate(m.windowsPerTrack, (_) => Float32List(m.windowSamples)),
      levelsDb: List.filled(m.windowsPerTrack, -20),
      decodeFailures: 0,
    );
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

/// TEST DOUBLE classifier with scripted scores per uri.
class FakeClassifier implements AudioClassifier {
  FakeClassifier(this.extractor, {this.version = '1.0.0'});

  final FakeExtractor extractor;
  String version;
  bool available = true;
  final scripted = <String, Map<String, double>>{};

  ModelManifest get manifest => ModelManifest.parse(
        manifestJson(overrides: {'model_version': version}),
        knownCategoryIds: knownIds,
      );

  @override
  ModelStatus get status =>
      available ? ModelStatus(ModelState.ready, manifest: manifest) : const ModelStatus(ModelState.unavailable, reason: 'no model');

  @override
  Future<ModelStatus> initialize() async => status;

  @override
  Future<List<List<double>>> predictWindows(List<Float32List> windows) async {
    final s = scripted[extractor.lastUri] ?? const {};
    return [for (final _ in windows) scores(manifest, s)];
  }

  @override
  Future<void> dispose() async {}
}

DiscoveredAudio audio(String name, {int modified = 1, int size = 1000}) => DiscoveredAudio(
      sourceId: 'ms:$name',
      sourceType: 'mediastore',
      uri: 'content://media/$name',
      displayName: '$name.mp3',
      durationMs: 180000,
      sizeBytes: size,
      modifiedMs: modified,
    );

void main() {
  sqfliteFfiInit();
  late String dbPath;
  late AppDatabase db;
  late TrackRepository tracks;
  late AIPlaylistManager manager;
  late PlaylistRepository playlists;
  late FakeDiscovery discovery;
  late FakeExtractor extractor;
  late FakeClassifier classifier;
  late LibraryScanner scanner;

  Future<void> openAll() async {
    db = await AppDatabase.open(path: dbPath, factory: databaseFactoryFfi);
    tracks = TrackRepository(db.db);
    manager = AIPlaylistManager(db.db);
    playlists = PlaylistRepository(db.db);
    scanner = LibraryScanner(
      discovery: discovery,
      metadata: FakeMetadata(),
      extractor: extractor,
      classifier: classifier,
      tracks: tracks,
      categories: CategoryRepository(db.db),
      settings: SettingsRepository(db.db),
      playlists: manager,
      interTrackDelay: Duration.zero,
    );
  }

  setUp(() async {
    dbPath = p.join(Directory.systemTemp.createTempSync('mpl_test').path, 'lib.db');
    discovery = FakeDiscovery();
    extractor = FakeExtractor();
    classifier = FakeClassifier(extractor);
    await openAll();
    discovery.items = [audio('recitation'), audio('poem'), audio('song'), audio('unclear')];
    classifier.scripted.addAll({
      'content://media/recitation': {'quran': 0.97},
      'content://media/poem': {'naat': 0.9},
      'content://media/song': {'sad': 0.9, 'romantic': 0.6},
      'content://media/unclear': {'speech': 0.3, 'quran': 0.2},
    });
  });

  tearDown(() => db.close());

  Future<List<String>> titlesIn(String cat) async => [for (final t in await tracks.all(categoryId: cat)) t.title];

  test('tracks appear automatically in their virtual playlists', () async {
    await scanner.scan();
    expect(scanner.phase, ScanPhase.completed);
    expect(await titlesIn(CategoryIds.quran), ['recitation']);
    expect(await titlesIn(CategoryIds.naat), ['poem']);
    expect(await titlesIn(CategoryIds.sad), ['song']);
    expect(await titlesIn(CategoryIds.romantic), ['song']); // multi-label, provisional
    expect(await titlesIn(CategoryIds.needsReview), ['unclear']);
    final counts = await tracks.categoryCounts();
    expect(counts[CategoryIds.quran], 1);
    final song = (await tracks.all(query: 'song')).single;
    final m = (await tracks.memberships(trackIds: [song.id]))[song.id]!;
    expect(m.firstWhere((x) => x.categoryId == 'romantic').tier, AssignmentTier.provisional);
    expect(m.firstWhere((x) => x.categoryId == 'sad').tier, AssignmentTier.auto);
  });

  test('rescans are incremental and idempotent', () async {
    await scanner.scan();
    expect(extractor.calls, 4);
    await scanner.scan();
    await scanner.scan();
    expect(extractor.calls, 4, reason: 'unchanged library must not be re-analysed');
    expect((await tracks.all()).length, 4, reason: 'no duplicate tracks');
    expect(await titlesIn(CategoryIds.quran), ['recitation'], reason: 'no duplicate playlist rows');
  });

  test('only new or changed files are analysed', () async {
    await scanner.scan();
    discovery.items = [
      audio('recitation'),
      audio('poem', modified: 2), // content replaced
      audio('song'),
      audio('unclear'),
      audio('lecture'),
    ];
    classifier.scripted['content://media/lecture'] = {'speech': 0.95};
    await scanner.scan();
    expect(extractor.calls, 6);
    expect(await titlesIn(CategoryIds.speech), ['lecture']);
  });

  test('manual correction survives rescans and reclassification until reset', () async {
    await scanner.scan();
    final song = (await tracks.all(query: 'song')).single;
    await manager.setUserCategories(song.id, {CategoryIds.noha});
    expect(await titlesIn(CategoryIds.noha), ['song']);
    expect(await titlesIn(CategoryIds.sad), isEmpty);

    await scanner.reclassifyAll();
    expect(extractor.calls, 8, reason: 'reclassify re-ran inference');
    expect(await titlesIn(CategoryIds.noha), ['song']);
    expect(await titlesIn(CategoryIds.sad), isEmpty);

    await manager.resetOverrides(song.id);
    expect(await titlesIn(CategoryIds.sad), ['song']);
    expect(await titlesIn(CategoryIds.noha), isEmpty);
  });

  test('excluding one AI category keeps the others', () async {
    await scanner.scan();
    final song = (await tracks.all(query: 'song')).single;
    await manager.excludeCategory(song.id, CategoryIds.romantic);
    await scanner.reclassify([song.id]);
    expect(await titlesIn(CategoryIds.romantic), isEmpty);
    expect(await titlesIn(CategoryIds.sad), ['song']);
  });

  test('confirming a Needs Review track removes it from Needs Review', () async {
    await scanner.scan();
    final t = (await tracks.all(query: 'unclear')).single;
    await manager.setUserCategories(t.id, {CategoryIds.speech});
    expect(await titlesIn(CategoryIds.needsReview), isEmpty);
    expect(await titlesIn(CategoryIds.speech), ['unclear']);
  });

  test('a new model version re-analyses everything but keeps corrections', () async {
    await scanner.scan();
    final poem = (await tracks.all(query: 'poem')).single;
    await manager.setUserCategories(poem.id, {CategoryIds.manqabat});
    classifier.version = '2.0.0';
    await scanner.scan();
    expect(extractor.calls, 8);
    expect((await tracks.byId(poem.id))!.modelVersion, '2.0.0');
    expect(await titlesIn(CategoryIds.manqabat), ['poem']);
  });

  test('deleted sources leave listings without losing data, and come back', () async {
    await scanner.scan();
    final rec = (await tracks.all(query: 'recitation')).single;
    await tracks.setFavorite(rec.id, true);
    discovery.items = discovery.items.where((d) => d.sourceId != 'ms:recitation').toList();
    await scanner.scan();
    expect(await titlesIn(CategoryIds.quran), isEmpty);
    expect((await tracks.all()).map((t) => t.title), isNot(contains('recitation')));
    expect((await tracks.byId(rec.id))!.available, isFalse);

    discovery.items.add(audio('recitation'));
    await scanner.scan();
    expect(await titlesIn(CategoryIds.quran), ['recitation']);
    expect((await tracks.byId(rec.id))!.favorite, isTrue);
    expect(extractor.calls, 4, reason: 'unchanged file is not re-analysed when it reappears');
  });

  test('without a validated model tracks wait, then get analysed', () async {
    classifier.available = false;
    await scanner.scan();
    expect(scanner.message, contains('unavailable'));
    expect((await tracks.all()).every((t) => t.analysisStatus == AnalysisStatus.awaitingModel), isTrue);
    expect(await tracks.categoryCounts(), isEmpty);
    expect(extractor.calls, 0);

    classifier.available = true;
    await scanner.scan();
    expect(extractor.calls, 4);
    expect(await titlesIn(CategoryIds.quran), ['recitation']);
  });

  test('decode errors are recorded per track and do not stop the scan', () async {
    extractor.failing.add('content://media/poem');
    await scanner.scan();
    expect(scanner.errors.single.title, 'poem');
    final poem = (await tracks.all(query: 'poem')).single;
    expect(poem.analysisStatus, AnalysisStatus.failed);
    expect(poem.analysisError, contains('corrupt'));
    expect(await titlesIn(CategoryIds.quran), ['recitation']);
    final stats = await tracks.stats('1.0.0');
    expect(stats.failed, 1);
    expect(stats.analyzed, 3);
  });

  test('cancel keeps finished work and leaves the rest pending', () async {
    extractor.onExtract = (n) {
      if (n == 2) scanner.cancel();
    };
    await scanner.scan();
    expect(scanner.phase, ScanPhase.cancelled);
    final all = await tracks.all();
    expect(all.where((t) => t.analysisStatus == AnalysisStatus.done).length, 1);
    expect(all.where((t) => t.analysisStatus == AnalysisStatus.pending).length, 3);
    extractor.onExtract = null;
    await scanner.scan();
    expect(extractor.calls, 5, reason: 'only the interrupted track and the 2 never started run again');
    expect((await tracks.all()).every((t) => t.analysisStatus == AnalysisStatus.done), isTrue);
  });

  test('classifications and playlists persist across an app restart', () async {
    await scanner.scan();
    final song = (await tracks.all(query: 'song')).single;
    await manager.setUserCategories(song.id, {CategoryIds.dance});
    final pl = await playlists.create('Mine');
    await playlists.addTracks(pl, [song.id]);
    await db.close();

    await openAll(); // same file, fresh connection
    expect(await titlesIn(CategoryIds.quran), ['recitation']);
    expect(await titlesIn(CategoryIds.dance), ['song']);
    expect((await playlists.tracks(pl)).single.title, 'song');
    await scanner.scan();
    expect(extractor.calls, 4, reason: 'nothing re-analysed after restart');
  });

  test('user playlists are independent of AI playlists and reject duplicates', () async {
    await scanner.scan();
    final ids = [for (final t in await tracks.all()) t.id];
    final pl = await playlists.create('Road trip');
    expect(await playlists.addTracks(pl, ids), 4);
    expect(await playlists.addTracks(pl, ids), 0);
    await scanner.reclassifyAll();
    await manager.recomputeAll();
    expect((await playlists.tracks(pl)).length, 4);
  });

  test('disabling a category moves its tracks to Other Audio', () async {
    await scanner.scan();
    final cats = CategoryRepository(db.db);
    final quran = (await cats.all()).firstWhere((c) => c.id == CategoryIds.quran);
    await cats.update(quran.copyWith(enabled: false));
    await scanner.categoriesChanged();
    expect(await titlesIn(CategoryIds.quran), isEmpty);
    expect(await titlesIn(CategoryIds.other), ['recitation']);
  });

  test('stats report remaining and organised counts', () async {
    await scanner.scan();
    final s = await tracks.stats('1.0.0');
    expect(s.total, 4);
    expect(s.analyzed, 4);
    expect(s.remaining, 0);
    expect(s.organized, 3);
    expect(s.needsReview, 1);
  });

  test('discovery dedupe drops the SAF copy of a MediaStore file', () {
    final list = MediaDiscovery.dedupe([
      audio('a'),
      DiscoveredAudio(sourceId: 'saf:x', sourceType: 'saf', uri: 'content://x', displayName: 'a.mp3', sizeBytes: 1000),
    ]);
    expect(list.single.sourceId, 'ms:a');
  });
}
