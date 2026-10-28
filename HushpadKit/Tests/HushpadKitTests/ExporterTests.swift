import Foundation
import Testing
@testable import HushpadCore
@testable import HushpadKit

@Suite struct ExporterTests {
    let transcript = Transcript(
        language: .german,
        speakers: [Speaker(key: "R1", name: "Me"), Speaker(key: "S1", name: "Remote 1")],
        utterances: [
            Utterance(speaker: "S1", start: 1.5, end: 3.25, text: "Hallo zusammen."),
            Utterance(speaker: "R1", start: 3754.0, end: 3755.5, text: "Danke."),
        ],
        engine: "whisperkit:test"
    )

    @Test func plainText() {
        #expect(Exporter.render(transcript, title: "Standup", as: .text) ==
            "[00:01] Remote 1: Hallo zusammen.\n[1:02:34] Me: Danke.\n")
    }

    @Test func subtitles() {
        let srt = Exporter.render(transcript, title: "Standup", as: .subtitles)
        #expect(srt.hasPrefix("1\n00:00:01,500 --> 00:00:03,250\nRemote 1: Hallo zusammen.\n"))
        #expect(srt.contains("2\n01:02:34,000 --> 01:02:35,500\nMe: Danke.\n"))
    }

    @Test func renamedSpeakerAppearsInExport() {
        var copy = transcript
        copy.renameSpeaker("S1", to: "Anna")
        #expect(Exporter.render(copy, title: "x", as: .markdown).contains("**Anna** _00:01_"))
    }
}

@Suite struct DefaultSpeakerNameTests {
    @Test func loneRoomVoiceOnCallIsMe() {
        let speakers = TranscriptPipeline.speakers(
            room: [Utterance(speaker: "R1", start: 0, end: 1, text: "a")],
            remote: [Utterance(speaker: "S1", start: 1, end: 2, text: "b"), Utterance(speaker: "S2", start: 2, end: 3, text: "c")])
        #expect(speakers.map(\.name) == ["Me", "Remote 1", "Remote 2"])
    }

    @Test func inPersonMeetingUsesNumberedSpeakers() {
        let speakers = TranscriptPipeline.speakers(
            room: [Utterance(speaker: "R1", start: 0, end: 1, text: "a"), Utterance(speaker: "R2", start: 1, end: 2, text: "b")],
            remote: [])
        #expect(speakers.map(\.name) == ["Speaker 1", "Speaker 2"])
    }
}
