import 'dart:isolate';
import 'dart:typed_data';

import 'package:crypto/crypto.dart' as crypto;
import 'package:flutter/services.dart';
import 'package:synchronized/synchronized.dart';
import 'package:tflite_flutter/tflite_flutter.dart';

import 'audio_classifier.dart';
import 'model_manifest.dart';

/// LiteRT/TensorFlow Lite classifier loaded from the app bundle. Nothing is
/// downloaded: if `assets/models/manifest.json` or the model it names is
/// missing, corrupted or inconsistent, the classifier reports
/// [ModelState.unavailable] with the reason and the AI feature stays off.
class TfliteAudioClassifier implements AudioClassifier {
  TfliteAudioClassifier({required this.knownCategoryIds, AssetBundle? bundle}) : _bundle = bundle ?? rootBundle;

  static const manifestAsset = 'assets/models/manifest.json';

  final Set<String> knownCategoryIds;
  final AssetBundle _bundle;
  final _lock = Lock();

  Interpreter? _interpreter;
  IsolateInterpreter? _isolate;
  ModelStatus _status = const ModelStatus.uninitialized();

  @override
  ModelStatus get status => _status;

  @override
  Future<ModelStatus> initialize() => _lock.synchronized(() async {
        if (_status.state == ModelState.ready) return _status;
        _status = const ModelStatus(ModelState.loading);
        _status = await _load();
        return _status;
      });

  Future<ModelStatus> _load() async {
    String manifestJson;
    try {
      manifestJson = await _bundle.loadString(manifestAsset, cache: false);
    } catch (_) {
      return const ModelStatus(
        ModelState.unavailable,
        reason: 'No trained model is bundled. Train and export one with tools/model_training, '
            'then place manifest.json and the .tflite file in assets/models/.',
      );
    }

    final ModelManifest manifest;
    try {
      manifest = ModelManifest.parse(manifestJson, knownCategoryIds: knownCategoryIds);
    } on FormatException catch (e) {
      return ModelStatus(ModelState.unavailable, reason: 'Invalid model manifest: ${e.message}');
    }

    final Uint8List bytes;
    try {
      final data = await _bundle.load('assets/models/${manifest.modelFile}');
      bytes = data.buffer.asUint8List(data.offsetInBytes, data.lengthInBytes);
    } catch (_) {
      return ModelStatus(ModelState.unavailable, reason: 'Model file "${manifest.modelFile}" is not bundled.');
    }

    final digest = await Isolate.run(() => crypto.sha256.convert(bytes).toString());
    if (digest != manifest.sha256) {
      return ModelStatus(ModelState.unavailable,
          reason: 'Model checksum mismatch: the bundled file is not the one that was evaluated.');
    }

    try {
      final interpreter = Interpreter.fromBuffer(bytes, options: InterpreterOptions()..threads = 2);
      final input = interpreter.getInputTensor(0);
      final output = interpreter.getOutputTensor(0);
      final inShape = input.shape.where((d) => d != 1).toList();
      if (input.type != TensorType.float32 || inShape.length != 1 || inShape.first != manifest.windowSamples) {
        interpreter.close();
        return ModelStatus(ModelState.unavailable,
            reason: 'Model input ${input.shape} ${input.type} does not match manifest '
                '[1, ${manifest.windowSamples}] float32.');
      }
      if (output.shape.last != manifest.labels.length || output.type != TensorType.float32) {
        interpreter.close();
        return ModelStatus(ModelState.unavailable,
            reason: 'Model output ${output.shape} does not match ${manifest.labels.length} manifest labels.');
      }
      _interpreter = interpreter;
      _isolate = await IsolateInterpreter.create(address: interpreter.address, debugName: 'mpl-ai');
      _manifestForRun = manifest;

      // Smoke test: silence must produce finite scores.
      final smoke = await _run(Float32List(manifest.windowSamples));
      if (smoke.any((v) => v.isNaN || v.isInfinite)) {
        await dispose();
        return const ModelStatus(ModelState.unavailable, reason: 'Model produced non-finite output on self-test.');
      }
    } catch (e) {
      await dispose();
      return ModelStatus(ModelState.unavailable, reason: 'Model failed to load in LiteRT: $e');
    }
    return ModelStatus(ModelState.ready, manifest: manifest);
  }

  ModelManifest? _manifestForRun;

  Future<List<double>> _run(Float32List window) async {
    final manifest = _manifestForRun!;
    final out = Uint8List(manifest.labels.length * 4);
    await _isolate!.run(window.buffer.asUint8List(window.offsetInBytes, window.lengthInBytes), out);
    final raw = out.buffer.asFloat32List().map((v) => v.toDouble()).toList();
    return postprocessScores(raw, manifest);
  }

  @override
  Future<List<List<double>>> predictWindows(List<Float32List> windows) => _lock.synchronized(() async {
        if (!_status.isReady) throw StateError('Model is not ready: ${_status.reason ?? _status.state.name}');
        final results = <List<double>>[];
        for (final w in windows) {
          if (w.length != _manifestForRun!.windowSamples) {
            throw ArgumentError('window has ${w.length} samples, model expects ${_manifestForRun!.windowSamples}');
          }
          results.add(await _run(w));
        }
        return results;
      });

  @override
  Future<void> dispose() async {
    await _isolate?.close();
    _isolate = null;
    _interpreter?.close();
    _interpreter = null;
    if (_status.state == ModelState.ready) _status = const ModelStatus.uninitialized();
  }
}
