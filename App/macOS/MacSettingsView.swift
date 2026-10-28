#if os(macOS)
import HushpadKit
import HushpadUI
import SwiftUI

/// The Settings window (⌘,): the shared pages as tabs, like a native Mac app.
struct MacSettingsView: View {
    var body: some View {
        TabView {
            ForEach(SettingsPage.allCases) { page in
                Tab(page.rawValue, systemImage: page.symbol) {
                    Form { page.content }.formStyle(.grouped)
                }
            }
        }
        .frame(width: 600, height: 600)
        .appLock()
    }
}
#endif
