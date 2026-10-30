import CoreGraphics
import Testing
@testable import HushpadCore

struct ScreenShareAnalyzerTests {
    private let window = CGRect(x: 100, y: 50, width: 1600, height: 1000)
    private let slide = CGRect(x: 110, y: 110, width: 1260, height: 860)

    /// A meeting window: toolbar, a strip of webcam tiles on the right, and whatever else is passed in.
    private func meeting(_ extra: [AXNodeSnapshot], title: String = "Zoom Meeting") -> AXWindowSnapshot {
        let tiles = (0..<4).map { AXNodeSnapshot(role: "AXGroup", frame: CGRect(x: 1390, y: 110 + Double($0) * 200, width: 300, height: 190)) }
        let chrome = [
            AXNodeSnapshot(role: "AXWindow", frame: window),
            AXNodeSnapshot(role: "AXGroup", frame: CGRect(x: 100, y: 100, width: 1600, height: 900)),  // the whole layout
            AXNodeSnapshot(role: "AXToolbar", frame: CGRect(x: 100, y: 990, width: 1600, height: 60)),
        ]
        return AXWindowSnapshot(title: title, frame: window, nodes: chrome + tiles + extra)
    }

    private func sharing(_ banner: String) -> [AXNodeSnapshot] {
        [AXNodeSnapshot(role: "AXStaticText", text: banner, frame: CGRect(x: 600, y: 60, width: 400, height: 30)),
         AXNodeSnapshot(role: "AXGroup", frame: slide.insetBy(dx: -2, dy: -2)),  // wrapper around the picture
         AXNodeSnapshot(role: "AXImage", frame: slide)]
    }

    @Test func findsSomeoneElsesShareAndCropsOutTheTiles() {
        let state = ScreenShareAnalyzer.state(provider: .zoom, windows: [meeting(sharing("You are viewing Sam's screen"))])
        #expect(state == .someoneElse(surface: slide, window: window))
    }

    @Test func meetAndTeamsMarkers() {
        let meet = meeting(sharing("Sam is presenting"), title: "Meet - abc-defg-hij")
        #expect(ScreenShareAnalyzer.state(provider: .meet, windows: [meet]) == .someoneElse(surface: slide, window: window))
        let teams = meeting(sharing("Sam is sharing"), title: "Weekly sync | Microsoft Teams")
        #expect(ScreenShareAnalyzer.state(provider: .teams, windows: [teams]) == .someoneElse(surface: slide, window: window))
    }

    @Test func ignoresYourOwnShare() {
        let toolbar = AXNodeSnapshot(role: "AXButton", identifier: "ZMMTToolbarContentIdentifierPauseShare", text: "Pause Share")
        #expect(ScreenShareAnalyzer.state(provider: .zoom, windows: [meeting([toolbar])]) == .selfSharing)
        let meet = meeting([AXNodeSnapshot(role: "AXButton", text: "Stop presenting")], title: "Meet")
        #expect(ScreenShareAnalyzer.state(provider: .meet, windows: [meet]) == .selfSharing)
    }

    @Test func nothingWithoutAShare() {
        #expect(ScreenShareAnalyzer.state(provider: .zoom, windows: [meeting([])]) == .none)
    }

    @Test func galleryOfEqualTilesIsNotAShare() {
        // A banner, but only equal-sized webcam tiles: no single shared surface.
        let gallery = (0..<4).map { i in
            AXNodeSnapshot(role: "AXGroup", frame: CGRect(x: 110 + Double(i % 2) * 640, y: 110 + Double(i / 2) * 440, width: 630, height: 430))
        }
        let window = meeting([AXNodeSnapshot(role: "AXStaticText", text: "Sam is presenting")] + gallery, title: "Meet")
        #expect(ScreenShareAnalyzer.state(provider: .meet, windows: [window]) == .ambiguous)
    }

    @Test func tinyShareIsAmbiguous() {
        let small = [AXNodeSnapshot(role: "AXStaticText", text: "Sam is sharing"),
                     AXNodeSnapshot(role: "AXImage", frame: CGRect(x: 110, y: 110, width: 300, height: 200))]
        #expect(ScreenShareAnalyzer.state(provider: .teams, windows: [meeting(small)]) == .ambiguous)
    }

    @Test func combinesApps() {
        let share = ScreenShareState.someoneElse(surface: slide, window: window)
        #expect(ScreenShareAnalyzer.combine([.none, share]) == share)
        #expect(ScreenShareAnalyzer.combine([share, share]) == .ambiguous)
        #expect(ScreenShareAnalyzer.combine([.selfSharing, .none]) == .selfSharing)
        #expect(ScreenShareAnalyzer.combine([]) == .none)
    }

    @Test func providers() {
        #expect(ScreenShareAnalyzer.provider(bundleID: "us.zoom.xos", windowTitle: "") == .zoom)
        #expect(ScreenShareAnalyzer.provider(bundleID: "com.microsoft.teams2", windowTitle: "") == .teams)
        #expect(ScreenShareAnalyzer.provider(bundleID: "com.google.Chrome", windowTitle: "Meet - abc-defg-hij") == .meet)
        #expect(ScreenShareAnalyzer.provider(bundleID: "com.google.Chrome", windowTitle: "Inbox") == nil)
        #expect(ScreenShareAnalyzer.provider(bundleID: "com.apple.TextEdit", windowTitle: "Meet notes") == nil)
    }

    @Test func cropIsInWindowCoordinates() {
        #expect(ScreenShareAnalyzer.sourceRect(surface: slide, window: window) == CGRect(x: 10, y: 60, width: 1260, height: 860))
        // A second display to the left of the main one has negative x.
        let left = CGRect(x: -1920, y: 0, width: 1600, height: 1000)
        #expect(ScreenShareAnalyzer.sourceRect(surface: CGRect(x: -1900, y: 40, width: 1000, height: 700), window: left)
                == CGRect(x: 20, y: 40, width: 1000, height: 700))
        // Clipped to the window when the share pokes out.
        #expect(ScreenShareAnalyzer.sourceRect(surface: CGRect(x: 1500, y: 50, width: 400, height: 300), window: window)
                == CGRect(x: 1400, y: 0, width: 200, height: 300))
    }
}
