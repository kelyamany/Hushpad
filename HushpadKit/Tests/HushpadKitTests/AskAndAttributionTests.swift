import Foundation
import Testing
@testable import HushpadCore
@testable import HushpadKit

// MARK: - Fixtures

private let fixedID = UUID(uuidString: "6F1C2B3A-1111-4A2B-9C3D-0123456789AB")!
private let otherID = UUID(uuidString: "0A0B0C0D-2222-4E5F-8A9B-FEDCBA987654")!

/// Gregorian calendar pinned to UTC with Monday as the first day, so "this week" is deterministic.
private let utc: Calendar = {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(identifier: "UTC")!
    calendar.firstWeekday = 2
    return calendar
}()

private func utcDate(_ year: Int, _ month: Int, _ day: Int, hour: Int = 12) -> Date {
    utc.date(from: DateComponents(year: year, month: month, day: day, hour: hour))!
}

/// Wednesday 14 October 2026, noon UTC. The week runs Monday 12 October to Monday 19 October.
private let fixedNow = utcDate(2026, 10, 14)

/// A long meeting: distinct first and last remarks, with filler in between.
private func longTranscript(count: Int = 200) -> Transcript {
    let utterances = (0..<count).map { index -> Utterance in
        let text: String
        if index == 0 {
            text = "opening-remark-zero kicks things off"
        } else if index == count - 1 {
            text = "closing-remark-final wraps everything up"
        } else {
            text = "filler number \(index) about the roadmap and the budget for next quarter"
        }
        return Utterance(speaker: index.isMultiple(of: 2) ? "microphone" : "call",
                         start: Double(index * 5), end: Double(index * 5 + 4), text: text)
    }
    return Transcript(language: .english, speakers: [], utterances: utterances, engine: "test")
}

// MARK: - 1. Note attribution

struct NoteAttributionTests {
    @Test func bulletRepeatingMostWordsOfYourNoteIsAuthored() {
        // Note words: send, the, pricing, deck, to, sara, by, friday (8). The bullet shares 6 of them (75%).
        let blocks: [MarkdownBlock] = [
            .heading(level: 2, text: "Summary"),
            .bullet(indent: 0, text: "Sara will send the pricing deck to her team"),
            .bullet(indent: 0, text: "Discussed the hiring plan for engineering"),
        ]
        let authored = NoteAttribution.authored(blocks, myNotes: "Send the pricing deck to Sara by Friday")
        #expect(authored == [1])
    }

    @Test func unrelatedBulletIsNotAuthored() {
        let blocks: [MarkdownBlock] = [.paragraph("The team reviewed the quarterly hiring forecast.")]
        #expect(NoteAttribution.authored(blocks, myNotes: "Call the dentist about the crown").isEmpty)
    }

    @Test func headingsAreNeverAuthoredEvenWhenTheyMatch() {
        let blocks: [MarkdownBlock] = [
            .heading(level: 2, text: "Pricing deck"),
            .bullet(indent: 0, text: "Pricing deck"),
        ]
        #expect(NoteAttribution.authored(blocks, myNotes: "Pricing deck") == [1])
    }

    @Test func oneWordNoteMustMatchExactly() {
        let blocks: [MarkdownBlock] = [
            .bullet(indent: 0, text: "Budget approved"),
            .bullet(indent: 0, text: "Budgets are tight"),
            .bullet(indent: 0, text: "Approved the spending plan"),
        ]
        #expect(NoteAttribution.authored(blocks, myNotes: "budget") == [0])
    }

    @Test func twoWordNoteMustMatchCompletely() {
        let blocks: [MarkdownBlock] = [
            .bullet(indent: 0, text: "Roadmap for Q3 agreed"),
            .bullet(indent: 0, text: "The roadmap slipped"),
        ]
        #expect(NoteAttribution.authored(blocks, myNotes: "Q3 roadmap") == [0])
    }

    @Test func emptyOrBlankNotesAuthorNothing() {
        let blocks: [MarkdownBlock] = [.bullet(indent: 0, text: "Anything at all"), .paragraph("More text")]
        #expect(NoteAttribution.authored(blocks, myNotes: "").isEmpty)
        #expect(NoteAttribution.authored(blocks, myNotes: "  \n \n").isEmpty)
    }

    @Test func everyNoteLineCounts() {
        let blocks: [MarkdownBlock] = [
            .bullet(indent: 0, text: "Noted: an unrelated thing came up here today"),
            .bullet(indent: 0, text: "Follow up with Sara on the contract terms"),
        ]
        let authored = NoteAttribution.authored(blocks, myNotes: "Unrelated thing here\nFollow up with Sara on contract terms")
        #expect(authored == [0, 1])
    }

