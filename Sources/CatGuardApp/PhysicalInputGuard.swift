import CoreGraphics
import Foundation

/// Suppresses physical keyboard actions and actionable pointer events while
/// allowing synthetic events from trusted Computer Use automation to pass.
final class PhysicalInputGuard: @unchecked Sendable {
    enum StartError: LocalizedError {
        case inputMonitoringDenied
        case accessibilityDenied
        case eventTapCreationFailed

        var errorDescription: String? {
            switch self {
            case .inputMonitoringDenied:
                "Input Monitoring permission was not granted."
            case .accessibilityDenied:
                "Accessibility permission was not granted."
            case .eventTapCreationFailed:
                "macOS would not create the physical-input event tap."
            }
        }
    }

    struct Callbacks: Sendable {
        let onBlockedKeyboardInput: @Sendable () -> Void
        let onBlockedPointerClick: @Sendable () -> Void
        let onCircle: @Sendable () -> Void
        let onRescuePhrase: @Sendable () -> Void
        let onBypassActivity: @Sendable () -> Void
    }

    private struct State {
        var isGuarded = false
        var isBypassed = false
        var circleEnabled = true
        var circleDetector = PointerCircleDetector()
        var circleCallbackPending = false
        var rescueMatcher = RescueSequenceMatcher(sequence: "catguard")
        var rescueCallbackPending = false
        var lastActivityCallbackAt: TimeInterval = 0
    }

    private enum Action {
        case pass
        case suppress
        case blockedKeyboardInput
        case blockedPointerClick
        case circle
        case rescuePhrase
        case bypassActivity
    }

    private let callbacks: Callbacks
    private let lock = NSLock()
    private var state = State()
    private var eventTap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?

    init(callbacks: Callbacks) {
        self.callbacks = callbacks
    }

    func start() throws {
        guard eventTap == nil else { return }
        guard CGPreflightListenEventAccess() || CGRequestListenEventAccess() else {
            throw StartError.inputMonitoringDenied
        }
        guard CGPreflightPostEventAccess() || CGRequestPostEventAccess() else {
            throw StartError.accessibilityDenied
        }

        let eventTypes: [CGEventType] = [
            .leftMouseDown, .leftMouseUp,
            .rightMouseDown, .rightMouseUp,
            .otherMouseDown, .otherMouseUp,
            .mouseMoved,
            .leftMouseDragged, .rightMouseDragged, .otherMouseDragged,
            .scrollWheel,
            .keyDown, .keyUp, .flagsChanged,
        ]
        let mask = eventTypes.reduce(CGEventMask(0)) { partial, type in
            partial | (CGEventMask(1) << type.rawValue)
        }

        guard
            let tap = CGEvent.tapCreate(
                tap: .cghidEventTap,
                place: .headInsertEventTap,
                options: .defaultTap,
                eventsOfInterest: mask,
                callback: physicalInputEventTapCallback,
                userInfo: Unmanaged.passUnretained(self).toOpaque()
            )
        else {
            throw StartError.eventTapCreationFailed
        }

        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        eventTap = tap
        runLoopSource = source
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
    }

    func setGuarded(circleEnabled: Bool, rescuePhrase: String) {
        lock.withLock {
            state.isGuarded = true
            state.isBypassed = false
            state.circleEnabled = circleEnabled
            state.circleDetector = PointerCircleDetector()
            state.circleCallbackPending = false
            state.rescueMatcher = RescueSequenceMatcher(sequence: rescuePhrase)
            state.rescueCallbackPending = false
        }
    }

    func setBypassed() {
        lock.withLock {
            state.isGuarded = false
            state.isBypassed = true
            state.circleDetector = PointerCircleDetector()
            state.circleCallbackPending = false
            state.rescueCallbackPending = false
            state.lastActivityCallbackAt = 0
        }
    }

    func setInactive() {
        lock.withLock {
            state.isGuarded = false
            state.isBypassed = false
            state.circleDetector = PointerCircleDetector()
            state.circleCallbackPending = false
            state.rescueCallbackPending = false
            state.lastActivityCallbackAt = 0
        }
    }

    fileprivate func handle(type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let eventTap {
                CGEvent.tapEnable(tap: eventTap, enable: true)
            }
            return Unmanaged.passUnretained(event)
        }

        // Physical HID events have consistently reported PID 0 in the hardware
        // experiments. Computer Use events carry their originating process PID.
        guard event.getIntegerValueField(.eventSourceUnixProcessID) == 0 else {
            return Unmanaged.passUnretained(event)
        }

        let now = ProcessInfo.processInfo.systemUptime
        let action: Action = lock.withLock {
            if state.isBypassed {
                let shouldNotifyImmediately = type != .mouseMoved
                if shouldNotifyImmediately || now - state.lastActivityCallbackAt >= 0.25 {
                    state.lastActivityCallbackAt = now
                    return .bypassActivity
                }
                return .pass
            }

            guard state.isGuarded else { return .pass }

            if type == .mouseMoved, state.circleEnabled, !state.circleCallbackPending {
                let didDetectCircle = state.circleDetector.observe(
                    deltaX: Double(event.getIntegerValueField(.mouseEventDeltaX)),
                    deltaY: Double(event.getIntegerValueField(.mouseEventDeltaY)),
                    at: now
                )
                if didDetectCircle {
                    state.circleCallbackPending = true
                    return .circle
                }
            }

            switch type {
            case .keyDown:
                if !state.rescueCallbackPending,
                    let letter = PhysicalKeyLetterMap.letter(
                        forMacVirtualKeyCode: event.getIntegerValueField(.keyboardEventKeycode)
                    ),
                    state.rescueMatcher.observe(letter)
                {
                    state.rescueCallbackPending = true
                    return .rescuePhrase
                }
                return .blockedKeyboardInput
            case .keyUp, .flagsChanged:
                return .suppress
            case .leftMouseDown, .rightMouseDown, .otherMouseDown:
                return .blockedPointerClick
            case .leftMouseUp, .rightMouseUp, .otherMouseUp,
                .leftMouseDragged, .rightMouseDragged, .otherMouseDragged,
                .scrollWheel:
                return .suppress
            default:
                return .pass
            }
        }

        switch action {
        case .pass:
            return Unmanaged.passUnretained(event)
        case .suppress:
            return nil
        case .blockedKeyboardInput:
            callbacks.onBlockedKeyboardInput()
            return nil
        case .blockedPointerClick:
            callbacks.onBlockedPointerClick()
            return nil
        case .circle:
            callbacks.onCircle()
            return Unmanaged.passUnretained(event)
        case .rescuePhrase:
            callbacks.onBlockedKeyboardInput()
            callbacks.onRescuePhrase()
            return nil
        case .bypassActivity:
            callbacks.onBypassActivity()
            return Unmanaged.passUnretained(event)
        }
    }
}

private func physicalInputEventTapCallback(
    proxy: CGEventTapProxy,
    type: CGEventType,
    event: CGEvent,
    userInfo: UnsafeMutableRawPointer?
) -> Unmanaged<CGEvent>? {
    guard let userInfo else { return Unmanaged.passUnretained(event) }
    return Unmanaged<PhysicalInputGuard>.fromOpaque(userInfo).takeUnretainedValue().handle(
        type: type,
        event: event
    )
}
