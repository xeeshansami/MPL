"""Build window-level YAMNet embeddings from a labelled audio dataset.

Dataset layout (single-label, simplest):

    data/
      quran/ *.mp3
      naat/  *.mp3
      ...

Optional multi-label / grouping file `data/labels.csv`:

    path,labels,group
    romantic/song1.mp3,romantic;sad,artist_x

`group` keeps related recordings (same reciter, album, artist, or the same
recitation re-uploaded) in the same split so the test set measures
generalisation instead of memorisation. Without it each file is its own group.

Output: <out>/features.npz with per-window pooled embeddings and an index,
plus <out>/splits.json.
"""
from __future__ import annotations

import argparse
import csv
import random
from collections import defaultdict
from pathlib import Path

import numpy as np

from common import (APP_CATEGORY_IDS, AUDIO_EXTENSIONS, SAMPLE_RATE, WINDOW_SAMPLES,
                    YAMNET_HANDLE, fit_length, plan_windows, rms_db, save_json)


def collect(data_dir: Path) -> list[dict]:
    items: dict[str, dict] = {}
    for f in sorted(data_dir.rglob("*")):
        if f.suffix.lower() not in AUDIO_EXTENSIONS:
            continue
        rel = f.relative_to(data_dir).as_posix()
        top = rel.split("/")[0]
        if top not in APP_CATEGORY_IDS:
            raise SystemExit(f"{rel}: folder '{top}' is not an app category id {APP_CATEGORY_IDS}")
        items[rel] = {"path": rel, "labels": [top], "group": rel}
    csv_path = data_dir / "labels.csv"
    if csv_path.exists():
        with open(csv_path, newline="", encoding="utf-8") as fh:
            for row in csv.DictReader(fh):
                rel = row["path"].replace("\\", "/")
                if rel not in items:
                    raise SystemExit(f"labels.csv references missing file {rel}")
                labels = [x.strip() for x in row["labels"].split(";") if x.strip()]
                bad = [x for x in labels if x not in APP_CATEGORY_IDS]
                if bad:
                    raise SystemExit(f"labels.csv {rel}: unknown labels {bad}")
                items[rel]["labels"] = labels
                if row.get("group"):
                    items[rel]["group"] = row["group"]
    return list(items.values())


def split_groups(items: list[dict], val: float, test: float, seed: int) -> dict[str, str]:
    """Group-aware split, balanced per primary label."""
    by_label: dict[str, list[str]] = defaultdict(list)
    group_label = {}
    for it in items:
        group_label.setdefault(it["group"], it["labels"][0])
    for g, lab in group_label.items():
        by_label[lab].append(g)
    rng = random.Random(seed)
    assign = {}
    for lab, groups in by_label.items():
        rng.shuffle(groups)
        n = len(groups)
        n_test = max(1, round(n * test)) if n >= 3 else 0
        n_val = max(1, round(n * val)) if n >= 3 else 0
        for i, g in enumerate(groups):
            assign[g] = "test" if i < n_test else "val" if i < n_test + n_val else "train"
        if n < 3:
            print(f"WARNING: label '{lab}' has only {n} group(s); it cannot be evaluated.")
    return assign


def main() -> None:
    ap = argparse.ArgumentParser()
    ap.add_argument("--data", type=Path, required=True)
    ap.add_argument("--out", type=Path, default=Path("build"))
    ap.add_argument("--val", type=float, default=0.15)
    ap.add_argument("--test", type=float, default=0.15)
    ap.add_argument("--windows", type=int, default=8, help="training windows per file (app uses 5)")
    ap.add_argument("--seed", type=int, default=13)
    args = ap.parse_args()

    import librosa  # heavy imports after arg parsing
    import tensorflow as tf
    import tensorflow_hub as hub

    items = collect(args.data)
    if not items:
        raise SystemExit("no audio found")
    labels = sorted({l for it in items for l in it["labels"]}, key=APP_CATEGORY_IDS.index)
    print(f"{len(items)} files, labels: {labels}")
    split_of_group = split_groups(items, args.val, args.test, args.seed)

    yamnet = hub.load(YAMNET_HANDLE)
    feats, ys, file_idx, levels, splits = [], [], [], [], []
    files = []
    for fi, it in enumerate(items):
        path = args.data / it["path"]
        try:
            duration = librosa.get_duration(path=str(path))
        except Exception as e:  # noqa: BLE001
            print(f"skip {it['path']}: {e}")
            continue
        y_vec = np.array([1.0 if l in it["labels"] else 0.0 for l in labels], dtype=np.float32)
        for off in plan_windows(duration, args.windows):
            wav, _ = librosa.load(str(path), sr=SAMPLE_RATE, mono=True, offset=off,
                                  duration=WINDOW_SAMPLES / SAMPLE_RATE)
            wav = fit_length(wav.astype(np.float32))
            _, emb, _ = yamnet(tf.constant(wav))
            emb = emb.numpy()
            pooled = np.concatenate([emb.mean(axis=0), emb.max(axis=0)])
            feats.append(pooled)
            ys.append(y_vec)
            file_idx.append(len(files))
            levels.append(rms_db(wav))
            splits.append(split_of_group[it["group"]])
        files.append(it)
        if fi % 25 == 0:
            print(f"  {fi + 1}/{len(items)}")

    args.out.mkdir(parents=True, exist_ok=True)
    np.savez_compressed(
        args.out / "features.npz",
        x=np.stack(feats), y=np.stack(ys), file=np.array(file_idx),
        level_db=np.array(levels), split=np.array(splits),
    )
    save_json(args.out / "dataset.json", {"labels": labels, "files": files, "source": str(args.data)})
    counts = defaultdict(lambda: defaultdict(int))
    for it in files:
        for l in it["labels"]:
            counts[split_of_group[it["group"]]][l] += 1
    save_json(args.out / "splits.json", counts)
    print("per-split file counts:", {k: dict(v) for k, v in counts.items()})


if __name__ == "__main__":
    main()
