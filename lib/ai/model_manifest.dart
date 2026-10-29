import 'dart:convert';

/// Contract between the training/export workflow (tools/model_training) and
/// the app. A model is only used when its manifest validates: thresholds and
/// evaluation results must come from a real evaluation run, never defaults.
class ModelManifest {
  ModelManifest({
    required this.modelId,
    required this.modelVersion,
    required this.modelFile,
    required this.sha256,
    required this.sampleRate,
    required this.windowSamples,
    required this.activation,
    required this.multiLabel,
    required this.windowsPerTrack,
    required this.labels,
    required this.evaluation,
  });

  static const supportedSchema = 1;

  final String modelId;
  final String modelVersion;
  final String modelFile;
  final String sha256;
  final int sampleRate;
  final int windowSamples;

  /// 'sigmoid' | 'softmax' (already applied inside the model) or 'logits'.
  final String activation;
  final bool multiLabel;
  final int windowsPerTrack;
  final List<ManifestLabel> labels;
  final ModelEvaluation evaluation;

  double get windowSeconds => windowSamples / sampleRate;

  /// Parses and validates. Throws [FormatException] describing the first problem.
  factory ModelManifest.parse(String source, {required Set<String> knownCategoryIds}) {
    final Object? decoded;
    try {
      decoded = jsonDecode(source);
    } on FormatException catch (e) {
      throw FormatException('manifest.json is not valid JSON: ${e.message}');
    }
    if (decoded is! Map<String, dynamic>) throw const FormatException('manifest root must be an object');
    final m = decoded;
    T req<T>(Map<String, dynamic> map, String key) {
      final v = map[key];
      if (v is! T) throw FormatException('manifest field "$key" missing or not ${T.toString()}');
      return v;
    }

    final schema = req<int>(m, 'schema_version');
    if (schema != supportedSchema) {
      throw FormatException('unsupported manifest schema_version $schema (expected $supportedSchema)');
    }
    final input = req<Map<String, dynamic>>(m, 'input');
    final output = req<Map<String, dynamic>>(m, 'output');
    final sampleRate = req<int>(input, 'sample_rate');
    final channels = req<int>(input, 'channels');
    final windowSamples = req<int>(input, 'window_samples');
    if (channels != 1) throw const FormatException('only mono model input is supported');
    if (sampleRate < 8000 || sampleRate > 48000) throw FormatException('implausible sample_rate $sampleRate');
    if (windowSamples < sampleRate ~/ 2) throw const FormatException('window_samples shorter than 0.5 s');
    final activation = req<String>(output, 'activation');
    if (!const {'sigmoid', 'softmax', 'logits'}.contains(activation)) {
      throw FormatException('unknown output activation "$activation"');
    }
    final multiLabel = req<bool>(output, 'multi_label');
    if (activation == 'softmax' && multiLabel) {
      throw const FormatException('softmax output cannot be multi_label');
    }

    final rawLabels = req<List<dynamic>>(m, 'labels');
    if (rawLabels.isEmpty) throw const FormatException('labels must not be empty');
    final labels = <ManifestLabel>[];
    final seen = <String>{};
    for (final (i, raw) in rawLabels.indexed) {
      if (raw is! Map<String, dynamic>) throw FormatException('label $i must be an object');
      final label = ManifestLabel._parse(raw, req);
      if (label.index != i) throw FormatException('label "${label.categoryId}" has index ${label.index}, expected $i');
      if (!knownCategoryIds.contains(label.categoryId)) {
        throw FormatException('label "${label.categoryId}" does not match a supported category');
      }
      if (label.categoryId == 'needs_review') {
        throw const FormatException('"needs_review" is a workflow outcome, not a model label');
      }
      if (!seen.add(label.categoryId)) throw FormatException('duplicate label "${label.categoryId}"');
      labels.add(label);
    }

    final eval = ModelEvaluation._parse(req<Map<String, dynamic>>(m, 'evaluation'), req);
    final aggregation = m['aggregation'];
    final windows = aggregation is Map<String, dynamic> && aggregation['windows'] is int
        ? aggregation['windows'] as int
        : 5;

    final sha = req<String>(m, 'sha256').toLowerCase();
    if (!RegExp(r'^[0-9a-f]{64}$').hasMatch(sha)) throw const FormatException('sha256 must be 64 hex chars');

    return ModelManifest(
      modelId: req<String>(m, 'model_id'),
      modelVersion: req<String>(m, 'model_version'),
      modelFile: req<String>(m, 'model_file'),
      sha256: sha,
      sampleRate: sampleRate,
      windowSamples: windowSamples,
      activation: activation,
      multiLabel: multiLabel,
      windowsPerTrack: windows.clamp(1, 12),
      labels: labels,
      evaluation: eval,
    );
  }
}

class ManifestLabel {
  ManifestLabel({
    required this.index,
    required this.categoryId,
    required this.autoThreshold,
    required this.provisionalThreshold,
    this.plattA,
    this.plattB,
    this.metrics = const {},
  });

  final int index;
  final String categoryId;
  final double autoThreshold;
  final double provisionalThreshold;
  final double? plattA;
  final double? plattB;

  /// Per-category test metrics written by evaluate.py (precision, recall, f1, support...).
  final Map<String, num> metrics;

  static ManifestLabel _parse(
    Map<String, dynamic> m,
    T Function<T>(Map<String, dynamic>, String) req,
  ) {
    final id = req<String>(m, 'category_id');
    final t = req<Map<String, dynamic>>(m, 'thresholds');
    final auto = (req<num>(t, 'auto')).toDouble();
    final prov = (req<num>(t, 'provisional')).toDouble();
    if (!(prov > 0 && prov <= auto && auto <= 1)) {
      throw FormatException('label "$id": thresholds must satisfy 0 < provisional <= auto <= 1');
    }
    double? a, b;
    final cal = m['calibration'];
    if (cal is Map<String, dynamic>) {
      if (cal['type'] != 'platt') throw FormatException('label "$id": unsupported calibration ${cal['type']}');
      a = (req<num>(cal, 'a')).toDouble();
      b = (req<num>(cal, 'b')).toDouble();
    }
    final metrics = <String, num>{};
    final rawMetrics = m['metrics'];
    if (rawMetrics is Map<String, dynamic>) {
      rawMetrics.forEach((k, v) {
        if (v is num) metrics[k] = v;
      });
    }
    return ManifestLabel(
      index: req<int>(m, 'index'),
      categoryId: id,
      autoThreshold: auto,
      provisionalThreshold: prov,
      plattA: a,
      plattB: b,
      metrics: metrics,
    );
  }
}

class ModelEvaluation {
  ModelEvaluation({
    required this.dataset,
    required this.testFiles,
    required this.date,
    required this.thresholdMethod,
    this.summary = const {},
  });

  final String dataset;
  final int testFiles;
  final String date;
  final String thresholdMethod;
  final Map<String, num> summary;

  static ModelEvaluation _parse(
    Map<String, dynamic> m,
    T Function<T>(Map<String, dynamic>, String) req,
  ) {
    final testFiles = req<int>(m, 'test_files');
    if (testFiles <= 0) throw const FormatException('evaluation.test_files must be > 0 (model is unvalidated)');
    final summary = <String, num>{};
    final s = m['summary'];
    if (s is Map<String, dynamic>) {
      s.forEach((k, v) {
        if (v is num) summary[k] = v;
      });
    }
    return ModelEvaluation(
      dataset: req<String>(m, 'dataset'),
      testFiles: testFiles,
      date: req<String>(m, 'date'),
      thresholdMethod: req<String>(m, 'threshold_method'),
      summary: summary,
    );
  }
}
