import 'dart:io';

import 'package:flutter/services.dart';

import '../models/track.dart';

class DecodedPcm {
  const DecodedPcm({required this.pcm, required this.sampleRate, required this.channels});

  final Uint8List pcm;
  final int sampleRate;
  final int channels;
}

/// Thin wrapper over the `mpl/native` platform channel (see MediaBridge.kt and
/// AppDelegate.swift). Kept as a class so tests can substitute a fake.
class NativeMedia {
  const NativeMedia();

  static const _channel = MethodChannel('mpl/native');

  bool get isAndroid => Platform.isAndroid;

  Future<int> sdkInt() async => (await _channel.invokeMethod<int>('sdkInt')) ?? 0;

  Future<List<DiscoveredAudio>> queryMediaStore({int minDurationMs = 15000}) async {
    final list = await _channel.invokeListMethod<Map<Object?, Object?>>('queryMediaStore', {'minDurationMs': minDurationMs});
    return (list ?? const []).map(DiscoveredAudio.fromMap).toList();
  }

  Future<List<DiscoveredAudio>> pickAudioDocuments() async {
    final list = await _channel.invokeListMethod<Map<Object?, Object?>>('pickAudioDocuments');
    return (list ?? const []).map(DiscoveredAudio.fromMap).toList();
  }

  Future<String?> pickFolder() => _channel.invokeMethod<String>('pickFolder');

  Future<List<DiscoveredAudio>> listTree(String uri) async {
    final list = await _channel.invokeListMethod<Map<Object?, Object?>>('listTree', {'uri': uri});
    return (list ?? const []).map(DiscoveredAudio.fromMap).toList();
  }

  /// Current size/mtime of persisted single documents; null when inaccessible.
  Future<List<DiscoveredAudio?>> describeDocuments(List<String> uris) async {
    if (uris.isEmpty) return const [];
    final list = await _channel.invokeListMethod<Map<Object?, Object?>?>('describeDocuments', {'uris': uris});
    return [for (final m in list ?? const []) m == null ? null : DiscoveredAudio.fromMap(m)];
  }

  Future<void> releaseUri(String uri) => _channel.invokeMethod('releaseUri', {'uri': uri});

  Future<List<bool>> checkAccessible(List<String> uris) async {
    if (uris.isEmpty) return const [];
    final r = await _channel.invokeListMethod<bool>('checkAccessible', {'uris': uris});
    return r ?? List.filled(uris.length, false);
  }

  /// Android only: MediaMetadataRetriever. Writes embedded art to [artworkPath].
  Future<Map<Object?, Object?>?> readMetadata(String uri, {String? artworkPath}) =>
      _channel.invokeMapMethod<Object?, Object?>('readMetadata', {'uri': uri, 'artworkPath': artworkPath});

  Future<DecodedPcm> decodePcm(String uri, {required int offsetMs, required int durationMs}) async {
    final r = await _channel.invokeMapMethod<String, Object?>(
      'decodePcm',
      {'uri': uri, 'offsetMs': offsetMs, 'durationMs': durationMs},
    );
    if (r == null) throw const FormatException('decoder returned nothing');
    return DecodedPcm(
      pcm: r['pcm'] as Uint8List,
      sampleRate: r['sampleRate'] as int,
      channels: r['channels'] as int,
    );
  }
}
