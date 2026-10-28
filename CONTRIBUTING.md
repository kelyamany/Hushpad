# Contributing

Thanks for helping make Hushpad better. Bug reports, ideas, documentation fixes, translations and code are all welcome.

## Before you start

- **Bugs:** open an issue with what you did, what you expected and what happened. Mention your Mac or iPhone model
  and OS version. Please never attach real meeting recordings or transcripts; describe the problem or make a test recording.
- **Features:** open an issue first for anything bigger than a small fix, so we can agree on the approach.

## Ground rules

These keep Hushpad what it is:

1. **Audio never leaves the device.** No change may upload recordings.
2. **Nothing goes to the cloud by default.** Any cloud feature must be off until the user turns it on, and must be
   clearly marked "Uses cloud" where it's used.
3. **No telemetry, no accounts, no servers.**
4. **Files stay plain and open.** Meetings are folders of ordinary files (unless the user turns on encryption).
5. **No performance regressions.** The library list and recording must stay fast with hundreds of meetings.

## Working on the code

See [docs/DEVELOPMENT.md](docs/DEVELOPMENT.md) for setup, the project layout, the design system and the tests.

- Keep changes focused, and follow the style of the code around you.
- Add or update tests in `HushpadKit/Tests` for logic changes.
- Run `cd HushpadKit && swift test` and build the Mac and iOS apps before opening a pull request.
- UI changes: follow [DESIGN.md](DESIGN.md) and include a screenshot (with made-up meetings, never real ones).

By contributing, you agree that your contributions are licensed under the [MIT License](LICENSE).
