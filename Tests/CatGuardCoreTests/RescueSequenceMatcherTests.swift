import Foundation
import Testing

@testable import CatGuardCore

@Test func rescueSequenceMatchesCaseInsensitively() {
    var matcher = RescueSequenceMatcher(sequence: "rescue")
    let start = Date(timeIntervalSinceReferenceDate: 1_000)

    let results = Array("ReScUe").enumerated().map { index, character in
        matcher.observe(character, at: start.addingTimeInterval(Double(index) * 0.1))
    }

    #expect(results == [false, false, false, false, false, true])
}

@Test func wrongInputRequiresTheFullSequenceAgain() {
    var matcher = RescueSequenceMatcher(sequence: "rescue")
    let start = Date(timeIntervalSinceReferenceDate: 2_000)

    for (index, character) in Array("resx").enumerated() {
        let matched = matcher.observe(
            character,
            at: start.addingTimeInterval(Double(index) * 0.1)
        )
        #expect(!matched)
    }

    let results = Array("rescue").enumerated().map { index, character in
        matcher.observe(character, at: start.addingTimeInterval(1 + Double(index) * 0.1))
    }
    #expect(results.last == true)
}

@Test func excessiveGapResetsTheSequence() {
    var matcher = RescueSequenceMatcher(sequence: "rescue", maximumGap: 1)
    let start = Date(timeIntervalSinceReferenceDate: 3_000)

    for (index, character) in Array("res").enumerated() {
        let matched = matcher.observe(
            character,
            at: start.addingTimeInterval(Double(index) * 0.1)
        )
        #expect(!matched)
    }

    for (index, character) in Array("cue").enumerated() {
        let matched = matcher.observe(
            character,
            at: start.addingTimeInterval(2 + Double(index) * 0.1)
        )
        #expect(!matched)
    }
}
