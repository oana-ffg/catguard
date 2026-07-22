import Foundation

enum ProtectionState: Equatable {
    case inputActive
    case guarded
    case bypassed
    case unavailable(String)

    var label: String {
        switch self {
        case .inputActive:
            "Input active"
        case .guarded:
            "CatGuard armed"
        case .bypassed:
            "Bypassed until 5 minutes idle"
        case .unavailable(let message):
            "Protection unavailable: \(message)"
        }
    }
}
