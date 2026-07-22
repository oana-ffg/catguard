import Foundation

enum CatGuardHelperConstants {
    static let machServiceName = "com.oanaffg.CatGuard.Helper"
    static let teamIdentifier = "RY297J6VR2"

    static let appCodeSigningRequirement =
        "anchor apple generic and identifier \"com.oanaffg.CatGuard\" and certificate leaf[subject.OU] = \"\(teamIdentifier)\""
    static let helperCodeSigningRequirement =
        "anchor apple generic and identifier \"com.oanaffg.CatGuard.Helper\" and certificate leaf[subject.OU] = \"\(teamIdentifier)\""
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
