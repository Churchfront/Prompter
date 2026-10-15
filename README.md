# Prompter

A native teleprompter for iPhone, iPad and Mac with two modes:

- **Voice Follow** (default): listens to the reader and keeps the script in step with their speech. The pace comes from the reader's voice, not from a words-per-minute setting.
- **Timed Scroll**: steady, time-based scrolling at an adjustable words-per-minute speed.

SwiftUI and UIKit, iOS 17 or later, with a Mac Catalyst build for macOS. No third-party dependencies. Styled with Churchfront Signal (Figtree, Midnight, Grey, Refresh).

Also included:
- **Notion import**: pulls lesson scripts from Churchfront course build docs (for example Video 101).
- **Stage directions**: bracketed cues such as `[ON CAMERA]` show small and dimmed, and Voice Follow skips them.
- **Mirror mode**: one-click flip for beam-splitter glass. Only the script flips; the controls stay readable.

## Open and run

1. Install Xcode 16 or later. Built and run with Xcode 27.
2. Open `Teleprompter.xcodeproj`.
3. Select the **Teleprompter** target > Signing & Capabilities, then choose your Team. Change the bundle identifier (`com.churchfront.prompter`) if Xcode reports a conflict.
4. Choose a simulator or a connected iPhone or iPad, then press Run (⌘R).

For a physical device, enable Developer Mode on it (Settings > Privacy & Security > Developer Mode) and trust your developer certificate when prompted.

Voice Follow works in the Simulator, using your Mac's microphone. Recognition quality and latency are best on a real device.

Run the tests with Product > Test (⌘U). The shared scheme includes the TeleprompterCore test suite.

### Mac

Choose **My Mac (Mac Catalyst)** as the run destination and press ⌘R. To build a copy that runs on this Mac without an Apple developer account:

```bash
xcodebuild -project Teleprompter.xcodeproj -scheme Teleprompter -configuration Release -destination 'platform=macOS,variant=Mac Catalyst' -derivedDataPath build CODE_SIGN_STYLE=Manual CODE_SIGN_IDENTITY=- DEVELOPMENT_TEAM= build
```

The app lands in `build/Build/Products/Release-maccatalyst/Teleprompter.app`. Copy it to Applications.

On the Mac, Voice Follow needs **Dictation** turned on (System Settings > Keyboard > Dictation). Apple's speech recognizer refuses requests while it is off, and the app explains this when it happens. `Prompter.entitlements` adds the microphone entitlement that the hardened runtime requires.

## Notion import

Library > **Import > From Notion**. One-time setup on each device:

1. At notion.so/my-integrations, create an **Internal** integration (no redirect URI) named Prompter, with **Read content** only.
2. In Notion, open **Course Development** > ••• > **Connections** and add Prompter.
3. Paste the integration's **Internal Integration Secret** into Prompter. It is stored in the Keychain and sent only to api.notion.com.

Course docs list lessons as level-2 headings. Each lesson's script lives in a toggle whose title starts with "Script". Each lesson imports as its own script, titled "Video 101 · 2. Video Sources". Subheadings inside a script become cues, and callouts (production notes) are left out. Re-importing, or **Refresh from Notion** in the editor's menu, updates a script in place. Prompter never writes to Notion.

## Project layout

```
Teleprompter.xcodeproj
Config-Info.plist              120 Hz ProMotion and font registration (merged with generated keys)
Prompter.entitlements          Mac microphone entitlement
Teleprompter/                  App target (folder is synchronized: new files are picked up automatically)
  App/                         Entry point
  DesignSystem/Signal.swift    Churchfront Signal colors, type, buttons, signature shape
  Models/                      Script, ReaderSettings (all preferences)
  Persistence/                 ScriptStore (one JSON file per script), SettingsStore
  Speech/SpeechRecognizer      Microphone + Apple Speech, permissions, interruptions
  Notion/NotionClient          Read-only Notion API client, Keychain token, importer
  Playback/PrompterController  Session logic: modes, countdown, jumps, lifecycle, resume
  Playback/PrompterTextSurface TextKit 1 text view, word geometry, highlight
  Views/                       Library, Editor, Prompter, Settings
  Resources/                   Assets, Figtree font, sample script
Packages/TeleprompterCore/     Pure Swift engine, no UIKit or audio
  TokenizedScript              Words, sentences, phrases, ranges
  TextNormalizer, WordSimilarity
  TranscriptBuffer             Context across recognition restarts
  ScriptMatcher                Speech-to-script alignment
  ReadingPacer                 Measured pace, pause grace
  ScrollPhysics                Spring, timed scroll, token geometry
  NotionScriptExtractor        Notion blocks to lesson scripts (tested offline)
Tools/
  run-core-tests.sh            Runs the core checks with only the Swift compiler
  typecheck-app.sh             Type-checks the app against the iOS UIKit/SwiftUI SDK
  run-app-harness.sh           Runs the app code in a Mac Catalyst process and renders screenshots
```

