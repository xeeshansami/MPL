/// Analysis lifecycle of a track.
abstract final class AnalysisStatus {
  static const pending = 'pending';
  static const processing = 'processing';
  static const done = 'done';
  static const failed = 'failed';

  /// Waiting because no validated model is bundled.
  static const awaitingModel = 'awaiting_model';
}

/// How a track's category membership was decided.
abstract final class AssignmentTier {
  /// High confidence: assigned automatically.
  static const auto = 'auto';

  /// Medium confidence: assigned provisionally, correction offered.
  static const provisional = 'provisional';

  /// Confirmed or chosen by the user.
  static const user = 'user';

  /// Workflow placement (Needs Review / Other Audio).
  static const workflow = 'workflow';
}

class Track {
  const Track({
    required this.id,
    required this.sourceId,
    required this.sourceType,
    required this.uri,
    required this.filename,
    required this.title,
    this.folder,
    this.artist,
    this.album,
    this.albumArtist,
    this.genre,
    this.durationMs = 0,
    this.sizeBytes,
    this.fingerprint = '',
    this.artworkPath,
    this.available = true,
    this.favorite = false,
    this.playCount = 0,
    this.lastPlayedMs,
    this.addedMs = 0,
    this.analysisStatus = AnalysisStatus.pending,
    this.analysisError,
    this.modelVersion,
    this.analyzedMs,
    this.needsReview = false,
    this.evidenceJson,
  });

  final int id;
  final String sourceId;
  final String sourceType;
  final String uri;
  final String filename;
  final String? folder;
  final String title;
  final String? artist;
  final String? album;
  final String? albumArtist;
  final String? genre;
  final int durationMs;
  final int? sizeBytes;
  final String fingerprint;
  final String? artworkPath;
  final bool available;
  final bool favorite;
  final int playCount;
  final int? lastPlayedMs;
  final int addedMs;
  final String analysisStatus;
  final String? analysisError;
  final String? modelVersion;
  final int? analyzedMs;
  final bool needsReview;
  final String? evidenceJson;

  String get displayArtist => (artist == null || artist!.isEmpty) ? 'Unknown artist' : artist!;
  String get displayAlbum => (album == null || album!.isEmpty) ? 'Unknown album' : album!;
  Duration get duration => Duration(milliseconds: durationMs);

  factory Track.fromRow(Map<String, Object?> r) => Track(
        id: r['id'] as int,
        sourceId: r['source_id'] as String,
        sourceType: r['source_type'] as String,
        uri: r['uri'] as String,
        filename: r['filename'] as String,
        folder: r['folder'] as String?,
        title: r['title'] as String,
        artist: r['artist'] as String?,
        album: r['album'] as String?,
        albumArtist: r['album_artist'] as String?,
        genre: r['genre'] as String?,
        durationMs: (r['duration_ms'] as int?) ?? 0,
        sizeBytes: r['size_bytes'] as int?,
        fingerprint: r['fingerprint'] as String,
        artworkPath: r['artwork_path'] as String?,
        available: (r['available'] as int) == 1,
        favorite: (r['favorite'] as int) == 1,
        playCount: r['play_count'] as int,
        lastPlayedMs: r['last_played_ms'] as int?,
        addedMs: r['added_ms'] as int,
        analysisStatus: r['analysis_status'] as String,
        analysisError: r['analysis_error'] as String?,
        modelVersion: r['model_version'] as String?,
        analyzedMs: r['analyzed_ms'] as int?,
        needsReview: (r['needs_review'] as int) == 1,
        evidenceJson: r['evidence_json'] as String?,
      );
}

/// A track's membership in one AI category (virtual playlist row).
class CategoryMembership {
  const CategoryMembership({
    required this.trackId,
    required this.categoryId,
    required this.tier,
    required this.origin,
    this.confidence,
  });

  final int trackId;
  final String categoryId;
  final double? confidence;
  final String tier;

  /// 'ai' | 'user' | 'workflow'
  final String origin;

  factory CategoryMembership.fromRow(Map<String, Object?> r) => CategoryMembership(
        trackId: r['track_id'] as int,
        categoryId: r['category_id'] as String,
        confidence: (r['confidence'] as num?)?.toDouble(),
        tier: r['tier'] as String,
        origin: r['origin'] as String,
      );
}

/// A discovered audio source, before it is stored as a [Track].
class DiscoveredAudio {
  const DiscoveredAudio({
    required this.sourceId,
    required this.sourceType,
    required this.uri,
    required this.displayName,
    this.title,
    this.artist,
    this.album,
    this.genre,
    this.folder,
    this.durationMs,
    this.sizeBytes,
    this.modifiedMs,
  });

  final String sourceId;
  final String sourceType;
  final String uri;
  final String displayName;
  final String? title;
  final String? artist;
  final String? album;
  final String? genre;
  final String? folder;
  final int? durationMs;
  final int? sizeBytes;
  final int? modifiedMs;

  /// Changes whenever the underlying file content is replaced.
  String get fingerprint => '${sizeBytes ?? -1}:${modifiedMs ?? -1}';

  factory DiscoveredAudio.fromMap(Map<Object?, Object?> m) => DiscoveredAudio(
        sourceId: m['sourceId'] as String,
        sourceType: m['sourceType'] as String,
        uri: m['uri'] as String,
        displayName: (m['displayName'] as String?) ?? 'Unknown',
        title: m['title'] as String?,
        artist: m['artist'] as String?,
        album: m['album'] as String?,
        genre: m['genre'] as String?,
        folder: m['folder'] as String?,
        durationMs: (m['durationMs'] as num?)?.toInt(),
        sizeBytes: (m['size'] as num?)?.toInt(),
        modifiedMs: (m['dateModifiedMs'] as num?)?.toInt(),
      );
}

/// Metadata read from tags (or the platform media index).
class TrackMetadata {
  const TrackMetadata({
    this.title,
    this.artist,
    this.album,
    this.albumArtist,
    this.genre,
    this.durationMs,
    this.artworkPath,
  });

  final String? title;
  final String? artist;
  final String? album;
  final String? albumArtist;
  final String? genre;
  final int? durationMs;
  final String? artworkPath;
}
