# Prompter

A native teleprompter for iPhone, iPad and Mac with two modes:

- **Voice Follow** (default): listens to the reader and keeps the script in step with their speech. The pace comes from the reader's voice, not from a words-per-minute setting.
- **Timed Scroll**: steady, time-based scrolling at an adjustable words-per-minute speed.

SwiftUI and UIKit, iOS 17 or later, with a Mac Catalyst build for macOS. No third-party dependencies. Styled with Churchfront Signal (Figtree, Midnight, Grey, Refresh).

Also included:
- **Notion import**: pulls lesson scripts from Churchfront course build docs (for example Video 101).
- **Stage directions**: bracketed cues such as `[ON CAMERA]` show small and dimmed, and Voice Follow skips them.
- **Mirror mode**: one-click flip for beam-splitter glass. Only the script flips; the controls stay readable.
- **Phone remote and iPad display**: the app serves a control page and a display page on two ports of the same address. Run the session from a phone and put the prompter on an iPad (or any screen with a browser).
- **Web embed**: the same prompter as a standalone web page. It runs in any browser and drops into a site with an iframe.

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

## Phone remote and iPad display

The device running Prompter (usually the Mac at the desk, or an iPhone) stays in charge. Voice Follow, timing and position all run there. Other devices open web pages it serves on the local network, so nothing needs installing on them.

| Port | Page | Open it on | Does |
| --- | --- | --- | --- |
| 7070 (control) | Phone remote | A phone | Play and pause, sentence jumps, restart, a position scrubber, mode, speed, text size, mirror, and a script picker. Shows the words at the reading line. |
| 7071 (present) | Display | An iPad, a confidence monitor, any browser | Full-screen prompter that follows the host at display refresh rate, with the same text, highlight and dimming. Read only. |

Turn it on from the library toolbar (the phone icon) > **Phone remote and iPad display**. The sheet shows each address with a QR code, for example `http://192.168.1.20:7070` and `http://192.168.1.20:7071`, and how many devices are connected. Both pages reconnect on their own if Wi-Fi drops.

- **Mirror the display only**: the display has its own mirror, flip and text size, set from the sheet or the phone. A beam-splitter iPad can be mirrored while the host screen stays readable.
- **Full screen on iPad**: tap Full screen, or in Safari use Share > Add to Home Screen and open it from there for no browser bars. The page keeps the screen awake where Safari allows it.
- **Ports**: change them in the same sheet if another app already uses 7070 or 7071.
- **Security**: the pages work only on the local network, with no sign-in. Anyone on the same network who has the address can open them. The display port never accepts commands, and commands must be JSON, so other websites cannot send them. Use a trusted network, and turn the feature off when not in use.
- **Opening from a link**: `prompter://` links open Prompter (or bring it forward) and turn on Phone remote and iPad display. Send to Teleprompter in the portal opens one when Prompter isn't running, then sends the script once the control port answers. The first time, Chrome asks to open Prompter; tick Always allow and it opens on its own after that. macOS registers the link when Prompter is installed or first opened.
- **From Curriculum Studio**: on a course's Teleprompter page in the Churchfront portal, **Send to Prompter** posts the script to this app on the same Mac (`POST /import` on the control port), which saves it, keyed by course, and opens it. Sending again updates the same script. The portal then shows QR codes for **Teleprompter** (the display, for an iPad) and **Teleprompter Control** (the remote, for a phone). Scripts from the portal show "Sent from Curriculum Studio" in the editor menu instead of a Notion refresh.
- **Mac**: macOS may ask once to allow incoming network connections. Choose Allow. On iPhone and iPad, allow Local Network access when asked.

