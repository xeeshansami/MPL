# MPL Organizer

A Flutter media player for Android and iOS, built around an **offline,
on-device audio classifier**. The classifier sorts local audio into
automatically maintained virtual playlists: Quran, Naat, Noha, Hamd,
Manqabat, Nasheed, Sad, Romantic, Dance, Pop, Rock, Classical, Instrumental,
Podcast/Speech, Other Audio and Needs Review.

> **Status:** the app, the AI pipeline and the training/export workflow are
> implemented. **No trained model is bundled yet**, so in-app classification
> reports itself as *unavailable* until a model has been trained and evaluated
> on real labelled data (see `tools/model_training/README.md`). No model
> files, predictions or accuracy figures have been fabricated.

## Pipeline

```
discover (MediaStore / SAF / iOS imported files)
  → metadata (tags, artwork cache)
  → decode 5 windows natively (MediaCodec / AVAssetReader, background thread)
  → down-mix + windowed-sinc resample to 16 kHz (Dart isolate)
  → LiteRT inference (IsolateInterpreter) + Platt calibration
  → CategoryResolver (evaluated thresholds + metadata evidence policy)
  → AIPlaylistManager (SQLite; user overrides win)
  → playlists refresh
```

| Area | Code |
|------|------|
| Model contract & validation | `lib/ai/model_manifest.dart`, `lib/ai/tflite_audio_classifier.dart` |
| Preprocessing | `lib/ai/audio_preprocessor.dart`, `lib/ai/audio_feature_extractor.dart` |
| Decision policy (documented in code) | `lib/ai/category_resolver.dart`, `lib/ai/metadata_rules.dart` |
| Virtual playlists & corrections | `lib/ai/ai_playlist_manager.dart` |
| Incremental scan, pause/resume/cancel | `lib/library/library_scanner.dart` |
| Discovery / import / tags | `lib/library/library_services.dart` |
| Native bridges | `android/app/src/main/kotlin/pk/mpl/mpl/*.kt`, `ios/Runner/AppDelegate.swift` |
| Schema | `lib/core/db/app_database.dart` |
| Player | `lib/player/player_controller.dart` (just_audio + just_audio_background) |
| UI | `lib/ui/*` |
| Training / evaluation / export | `tools/model_training/` |

### Guarantees in the design

- **Offline:** the model is loaded from `assets/models/` only. The release
  Android manifest has no `INTERNET` permission.
- **Originals untouched:** playlists are SQLite rows referencing URIs. On
  Android, SAF files are referenced in place. On iOS, Files imports are
  copied into app-private storage, because iOS grants no lasting access to
  outside files; the source is not modified.
- **No guessed thresholds:** auto and provisional thresholds come from
  `evaluate.py` on held-out data. A model without an evaluation block is
  rejected.
- **Corrections win:** `category_overrides` beat every later AI result until
  *Reset to AI*.
- **Incremental:** a track is analysed only when it is new, its fingerprint
  (size and mtime) changed, the model version changed, or the user asked.

## Development

```bash
flutter pub get
flutter analyze
flutter test
flutter build apk --debug
```

Unit tests run on desktop with `sqflite_common_ffi` and the OS SQLite
(`pubspec.yaml` → `hooks`).

The on-device acceptance checklist is in `docs/ACCEPTANCE_TESTS.md`.
