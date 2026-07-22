import Foundation

enum BypassTrigger: Equatable {
    case circle
    case rescuePhrase
    case menu

    var label: String {
        switch self {
        case .circle:
            "pointer circle"
        case .rescuePhrase:
            "rescue phrase"
        case .menu:
            "menu command"
        }
    }
}

enum ProtectionState: Equatable {
    case inputActive
    case guarded
    case bypassed(BypassTrigger)
    case unavailable(String)

    var label: String {
        switch self {
        case .inputActive:
            "Input active"
        case .guarded:
            "CatGuard armed"
        case .bypassed(let trigger):
            "Bypassed by \(trigger.label) until 5 minutes idle"
        case .unavailable(let message):
            "Protection unavailable: \(message)"
        }
    }

    var isBypassed: Bool {
        if case .bypassed = self { return true }
        return false
    }
}
