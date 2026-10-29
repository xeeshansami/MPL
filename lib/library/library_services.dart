import 'dart:io';
import 'dart:isolate';

import 'package:audio_metadata_reader/audio_metadata_reader.dart' as amr;
import 'package:file_picker/file_picker.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:permission_handler/permission_handler.dart';

import '../core/models/track.dart';
import '../core/platform/native_media.dart';
import '../data/catalog_repositories.dart';

const audioExtensions = {'.mp3', '.m4a', '.aac', '.flac', '.wav', '.ogg', '.opus', '.aiff', '.aif', '.caf', '.alac'};

/// Finds audio the user has granted access to. Read-only: discovery never
/// modifies, moves or copies the user's files.
class MediaDiscovery {
  MediaDiscovery(this._native, this._settings);

  final NativeMedia _native;
  final SettingsRepository _settings;

  /// iOS: imported audio lives in the app's private Documents/Imported folder.
  static Future<Directory> importedDir() async {
    final dir = Directory(p.join((await getApplicationDocumentsDirectory()).path, 'Imported'));
    if (!await dir.exists()) await dir.create(recursive: true);
    return dir;
  }

  Future<bool> ensurePermission() async {
    if (!Platform.isAndroid) return true;
    final sdk = await _native.sdkInt();
    final perm = sdk >= 33 ? Permission.audio : Permission.storage;
    var status = await perm.status;
    if (!status.isGranted) status = await perm.request();
    return status.isGranted;
  }

  Future<List<DiscoveredAudio>> discover() async {
    final found = <DiscoveredAudio>[];
    if (Platform.isAndroid) {
      final useMediaStore = (await _settings.get('use_mediastore')) != 'false';
      if (useMediaStore && await ensurePermission()) {
        final minSec = int.tryParse(await _settings.get('min_duration_sec') ?? '') ?? 15;
        found.addAll(await _native.queryMediaStore(minDurationMs: minSec * 1000));
      }
      final sources = await _settings.sources();
      final docUris = [for (final s in sources) if (s.type == 'saf_doc') s.uri];
      for (final d in await _native.describeDocuments(docUris)) {
        if (d != null) found.add(d);
      }
      for (final s in sources.where((s) => s.type == 'saf_tree')) {
        try {
          found.addAll(await _native.listTree(s.uri));
        } catch (_) {
          // Folder permission revoked or volume unmounted: its tracks become unavailable.
        }
      }
    } else {
      found.addAll(await _listImported());
    }
    return dedupe(found);
  }

  /// The same file can be reachable through MediaStore and through SAF.
  /// Keep the first (MediaStore) entry for identical name + size.
  static List<DiscoveredAudio> dedupe(List<DiscoveredAudio> list) {
    final keys = <String>{};
    final out = <DiscoveredAudio>[];
    for (final d in list) {
      final key = d.sizeBytes == null ? d.sourceId : '${d.displayName.toLowerCase()}|${d.sizeBytes}';
      if (keys.add(key)) out.add(d);
    }
    return out;
  }

  Future<List<DiscoveredAudio>> _listImported() async {
    final root = await importedDir();
    final out = <DiscoveredAudio>[];
    await for (final e in root.list(recursive: true, followLinks: false)) {
      if (e is! File || !audioExtensions.contains(p.extension(e.path).toLowerCase())) continue;
      final stat = await e.stat();
      final rel = p.relative(e.path, from: root.path);
      out.add(DiscoveredAudio(
        sourceId: 'imported:$rel',
        sourceType: 'imported',
        uri: e.path,
        displayName: p.basename(e.path),
        folder: p.dirname(rel) == '.' ? null : p.dirname(rel),
        sizeBytes: stat.size,
        modifiedMs: stat.modified.millisecondsSinceEpoch,
      ));
    }
    return out;
  }
}

/// Reads tags and artwork. Artwork is cached in app storage; source files are
/// opened read-only.
class MetadataService {
  MetadataService(this._native);

  final NativeMedia _native;
  Directory? _artDir;

  Future<Directory> _artworkDir() async {
    if (_artDir != null) return _artDir!;
    final d = Directory(p.join((await getApplicationSupportDirectory()).path, 'artwork'));
    if (!await d.exists()) await d.create(recursive: true);
    return _artDir = d;
  }

  Future<TrackMetadata> read(Track t) async {
    final artPath = p.join((await _artworkDir()).path, '${t.id}.img');
    if (Platform.isAndroid) {
      final m = await _native.readMetadata(t.uri, artworkPath: artPath);
      if (m == null) return const TrackMetadata();
      return TrackMetadata(
        title: m['title'] as String?,
        artist: m['artist'] as String?,
        album: m['album'] as String?,
        albumArtist: m['albumArtist'] as String?,
        genre: m['genre'] as String?,
        durationMs: (m['durationMs'] as num?)?.toInt(),
        artworkPath: m['artworkWritten'] == true ? artPath : null,
      );
    }
    final path = t.uri;
    return Isolate.run(() => readTagsFromFile(path, artPath));
  }
}

/// Pure-Dart tag reader for local files (iOS imported audio). Top-level so it
/// can run in a background isolate.
TrackMetadata readTagsFromFile(String path, String artPath) {
  try {
    final m = amr.readMetadata(File(path), getImage: true);
    String? art;
    if (m.pictures.isNotEmpty && m.pictures.first.bytes.isNotEmpty) {
      File(artPath).writeAsBytesSync(m.pictures.first.bytes);
      art = artPath;
    }
    return TrackMetadata(
      title: m.title,
      artist: m.artist,
      album: m.album,
      albumArtist: m.albumArtist,
      genre: m.genres.isEmpty ? null : m.genres.join(', '),
      durationMs: m.duration?.inMilliseconds,
      artworkPath: art,
    );
  } catch (_) {
    return const TrackMetadata();
  }
}

/// Adds audio to the library.
///  * Android: Storage Access Framework with persisted read permission. The
///    file is referenced in place, never copied.
///  * iOS: Files picker; the picked copy is stored in app-private storage
///    (iOS gives apps no lasting access to files outside their container).
class ImportService {
  ImportService(this._native, this._settings);

  final NativeMedia _native;
  final SettingsRepository _settings;

  Future<int> importFiles() async {
    if (Platform.isAndroid) {
      final docs = await _native.pickAudioDocuments();
      for (final d in docs) {
        await _settings.addSource('saf_doc', d.uri, label: d.displayName);
      }
      return docs.length;
    }
    final picked = await FilePicker.pickFiles(type: FileType.audio);
    final dir = await MediaDiscovery.importedDir();
    var count = 0;
    for (final f in picked) {
      final src = f.path;
      if (src == null) continue;
      var target = File(p.join(dir.path, f.name));
      final srcLen = await File(src).length();
      if (await target.exists() && await target.length() == srcLen) continue; // already imported
      var n = 1;
      while (await target.exists()) {
        target = File(p.join(dir.path, '${p.basenameWithoutExtension(f.name)} ($n)${p.extension(f.name)}'));
        n++;
      }
      await File(src).copy(target.path);
      count++;
    }
    await FilePicker.clearTemporaryFiles();
    return count;
  }

  /// Android only: watch a whole folder through SAF.
  Future<bool> addFolder() async {
    final uri = await _native.pickFolder();
    if (uri == null) return false;
    await _settings.addSource('saf_tree', uri, label: Uri.decodeComponent(uri.split('/').last));
    return true;
  }

  Future<void> removeSource(LibrarySource s) async {
    await _native.releaseUri(s.uri);
    await _settings.removeSource(s.id);
  }
}
