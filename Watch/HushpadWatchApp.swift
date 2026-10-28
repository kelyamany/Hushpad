import SwiftUI

@main
struct HushpadWatchApp: App {
    @State private var recorder = WatchRecorder()

    var body: some Scene {
        WindowGroup {
            WatchRootView()
                .environment(recorder)
        }
    }
}
