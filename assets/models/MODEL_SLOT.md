# Model slot

The app loads its audio classifier from this folder **only**; nothing is
downloaded at runtime.

Required files (produced by `tools/model_training/export_tflite.py` +
`evaluate.py`):

- `manifest.json` – labels, preprocessing contract, SHA-256, and thresholds
  and metrics from a real held-out evaluation.
- the `.tflite` file named by `manifest.json` → `model_file`.

When these files are absent or fail validation, the AI feature reports itself
as unavailable, with the reason, and tracks wait in the "awaiting model"
state.
