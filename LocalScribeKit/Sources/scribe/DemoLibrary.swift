import AppKit
import ArgumentParser
import Foundation
import LocalScribeKit

/// Writes a library of invented meetings, for screenshots and demos (see docs/DEVELOPMENT.md › Screenshots).
/// Every name, company and number in it is made up.
struct DemoLibrary: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "demo-library", abstract: "Write a library of invented meetings for screenshots.", shouldDisplay: false)

    @Option(help: "Folder to create (must not exist yet).") var output: String

    func run() throws {
        let root = URL(fileURLWithPath: output, isDirectory: true)
        guard !FileManager.default.fileExists(atPath: root.path) else {
            throw ValidationError("\(root.path) already exists; pick a new folder.")
        }
        let store = try RecordingStore(root: root)
        let team = Folder(name: "Team", symbol: "person.2", colorIndex: 2)
        let clients = Folder(name: "Clients", symbol: "briefcase", colorIndex: 4)
        try store.saveFolders([team, clients])
        for meeting in Self.meetings(team: team.id, clients: clients.id) { try write(meeting, to: store) }
        print("Wrote \(store.loadAll().count) invented meetings to \(root.path)")
    }

    private struct Meeting {
        var title: String
        var daysAgo: Int
        var time: (Int, Int)
        var minutes: Double
        var people: [String]
        var folder: UUID?
        var mine: String
        var notes: String
        var lines: [(speaker: Int, text: String)]
        var slides: [(title: String, bullets: [String])] = []
    }

    private func write(_ meeting: Meeting, to store: RecordingStore) throws {
        let calendar = Calendar.current
        let day = calendar.date(byAdding: .day, value: -meeting.daysAgo, to: Date())!
        let start = calendar.date(bySettingHour: meeting.time.0, minute: meeting.time.1, second: 0, of: day)!
        var recording = Recording(title: meeting.title, createdAt: start, duration: meeting.minutes * 60, hasMic: false,
                                  language: .init(rawValue: "en"), activeEngine: "whisperkit:openai_whisper-large-v3-v20240930_turbo",
                                  source: .mac, attendees: meeting.people, folderID: meeting.folder)
        recording.notesLanguage = .init(rawValue: "en")

        let speakers = [Speaker(key: "me", name: "You")]
            + meeting.people.enumerated().map { Speaker(key: "S\($0.offset + 1)", name: $0.element) }
        var clock = 4.0
        let utterances = meeting.lines.map { line -> Utterance in
            let length = Double(line.text.split(separator: " ").count) * 0.42 + 1
            defer { clock += length + 1.5 }
            return Utterance(speaker: speakers[line.speaker].key, start: clock, end: clock + length, text: line.text)
        }
        let transcript = Transcript(language: recording.language, detectedLanguage: "en", speakers: speakers,
                                    utterances: utterances, engine: recording.activeEngine!, createdAt: start)
        try store.save(recording)
        try store.save(transcript, for: recording.id)
        try store.saveNotes(meeting.mine, for: recording.id, .mine)
        let input = NotesInput(recording: recording, transcript: transcript, myNotes: meeting.mine)
        try store.saveNotes(NotesGenerator.document(body: meeting.notes, input: input, model: "qwen3-14b", includeTranscript: false),
                            for: recording.id, .enhanced)
        let folder = store.folder(for: recording.id)
        for (index, slide) in meeting.slides.enumerated() {
            try ScreenshotStore.save(Self.slide(slide.title, slide.bullets), at: 60 + Double(index) * 240, in: folder)
        }
    }

    /// A plain presentation slide: a title and a few bullets on white.
    private static func slide(_ title: String, _ bullets: [String]) -> CGImage {
        let size = NSSize(width: 1600, height: 900)
        let image = NSImage(size: size, flipped: true) { rect in
            NSColor.white.setFill()
            rect.fill()
            NSColor(red: 0.18, green: 0.29, blue: 0.48, alpha: 1).setFill()
            NSRect(x: 0, y: 0, width: rect.width, height: 14).fill()
            (title as NSString).draw(at: NSPoint(x: 110, y: 120), withAttributes: [
                .font: NSFont.systemFont(ofSize: 76, weight: .semibold), .foregroundColor: NSColor(white: 0.12, alpha: 1)])
            for (index, bullet) in bullets.enumerated() {
                ("•  " + bullet as NSString).draw(at: NSPoint(x: 120, y: 300 + CGFloat(index) * 110), withAttributes: [
                    .font: NSFont.systemFont(ofSize: 50), .foregroundColor: NSColor(white: 0.3, alpha: 1)])
            }
            return true
        }
        return image.cgImage(forProposedRect: nil, context: nil, hints: nil)!
    }

    private static func meetings(team: UUID, clients: UUID) -> [Meeting] {
        [
            Meeting(
                title: "Lumen app launch sync", daysAgo: 1, time: (16, 5), minutes: 28,
                people: ["Anna Weber", "Omar Haddad", "Jamie Chen"], folder: team,
                mine: "launch 12 nov?\npayment crash on old iphones — omar\nloyalty → january\ndelivery fee?",
                notes: """
                ## Summary
                The team agreed to launch the Lumen ordering app on **12 November**, provided the payment crash on older iPhones is fixed by Friday. Loyalty points move to January.

                ## Decisions
                - Launch date: 12 November
                - Loyalty points postponed to January
                - Delivery fee stays at €2.50 for launch, reviewed in December

                ## Action items
                - [ ] Fix the payment screen crash on older iPhones — **Omar** (Friday)
                - [ ] Send two test devices to Omar — **Jamie** (tomorrow)
                - [ ] Update App Store screenshots with new prices — **Jamie** (Monday)

                ## Open questions
                - Who answers support emails during launch week?
                """,
                lines: [
                    (1, "Okay, let's start. The big question today is whether we can still launch on the twelfth."),
                    (2, "Mostly yes. The one blocker is the payment screen. It crashes on older iPhones when you add a card."),
                    (0, "How long do you need for that?"),
                    (2, "I think I can have a fix by Friday if I get two of the older test devices."),
                    (3, "I can send you two tomorrow morning."),
                    (1, "Great. Then we keep the twelfth, as long as the crash is fixed by Friday."),
                    (0, "And loyalty points? I'd rather not squeeze them in."),
                    (1, "Agreed, let's move loyalty to January and launch without it."),
                    (3, "What about the delivery fee? Marketing asked if we're keeping two fifty."),
                    (1, "Keep it at two fifty for launch and we look at the numbers again in December."),
                    (3, "Then I'll update the App Store screenshots with the new prices on Monday."),
                    (0, "One thing we haven't decided: who answers support emails in launch week?"),
                ],
                slides: [("Launch plan", ["Ship: 12 November", "Fix payment crash by Friday", "Loyalty points: January"]),
                         ("Pricing at launch", ["Delivery fee: €2.50", "Review in December", "No launch discount"])]),
            Meeting(
                title: "Design review: onboarding", daysAgo: 4, time: (12, 30), minutes: 41,
                people: ["Mia Torres", "Leo Martin"], folder: team,
                mine: "3 screens → 2\nskip sign-up until first order",
                notes: """
                ## Summary
                Onboarding shrinks from three screens to two, and sign-up waits until the first order.

                ## Decisions
                - Merge the welcome and location screens
                - Ask for an account only at checkout

                ## Action items
                - [ ] New two-screen flow in Figma — **Mia** (Wednesday)
                - [ ] Check analytics for drop-off on screen two — **Leo** (Tuesday)
                """,
                lines: [
                    (1, "People drop off on the second screen. Three screens is just too many before they see any food."),
                    (2, "We could merge welcome and location into one."),
                    (0, "And do we really need sign-up before the first order?"),
                    (1, "No. Let's ask at checkout instead."),
                ]),
            Meeting(
                title: "Kickoff with Northwind", daysAgo: 5, time: (18, 0), minutes: 52,
                people: ["Priya Nair", "Tom Becker"], folder: clients,
                mine: "pilot in 3 stores\nweekly call thu",
                notes: """
                ## Summary
                Northwind starts with a six-week pilot in three stores, with a weekly check-in on Thursdays.

                ## Action items
                - [ ] Share the pilot plan — **You** (Friday)
                - [ ] Pick the three pilot stores — **Priya** (next week)
                """,
                lines: [
                    (1, "We'd like to start small. Maybe three stores for six weeks?"),
                    (0, "That works well for us. Shall we do a weekly call?"),
                    (2, "Thursdays are best for our team."),
                ]),
            Meeting(
                title: "Weekly 1:1", daysAgo: 6, time: (11, 0), minutes: 25,
                people: ["Sam Lee"], folder: nil,
                mine: "conference talk\nvacation in dec",
                notes: """
                ## Summary
                Sam will submit a talk to the spring conference and is off the last two weeks of December.

                ## Action items
                - [ ] Send Sam the talk submission link — **You** (today)
                """,
                lines: [
                    (1, "I'd like to give a talk at the spring conference this year."),
                    (0, "Love that. I'll send you the submission link today."),
                ]),
        ]
    }
}
