import SwiftUI

@main
struct LocalScribeWatchApp: App {
    @State private var recorder = WatchRecorder()

    var body: some Scene {
        WindowGroup {
            WatchRootView()
                .environment(recorder)
        }
    }
}
