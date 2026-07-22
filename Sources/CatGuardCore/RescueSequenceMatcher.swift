import Foundation

public struct RescueSequenceMatcher: Sendable {
    private let expectedCharacters: [Character]
    private let maximumGap: TimeInterval
    private var matchedCharacterCount = 0
    private var lastCharacterAt: Date?

    public init(sequence: String = "rescue", maximumGap: TimeInterval = 2) {
        precondition(!sequence.isEmpty)
        precondition(maximumGap > 0)

        self.expectedCharacters = Array(sequence.lowercased())
        self.maximumGap = maximumGap
    }

    public mutating func observe(
        _ character: Character,
        at timestamp: Date = Date()
    ) -> Bool {
        let normalizedCharacters = Array(String(character).lowercased())
        guard normalizedCharacters.count == 1, let normalized = normalizedCharacters.first else {
            reset()
            return false
        }

        if let lastCharacterAt,
            timestamp.timeIntervalSince(lastCharacterAt) > maximumGap
        {
            matchedCharacterCount = 0
        }
        lastCharacterAt = timestamp

        if normalized == expectedCharacters[matchedCharacterCount] {
            matchedCharacterCount += 1
        } else {
            matchedCharacterCount = normalized == expectedCharacters[0] ? 1 : 0
        }

        guard matchedCharacterCount == expectedCharacters.count else { return false }
        reset()
        return true
    }

    private mutating func reset() {
        matchedCharacterCount = 0
        lastCharacterAt = nil
    }
}
