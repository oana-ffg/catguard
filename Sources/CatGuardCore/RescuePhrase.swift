import Foundation

public struct RescuePhrase: Equatable, Sendable {
    public static let `default` = RescuePhrase(validatedValue: "catguard")

    public let value: String

    public init?(_ candidate: String) {
        let normalized = candidate.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        let allowedCharacters = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyz")
        guard (4...32).contains(normalized.count),
            normalized.unicodeScalars.allSatisfy(allowedCharacters.contains)
        else {
            return nil
        }

        value = normalized
    }

    private init(validatedValue: String) {
        value = validatedValue
    }
}
