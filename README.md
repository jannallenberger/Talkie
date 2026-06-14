# Talkie

A fast, private, on-device dictation app for macOS — your own free **Wispr Flow**.
Hold a key, talk, release; Talkie transcribes locally and pastes the text into
whatever app you're using. No subscription, no cloud, no account. Your voice
never leaves your Mac.

Built natively against macOS 26's `SpeechAnalyzer` / `SpeechTranscriber` engine
(Apple's newest on-device model — ~55% faster than Whisper Large V3).

---

## Requirements

- **macOS 26 (Tahoe) or later** — Talkie uses the macOS 26 on-device speech API.
- **Apple Silicon** Mac.
- **Xcode 26** (for building). Check with `xcodebuild -version`.

## Quick start

```bash
cd ~/Talkie
./scripts/run.sh            # builds Talkie.app and launches it
```

A **microphone icon appears in your menu bar**. First launch opens a setup
window asking for three permissions (see below). Grant them, then:

- **Hold the Right ⌥ Option key**, speak, and **release**. The text is inserted
  where your cursor is.

That's the default. You can change the key and everything else in
**Settings** (menu-bar icon → Settings).

## Permissions (one-time)

macOS gates the three things a dictation app must do. Talkie's **Permissions**
tab has a button for each:

| Permission | Why Talkie needs it |
|---|---|
| **Microphone** | Capture your voice while you hold the key. |
| **Input Monitoring** | Notice your dictation key in any app (it never blocks the key). |
| **Accessibility** | Paste the transcribed text into the focused app. |

After granting Input Monitoring or Accessibility, Talkie re-checks automatically
when you switch back to it. If a toggle won't stick, the **Open Settings** button
deep-links you to the exact System Settings pane.

> First run also downloads the on-device speech model for your language once
> (a few seconds). After that, dictation is instant and fully offline.

## Settings

- **Dictation key** — Right/Left Option, Right Control, or Fn (🌐).
- **Mode** — *Hold to talk* (hold/release) or *Toggle* (tap to start, tap to stop).
- **Insertion** — *Paste* (fast, default) or *Type character-by-character* (when
  you don't want the clipboard touched).
- **Capitalize the first letter**, **Play sounds**, **Open at login**.
- **Language** — locale identifier (e.g. `en-US`, `de-DE`). Changing it applies
  after you reopen Talkie.

## Dictionary

The **Dictionary** tab does two things:

1. **Custom Vocabulary** — names, brands, jargon ("Coralate", "Nemo", "LiDAR").
   These are fed to the recognizer as *contextual strings* so it spells them
   right in the first place.
2. **Replacements** — rewrite what was heard into what you meant, e.g.
   `correlate → Coralate`, `api → API`. Each rule can be whole-word and/or
   case-sensitive. Applied to the final transcript.

Everything is stored locally in `~/Library/Application Support/Talkie/`.

## Sharing with your co-founders

An **ad-hoc** build (the default `run.sh`) runs great on the Mac that built it,
but macOS 26 won't let *another* Mac open it without friction. To hand Talkie to
your co-founders cleanly, sign + notarize it with your Apple Developer account:

```bash
# one-time: store a notary credential in your keychain
xcrun notarytool store-credentials talkie-notary \
  --apple-id you@example.com --team-id TEAMID --password <app-specific-password>

export TALKIE_DEVID_ID="Developer ID Application: Your Name (TEAMID)"
export TALKIE_NOTARY_PROFILE="talkie-notary"
./scripts/notarize.sh
```

This produces a notarized **`Talkie.zip`** they can download and open normally.
They still grant the three permissions on their own machine (Apple requires that
per-device).

> Tip for your own daily use: ad-hoc signatures change every rebuild, so macOS
> may re-ask for permissions after a rebuild. To avoid that, sign with your
> stable *Apple Development* cert instead:
> `export TALKIE_SIGN_ID="Apple Development: Your Name (TEAMID)"` before `run.sh`.

## How it works (architecture)

```
Right ⌥ held ──▶ HotKeyMonitor ──▶ AudioCapture ──▶ TranscriptionEngine ──▶ TextInjector
 (CGEventTap,     (AVAudioEngine     (SpeechAnalyzer +     (clipboard + ⌘V
  listen-only)     mic → converter)   SpeechTranscriber)    into focused app)
                                            │
                                       live partials ──▶ HUD pill
```

| File | Responsibility |
|---|---|
| `TranscriptionEngine.swift` | macOS 26 `SpeechAnalyzer`/`SpeechTranscriber`; model download; live partial + final results; vocabulary biasing. |
| `AudioCapture.swift` | `AVAudioEngine` mic tap → `AVAudioConverter` → analyzer input stream. |
| `HotKeyMonitor.swift` | Global `CGEventTap` (listen-only) on a dedicated thread; Right-Option hold detection; tap-disable recovery. |
| `TextInjector.swift` | Pasteboard + synthetic ⌘V with clipboard save/restore; secure-input (password field) guard. |
| `DictionaryStore.swift` | Vocabulary + replacements; persistence; post-processing. |
| `AppSettings.swift` | Preferences (`UserDefaults`). |
| `HUD.swift` | Floating live-transcript pill. |
| `SettingsView.swift` | General / Dictionary / Permissions UI (SwiftUI). |
| `Permissions.swift` | TCC status + requests. |
| `AppDelegate.swift` | Menu bar + wires everything together. |

## Troubleshooting

- **No menu-bar icon** — it's an accessory app (no Dock icon by design). Look
  near the clock. If it's not there, run `./scripts/run.sh` again and check for
  a crash with `ls ~/Library/Logs/DiagnosticReports/Talkie*`.
- **Key does nothing** — grant **Input Monitoring**, then click the Talkie menu
  (it re-arms the key when you return to the app). The Right-Option key still
  works normally elsewhere; Talkie only *observes* it.
- **Text didn't paste** — grant **Accessibility**. If a password field is
  focused, Talkie deliberately won't auto-paste; it copies the text and tells
  you to press ⌘V yourself.
- **Permissions keep resetting after a rebuild** — that's the ad-hoc signature
  changing. Use a stable `TALKIE_SIGN_ID` (see above).

## Privacy

100% on-device. Audio is processed by Apple's local speech model and discarded;
nothing is uploaded. The dictionary and settings live only in your
`~/Library/Application Support/Talkie/` folder and `UserDefaults`.
