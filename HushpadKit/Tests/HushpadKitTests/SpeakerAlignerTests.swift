import Testing
@testable import HushpadCore
@testable import HushpadKit

private func w(_ text: String, _ start: Double, _ end: Double) -> TimedWord {
    TimedWord(text: text, start: start, end: end)
}

@Suite struct SpeakerAlignerTests {
    @Test func assignsByLargestOverlap() {
        let words = [w(" Hello", 0.0, 0.4), w(" there", 0.9, 1.3)]
        let turns = [SpeakerTurn(speaker: "A", start: 0.0, end: 1.0), SpeakerTurn(speaker: "B", start: 1.0, end: 2.0)]
        // "there" overlaps A by 0.1s and B by 0.3s
        #expect(SpeakerAligner.assign(words: words, turns: turns).map(\.speaker) == ["A", "B"])
    }

    @Test func wordInGapSnapsToNearestTurn() {
        let words = [w(" um", 2.2, 2.4)]
        let turns = [SpeakerTurn(speaker: "A", start: 0, end: 1), SpeakerTurn(speaker: "B", start: 2.6, end: 4)]
        #expect(SpeakerAligner.assign(words: words, turns: turns).map(\.speaker) == ["B"])
    }

    @Test func farWordInheritsPreviousSpeaker() {
        let words = [w(" yes", 0.1, 0.3), w(" right", 10, 10.2)]
        let turns = [SpeakerTurn(speaker: "A", start: 0, end: 1)]
        #expect(SpeakerAligner.assign(words: words, turns: turns).map(\.speaker) == ["A", "A"])
    }

    @Test func noTurnsGivesUnknown() {
        let assigned = SpeakerAligner.assign(words: [w(" hi", 0, 1)], turns: [])
        #expect(assigned.map(\.speaker) == [SpeakerAligner.unknownSpeaker])
    }

    @Test func groupsWordsAndSplitsOnSpeakerChangeAndLongPause() {
        let assigned: [(word: TimedWord, speaker: String)] = [
            (w(" Guten", 0, 0.3), "A"), (w(" Tag", 0.3, 0.6), "A"),
            (w(" Hallo", 0.8, 1.1), "B"),
            (w(" Ja", 5.0, 5.2), "B"),
        ]
        let result = SpeakerAligner.utterances(from: assigned, maxGap: 2.0)
        #expect(result.map(\.text) == ["Guten Tag", "Hallo", "Ja"])
        #expect(result.map(\.speaker) == ["A", "B", "B"])
        #expect(result[0].start == 0 && result[0].end == 0.6)
    }

    @Test func joinKeepsSubwordPiecesTogether() {
        #expect(SpeakerAligner.joinWords([w(" don", 0, 0.1), w("'t", 0.1, 0.2), w(" go", 0.2, 0.3)]) == "don't go")
    }

    @Test func joinsArabicWords() {
        #expect(SpeakerAligner.joinWords([w(" مرحبا", 0, 0.5), w(" بكم", 0.5, 1)]) == "مرحبا بكم")
    }

    @Test func removesEchoRunsButKeepsOwnSpeech() {
        let system = [w(" we", 1.0, 1.2), w(" should", 1.2, 1.5), w(" ship", 1.5, 1.8), w(" it", 1.8, 2.0)]
        let mic = [
            w(" We", 1.1, 1.3), w(" should,", 1.3, 1.6), w(" ship", 1.6, 1.9), w(" it", 1.9, 2.1), // echo
            w(" I", 4.0, 4.1), w(" agree", 4.1, 4.5), // the user talking
        ]
        let kept = SpeakerAligner.removeEcho(micWords: mic, systemWords: system)
        #expect(SpeakerAligner.joinWords(kept) == "I agree")
    }

    @Test func singleCoincidentalMatchIsKept() {
        let system = [w(" okay", 3.0, 3.2)]
        let mic = [w(" so", 2.6, 2.8), w(" okay", 3.0, 3.2), w(" let's", 3.3, 3.5), w(" start", 3.5, 3.8)]
        #expect(SpeakerAligner.removeEcho(micWords: mic, systemWords: system).count == 4)
    }

    @Test func dropsLowConfidenceWordsInSilence() {
        let turns = [SpeakerTurn(speaker: "1", start: 20.17, end: 25.11)]
        let words = [
            TimedWord(text: " year.", start: 24.68, end: 24.92, probability: 1.0),
            TimedWord(text: " you", start: 24.98, end: 25.68, probability: 0.59), // real hallucination from a test run
            TimedWord(text: " ok", start: 25.6, end: 25.8, probability: 0.95), // confident, just past a clipped turn
            TimedWord(text: " Dank.", start: 44.42, end: 45.82, probability: 1.0), // confident but far from any speech
        ]
        #expect(SpeakerAligner.dropNonSpeech(words: words, turns: turns).map(\.text) == [" year.", " ok"])
    }

    @Test func normalizesSpeakerKeysInOrderOfAppearance() {
        let utterances = [
            Utterance(speaker: "7", start: 0, end: 1, text: "a"),
            Utterance(speaker: "2", start: 1, end: 2, text: "b"),
            Utterance(speaker: "7", start: 2, end: 3, text: "c"),
            Utterance(speaker: SpeakerAligner.unknownSpeaker, start: 3, end: 4, text: "d"),
        ]
        #expect(SpeakerAligner.normalizeSpeakerKeys(utterances).map(\.speaker) == ["S1", "S2", "S1", "unknown"])
    }

    @Test func mergeInterleavesTracksByTime() {
        let me = [Utterance(speaker: "me", start: 2, end: 3, text: "b")]
        let others = [Utterance(speaker: "S1", start: 0, end: 1, text: "a"), Utterance(speaker: "S1", start: 4, end: 5, text: "c")]
        #expect(SpeakerAligner.merge([me, others]).map(\.text) == ["a", "b", "c"])
    }
}

struct SilenceTests {
    @Test func silentTrackKeepsOnlyConfidentWords() {
        let words = [TimedWord(text: " Thanks", start: 1, end: 1.4, probability: 0.4),
                     TimedWord(text: " Hello", start: 2, end: 2.4, probability: 0.95)]
        #expect(SpeakerAligner.dropNonSpeech(words: words, turns: []).map(\.text) == [" Hello"])
    }

    @Test func punctuationOnlyUtteranceIsDropped() {
        let assigned = [(word: TimedWord(text: " .", start: 29, end: 29.2), speaker: "unknown")]
        #expect(SpeakerAligner.utterances(from: assigned).isEmpty)
    }
}
