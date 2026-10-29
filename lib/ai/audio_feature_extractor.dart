import 'dart:isolate';
import 'dart:typed_data';

import '../core/models/track.dart';
import '../core/platform/native_media.dart';
import 'audio_preprocessor.dart';
import 'model_manifest.dart';

class ExtractedAudio {
  const ExtractedAudio({required this.windows, required this.levelsDb, required this.decodeFailures});

  final List<Float32List> windows;
  final List<double> levelsDb;
  final int decodeFailures;
}

/// Decodes evenly spaced windows of a track (native decoder, background
/// thread) and prepares them for the model in a background isolate.
class AudioFeatureExtractor {
  AudioFeatureExtractor(this._native);

  final NativeMedia _native;

  Future<ExtractedAudio> extract(Track track, ModelManifest m) async {
    final windowMs = (m.windowSamples * 1000 / m.sampleRate).ceil();
    final offsets = AudioPreprocessor.planWindows(track.durationMs, windowMs, m.windowsPerTrack);
    final windows = <Float32List>[];
    final levels = <double>[];
    var failures = 0;
    Object? lastError;
    for (final offset in offsets) {
      try {
        final d = await _native.decodePcm(track.uri, offsetMs: offset, durationMs: windowMs);
        if (d.pcm.lengthInBytes < d.channels * 2 * (d.sampleRate ~/ 4)) {
          failures++; // under 0.25 s decoded
          continue;
        }
        final args = (
          pcm: d.pcm,
          channels: d.channels,
          sourceRate: d.sampleRate,
          targetRate: m.sampleRate,
          length: m.windowSamples,
        );
        final w = await Isolate.run(() => prepareWindow(args));
        windows.add(w);
        levels.add(AudioPreprocessor.rmsDb(w));
      } catch (e) {
        failures++;
        lastError = e;
      }
    }
    if (windows.isEmpty) {
      throw AudioDecodeException('Could not decode audio${lastError == null ? '' : ': $lastError'}');
    }
    return ExtractedAudio(windows: windows, levelsDb: levels, decodeFailures: failures);
  }
}

class AudioDecodeException implements Exception {
  AudioDecodeException(this.message);

  final String message;

  @override
  String toString() => message;
}
