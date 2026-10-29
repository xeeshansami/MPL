import 'dart:math' as math;
import 'dart:typed_data';

import 'model_manifest.dart';

enum ModelState { uninitialized, loading, ready, unavailable }

class ModelStatus {
  const ModelStatus(this.state, {this.reason, this.manifest});

  const ModelStatus.uninitialized() : this(ModelState.uninitialized);

  final ModelState state;

  /// Human-readable explanation when [state] is [ModelState.unavailable].
  final String? reason;
  final ModelManifest? manifest;

  bool get isReady => state == ModelState.ready && manifest != null;
}

/// On-device audio classifier. Implementations receive model-ready mono
/// windows (manifest sample rate, `windowSamples` long, range [-1, 1]) and
/// return calibrated per-label probabilities for each window.
abstract interface class AudioClassifier {
  ModelStatus get status;

  Future<ModelStatus> initialize();

  /// One score list per window, ordered like `manifest.labels`.
  Future<List<List<double>>> predictWindows(List<Float32List> windows);

  Future<void> dispose();
}

/// Converts raw model outputs into calibrated probabilities as declared by
/// the manifest. Pure so it can be unit-tested without a model.
List<double> postprocessScores(List<double> raw, ModelManifest manifest) {
  List<double> probs;
  switch (manifest.activation) {
    case 'logits':
      probs = manifest.multiLabel ? raw.map(_sigmoid).toList() : softmax(raw);
    default:
      probs = List<double>.of(raw);
  }
  for (final label in manifest.labels) {
    final a = label.plattA, b = label.plattB;
    if (a == null || b == null) continue;
    final p = probs[label.index].clamp(1e-7, 1 - 1e-7);
    probs[label.index] = _sigmoid(a * math.log(p / (1 - p)) + b);
  }
  return probs;
}

List<double> softmax(List<double> x) {
  final maxV = x.reduce(math.max);
  final e = x.map((v) => math.exp(v - maxV)).toList();
  final sum = e.fold<double>(0, (a, b) => a + b);
  return e.map((v) => v / sum).toList();
}

double _sigmoid(double x) => 1 / (1 + math.exp(-x));
