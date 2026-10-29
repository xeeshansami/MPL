import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:mpl/ai/audio_preprocessor.dart';
import 'package:mpl/ai/metadata_rules.dart';
import 'package:mpl/core/models/category.dart';

Float32List sine(double freq, int rate, double seconds, {double amp = 0.5}) {
  final n = (rate * seconds).round();
  return Float32List.fromList([for (var i = 0; i < n; i++) amp * math.sin(2 * math.pi * freq * i / rate)]);
}

int zeroCrossings(Float32List x) {
  var c = 0;
  for (var i = 1; i < x.length; i++) {
    if ((x[i - 1] < 0) != (x[i] < 0)) c++;
  }
  return c;
}

void main() {
  group('AudioPreprocessor', () {
    test('int16 stereo → mono average in [-1, 1]', () {
      final bd = ByteData(8)
        ..setInt16(0, 32767, Endian.little)
        ..setInt16(2, -32768, Endian.little)
        ..setInt16(4, 16384, Endian.little)
        ..setInt16(6, 16384, Endian.little);
      final mono = AudioPreprocessor.int16ToMono(bd.buffer.asUint8List(), 2);
      expect(mono.length, 2);
      expect(mono[0], closeTo(0, 1e-4));
      expect(mono[1], closeTo(0.5, 1e-4));
    });

    test('resampling 44.1 kHz → 16 kHz preserves frequency and amplitude', () {
      final src = sine(440, 44100, 1.0);
      final out = AudioPreprocessor.resample(src, 44100, 16000);
      expect(out.length, 16000);
      // 440 Hz → ~880 zero crossings per second
      expect(zeroCrossings(out), inInclusiveRange(875, 885));
      final mid = out.sublist(2000, 14000);
      final peak = mid.map((v) => v.abs()).reduce(math.max);
      expect(peak, closeTo(0.5, 0.02));
    });

    test('resampling removes content above the new Nyquist (anti-aliasing)', () {
      final src = sine(12000, 44100, 0.5); // above 8 kHz Nyquist of 16 kHz
      final out = AudioPreprocessor.resample(src, 44100, 16000);
      final level = AudioPreprocessor.rmsDb(Float32List.sublistView(out, 500, out.length - 500));
      expect(level, lessThan(-30));
    });

    test('fitLength pads and crops around the centre', () {
      final short = Float32List.fromList([1, 1]);
      expect(AudioPreprocessor.fitLength(short, 6), [0, 0, 1, 1, 0, 0]);
      final long = Float32List.fromList([1, 2, 3, 4, 5, 6]);
      expect(AudioPreprocessor.fitLength(long, 2), [3, 4]);
    });

    test('planWindows spreads windows across 10–90 % and handles short tracks', () {
      final w = AudioPreprocessor.planWindows(105000, 5000, 5);
      expect(w.first, 10000);
      expect(w.last, 90000);
      expect(w.length, 5);
      expect(AudioPreprocessor.planWindows(3000, 5000, 5), [0]);
      expect(AudioPreprocessor.planWindows(0, 5000, 5), [0]);
    });

    test('rmsDb', () {
      expect(AudioPreprocessor.rmsDb(Float32List(100)), -120);
      expect(AudioPreprocessor.rmsDb(Float32List.fromList(List.filled(100, 1.0))), closeTo(0, 1e-6));
    });
  });

  group('MetadataRules', () {
    final rules = MetadataRules(CategoryDefaults.all);

    test('genre tag is strong evidence, title medium, filename weak', () {
      final r = rules.evaluate(genre: 'Quran', title: 'Naat Sharif', filename: 'noha_2024.mp3');
      final by = {for (final m in r) m.categoryId: m.strength};
      expect(by['quran'], EvidenceStrength.strong);
      expect(by['naat'], EvidenceStrength.medium);
      expect(by['noha'], EvidenceStrength.weak);
    });

    test('whole-token matching only', () {
      expect(rules.evaluate(title: 'Sadness Within'), isEmpty);
      expect(rules.evaluate(title: 'Popcorn'), isEmpty);
      expect(rules.evaluate(title: 'A Sad Song').map((m) => m.categoryId), contains('sad'));
    });

    test('apostrophes and Urdu / Arabic script', () {
      expect(rules.evaluate(title: "Na'at e Rasool").map((m) => m.categoryId), contains('naat'));
      expect(rules.evaluate(title: 'نعت شریف').map((m) => m.categoryId), contains('naat'));
      expect(rules.evaluate(album: 'سورة الرحمن').map((m) => m.categoryId), contains('quran'));
    });

    test('disabled categories are not matched', () {
      final r = MetadataRules([
        for (final c in CategoryDefaults.all) c.id == 'quran' ? c.copyWith(enabled: false) : c,
      ]);
      expect(r.evaluate(genre: 'Quran'), isEmpty);
    });
  });
}
