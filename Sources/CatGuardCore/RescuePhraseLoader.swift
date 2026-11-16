import Foundation

/// A read failure or invalid existing value must never become the default phrase.
enum RescuePhraseLoader {
    enum LoadError: LocalizedError {
        case invalidPhrase
        var errorDescription: String? { "The stored rescue phrase is invalid. It has been preserved. Choose and save a valid phrase before arming." }
    }

    static func load(read: () throws -> String?, write: (String) throws -> Void) throws -> RescuePhrase {
        if let stored = try read() {
            guard let phrase = RescuePhrase(stored) else { throw LoadError.invalidPhrase }
            return phrase
        }
        try write(RescuePhrase.default.value)
        return .default
    }
}
