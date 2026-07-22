import AppIntents
import Foundation

struct FocusGuardIntent: SetFocusFilterIntent {
    static let title: LocalizedStringResource = "CatGuard"
    static let description = IntentDescription(
        "Blocks accidental physical keyboard and pointer input while this Focus is active."
    )
    static let openAppWhenRun = false

    @Parameter(title: "Guard against cat input", default: true)
    var isEnabled: Bool

    var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(
            title: isEnabled ? "Guard against cat input" : "Leave input active",
            subtitle: "Feline accidents only—not human security"
        )
    }

    static var parameterSummary: some ParameterSummary {
        Summary("Set CatGuard to \(\.$isEnabled)")
    }

    func perform() async throws -> some IntentResult {
        return .result()
    }
}
