"""Calibrate, pick thresholds on validation, and measure on the held-out test set.

All numbers are computed at *file* level using the same aggregation the app
uses (mean of window probabilities over audible windows), so the reported
metrics describe what users will actually see.

Thresholds per label (written to evaluation.json, then into the manifest):
  auto        = lowest threshold whose validation precision >= --auto-precision
  provisional = lowest threshold whose validation precision >= --provisional-precision
If a target is unreachable the threshold is set to 1.0 for auto (never
automatic) and to the auto threshold for provisional; the report says so.
"""
from __future__ import annotations

import argparse
import datetime as dt
from pathlib import Path

import numpy as np

from common import load_json, save_json

SILENCE_DB = -50.0


def sigmoid(z):
    return 1 / (1 + np.exp(-z))


def file_level(probs, y, file_idx, level_db):
    files = np.unique(file_idx)
    P, Y = [], []
    for f in files:
        m = file_idx == f
        audible = m & (level_db > SILENCE_DB)
        use = audible if audible.any() else m
        P.append(probs[use].mean(axis=0))
        Y.append(y[m][0])
    return np.array(P), np.array(Y)


def fit_platt(p, y):
    """1-D logistic regression on logit(p). Returns (a, b)."""
    from sklearn.linear_model import LogisticRegression
    z = np.log(np.clip(p, 1e-7, 1 - 1e-7) / np.clip(1 - p, 1e-7, 1)).reshape(-1, 1)
    if len(np.unique(y)) < 2:
        return 1.0, 0.0
    lr = LogisticRegression(C=1e4).fit(z, y)
    return float(lr.coef_[0, 0]), float(lr.intercept_[0])


def apply_platt(p, a, b):
    z = np.log(np.clip(p, 1e-7, 1 - 1e-7) / np.clip(1 - p, 1e-7, 1))
    return sigmoid(a * z + b)


def threshold_for_precision(p, y, target):
    order = np.argsort(-p)
    ps, ys = p[order], y[order]
    tp = np.cumsum(ys)
    prec = tp / np.arange(1, len(ys) + 1)
    ok = np.where(prec >= target)[0]
    if len(ok) == 0 or ys.sum() == 0:
        return None
    # largest k achieving the target -> lowest threshold
    return float(ps[ok.max()])


def metrics_at(p, y, t):
    pred = p >= t
    tp = int((pred & (y == 1)).sum()); fp = int((pred & (y == 0)).sum()); fn = int((~pred & (y == 1)).sum())
    precision = tp / (tp + fp) if tp + fp else 0.0
    recall = tp / (tp + fn) if tp + fn else 0.0
    f1 = 2 * precision * recall / (precision + recall) if precision + recall else 0.0
    return precision, recall, f1


def ece(p, y, bins=10):
    edges = np.linspace(0, 1, bins + 1)
    e = 0.0
    for lo, hi in zip(edges[:-1], edges[1:]):
        m = (p >= lo) & (p < hi if hi < 1 else p <= hi)
        if m.any():
            e += m.mean() * abs(p[m].mean() - y[m].mean())
    return float(e)


def main() -> None:
    ap = argparse.ArgumentParser()
    ap.add_argument("--build", type=Path, default=Path("build"))
    ap.add_argument("--auto-precision", type=float, default=0.95)
    ap.add_argument("--provisional-precision", type=float, default=0.80)
    ap.add_argument("--dataset-name", required=True, help="name/version of the labelled dataset")
    args = ap.parse_args()

    import tensorflow as tf
    from sklearn.metrics import average_precision_score

    d = np.load(args.build / "features.npz")
    labels = load_json(args.build / "dataset.json")["labels"]
    head = tf.keras.models.load_model(args.build / "head.keras", compile=False)
    probs = sigmoid(head.predict(d["x"], verbose=0))
    split = d["split"]

    def subset(name):
        m = split == name
        return file_level(probs[m], d["y"][m], d["file"][m], d["level_db"][m])

    pv, yv = subset("val")
    pt, yt = subset("test")
    if len(yt) == 0:
        raise SystemExit("test split is empty; cannot evaluate")

    out_labels, warnings = [], []
    for i, lab in enumerate(labels):
        a, b = fit_platt(pv[:, i], yv[:, i])
        cv, ct = apply_platt(pv[:, i], a, b), apply_platt(pt[:, i], a, b)
        t_auto = threshold_for_precision(cv, yv[:, i], args.auto_precision)
        t_prov = threshold_for_precision(cv, yv[:, i], args.provisional_precision)
        if t_auto is None:
            warnings.append(f"{lab}: validation precision never reaches {args.auto_precision}; auto disabled")
            t_auto = 1.0
        if t_prov is None:
            warnings.append(f"{lab}: validation precision never reaches {args.provisional_precision}")
            t_prov = t_auto
        t_prov = min(max(t_prov, 1e-3), t_auto)
        p_auto, r_auto, f_auto = metrics_at(ct, yt[:, i], t_auto)
        p_prov, r_prov, f_prov = metrics_at(ct, yt[:, i], t_prov)
        support = int(yt[:, i].sum())
        if support < 20:
            warnings.append(f"{lab}: only {support} test files; metrics are unreliable")
        out_labels.append({
            "index": i, "category_id": lab,
            "calibration": {"type": "platt", "a": a, "b": b},
            "thresholds": {"auto": round(t_auto, 4), "provisional": round(t_prov, 4)},
            "metrics": {
                "test_support": support,
                "precision_at_auto": round(p_auto, 4), "recall_at_auto": round(r_auto, 4), "f1_at_auto": round(f_auto, 4),
                "precision_at_provisional": round(p_prov, 4), "recall_at_provisional": round(r_prov, 4),
                "f1_at_provisional": round(f_prov, 4),
                "average_precision": round(float(average_precision_score(yt[:, i], ct)) if support else 0.0, 4),
                "ece": round(ece(ct, yt[:, i]), 4),
            },
        })

    report = {
        "dataset": args.dataset_name,
        "test_files": int(len(yt)),
        "val_files": int(len(yv)),
        "date": dt.date.today().isoformat(),
        "threshold_method": f"validation precision >= {args.auto_precision} (auto) / "
                            f">= {args.provisional_precision} (provisional), Platt-calibrated",
        "labels": out_labels,
        "warnings": warnings,
    }
    save_json(args.build / "evaluation.json", report)
    print(f"test files: {len(yt)}")
    for l in out_labels:
        m = l["metrics"]
        print(f"{l['category_id']:>13}: n={m['test_support']:<4} AP={m['average_precision']:.3f} "
              f"P@auto={m['precision_at_auto']:.3f} R@auto={m['recall_at_auto']:.3f} "
              f"thr={l['thresholds']}")
    for w in warnings:
        print("WARNING:", w)


if __name__ == "__main__":
    main()