How it works: `RemoteHTTPServer` is a small HTTP/1.1 server on Network.framework, one per port. Pages get live updates over Server-Sent Events (`GET /events`) and the remote sends commands with `POST /command`. `RemoteHub` connects the servers to the open prompter: it sends the script (with the app's own word ranges, so the display matches word for word), the reading style, and the reading position as a fractional word index about 30 times a second while it changes. The display lays the text out for its own screen and maps that word position to its own scroll offset, then eases between updates, so different screen sizes stay in step. `GET /state` returns the current state as JSON for checking. `POST /import` takes `{key, title, course?, text}` as JSON and answers with the script id and both addresses. Its addresses are read again on every import and whenever the device changes networks (`NWPathMonitor`), so the portal always gets the current Wi-Fi address. It is accepted only from this computer (loopback), only from Churchfront portal origins when the browser sends an Origin, and only on the control port. Its CORS preflight includes `Access-Control-Allow-Private-Network: true` so Chrome lets the https portal reach `127.0.0.1`.

## Web embed

`Teleprompter/Resources/Web/embed.html` is a standalone timed-scroll prompter: paste a script, press play. It shares its renderer (`prompter.js`) with the iPad display. Voice Follow stays in the native app.

Publish it with **Actions > Publish web prompter** once GitHub Pages is enabled for the repository (Settings > Pages > Source: GitHub Actions), or host the three files (`embed.html`, `prompter.js`, `prompter.css`, plus the Figtree font as `figtree.ttf`) anywhere. Then embed it:

```html
<iframe src="https://YOUR-HOST/embed.html?wpm=150&theme=midnight"
        style="width:100%;aspect-ratio:16/9;border:0" allow="fullscreen; screen-wake-lock"></iframe>
```

URL options: `text` (the script), `src` (a URL to load the script from; it must allow cross-origin reads), `wpm` (40 to 320), `size` (20 to 140), `spacing`, `line` (reading line, 0.12 to 0.6), `margin`, `align` (left, center, right), `theme` (midnight, black, grey, amber), `mirror=1`, `flip=1`, `countdown` (seconds), `controls=0`, `autoplay=1`, `marker=0`, `title`.

Keys: Space, Return or B play and pause; up and down arrows jump by sentence; left and right change speed; + and - change size; M mirrors; Home restarts; E edits. Dragging or scrolling moves the text by hand.

A host page can drive it with `postMessage`:

```js
const prompter = document.querySelector("iframe").contentWindow;
prompter.postMessage({ type: "prompter", action: "load", text: "Good morning, church." }, "*");
prompter.postMessage({ type: "prompter", action: "play" }, "*");
// Also: pause, toggle, restart, back, ahead, speed (value), size (value), mirror (value), theme (value)
```

It posts `{ type: "prompter:state", playing, progress, wordsPerMinute }` back to the parent page.

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
  Remote/                      Phone remote and iPad display: HTTP server, hub, settings sheet
  Notion/NotionClient          Read-only Notion API client, Keychain token, importer
  Playback/PrompterController  Session logic: modes, countdown, jumps, lifecycle, resume
  Playback/PrompterTextSurface TextKit 1 text view, word geometry, highlight
  Views/                       Library, Editor, Prompter, Settings
  Resources/                   Assets, Figtree font, sample script
  Resources/Web/               remote.html, display.html, embed.html, shared prompter.js and .css
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
- **Runtime**: `Tools/run-app-harness.sh` passes 61 checks. It runs the real app code in a Mac Catalyst process and covers:
  - persistence and relaunch, including corrupt files and text encodings
  - settings migration
  - timed-scroll speed accuracy and smoothness
  - font change and rotation keeping the reading position
  - tap to pause, sentence jumps, restart, resume position, end of script
  - empty scripts, and a 15,300-word script

  - opening from a `prompter://` link (5 checks): only that scheme is handled, it turns the ports on, and opening it again while running changes nothing
  - the phone remote and display link (31 checks): both ports serve their pages, nothing else is served, the display port refuses commands, play, pause, scrubbing, speed, mode, display-only mirror and size, script picking and closing from the phone, the event stream order and rate (about 30 positions a second while playing), the ports closing when turned off, and portal imports (preflight, create, update in place, other websites, network clients and the display port refused, JSON required)

  It also renders iPhone- and iPad-sized screens to `Tools/Harness/Screenshots`. `Tools/run-app-harness.sh --serve` (or `--serve 18070` to use other ports beside an installed Prompter) runs the library with the remote on 7070 and 7071 for testing in a browser.

- **Web pages**: the remote, display and embed were exercised in a browser against the running harness: opening a script from the phone, play with countdown, live highlight and dimming on the display, display-only mirror, the embed's keyboard play, and the iframe `postMessage` API. Display motion measured at 120 frames a second with no backward steps.

Not yet verified:

- Install on a physical iPhone or iPad (needs a signing team).
- Live Voice Follow tracking with a real voice.
- A real Notion import (needs an integration token). The extractor is tested against a fixture shaped like the Video 101 doc.
- Phone-call interruptions and AirPods route changes.
- On-device feel at 120 Hz.
- The remote and display on a real phone and iPad over Wi-Fi (tested on this Mac's own network address and localhost), including the Local Network permission prompt on iOS.

## Limitations

- **Recognition language** follows the device language, with US English as the fallback. Matching tolerates accents through the tolerance setting, but very noisy rooms reduce accuracy. Use a lenient tolerance there, or Timed Scroll.
- **Without on-device recognition**, older devices send audio to Apple's servers and need a network connection. Settings shows whether recognition is on-device.
- **Background listening**: the app stops listening in the background (no background audio mode). Returning to the app leaves the script paused at the same place.
- **Mac storage**: scripts live in `~/Library/Application Support/com.churchfront.prompter/Scripts`. They do not sync between devices yet.
- **Ad hoc signing** on the Mac means macOS may ask for microphone access again after each rebuild. Signing with a team avoids this.
- **Icons** use SF Symbols, the native iOS equivalent of the Lucide set Signal specifies for web.
- **Future option**: iOS 26 adds the `SpeechAnalyzer` API for long-form transcription. The recognizer is isolated behind `SpeechRecognizer`, so it can be swapped in without touching the matcher.
