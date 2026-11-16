import Foundation

enum InputProtectionError: LocalizedError {
    case inputMonitoringDenied
    case accessibilityDenied
    case eventTapCreationFailed
    case eventTapUnavailable

    var errorDescription: String? {
        switch self {
        case .inputMonitoringDenied:
            "Input Monitoring permission was not granted."
        case .accessibilityDenied:
            "Accessibility permission was not granted."
        case .eventTapUnavailable:
            "The physical-input event tap stopped working. CatGuard is leaving input active and will retry."
        case .eventTapCreationFailed:
            "macOS would not create the physical-input event tap."
        }
    }
}

/// The platform adapter supplies non-prompting probes. Re-enable only with both
/// permissions and a valid port; a failed re-enable must become visibly unavailable.
enum EventTapHealthCheck {
    static func validate(listenAccess: Bool, postAccess: Bool, portValid: Bool,
                         isEnabled: () -> Bool, enable: () -> Void) throws {
        guard listenAccess else { throw InputProtectionError.inputMonitoringDenied }
        guard postAccess else { throw InputProtectionError.accessibilityDenied }
        guard portValid else { throw InputProtectionError.eventTapUnavailable }
        if !isEnabled() { enable() }
        guard isEnabled() else { throw InputProtectionError.eventTapUnavailable }
    }
}
