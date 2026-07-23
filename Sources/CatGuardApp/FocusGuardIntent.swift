import AppIntents
import Foundation

struct FocusGuardIntent: SetFocusFilterIntent {
    static let title: LocalizedStringResource = "CatGuard"
    static let description = IntentDescription(
        "Blocks accidental physical keyboard and pointer input while this Focus is active."
    )
    static let openAppWhenRun = false

    // macOS may instantiate `current` with parameter defaults when no Focus
    // action exists, so the default must be fail-open. A configured filter
    // explicitly stores `true` when the user enables this toggle.
    @Parameter(title: "Guard against cat input", default: false)
    var isEnabled: Bool

    var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(
            title: isEnabled ? "Guard against cat input" : "Leave input active",
            subtitle: "Blocks physical keyboard and pointer input"
        )
    }

    static var parameterSummary: some ParameterSummary {
        Summary("Set CatGuard to \(\.$isEnabled)")
    }

    func perform() async throws -> some IntentResult {
        return .result()
    }
}
