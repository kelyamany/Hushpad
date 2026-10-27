# Privacy

LocalScribe has no servers, no accounts and no analytics. This page lists everything that can leave your devices,
and when.

## What never leaves your devices

- **Audio.** Recording, transcription and speaker separation all run on your Mac, iPhone or Apple Watch.
  There is no cloud transcription.
- **Screenshots** of shared screens and photos of whiteboards.
- **Live captions.** Captions while you record come from Apple's on-device speech recogniser. The only network use is
  Apple downloading its speech model for a language, once.
- **Which apps are in a call.** Meeting detection only checks which apps are using the microphone (a Core Audio
  property, no permission needed). It never reads, joins or changes your call, and nothing about it is stored.
- **Anything at all, by default.** Cloud features are off until you turn them on in Settings and add a key.

## What can leave, and only if you choose it

| What | Sent to | When |
| --- | --- | --- |
| Speech models (download) | Hugging Face (Argmax's WhisperKit models) | Once per model, the first time you use it. Nothing about you is sent. |
| Transcript text and your notes | The notes model you picked: OpenRouter or OpenCode Go | Only when you generate notes with a cloud model. The app shows "Uses cloud". |
| Transcript text and your notes | Your own computer (LM Studio, Ollama, a server you run) | When you generate notes with a local model. Stays on your machine or network. |
| Your question, plus the notes and transcript of the meeting(s) it's about | Your notes model (local, or the cloud one you chose) | Only when you use Ask anything or a recipe. Same rules as notes. |
| Apple's speech model (download) | Apple | Once per language, the first time live captions run in it. No audio is sent. |
| Your library folder | Your iCloud Drive (or another sync service you chose) | Only if you put the library there. Turn on Advanced Data Protection for end-to-end encryption. |
| API keys and the library key | Your iCloud Keychain | End-to-end encrypted by Apple, so your other devices can use them. |

When a cloud notes model is used:

- **Only providers that keep no data** (on by default): OpenRouter only routes the request to providers with a
  zero-data-retention policy that don't train on your data. If none is available for the model you chose, the request
  fails instead of falling back.
- **Names hidden** (on by default): speaker and attendee names are replaced with "Person 1", "Person 2"… before
  the text is sent, and put back into the notes on your device. Names that only appear inside sentences and aren't
  known to LocalScribe can't be detected.
- Requests use an ephemeral connection: nothing is cached on disk.
- OpenCode Go is made for coding tools; check its terms before using it for meeting notes.

## Protection on your devices

- **App lock:** Touch ID, Face ID or your password, at launch and after a few minutes away. Recording continues
  while locked.
- **Encrypted library:** every file of every meeting is encrypted with ChaCha20-Poly1305 using a 256-bit key. The key
  is kept in your iCloud Keychain, and you get a Recovery Key to write down. Without both, nobody can open the
  meetings, including you. Plain copies needed for playback live in a private temporary folder and are deleted when
  the app restarts.
- **iPhone file protection:** recordings use iOS Data Protection. Finished meetings can't be read while the phone is
  locked; meetings still being recorded or transcribed stay readable after the first unlock, so background work can finish.
- **Excluded from backups:** the app's private library isn't included in iCloud or computer backups (a library
  folder you choose follows your own backup settings).
- **Invisible to the other side of a call:** every LocalScribe window (the app, the floating nub, the captions bubble,
  menus and sheets) is excluded from screen shares and screen recordings, even when you share the whole screen. No bot
  joins, no virtual camera or microphone is added, the call-audio tap is private to LocalScribe (call apps never see a
  new device), and LocalScribe plays no sounds. The menu bar icon (drawn by macOS, so it can't be hidden) looks the
  same whether or not you're recording. The orange and purple privacy dots are macOS's own and are shown to you only.
  Automatic screenshots are silent too: macOS's ScreenCaptureKit copies the screen from the window server, so the call
  app is never touched or notified, no shutter sound plays, LocalScribe's own windows are left out, and nothing is
  captured while you pause.
  Because no one else is notified, it's up to you to tell people and get their consent before you record. Recording
  laws differ by place, and some require everyone's agreement.
- **Delete old audio:** optionally remove audio after 30, 90 or 365 days and keep only the text.
- **Deleting a meeting** (or its audio) removes the files for good. Nothing goes to the system Trash, where audio and notes would sit outside the library for anyone to open. LocalScribe asks first.

## Permissions

- **Microphone:** to record the room.
- **Screen & System Audio Recording (Mac):** to record the call audio and take screenshots of the shared screen.
- **Camera (iPhone):** only when you take a photo of a slide or whiteboard.
- **Notifications (iPhone):** to tell you when a transcript is ready.

## Telemetry

None. LocalScribe doesn't collect usage data, crash reports or identifiers.
