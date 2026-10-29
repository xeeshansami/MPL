"""Train the classification head on pooled YAMNet embeddings.

Multi-label sigmoid output (a track can be e.g. both romantic and sad).
YAMNet stays frozen; only the small head is trained, which keeps the data
requirement realistic for niche categories such as Noha or Manqabat.
"""
from __future__ import annotations

import argparse
from pathlib import Path

import numpy as np

from common import load_json, save_json


def main() -> None:
    ap = argparse.ArgumentParser()
    ap.add_argument("--build", type=Path, default=Path("build"))
    ap.add_argument("--epochs", type=int, default=200)
    ap.add_argument("--seed", type=int, default=13)
    args = ap.parse_args()

    import tensorflow as tf

    tf.keras.utils.set_random_seed(args.seed)
    d = np.load(args.build / "features.npz")
    meta = load_json(args.build / "dataset.json")
    labels = meta["labels"]
    x, y, split = d["x"], d["y"], d["split"]
    tr, va = split == "train", split == "val"
    if not va.any():
        raise SystemExit("validation split is empty; add more data per label")

    # Balance positives vs negatives per label.
    pos = y[tr].sum(axis=0)
    neg = tr.sum() - pos
    pos_weight = np.where(pos > 0, neg / np.maximum(pos, 1), 1.0).astype(np.float32)

    def weighted_bce(y_true, logits):
        loss = tf.nn.weighted_cross_entropy_with_logits(y_true, logits, pos_weight)
        return tf.reduce_mean(loss)

    head = tf.keras.Sequential([
        tf.keras.layers.Input(shape=(x.shape[1],)),
        tf.keras.layers.LayerNormalization(),
        tf.keras.layers.Dense(256, activation="relu"),
        tf.keras.layers.Dropout(0.4),
        tf.keras.layers.Dense(len(labels)),  # logits; sigmoid added at export
    ], name="mpl_head")
    head.compile(
        optimizer=tf.keras.optimizers.Adam(1e-3),
        loss=weighted_bce,
        metrics=[tf.keras.metrics.AUC(curve="PR", multi_label=True, from_logits=True, name="pr_auc")],
    )
    head.fit(
        x[tr], y[tr],
        validation_data=(x[va], y[va]),
        epochs=args.epochs,
        batch_size=64,
        callbacks=[tf.keras.callbacks.EarlyStopping(monitor="val_pr_auc", mode="max", patience=15,
                                                    restore_best_weights=True)],
        verbose=2,
    )
    head.save(args.build / "head.keras")
    save_json(args.build / "train_info.json", {
        "labels": labels, "train_windows": int(tr.sum()), "val_windows": int(va.sum()),
        "pos_weight": pos_weight.tolist(),
    })
    print("saved", args.build / "head.keras")


if __name__ == "__main__":
    main()
