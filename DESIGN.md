# Hushpad design system

Hushpad should feel calm, like paper and ink. The notes and the transcript are the page; everything around them stays quiet.
Inspired by Apple's own apps. Code lives in `LocalScribeKit/Sources/LocalScribeUI`.

## Principles (check every change against these)

1. **Content first.** Titles, notes and transcript lead. Chrome, badges and captions recede.
2. **One primary action per screen.** Secondary actions go in the single "More" (…) menu. Don't put the same action in several places.
3. **Show it when it matters.** Status appears only when something needs attention: recording, working, failed, or uses the cloud. A healthy state shows nothing.
4. **Plain words.** No model ids, file formats, vendor names or engine jargon outside Settings › Advanced. Errors give one plain sentence; technical text goes behind "Details".
5. **Never lose work.** Edits autosave (debounced, and again when the view closes). Titles save on Return and when focus leaves. Destructive actions ask first and say what is lost and where.
6. **Calm motion.** Only an active recording animates continuously (waveform, record button). Everything else uses one-shot springs (`Motion.snappy`, `Motion.smooth`). Respect Reduce Motion.
7. **Native first.** Use system controls, Dynamic Type text styles and materials. Every icon-only control has an accessibility label. Never use colour alone: pair it with text or a symbol.
8. **Performance budget.** No file IO, sorting, filtering, parsing or date formatting inside `body`. Derived data (list sections, summaries, transcript layout, Markdown blocks, thumbnails) is computed once and cached. Only the smallest possible view observes fast-changing values such as the playback clock or audio levels.

## Tokens

| Token | Values | Use |
|---|---|---|
| `Space` | xxs 2 · xs 4 · s 8 · m 12 · l 16 · xl 24 · xxl 32 · xxxl 48 | All padding and spacing |
| `Radius` | s 6 (chips) · m 8 (buttons, fields, rows) · l 12 (cards) · xl 16 (sheets, art) · xxl 24 (nub prompt) | Always `.continuous`, via `Radius.shape(_:)` |
| `Size` | hitTarget 44 · readableWidth 720 | Tap targets, document line length |
| `Motion` | snappy · smooth · recordPulse | Springs; recordPulse is the only repeating animation |

**Type**
- Fonts, bundled in `LocalScribeUI/Fonts` under the SIL Open Font License:
  - IBM Plex Serif for titles. Always regular weight, never bold.
  - Hanken Grotesk for everything else.
  - The Watch keeps SF.
- Titles: `.displayLarge` 36 (meeting titles), `.displayMedium` 28 (page titles), `.displaySmall` 24 (section headers).
- Text:
  - `.heading` 18 semibold, for headings in notes and cards.
  - `.editor` 16, for notes.
  - `.base` 14, the default and set on every window.
  - `.small` 13; `.meta` uses it.
  - `.label` 12, for chips and captions.
  - `.micro` 11.
  - `.mono`.
- Roles: `.rowTitle` is base medium; `.timer` has fixed-width digits.
- On iPhone the text tokens are 15 % larger, and every token follows Dynamic Type.
- Never use SwiftUI's built-in styles (`.body`, `.footnote` and so on) in views. `TypographyLintTests` enforces this.
  Fixed sizes are only for SF Symbol icons.

**Colour** (`Theme`, light/dark). Our own palette: cool neutrals and ink blue. The nub's pill is navy, and its prompt
card is periwinkle.
- Surfaces:
  - `paper` is the page.
  - `paperRaised` is used for cards and rows.
  - `paperSunken` is used for wells, inputs and illustration discs.
  - `hairline` is used for borders.
- Ink: `ink`, `inkSecondary`, `inkTertiary`.
- Meaning:
  - `accent` (deep ink-blue): selection, links, progress.
  - `record`: recording only.
  - `danger`: errors and destruction.
  - `success`.
  - `cloud`: amber, always with the "Uses cloud" text.
- The speaker and folder palette is 8 muted hues.
- The only gradient is on the record button.

**Elevation**
- Flat: text on paper.
- Raised: the `.card()` modifier, a hairline border with no heavy shadow.
- Floating: Liquid Glass. Use it only for chrome that floats over content: the record bar, playback bar, recording HUD and mini recorder.

## Components

