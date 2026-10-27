import Foundation
import Testing
@testable import LocalScribeKit

private let zoom = MeetingApp(name: "Zoom")
private let chrome = MeetingApp(name: "Chrome", isBrowser: true)

/// Fixed clock: every test works in seconds after this instant, never with real time.
private func at(_ seconds: Double) -> Date { Date(timeIntervalSince1970: 1000 + seconds) }

@Suite struct MeetingAppTests {
    @Test func identifiesZoom() {
        let app = MeetingApp.identify(bundleID: "us.zoom.xos")
        #expect(app?.name == "Zoom")
        #expect(app?.isBrowser == false)
        #expect(app?.callTitle == "Zoom call")
    }

    @Test func identifiesTeams() {
        #expect(MeetingApp.identify(bundleID: "com.microsoft.teams2")?.name == "Teams")
    }

    @Test func chromeHelperMatchesChromeAsBrowser() {
        let app = MeetingApp.identify(bundleID: "com.google.Chrome.helper")
        #expect(app?.name == "Chrome")
        #expect(app?.isBrowser == true)
        #expect(app?.callTitle == "Browser call")
    }

    @Test func unknownBundleIsNil() {
        #expect(MeetingApp.identify(bundleID: "com.example.notes") == nil)
    }

    @Test func allNamesListsEachAppOnce() {
        let names = MeetingApp.allNames
        #expect(names.contains("Zoom"))
        #expect(names.contains("Chrome"))
        #expect(Set(names).count == names.count)
    }
}

@Suite struct MeetingDetectionTests {
    @Test func noPromptBeforeDebounce() {
        var detection = MeetingDetection()
        detection.update(apps: [zoom], now: at(0))
        #expect(detection.prompt(now: at(2.9)) == nil)
    }

    @Test func promptAfterDebounce() {
        var detection = MeetingDetection()
        detection.update(apps: [zoom], now: at(0))
        #expect(detection.prompt(now: at(3)) == zoom)
    }

    @Test func nativeAppPreferredOverBrowser() {
        var detection = MeetingDetection()
        // Chrome started first, so only the native preference (not order) can pick Zoom.
        detection.update(apps: [chrome], now: at(0))
        detection.update(apps: [chrome, zoom], now: at(1))
        #expect(detection.prompt(now: at(10)) == zoom)
    }

    @Test func dismissHidesPromptUntilAppReleasesAndReturns() {
        var detection = MeetingDetection()
        detection.update(apps: [zoom], now: at(0))
        #expect(detection.prompt(now: at(5)) == zoom)

        detection.dismiss(zoom)
        #expect(detection.prompt(now: at(6)) == nil)

        // Still in the same call: stays dismissed.
        detection.update(apps: [zoom], now: at(7))
        #expect(detection.prompt(now: at(20)) == nil)

        // Releases the mic, then comes back for a new call.
        detection.update(apps: [], now: at(8))
        detection.update(apps: [zoom], now: at(9))
        #expect(detection.prompt(now: at(11.9)) == nil)
        #expect(detection.prompt(now: at(12)) == zoom)
    }

    @Test func ignoredAppsNeverPrompt() {
        var detection = MeetingDetection()
        detection.ignored = ["Zoom"]
        detection.update(apps: [zoom], now: at(0))
        #expect(detection.prompt(now: at(30)) == nil)
    }

    @Test func ignoringOneAppStillPromptsForAnother() {
        var detection = MeetingDetection()
        detection.ignored = ["Zoom"]
        detection.update(apps: [zoom, chrome], now: at(0))
        #expect(detection.prompt(now: at(10)) == chrome)
    }

    @Test func hasEndedAfterGracePeriodOnly() {
        var detection = MeetingDetection()
        detection.update(apps: [zoom], now: at(0))
        #expect(detection.hasEnded(zoom, now: at(200)) == false) // still in the call

        detection.update(apps: [], now: at(100))
        #expect(detection.hasEnded(zoom, now: at(105)) == false)
        #expect(detection.hasEnded(zoom, now: at(109.9)) == false)
        #expect(detection.hasEnded(zoom, now: at(110)) == true)
        #expect(detection.hasEnded(zoom, now: at(111)) == true)
    }

    @Test func callAppIsTheActiveApp() {
        var detection = MeetingDetection()
        #expect(detection.callApp(now: at(0)) == nil)

        detection.update(apps: [chrome], now: at(0))
        #expect(detection.callApp(now: at(1)) == chrome)

        detection.update(apps: [chrome, zoom], now: at(2))
        #expect(detection.callApp(now: at(3)) == zoom) // native beats browser
    }

    @Test func nextChangeIsTheDebounceDeadline() {
        var detection = MeetingDetection()
        detection.update(apps: [zoom], now: at(0))
        #expect(detection.nextChange(after: at(1)) == at(3))
        #expect(detection.nextChange(after: at(3)) == nil)
    }

    @Test func nextChangeIsTheEndGraceDeadlineAfterRelease() {
        var detection = MeetingDetection()
        detection.update(apps: [zoom], now: at(0))
        detection.update(apps: [], now: at(100))
        #expect(detection.nextChange(after: at(101)) == at(110))
    }
}
