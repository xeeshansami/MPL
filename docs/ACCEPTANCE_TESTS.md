# On-device acceptance tests

These are the mandatory tests from the product requirements. They need a
**real trained model** in `assets/models/` and **real devices**. None of them
had been run when this file was written, because no trained model exists yet.
Record results only after actually executing a test.

Setup for every run:
- Release build (`flutter build apk --release` / an Xcode archive). The release
  Android manifest has no `INTERNET` permission.
- Fresh install, **airplane mode on before first launch**, Wi-Fi off.
- Record the device model, OS version, app version and the `model_version`
  shown in Settings.

| # | Test | How | Pass criteria | Result |
|---|------|-----|---------------|--------|
| 1 | Quran | Import 10+ recitations not used in training (different reciters) | Predicted Quran; per-track confidence shown in the AI sheet; record the scores | NOT RUN |
| 2 | Naat | Import 10+ Naat | Naat assigned (auto or provisional) | NOT RUN |
| 3 | Noha | Import 10+ Noha | Noha assigned | NOT RUN |
| 4 | Other categories | 5+ files each for Hamd, Manqabat, Nasheed, Sad, Romantic, Dance, Pop, Rock, Classical, Instrumental, Podcast/Speech, Other | Correct category; note confusions | NOT RUN |
| 5 | Ambiguous audio | Noise, silence, a 3 s clip, mixed speech+music, very low bitrate | Stays in Needs Review or provisional; no confident wrong auto label | NOT RUN |
| 6 | Automatic playlists | After the scan, open AI Categories | Tracks listed under their categories with counts; no manual steps | NOT RUN |
| 7 | Correction precedence | Set categories on a track, then Rescan and Reclassify all | Correction unchanged; Reset to AI restores the AI result | NOT RUN |
| 8 | Persistence | Force-stop, relaunch | Categories, corrections, playlists, favourites, queue position intact; no re-analysis | NOT RUN |
| 9 | Airplane mode, first launch | Steps 1–6 with airplane mode on from install | Model loads ("On-device AI · model …"), inference runs | NOT RUN |
| 10 | Originals unchanged | `sha256sum` of source files before and after the scan, corrections and playlist edits | Identical hashes, same paths and names | NOT RUN |
| 11 | Incremental scan | Add 3 new files; rescan; time it | Only the 3 new files analysed (AI manager: Analysed +3) | NOT RUN |
| 12 | Performance | See below | Numbers recorded per device | NOT RUN |

## Performance measurements (test 12)

Use at least one low-end device (≈ 3 GB RAM) and one recent device per platform.

- **Inference time per track**: from the AI manager, total analysis time ÷
  tracks. Also record `Interpreter.lastNativeInferenceDurationMicroSeconds`
  per window.
- **Memory**: peak PSS during a 200-track scan (Android Studio profiler /
  Xcode Instruments). Playback must not stutter.
- **Package size**: APK/IPA size with and without the model file.
- **Per-category metrics**: copy `precision/recall/F1/support` from
  `assets/models/manifest.json` (held-out test set), and add the on-device
  confusion counts from tests 1–5. Compare the on-device scores for a few
  files against `evaluate.py` to catch preprocessing drift.
