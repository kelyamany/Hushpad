import LocalScribeUI
import SwiftUI

/// What the list shows instead of "No meetings yet" while the library is still opening, or when it is encrypted
/// and this device doesn't have the key. Shows nothing otherwise.
struct LibraryStatusView: View {
    @Environment(AppModel.self) private var model

    /// True when this view has something to say, so the list shouldn't show its normal empty state.
    static func applies(_ model: AppModel) -> Bool {
        !model.hasLoaded || (model.libraryLocked && model.recordings.isEmpty)
    }

    var body: some View {
        if !model.hasLoaded {
            ProgressView("Opening your meetings…")
                .controlSize(.small)
                .foregroundStyle(Theme.inkSecondary)
        } else if model.libraryLocked && model.recordings.isEmpty {
            EmptyState(.library, title: "This library is locked",
                       message: "It's encrypted and this device doesn't have the key yet. Enter your Recovery Key in Settings, or wait for iCloud Keychain to bring it.") {
                OpenSettingsButton()
            }
        }
    }
}
