/// Every explanation shown in Settings, in one place so Mac and iPhone say the same thing and stay short.
/// `SettingsCopyTests` keeps captions to 12 words and the total small; longer detail goes in `info…` (behind ⓘ).
enum SettingsCopy {
    // General
    static let librarySync = "Choose the same iCloud Drive folder on Mac and iPhone to sync."
    static let meetingsOffer = "Nothing records until you click Take notes."
    static let meetingsStop = "Asks if you're still there after 10 quiet minutes."
    static let infoMeetings = "Hushpad only checks which apps are using the microphone. It never joins, reads or changes your call, so nobody in the meeting can tell. Leaving a call doesn't stop the note, so you can rejoin."

    // Recording
    static let fullTranscript = "Off: click Transcribe when you want one."
    static let infoTranscription = "Live captions are quick. The full transcript is more accurate and names speakers, but takes a while; it can be paused and resumed. Auto-detect handles meetings in several languages; choosing one is faster and more accurate."

    // Notes
    static let notesLocalLMStudio = "Open LM Studio and start its server."
    static let notesLocalOllama = "Start Ollama on this Mac."
    static let notesLocalCustom = "Any OpenAI-compatible server."
    static let notesOnMac = "Runs on your Mac. Choose a cloud model to write notes here."
    static let notesOpenCodeGo = "Made for coding tools; check its terms first."
    static let instructions = "Folders can have their own (Edit Folder…)."
    static let recipes = "Type / in the Ask bar to use one."

    // Privacy
    static let lock = "Recording keeps going while locked."
    static let infoLockPhone = "Finished meetings on this iPhone can't be read while the iPhone is locked."
    static let retention = "Transcripts and notes are kept."
    static let encryption = "Only Hushpad on your devices can open your meetings."
    static let infoEncryption = "Even someone with the files can't read them. The key is kept in iCloud Keychain; keep your Recovery Key somewhere safe. Encrypted files can't be opened in Finder or Obsidian, so use Export for plain copies."
    static let cloud = "Only for notes. Audio never leaves your devices."
    static let infoCloud = "When you pick a cloud notes model, the transcript text and your notes are sent to it. Transcription always runs on your devices. Keys are kept in your Keychain and sync through iCloud Keychain."
    static let cloudPrivateRouting = "Skips providers that store or train on data."
    static let cloudMaskNames = "Names are swapped out before sending."

    // Models
    static let models = "Downloaded once, then run on this device."
}
