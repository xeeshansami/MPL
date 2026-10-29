# Training the on-device category model

The app ships **without** a model until one has been trained and evaluated on
real, properly labelled audio. Until then the AI feature shows as unavailable
and tracks wait in the "awaiting model" state. This folder is the reproducible
path to a model the app will accept.

## Why a custom model

General sound-event classifiers such as YAMNet (AudioSet) can tell speech from
music. They have no notion of Quran recitation vs Naat vs Noha vs Hamd vs
Manqabat, which are often unaccompanied vocal performances in related languages
and styles. Telling them apart takes labelled examples of each. The
pipeline uses YAMNet only as a frozen feature extractor and trains a small
multi-label head on your data.

## Data you need

```
data/
  quran/        recitations (many reciters, maqamat, recording qualities)
  naat/
  noha/
  hamd/
  manqabat/
  nasheed/
  sad/ romantic/ dance/ pop/ rock/ classical/ instrumental/
  speech/       podcasts, lectures, bayan, audiobooks
  other/        anything else you want recognised as "Other Audio"
  labels.csv    optional: multi-label + grouping (see prepare_dataset.py)
```

Folder names must be app category ids (`common.APP_CATEGORY_IDS`). You may
train on a subset; the app only uses the categories present in the manifest.

Guidance:
- Aim for **≥ 150 files from ≥ 30 distinct performers per category**, and
  ≥ 20 test files per category, or the metrics are not trustworthy.
  `evaluate.py` warns when support is low.
- Use the `group` column (reciter / artist / album) so the same performer never
  appears in both train and test.
- Include hard negatives: Arabic speech that is not recitation, Urdu poetry
  that is not Naat, sad songs in the same languages as Noha, and so on.
- Only use audio you have the rights to use for training.

## Steps

Use Python 3.10–3.12 in a virtual environment:

```bash
pip install -r requirements.txt
python prepare_dataset.py --data /path/to/data --out build
python train.py --build build
python evaluate.py --build build --dataset-name "mpl-dataset-v1"
python export_tflite.py --build build --data /path/to/data --version 2026.11.0 --out ../../assets/models
```

`export_tflite.py` writes `assets/models/<model>.tflite` and
`assets/models/manifest.json` (SHA-256, preprocessing contract, Platt
calibration, thresholds and per-category test metrics). It refuses to write a
manifest if the TFLite output differs from TensorFlow.

YAMNet is downloaded from TF Hub **at training time on your machine only**. The
exported `.tflite` contains it, so the app never downloads anything.

## How the app uses the manifest

- Rejects the model when any of these is wrong: schema, checksum, tensor
  shapes, unknown labels, missing thresholds, or a missing evaluation
  (`lib/ai/model_manifest.dart`, `lib/ai/tflite_audio_classifier.dart`).
- Decodes 5 windows spread across 10–90 % of each track. It down-mixes and
  resamples them to 16 kHz in Dart (`lib/ai/audio_preprocessor.dart`), runs
  LiteRT in a background isolate, applies Platt calibration, and averages
  over the audible windows.
- Assigns a category automatically at or above `thresholds.auto`,
  provisionally at or above `thresholds.provisional`, and sends the track to
  Needs Review otherwise. Metadata is supporting evidence only
  (`lib/ai/category_resolver.dart`).
- A new `model_version` triggers re-analysis of every track. User
  corrections are preserved.

## After exporting: acceptance tests on a device

Run these on real phones, in airplane mode, from a fresh install. The
checklist is in `docs/ACCEPTANCE_TESTS.md`. Do not report a category as
working until it has passed there.

Known gap to check: training resamples with librosa, while the app uses its
own windowed-sinc resampler. Spot-check that on-device scores match
`evaluate.py` scores for the same files.
