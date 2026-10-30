# Development

## Requirements

- macOS 26 and Xcode 26 or later
- [XcodeGen](https://github.com/yonaskolb/XcodeGen) (`brew install xcodegen`). The Xcode project is generated from `project.yml`.
- For iPhone and Watch: an Apple ID in Xcode › Settings › Accounts with an *Apple Development* certificate.

## Build and install

```bash
./install.sh                # Mac: test, build, install to /Applications, launch
./install.sh --iphone       # Mac + iPhone (the Watch app comes with the iPhone app)
./install.sh --iphone-only  # just renew or update the iPhone and Watch
./install.sh --clean        # wipe build caches first
./install.sh --tidy         # remove stray copies (duplicate Launchpad icons, old builds)
./uninstall.sh              # remove the app, settings, permissions, keys, models and build files; meetings stay (add --iphone for the phone)
```

Builds go to `build.noindex/`, so Spotlight and Launchpad ignore them.

Signing: with an Apple Development certificate the Mac app is signed with your team, so macOS keeps its permissions
across updates and keys sync through iCloud Keychain. Without one it's signed to run locally, and macOS may ask for
permissions again after updates.

To open the project in Xcode: `xcodegen generate && open Hushpad.xcodeproj`.

Before 1.1 the app's hidden identifiers still used the project's first name, LocalScribe (bundle id
`dev.localscribe.app`, keychain service, Application Support folder, `localscribe://` meeting links). On its first
launch the Mac app copies the old settings and keys and moves the old folder (`LegacyInstall`). On iPhone the new
bundle id is a separate app: meetings move through an iCloud Drive library folder picked in both apps.

## Layout

- `HushpadKit/`: Swift package with the logic, plus the `hushpad` CLI (`swift run hushpad --help`)
  - `HushpadCore/`: data model, storage, file coordination, library encryption, exporters (also used by the Watch)
  - `HushpadKit/Recording/`: mic and system audio capture on one shared clock, permissions
  - `HushpadKit/Screenshots/`: ScreenCaptureKit capture, screen-share detection and slide-change detection.
    Automatic screenshots only run while someone else shares in Zoom, Teams or Google Meet. The share is found
    through Accessibility (`ScreenShareDetector`, rules in `HushpadCore/Screenshots/ScreenShareAnalyzer.swift`),
    each frame is cropped to the shared content, and a frame is kept once it has been still for 6 s. If a share
    isn't picked up, run `swift run hushpad ax-share` during it: it prints a redacted outline of the meeting window
    (lengths and share keywords only, no names or text) to tune the rules with.
  - `HushpadKit/Transcription/`: WhisperKit engine, model catalog
  - `HushpadKit/Diarization/`: SpeakerKit (pyannote) speaker separation
  - `HushpadKit/Pipeline/`: transcribe → diarize → align → merge, echo and hallucination filtering
  - `HushpadKit/Notes/`: notes generation (OpenAI-compatible client, prompts, name masking), shared settings
  - `HushpadKit/Cloud/`: Keychain (API keys and the library key)
  - `HushpadUI/`: the design system shared by all apps
- `App/`: SwiftUI app (`Shared/`, `macOS/`, `iOS/`, `Model/`)
  - `Model/AppModel` is the composition root and the one object views observe. The work lives in services it owns:
    `TranscriptionQueue` (jobs, speech models, downloads), `NotesService` (notes jobs and streaming), `PrivacyState`
    (lock and encryption), and `LibraryIndex` in the package (reads the library off the main thread).
  - `Shared/MeetingDetail.swift`: `MeetingDetailModel` loads one meeting's files off the main thread for both the
    Mac and iPhone detail screens; audio players are only created on the first Play.
  - Errors that need an answer use `AppModel.errorMessage` (an alert); things worth knowing use `AppModel.notice`
    (a banner, optionally with an Open Settings button).
- `Watch/`, `Widgets/`: Apple Watch app, Live Activity and widgets
- `DESIGN.md`: design system and UI rules

## Tests

```bash
cd HushpadKit && swift test
```

Live provider tests call the real cloud notes APIs with **made-up** meeting text. They're never part of
`swift test` (providers can break for reasons outside this repo); the target only exists when you ask for it, and
reads keys from a git-ignored `.env.local` at the repository root (`OPENROUTER_API_KEY=…`, `OPENCODE_API_KEY=…`):

```bash
HUSHPAD_LIVE=1 HUSHPAD_LIVE_OUT=/tmp/live swift test --filter LiveProviderTests
```

## Screenshots

Debug builds have a demo mode that runs on invented meetings and keeps everything apart from your real app: its own
library, app data, keychain entries and settings. It only starts in a build with a `.demo` bundle id.

```bash
cd HushpadKit && swift run hushpad demo-library --output "/tmp/Demo Library" && cd ..
xcodebuild -scheme Hushpad -destination 'platform=macOS' -derivedDataPath build.noindex/demo \
  CODE_SIGNING_ALLOWED=NO PRODUCT_BUNDLE_IDENTIFIER=dev.hushpad.demo build
defaults write dev.hushpad.demo onboarded -bool true
HUSHPAD_DEMO_LIBRARY="/tmp/Demo Library" HUSHPAD_SNAPSHOT=/tmp/shot \
  build.noindex/demo/Build/Products/Debug/Hushpad.app/Contents/MacOS/Hushpad -NSRequiresAquaSystemAppearance YES
```

`HUSHPAD_SNAPSHOT` saves PNGs of the windows after a few seconds, without screen recording permission. Add
`HUSHPAD_SELECT=<meeting id>` to open a meeting, `HUSHPAD_SNAPSHOT_TRANSCRIPT=1` to open its transcript, or
`HUSHPAD_NUB=prompt|recording|ended|quiet` to show the floating nub. When you're done, run
`lsregister -u` on the demo app so it doesn't show up in Launchpad.

To rebuild the README demo, take four snapshots with `HUSHPAD_SNAPSHOT` set to `/tmp/shot/nub` (with
`HUSHPAD_NUB=prompt`), `/tmp/shot/notes` (with `HUSHPAD_SELECT` set to the Lumen meeting),
`/tmp/shot/transcript` (the same, plus `HUSHPAD_SNAPSHOT_TRANSCRIPT=1`) and `/tmp/shot/list`, then run
`python3 -I scripts/make-demo.py /tmp/shot docs/images/demo.svg` (needs `cwebp` and `uv`).

Only ever use invented meetings in screenshots and bug reports.

## A meeting on disk

```
2026-10-09 1405 Lumen app launch sync/
  recording.json          title, date, people, languages
  mic.wav, system.wav     the room and the call
  transcripts/            one transcript per speech model
  notes/mine.md           what you typed
  notes/enhanced.md       the generated notes (Obsidian-ready)
  screens/*.jpg           slides and screenshots
```

With a free Apple ID, the iPhone app has to be renewed every 7 days (`./install.sh --iphone-only`, about a minute).