- `MeetingRow`: a title, a meta line, and at most one `StatusPill`.
- `StatusPill`: recording · waiting · transcribing % · writing notes · failed · uses cloud.
- `MetaLine`: parts joined with "·"; empty parts are skipped.
- `EmptyState`: a `Vignette` illustration, one sentence, at most one action.
- `InlineBanner`: an error with Retry; raw text is behind "Details".
- `.card()`: a raised surface.
- `PrivacyFooter`: the one place the privacy promise is written out.
- `FolderLabel`, `SpeakerChip`, `SourceBadge`.
- App-level (`App/Shared`): `NotesEditor` (debounced autosave), `TitleField`, `MoveToFolderMenu`, `FolderEditor`, `TranscribeAgainSheet`, `JobCard`, `TranscriptExport` (written only when shared), `SpeakerEditor` (rename, or "Same person as…" to merge), `MergeSpeakerMenu`, `SpeakerUndoBar` (10-second Undo after a merge), `PermissionRow`.
- `LanguagePicker` (Auto, then Common, then all languages) and `MeetingLanguages` (per-meeting transcript and notes language, offering to redo the transcript or notes after a change).
- `PrivacySection`, `.appLock()` (cover while locked, app-switcher curtain on iPhone), `RecoveryKeySheet`.
- **Audio never leaves the device.** There is no cloud transcription; cloud is only for notes (text), opt-in, and always shown with the "uses cloud" pill.
- **Permissions** are read only from `AppModel.permissions` (`PermissionCenter`). Never call `Permissions.status` in a view. Each row shows one next step: Allow · Open Settings · Restart (screen recording) · ✓.

## Words (one name per action, Title Case on buttons and menu items)

| Action | Say | Not |
|---|---|---|
| Write AI notes | Generate Notes · Regenerate… | Enhance notes, Write Again |
| Remove a meeting | Delete… (menus) · "Delete “Title”?" (dialog) | Delete Meeting… in some places only |
| Transcript file | Export Transcript | Share Transcript |
| Images on a meeting | Attachments | Photos, Screens |
| Folders | New Folder… · Move to Folder · Remove from Folder | |
| Recording | Stop Recording (menus) · Stop (inline) | Stop recording |

## Settings

- **Five pages, the same on Mac (tabs) and iPhone (a list of pages):** General · Recording · Notes · Privacy · Models (`SettingsPage`).
- **Short copy.**
  - Each control has a label and at most one caption of 12 words or fewer.
  - Longer explanations sit behind an ⓘ (`InfoButton`) next to the section title.
  - All wording lives in `SettingsCopy`. `SettingsCopyTests` caps the on-screen total at 150 words.
- **Long editors open in sheets:** templates, instructions and recipes, so the pages stay scannable.

## Art

The brand mark is the **sound line**, `SoundLine`. A sound wave settles into a handwritten line, which reads as "listen → notes". The app icon is a separate mark: one ribbon that loops over itself on ink, drawn with a flat calligraphy nib so it twists to show a cream front and an apricot back. It is playful but says nothing about recording (no sound wave, microphone or red dot). iPhone has light, dark and tinted variants; the Watch uses the light one, slightly smaller to clear the circular mask. The Mac menu bar shows the same ribbon as an 18 pt template image (`MenuBarIcon`), with the back side half transparent.

Empty-state illustrations are `Vignette`s:
- a soft disc
- two paper cards with ruled lines
- one SF Symbol in ink
- the sound line in accent

They are pure shapes, so they theme automatically and cost nothing to draw.

To regenerate the icons, run `swift scripts/make-icons.swift <folder>`, then copy the output into `App/Assets.xcassets/AppIcon.appiconset` (Mac sizes via `sips`) and `Watch/Assets.xcassets`.

## Layout

- **Mac**: three columns.
  - Sidebar: New Meeting, All Meetings, Imported, Folders.
  - Meeting list: grouped by day, with search.
  - Document: title, meta, the notes, then Attachments (screenshots and added images). The transcript opens in a drawer.
  - The Transcript tab starts with the version picker and "Transcribe Again…", which is that tab's primary action.
  - The toolbar holds the tab picker and "More". The primary action for each tab sits inside the page.
  - Attachments: "Add Images…" or drop image files anywhere on the meeting (e.g. screenshots saved from another app). An olive outline shows the drop target; empty meetings show a dashed drop zone.
- **iPhone**:
  - The list title is a menu: All Meetings / Imported / folders / New Folder.
  - The big glass record button sits at the bottom.
  - The detail view follows the same document structure as the Mac.
  - Swipe right to Move and left to Delete.
- **Watch**: one big button. The list shows each recording's sync state in words.
