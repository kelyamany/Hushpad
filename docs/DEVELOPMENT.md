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
./install.sh --uninstall    # remove the app, settings, permissions, models and build files (add --iphone for the phone)
```

Builds go to `build.noindex/`, so Spotlight and Launchpad ignore them.

Signing: with an Apple Development certificate the Mac app is signed with your team, so macOS keeps its permissions
across updates and keys sync through iCloud Keychain. Without one it's signed to run locally, and macOS may ask for
permissions again after updates.

To open the project in Xcode: `xcodegen generate && open LocalScribe.xcodeproj`.

## Layout

- `LocalScribeKit/`: Swift package with the logic, plus the `scribe` CLI (`swift run scribe --help`)
  - `LocalScribeCore/`: data model, storage, file coordination, library encryption, exporters (also used by the Watch)
  - `LocalScribeKit/Recording/`: mic and system audio capture on one shared clock, permissions
  - `LocalScribeKit/Screenshots/`: ScreenCaptureKit capture and slide-change detection
  - `LocalScribeKit/Transcription/`: WhisperKit engine, model catalog
  - `LocalScribeKit/Diarization/`: SpeakerKit (pyannote) speaker separation
  - `LocalScribeKit/Pipeline/`: transcribe → diarize → align → merge, echo and hallucination filtering
  - `LocalScribeKit/Notes/`: notes generation (OpenAI-compatible client, prompts, name masking), shared settings
  - `LocalScribeKit/Cloud/`: Keychain (API keys and the library key)
  - `LocalScribeUI/`: the design system shared by all apps
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
cd LocalScribeKit && swift test
```

Live provider tests call the real cloud notes APIs with **made-up** meeting text. They're never part of
`swift test` (providers can break for reasons outside this repo); the target only exists when you ask for it, and
reads keys from a git-ignored `.env.local` at the repository root (`OPENROUTER_API_KEY=…`, `OPENCODE_API_KEY=…`):

```bash
LOCALSCRIBE_LIVE=1 LOCALSCRIBE_LIVE_OUT=/tmp/live swift test --filter LiveProviderTests
```

## Screenshots

Debug builds can open a demo library instead of yours and save window images, without screen recording permission:

```bash
LOCALSCRIBE_DEMO_LIBRARY=/path/to/demo LOCALSCRIBE_SELECT=<meeting id> LOCALSCRIBE_SNAPSHOT=/tmp/shot \
  build.noindex/…/LocalScribe.app/Contents/MacOS/LocalScribe
```

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
