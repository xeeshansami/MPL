import 'dart:math' as math;
import 'dart:typed_data';

/// Pure-Dart preprocessing shared by Android and iOS so that the model sees
/// identical input on both platforms: interleaved int16 PCM → mono float
/// [-1, 1] → band-limited resample to the model rate → fixed-length window.
abstract final class AudioPreprocessor {
  /// Averages channels of interleaved little-endian int16 PCM.
  static Float32List int16ToMono(Uint8List pcm, int channels) {
    if (channels < 1) throw ArgumentError.value(channels, 'channels');
    final samples = ByteData.sublistView(pcm);
    final frames = pcm.lengthInBytes ~/ (2 * channels);
    final out = Float32List(frames);
    for (var f = 0; f < frames; f++) {
      var acc = 0.0;
      for (var c = 0; c < channels; c++) {
        acc += samples.getInt16((f * channels + c) * 2, Endian.little);
      }
      out[f] = acc / (channels * 32768.0);
    }
    return out;
  }

  /// Windowed-sinc (Hann) resampler with an anti-aliasing cutoff at the
  /// lower Nyquist frequency.
  static Float32List resample(Float32List input, int fromRate, int toRate, {int zeroCrossings = 16}) {
    if (fromRate == toRate || input.isEmpty) return Float32List.fromList(input);
    final ratio = toRate / fromRate;
    final cutoff = math.min(1.0, ratio); // relative to input Nyquist
    final outLen = (input.length * ratio).floor();
    final out = Float32List(outLen);
    final half = (zeroCrossings / cutoff).ceil();
    for (var n = 0; n < outLen; n++) {
      final t = n / ratio;
      final center = t.floor();
      var acc = 0.0;
      var norm = 0.0;
      for (var k = center - half + 1; k <= center + half; k++) {
        if (k < 0 || k >= input.length) continue;
        final x = t - k;
        final w = 0.5 + 0.5 * math.cos(math.pi * x / (half + 1));
        final h = cutoff * _sinc(cutoff * x) * w;
        acc += input[k] * h;
        norm += h;
      }
      out[n] = norm.abs() > 1e-9 ? acc / norm : 0;
    }
    return out;
  }

  static double _sinc(double x) {
    if (x.abs() < 1e-9) return 1;
    final px = math.pi * x;
    return math.sin(px) / px;
  }

  /// Zero-pads (centred) or centre-crops to exactly [length] samples.
  static Float32List fitLength(Float32List input, int length) {
    if (input.length == length) return input;
    final out = Float32List(length);
    if (input.length > length) {
      final start = (input.length - length) ~/ 2;
      out.setRange(0, length, input, start);
    } else {
      final start = (length - input.length) ~/ 2;
      out.setRange(start, start + input.length, input);
    }
    return out;
  }

  /// RMS level in dBFS (−inf for digital silence, returned as −120).
  static double rmsDb(Float32List x) {
    if (x.isEmpty) return -120;
    var sum = 0.0;
    for (final v in x) {
      sum += v * v;
    }
    final rms = math.sqrt(sum / x.length);
    return rms <= 1e-6 ? -120 : 20 * math.log(rms) / math.ln10;
  }

  /// Start offsets (ms) of [count] analysis windows spread across the
  /// 10 %–90 % span of the track, so intros/outros don't dominate.
  static List<int> planWindows(int durationMs, int windowMs, int count) {
    if (durationMs <= windowMs || count <= 1) {
      return [math.max(0, (durationMs - windowMs) ~/ 2)];
    }
    final span = durationMs - windowMs;
    final lo = span * 0.1, hi = span * 0.9;
    return List.generate(count, (i) => (lo + (hi - lo) * i / (count - 1)).round());
  }
}

/// Converts one decoded native window into a model-ready window.
/// Top-level so it can run in a background isolate.
Float32List prepareWindow(({Uint8List pcm, int channels, int sourceRate, int targetRate, int length}) a) {
  final mono = AudioPreprocessor.int16ToMono(a.pcm, a.channels);
  final resampled = AudioPreprocessor.resample(mono, a.sourceRate, a.targetRate);
  return AudioPreprocessor.fitLength(resampled, a.length);
}
