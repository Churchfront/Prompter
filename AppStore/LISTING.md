# CuePrompter: App Store listing

Everything App Store Connect asks for, ready to paste. Character limits are
Apple's; counts are noted where they are tight.

## App record

| Field | Value |
| --- | --- |
| Platforms | iOS (iPhone and iPad) |
| Name | CuePrompter |
| Primary language | English (U.S.) |
| Bundle ID | com.churchfront.prompter |
| SKU | CUEPROMPTER-IOS |
| User access | Full access |
| Primary category | Productivity |
| Secondary category | Photo & Video |
| Price | Free (confirm with Matt) |
| Copyright | 2026 Churchfront LLC |

## Subtitle (30 max)

Teleprompter that follows you

## Promotional text (170 max)

Read naturally and the script keeps your place. Voice Follow listens as you speak, so there is no speed to set and no one to run the scroll.

## Description (4000 max)

CuePrompter is a teleprompter that listens. Press play, start reading, and the script moves with your voice. Slow down and it waits. Speed up and it keeps up. Pause to take a breath and the text pauses with you.

Built by Churchfront for pastors, worship leaders, hosts and anyone who speaks on camera or from a stage. The goal is simple: eyes on the people in the room, not on hunting for the next line.

VOICE FOLLOW
- Follows your speech word by word, with no speed to set
- Finds your place if you skip ahead, repeat a phrase or ad lib
- Stage directions in brackets, like [WALK TO CENTER], show small and are skipped
- Uses on-device speech recognition where your device supports it

TIMED SCROLL
- A steady scroll at the words-per-minute speed you choose
- Countdown before the first line
- Drag the text at any time to move it by hand

MADE FOR THE STAGE AND THE STUDIO
- Mirror and flip for beam-splitter glass. Only the script flips, the controls stay readable
- Large, clear type with adjustable size, weight, line spacing and margins
- Reading line marker so you always know where to look
- Keyboard and pedal friendly: Space plays and pauses, arrows and Page Up and Page Down jump by sentence

PHONE REMOTE AND SECOND SCREENS
- Run the session from a phone on the same Wi-Fi: play, pause, jump, scrub and change speed
- Put the prompter on an iPad, a confidence monitor or any screen with a browser
- Nothing to install on the other devices

YOUR SCRIPTS
- Write, paste or import plain text files
- Import lesson scripts from Notion
- Scripts stay on your device. CuePrompter has no account, no ads and no tracking

## Keywords (100 max, comma separated, no spaces)

teleprompter,prompter,autocue,sermon,church,speech,script,voice,mirror,beam splitter,livestream

(95 characters)

## URLs

| Field | Value |
| --- | --- |
| Support URL | https://churchfront.com/cueprompter/support (page to publish, see SUPPORT.md) |
| Marketing URL | optional, leave blank |
| Privacy Policy URL | https://churchfront.com/cueprompter/privacy (page to publish, see PRIVACY.md) |

## App Privacy (the "nutrition label")

Choose **Data Not Collected**. CuePrompter has no analytics, no accounts and no
servers of its own. Scripts and settings stay on the device. Speech is matched
live and never stored. A Notion token, if used, is kept in the Keychain and sent
only to Notion. This matches `Teleprompter/Resources/PrivacyInfo.xcprivacy`.

## Age rating

Answer **None** to every content question and **No** to unrestricted web
access, gambling, contests and user-generated content shared with others.
Result: 4+.

## Export compliance

Already answered in the build (`ITSAppUsesNonExemptEncryption = NO`): the app
uses only the encryption built into iOS (HTTPS to Notion).

## Notes for App Review

CuePrompter is a teleprompter. No sign-in is needed.

To try Voice Follow: open the sample script "Welcome to CuePrompter", press Play,
allow the microphone and speech recognition, and read the text out loud. The
script moves as you read.

To try Timed Scroll: choose Timed at the bottom left, then Play.

Notion import is optional and needs the user's own Notion integration token, so
it cannot be demonstrated without a Notion workspace. Everything else works
without it.

The phone remote (phone icon in the library) serves a local web page on the
device's Wi-Fi network so a second device can control or show the prompter. It
is off until the user turns it on, which is why the app asks for Local Network
access.

Contact: Matt Woltjer, matt@churchfront.com

## Screenshots

In `screenshots/`, taken from the simulator at Apple's required sizes:

| Display | Size | Files |
| --- | --- | --- |
| iPad 13" | 2064 x 2752 | `ipad-1-library.png`, `ipad-2-prompter.png`, `ipad-3-settings.png` |
| iPhone 6.9" | 1320 x 2868 | `iphone-1-library.png`, `iphone-2-prompter.png`, `iphone-3-settings.png` |

Apple scales these down for the smaller displays.