    @Test func caseAndMarkdownMarkupDoNotMatter() {
        let blocks: [MarkdownBlock] = [
            .bullet(indent: 0, text: "ship THE beta build for [Example](https://example.com)"),
            .task(indent: 0, done: false, text: "Ship it"),
        ]
        let authored = NoteAttribution.authored(blocks, myNotes: "**Ship** the [beta](https://example.com) build")
        #expect(authored == [0])
    }
}

// MARK: - 2. Meeting links

struct MeetingLinkTests {
    @Test func linkRoundTripsThroughMeetingID() throws {
        let link = MeetingChat.link(fixedID)
        #expect(link == "hushpad://meeting/6F1C2B3A-1111-4A2B-9C3D-0123456789AB")
        let url = try #require(URL(string: link))
        #expect(MeetingChat.meetingID(from: url) == fixedID)
    }

    @Test func linksFromBeforeTheRenameStillOpen() throws {
        let url = try #require(URL(string: "localscribe://meeting/\(fixedID.uuidString)"))
        #expect(MeetingChat.meetingID(from: url) == fixedID)
    }

    @Test func meetingIDRejectsOtherSchemesHostsAndIDs() throws {
        #expect(MeetingChat.meetingID(from: try #require(URL(string: "https://meeting/\(fixedID.uuidString)"))) == nil)
        #expect(MeetingChat.meetingID(from: try #require(URL(string: "hushpad://note/\(fixedID.uuidString)"))) == nil)
        #expect(MeetingChat.meetingID(from: try #require(URL(string: "hushpad://meeting/not-a-uuid"))) == nil)
        #expect(MeetingChat.meetingID(from: try #require(URL(string: "mailto:someone@example.com"))) == nil)
    }
}

// MARK: - 3. Context building

struct MeetingChatContextTests {
    @Test func notesAreIncluded() {
        let meeting = MeetingChat.Meeting(
            id: fixedID, title: "Weekly sync", date: fixedNow,
            myNotes: "Ask about the Q3 numbers", enhancedNotes: "- Hiring is on track")
        let context = MeetingChat.context(meeting, budget: 10_000)
        #expect(context.contains("# Weekly sync"))
        #expect(context.contains("## My notes\nAsk about the Q3 numbers"))
        #expect(context.contains("## Meeting notes\n- Hiring is on track"))
    }

    @Test func neverExceedsTheBudget() {
        let meeting = MeetingChat.Meeting(
            id: fixedID, title: "Long one", date: fixedNow,
            myNotes: "Some notes", transcript: longTranscript())
        for budget in [0, 10, 100, 500, 1_500] {
            #expect(MeetingChat.context(meeting, budget: budget).count <= budget)
        }
    }

    @Test func liveMeetingKeepsTheEndOfTheTranscript() {
        let meeting = MeetingChat.Meeting(id: fixedID, title: "Live", date: fixedNow, transcript: longTranscript())
        let context = MeetingChat.context(meeting, budget: 1_500, live: true)
        #expect(context.contains("closing-remark-final"))
        #expect(!context.contains("opening-remark-zero"))
    }

    @Test func finishedMeetingKeepsStartAndEndWithMarker() {
        let meeting = MeetingChat.Meeting(id: fixedID, title: "Done", date: fixedNow, transcript: longTranscript())
        let context = MeetingChat.context(meeting, budget: 1_500, live: false)
        #expect(context.contains("opening-remark-zero"))
        #expect(context.contains("closing-remark-final"))
        #expect(context.contains("[…]"))
    }
}

// MARK: - 4. Ranking

struct MeetingChatRankTests {
    @Test func keywordMatchesRankAboveNonMatches() {
        let budget = MeetingChat.Candidate(id: fixedID, date: fixedNow, text: "budget review with sara")
        let lunch = MeetingChat.Candidate(id: otherID, date: fixedNow, text: "team lunch plans")
        let ranked = MeetingChat.rank([lunch, budget], question: "What did Sara say about the budget?",
                                      now: fixedNow, calendar: utc)
        #expect(ranked.first == fixedID)
        #expect(ranked.count == 2)
    }

    @Test func thisWeekFavoursMeetingsInsideTheWeek() {
        let inWeek = MeetingChat.Candidate(id: fixedID, date: utcDate(2026, 10, 13, hour: 9), text: "roadmap decision")
        let longAgo = MeetingChat.Candidate(id: otherID, date: utcDate(2026, 6, 10), text: "roadmap decision")
        let ranked = MeetingChat.rank([longAgo, inWeek], question: "What did we decide this week about the roadmap?",
                                      now: fixedNow, calendar: utc)
        #expect(ranked == [fixedID, otherID])
    }