Speech recognition, matching, pacing, scrolling and rendering are separate layers. Each one can be tested on its own.

## How Voice Follow works

1. `SpeechRecognizer` streams microphone buffers into Apple's speech recognizer. It uses on-device recognition when the device supports it, and gives the recognizer the script's names and rare words as hints. Audio goes straight from the microphone to the recognizer and is never written anywhere.
2. Recognition tasks are restarted before Apple's time limits, after silence, and after errors. `TranscriptBuffer` carries the last words across restarts, so the matcher never loses context.
3. `ScriptMatcher` aligns the last 10 recognized words against the script near the current position. It uses a fuzzy local alignment that tolerates misrecognized, dropped, and inserted words. Homophones, numbers, and contractions are normalized first.
   - A distance penalty favors nearby positions, so a duplicate phrase elsewhere in the script cannot pull the position away.
   - Weak or ambiguous evidence holds the position instead of guessing.
   - Short backward matches (repeating a phrase) are ignored.
   - Only after several unmatched updates does it search the whole script. Even then it accepts only a strong match that clearly beats every other location.
4. `ReadingPacer` measures the reader's pace. Between recognition bursts it glides ahead for at most the pause grace period (default 1.2 s) and at most 1.5 words. When the reader stops, the text stops.
5. A critically damped spring follows that goal at display refresh rate. It never moves backward for small corrections.

Dragging the text repositions the matcher, as do the sentence back and forward buttons and restart.

## Controls

- **Tap the text**: play or pause. This can be turned off in Settings.
- **Bottom bar**: mode, back one sentence, play/pause, ahead one sentence, restart. In Timed Scroll it also has the speed slider and −/+ buttons.
- **Top bar**: close, listening status, progress, time left, mirror mode, reading settings.
- **Hardware keyboard and presentation remotes**:
  - Space, Return or B: play or pause
  - Up and down arrows, Page Up and Page Down: sentence back and ahead
  - Left and right arrows: speed down and up
  - M: mirror mode on or off

## Verification status

Verified:

- **Xcode builds**: the project builds with Xcode 27 for the iOS Simulator and for Mac Catalyst.
- **Simulator (iPhone 17)**: walked through the library, editor, prompter, the real permission prompt and the denial message, the Notion connect screen, cue display, and mirror mode.
- **Mac**: microphone access works from the installed app. Voice Follow then needs Dictation turned on, as described above.

- **Core engine**: `Tools/run-core-tests.sh` passes all 12 unit check groups (including cues and Notion extraction) and all speech scenarios. The scenarios feed realistic recognizer output (latency, revised partial words, task restarts, garbled, dropped and inserted words) through the real pipeline. They cover slow and fast reading, silence, resuming, skipping a sentence with a duplicate phrase, repeating a phrase, recognition errors, relayout, off-script speech, and 4.5 minutes of continuous reading without drift.
- **App code**: `Tools/typecheck-app.sh` type-checks every app file against the iOS UIKit/SwiftUI SDK (the Mac Catalyst variant).
- **Runtime**: `Tools/run-app-harness.sh` passes 35 checks. It runs the real app code in a Mac Catalyst process and covers:
  - persistence and relaunch, including corrupt files and text encodings
  - settings migration
  - timed-scroll speed accuracy and smoothness
  - font change and rotation keeping the reading position
  - tap to pause, sentence jumps, restart, resume position, end of script
  - empty scripts, and a 15,300-word script

  It also renders iPhone- and iPad-sized screens to `Tools/Harness/Screenshots`.

Not yet verified:

- Install on a physical iPhone or iPad (needs a signing team).
- Live Voice Follow tracking with a real voice.
- A real Notion import (needs an integration token). The extractor is tested against a fixture shaped like the Video 101 doc.
- Phone-call interruptions and AirPods route changes.
- On-device feel at 120 Hz.

## Limitations

- **Recognition language** follows the device language, with US English as the fallback. Matching tolerates accents through the tolerance setting, but very noisy rooms reduce accuracy. Use a lenient tolerance there, or Timed Scroll.
- **Without on-device recognition**, older devices send audio to Apple's servers and need a network connection. Settings shows whether recognition is on-device.
- **Background listening**: the app stops listening in the background (no background audio mode). Returning to the app leaves the script paused at the same place.
- **Mac storage**: scripts live in `~/Library/Application Support/com.churchfront.prompter/Scripts`. They do not sync between devices yet.
- **Ad hoc signing** on the Mac means macOS may ask for microphone access again after each rebuild. Signing with a team avoids this.
- **Icons** use SF Symbols, the native iOS equivalent of the Lucide set Signal specifies for web.
- **Future option**: iOS 26 adds the `SpeechAnalyzer` API for long-form transcription. The recognizer is isolated behind `SpeechRecognizer`, so it can be swapped in without touching the matcher.
