import 'ai/ai_playlist_manager.dart';
import 'ai/audio_classifier.dart';
import 'ai/audio_feature_extractor.dart';
import 'ai/tflite_audio_classifier.dart';
import 'core/db/app_database.dart';
import 'core/models/category.dart';
import 'core/platform/native_media.dart';
import 'data/catalog_repositories.dart';
import 'data/track_repository.dart';
import 'library/library_scanner.dart';
import 'library/library_services.dart';
import 'player/player_controller.dart';

/// Composition root.
class AppServices {
  AppServices._({
    required this.database,
    required this.tracks,
    required this.categories,
    required this.playlists,
    required this.settings,
    required this.aiPlaylists,
    required this.classifier,
    required this.scanner,
    required this.importer,
    required this.player,
  });

  final AppDatabase database;
  final TrackRepository tracks;
  final CategoryRepository categories;
  final PlaylistRepository playlists;
  final SettingsRepository settings;
  final AIPlaylistManager aiPlaylists;
  final AudioClassifier classifier;
  final LibraryScanner scanner;
  final ImportService importer;
  final PlayerController player;

  static Future<AppServices> create() async {
    final database = await AppDatabase.open();
    final db = database.db;
    const native = NativeMedia();
    final tracks = TrackRepository(db);
    final categories = CategoryRepository(db);
    final settings = SettingsRepository(db);
    final aiPlaylists = AIPlaylistManager(db);
    final classifier = TfliteAudioClassifier(knownCategoryIds: {for (final c in CategoryDefaults.all) c.id});
    final scanner = LibraryScanner(
      discovery: MediaDiscovery(native, settings),
      metadata: MetadataService(native),
      extractor: AudioFeatureExtractor(native),
      classifier: classifier,
      tracks: tracks,
      categories: categories,
      settings: settings,
      playlists: aiPlaylists,
    );
    final player = PlayerController(tracks, settings);
    await player.init();
    return AppServices._(
      database: database,
      tracks: tracks,
      categories: categories,
      playlists: PlaylistRepository(db),
      settings: settings,
      aiPlaylists: aiPlaylists,
      classifier: classifier,
      scanner: scanner,
      importer: ImportService(native, settings),
      player: player,
    );
  }
}
