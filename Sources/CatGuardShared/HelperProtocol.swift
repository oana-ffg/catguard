import Foundation

enum CatGuardHelperConstants {
    static let machServiceName = "com.oanaffg.CatGuard.Helper"

    static var appCodeSigningRequirement: String {
        requirement(named: "CatGuardAppCodeSigningRequirement")
    }

    static var helperCodeSigningRequirement: String {
        requirement(named: "CatGuardHelperCodeSigningRequirement")
    }

    private static func requirement(named key: String) -> String {
        guard
            let value = Bundle.main.object(forInfoDictionaryKey: key) as? String,
            !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else {
            fatalError("Missing code-signing requirement in Info.plist: \(key)")
        }
        return value
    }
}

@objc protocol CatGuardHelperProtocol {
    func arm(
        rescuePhrase: String,
        reply: @escaping (Bool, String?) -> Void
    )

    func disarm(reply: @escaping (_ blockedKeyboardInputs: Int) -> Void)

    func heartbeat(
        reply:
            @escaping (
                _ isGuarded: Bool,
                _ blockedKeyboardInputs: Int,
                _ rescuePhraseTriggered: Bool,
                _ errorMessage: String?
            ) -> Void
    )
}
