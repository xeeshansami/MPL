import 'dart:convert';

import 'package:mpl/ai/model_manifest.dart';
import 'package:mpl/core/models/category.dart';

final knownIds = {for (final c in CategoryDefaults.all) c.id};

/// Builds a manifest JSON for tests. The thresholds here are test fixtures,
/// not evaluated values.
String manifestJson({
  List<String> labels = const ['quran', 'naat', 'noha', 'sad', 'romantic', 'speech', 'other'],
  bool multiLabel = true,
  String activation = 'sigmoid',
  double auto = 0.8,
  double provisional = 0.5,
  int testFiles = 100,
  Map<String, Object?>? overrides,
}) {
  final m = <String, Object?>{
    'schema_version': 1,
    'model_id': 'test-model',
    'model_version': '1.0.0',
    'model_file': 'test.tflite',
    'sha256': 'a' * 64,
    'input': {'sample_rate': 16000, 'channels': 1, 'window_samples': 80000},
    'output': {'activation': activation, 'multi_label': multiLabel},
    'aggregation': {'windows': 5},
    'labels': [
      for (final (i, l) in labels.indexed)
        {
          'index': i,
          'category_id': l,
          'thresholds': {'auto': auto, 'provisional': provisional},
        },
    ],
    'evaluation': {
      'dataset': 'fixture',
      'test_files': testFiles,
      'date': '2026-10-29',
      'threshold_method': 'fixture',
    },
    ...?overrides,
  };
  return jsonEncode(m);
}

ModelManifest testManifest({
  List<String> labels = const ['quran', 'naat', 'noha', 'sad', 'romantic', 'speech', 'other'],
  bool multiLabel = true,
}) =>
    ModelManifest.parse(manifestJson(labels: labels, multiLabel: multiLabel), knownCategoryIds: knownIds);

/// Score vector for [m] with the given label → score entries, others 0.01.
List<double> scores(ModelManifest m, Map<String, double> s) =>
    [for (final l in m.labels) s[l.categoryId] ?? 0.01];