    @Test func limitIsRespected() {
        let candidates = (0..<10).map { index in
            MeetingChat.Candidate(id: UUID(), date: fixedNow.addingTimeInterval(TimeInterval(-index * 86_400)),
                                  text: "roadmap budget")
        }
        let ranked = MeetingChat.rank(candidates, question: "roadmap budget", limit: 3, now: fixedNow, calendar: utc)
        #expect(ranked.count == 3)
    }
}

// MARK: - 5. Conversation

struct MeetingChatMessagesTests {
    @Test func buildsSystemContextHistoryAndQuestionInOrder() {
        let history: [ChatMessage] = [
            .user("Who owns the deck?"),
            ChatMessage(role: "assistant", content: "Sara owns it."),
        ]
        let messages = MeetingChat.messages(system: "SYSTEM RULES", context: "MEETING-BODY",
                                            history: history, question: "And by when?")
        #expect(messages.count == history.count + 2)
        #expect(messages.first?.role == "system")
        #expect(messages.first?.content.hasPrefix("SYSTEM RULES") == true)
        #expect(messages.first?.content.contains("<meetings>\nMEETING-BODY\n</meetings>") == true)
        #expect(Array(messages[1..<(messages.count - 1)]) == history)
        #expect(messages.last == .user("And by when?"))
    }
}

// MARK: - 6. Live captions

@MainActor
struct LiveTranscriptTests {
    @Test func nonFinalLineIsPending() {
        let live = LiveTranscript()
        live.apply(LiveLine(source: .microphone, start: 1, end: 2, text: "hello wor", isFinal: false))
        #expect(live.pending[.microphone]?.text == "hello wor")
        #expect(live.finals.isEmpty)
    }

    @Test func finalLineClearsPendingAndIsAppended() {
        let live = LiveTranscript()
        live.apply(LiveLine(source: .microphone, start: 1, end: 2, text: "hello wor", isFinal: false))
        live.apply(LiveLine(source: .microphone, start: 1, end: 3, text: "hello world", isFinal: true))
        #expect(live.pending[.microphone] == nil)
        #expect(live.finals.map(\.text) == ["hello world"])
    }

    @Test func finalsStaySortedByStartWhenLinesArriveOutOfOrder() {
        let live = LiveTranscript()
        live.apply(LiveLine(source: .call, start: 5, end: 6, text: "five", isFinal: true))
        live.apply(LiveLine(source: .microphone, start: 2, end: 3, text: "two", isFinal: true))
        live.apply(LiveLine(source: .call, start: 9, end: 10, text: "nine", isFinal: true))
        #expect(live.finals.map(\.start) == [2, 5, 9])
    }

    @Test func emptyFinalTextIsIgnoredButClearsPending() {
        let live = LiveTranscript()
        live.apply(LiveLine(source: .call, start: 1, end: 2, text: "partial", isFinal: false))
        live.apply(LiveLine(source: .call, start: 1, end: 2, text: "", isFinal: true))
        #expect(live.finals.isEmpty)
        #expect(live.pending[.call] == nil)
    }

    @Test func transcriptIsNilWithoutFinals() {
        let live = LiveTranscript()
        #expect(live.transcript(language: .english) == nil)
        live.apply(LiveLine(source: .microphone, start: 0, end: 1, text: "still talking", isFinal: false))
        #expect(live.transcript(language: .english) == nil)
    }

    @Test func transcriptLabelsSpeakersAndMarksItselfLive() throws {
        let live = LiveTranscript()
        live.apply(LiveLine(source: .microphone, start: 0, end: 2, text: "Hi there", isFinal: true))
        live.apply(LiveLine(source: .call, start: 3, end: 5, text: "Hello back", isFinal: true))

        let transcript = try #require(live.transcript(language: .english))
        #expect(transcript.engine == LiveTranscriber.engineID)
        #expect(transcript.isLive)
        #expect(transcript.speakers.map(\.name) == ["You", "Them"])
        #expect(transcript.utterances.map(\.text) == ["Hi there", "Hello back"])
        #expect(transcript.utterances.map { transcript.speakerName(for: $0.speaker) } == ["You", "Them"])
    }

    @Test func fullTranscriptIsNotLive() {
        let transcript = Transcript(language: .english, speakers: [], utterances: [], engine: "whisperkit:tiny")
        #expect(!transcript.isLive)
    }
}

// MARK: - 7. Recipes

struct RecipeBuiltInTests {
    @Test func builtInIDsAreUnique() {
        let ids = Recipe.builtIn.map(\.id)
        #expect(!ids.isEmpty)
        #expect(Set(ids).count == ids.count)
    }

    @Test func everyBuiltInRecipeHasAPrompt() {
        for recipe in Recipe.builtIn {
            #expect(!recipe.prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, "Recipe \(recipe.id) has no prompt")
        }
    }
}
