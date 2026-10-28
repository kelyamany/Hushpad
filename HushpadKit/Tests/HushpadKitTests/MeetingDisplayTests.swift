#if os(macOS)
import CoreGraphics
import Testing
@testable import HushpadKit

struct MeetingDisplayTests {
    // Main display at the origin, a second monitor to its right.
    private let displays: [(id: CGDirectDisplayID, frame: CGRect)] = [
        (1, CGRect(x: 0, y: 0, width: 1512, height: 982)),
        (2, CGRect(x: 1512, y: 0, width: 2560, height: 1440)),
    ]

    @Test func callOnSecondMonitorPicksIt() {
        let call = CGRect(x: 1800, y: 100, width: 300, height: 200)
        #expect(ScreenCapturer.meetingDisplay(windows: [call], displays: displays) == 2)
    }

    @Test func windowSpanningBothPicksTheOneShowingMostOfIt() {
        let call = CGRect(x: 1400, y: 100, width: 800, height: 600)  // 112 pt on 1, 688 pt on 2
        #expect(ScreenCapturer.meetingDisplay(windows: [call], displays: displays) == 2)
    }

    @Test func largestMeetingWindowWins() {
        let small = CGRect(x: 1600, y: 0, width: 200, height: 100)
        let large = CGRect(x: 100, y: 100, width: 900, height: 700)
        #expect(ScreenCapturer.meetingDisplay(windows: [small, large], displays: displays) == 1)
    }

    @Test func noMeetingWindowGivesNil() {
        #expect(ScreenCapturer.meetingDisplay(windows: [], displays: displays) == nil)
    }
}
#endif
