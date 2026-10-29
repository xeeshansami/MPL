import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:mpl/ai/audio_classifier.dart';
import 'package:mpl/ai/model_manifest.dart';

import 'helpers.dart';

void main() {
  ModelManifest parse(String s) => ModelManifest.parse(s, knownCategoryIds: knownIds);

  test('valid manifest parses', () {
    final m = parse(manifestJson());
    expect(m.labels.map((l) => l.categoryId), contains('quran'));
    expect(m.windowSamples, 80000);
    expect(m.windowSeconds, 5);
    expect(m.multiLabel, isTrue);
  });

  test('rejects an unvalidated model (no evaluated test files)', () {
    expect(() => parse(manifestJson(testFiles: 0)), throwsFormatException);
  });

  test('rejects missing evaluation block', () {
    final j = jsonDecode(manifestJson()) as Map<String, dynamic>..remove('evaluation');
    expect(() => parse(jsonEncode(j)), throwsFormatException);
  });

  test('rejects labels the app does not support', () {
    expect(() => parse(manifestJson(labels: ['quran', 'jazz'])), throwsFormatException);
  });

  test('needs_review can never be a model label', () {
    expect(() => parse(manifestJson(labels: ['quran', 'needs_review'])), throwsFormatException);
  });

  test('rejects inconsistent thresholds', () {
    expect(() => parse(manifestJson(auto: 0.4, provisional: 0.6)), throwsFormatException);
    expect(() => parse(manifestJson(auto: 1.2, provisional: 0.6)), throwsFormatException);
  });

  test('rejects multi-label softmax', () {
    expect(() => parse(manifestJson(activation: 'softmax', multiLabel: true)), throwsFormatException);
  });

  test('rejects stereo input and bad checksum', () {
    expect(
      () => parse(manifestJson(overrides: {'input': {'sample_rate': 16000, 'channels': 2, 'window_samples': 80000}})),
      throwsFormatException,
    );
    expect(() => parse(manifestJson(overrides: {'sha256': 'xyz'})), throwsFormatException);
  });

  test('rejects garbage JSON', () {
    expect(() => parse('{not json'), throwsFormatException);
  });

  group('postprocessScores', () {
    test('sigmoid output passes through without calibration', () {
      final m = parse(manifestJson(labels: ['quran', 'naat']));
      expect(postprocessScores([0.9, 0.2], m), [0.9, 0.2]);
    });

    test('logits get sigmoid for multi-label and softmax for single-label', () {
      final ml = parse(manifestJson(labels: ['quran', 'naat'], activation: 'logits'));
      final p = postprocessScores([0.0, 2.0], ml);
      expect(p[0], closeTo(0.5, 1e-9));
      expect(p[1], closeTo(0.8808, 1e-4));
      final sl = parse(manifestJson(labels: ['quran', 'naat'], activation: 'logits', multiLabel: false));
      final q = postprocessScores([0.0, 0.0], sl);
      expect(q, [closeTo(0.5, 1e-9), closeTo(0.5, 1e-9)]);
    });

    test('platt calibration is applied per label', () {
      final j = jsonDecode(manifestJson(labels: ['quran'])) as Map<String, dynamic>;
      (j['labels'] as List).first['calibration'] = {'type': 'platt', 'a': 1.0, 'b': 1.0};
      final m = parse(jsonEncode(j));
      // logit(0.5) = 0 -> sigmoid(1) = 0.731
      expect(postprocessScores([0.5], m).single, closeTo(0.7311, 1e-4));
    });
  });
}
