import Testing
@testable import HushpadKit

@Suite struct CallEndTests {
    @Test func goodbyesAtTheEndCount() {
        #expect(CallEnd.saidGoodbye("so that's the plan. Great, thanks everyone, see you next week. Bye!"))
        #expect(CallEnd.saidGoodbye("Okay, take care."))
        #expect(CallEnd.saidGoodbye("Super, dann bis bald. Tschüss!"))
    }

    @Test func ordinaryTalkDoesNot() {
        #expect(!CallEnd.saidGoodbye("let me share my screen, can you see the roadmap?"))
        #expect(!CallEnd.saidGoodbye("the bypass road and the byelaws"))  // "bye" only as a whole word
        #expect(!CallEnd.saidGoodbye(""))
    }

    @Test func onlyTheLastHundredWordsMatter() {
        let early = "bye " + Array(repeating: "roadmap", count: 120).joined(separator: " ")
        #expect(!CallEnd.saidGoodbye(early))
    }
}
