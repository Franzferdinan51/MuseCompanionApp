# Wake word models (openWakeWord)

The wake word engine is [openWakeWord](https://github.com/dscripka/openWakeWord)
— fully open-source (Apache 2.0), fully on-device, zero accounts, zero API
keys, zero cloud.

## Bundled models

Three TFLite models ship with the app in this directory:

| File | What it does |
|------|--------------|
| `melspectrogram.tflite` | Raw 16kHz PCM → mel-scale spectrogram frames |
| `embedding_model.tflite` | 76-frame spectrogram windows → 96-dim speech embeddings |
| `hey_jarvis_v0.1.tflite` | Last 16 embeddings → wake-word score 0..1 |

The bundled keyword is **"Hey Jarvis"** — a stand-in. Duckets wants the
wake word to be **"Hey Muse"**, but openWakeWord has no pre-trained
"hey_muse" model (checked 2026-10-04; available: alexa, hey_mycroft,
hey_jarvis, hey_rhasspy, timer, weather). The Settings UI labels this
honestly as "Hey Jarvis (Hey Muse model pending)" until a custom model
is trained.

## No setup needed

Unlike the old Porcupine-based implementation (which needed a Picovoice
account, an AccessKey, and a console-trained keyword file), openWakeWord
needs nothing from the user. Flip the toggle in Settings → Wake word and
it works.

## Training a true "Hey Muse" model

To get the actual phrase "hey muse", train it locally — no account:

1. Follow https://github.com/dscripka/openWakeWord#training-new-models
   (all local Python, ~1 hour on a decent machine, 100% synthetic data)
2. Drop the resulting `.tflite` in this directory
3. Update `_classifierAsset` in `app/lib/app/wake_word.dart` and
   `wakeWordLabel`/`wakeWordUiLabel` to match

## Notes

- Detection threshold: Settings slider maps 0–100% to a 0.8–0.2 score
  threshold (50% = openWakeWord's default 0.5). Higher sensitivity catches
  more but false-alarms more.
- The models are ~3.6MB total, bundled in the APK.
