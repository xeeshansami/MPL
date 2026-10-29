"""Export waveform -> category probabilities as a single LiteRT/TFLite model
and write the app manifest.

Graph: float32[1, WINDOW_SAMPLES] (16 kHz mono, [-1, 1]) -> YAMNet
embeddings -> mean+max pooling -> trained head -> sigmoid -> float32[1, L].

Only TFLite builtin ops are allowed (tflite_flutter does not ship the Flex
delegate by default). The exported model is checked against the TensorFlow
graph on real test windows before the manifest is written.
"""
from __future__ import annotations

import argparse
from pathlib import Path

import numpy as np

from common import (SAMPLE_RATE, WINDOW_SAMPLES, WINDOWS_PER_TRACK, YAMNET_HANDLE, fit_length,
                    load_json, plan_windows, save_json, sha256_file)


def main() -> None:
    ap = argparse.ArgumentParser()
    ap.add_argument("--build", type=Path, default=Path("build"))
    ap.add_argument("--data", type=Path, required=True, help="dataset root, for parity checks")
    ap.add_argument("--out", type=Path, default=Path("../../assets/models"))
    ap.add_argument("--version", required=True, help="model version, e.g. 2026.11.0")
    ap.add_argument("--model-id", default="mpl-audio-categories")
    args = ap.parse_args()

    import librosa
    import tensorflow as tf
    import tensorflow_hub as hub

    meta = load_json(args.build / "dataset.json")
    evaluation = load_json(args.build / "evaluation.json")
    labels = meta["labels"]
    yamnet = hub.load(YAMNET_HANDLE)
    head = tf.keras.models.load_model(args.build / "head.keras", compile=False)

    class Classifier(tf.Module):
        def __init__(self):
            super().__init__()
            self.yamnet = yamnet
            self.head = head

        @tf.function(input_signature=[tf.TensorSpec([1, WINDOW_SAMPLES], tf.float32, name="waveform")])
        def __call__(self, waveform):
            _, emb, _ = self.yamnet(tf.reshape(waveform, [-1]))
            pooled = tf.concat([tf.reduce_mean(emb, 0), tf.reduce_max(emb, 0)], 0)[tf.newaxis, :]
            return {"scores": tf.sigmoid(self.head(pooled))}

    module = Classifier()
    converter = tf.lite.TFLiteConverter.from_concrete_functions(
        [module.__call__.get_concrete_function()], module)
    converter.target_spec.supported_ops = [tf.lite.OpsSet.TFLITE_BUILTINS]
    try:
        tflite_bytes = converter.convert()
    except Exception as e:  # noqa: BLE001
        raise SystemExit(f"TFLite conversion with builtin ops failed: {e}\n"
                         "Do not enable SELECT_TF_OPS unless the app also bundles the Flex delegate.")

    args.out.mkdir(parents=True, exist_ok=True)
    model_file = f"{args.model_id}-{args.version}.tflite"
    model_path = args.out / model_file
    model_path.write_bytes(tflite_bytes)

    # Parity check on real test audio.
    interp = tf.lite.Interpreter(model_path=str(model_path))
    interp.allocate_tensors()
    inp, out = interp.get_input_details()[0], interp.get_output_details()[0]
    max_diff, checked = 0.0, 0
    # Numerical parity only (accuracy is measured by evaluate.py).
    for it in meta["files"][:20]:
        path = args.data / it["path"]
        dur = librosa.get_duration(path=str(path))
        off = plan_windows(dur, WINDOWS_PER_TRACK)[0]
        wav, _ = librosa.load(str(path), sr=SAMPLE_RATE, mono=True, offset=off, duration=WINDOW_SAMPLES / SAMPLE_RATE)
        x = fit_length(wav.astype(np.float32))[np.newaxis, :]
        ref = module(tf.constant(x))["scores"].numpy()
        interp.set_tensor(inp["index"], x)
        interp.invoke()
        got = interp.get_tensor(out["index"])
        max_diff = max(max_diff, float(np.abs(ref - got).max()))
        checked += 1
    if max_diff > 1e-3:
        raise SystemExit(f"TFLite output differs from TensorFlow by {max_diff:.2e}; not exporting manifest")

    manifest = {
        "schema_version": 1,
        "model_id": args.model_id,
        "model_version": args.version,
        "model_file": model_file,
        "sha256": sha256_file(model_path),
        "input": {"sample_rate": SAMPLE_RATE, "channels": 1, "window_samples": WINDOW_SAMPLES},
        "output": {"activation": "sigmoid", "multi_label": True},
        "aggregation": {"windows": WINDOWS_PER_TRACK, "method": "mean_of_audible_windows"},
        "labels": evaluation["labels"],
        "evaluation": {
            "dataset": evaluation["dataset"],
            "test_files": evaluation["test_files"],
            "date": evaluation["date"],
            "threshold_method": evaluation["threshold_method"],
            "summary": {"tflite_parity_max_abs_diff": max_diff, "tflite_parity_files": checked},
            "warnings": evaluation["warnings"],
        },
    }
    if [l["category_id"] for l in manifest["labels"]] != labels:
        raise SystemExit("label order mismatch between dataset and evaluation")
    save_json(args.out / "manifest.json", manifest)
    print(f"wrote {model_path} ({model_path.stat().st_size / 1e6:.1f} MB) and manifest.json; "
          f"parity max diff {max_diff:.2e} over {checked} files")


if __name__ == "__main__":
    main()
