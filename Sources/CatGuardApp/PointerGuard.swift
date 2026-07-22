import CoreGraphics
import Foundation

final class PointerGuard: @unchecked Sendable {
    enum StartError: LocalizedError {
        case inputMonitoringDenied
        case eventTapCreationFailed

        var errorDescription: String? {
            switch self {
            case .inputMonitoringDenied:
                "Input Monitoring permission was not granted."
            case .eventTapCreationFailed:
                "macOS would not create the physical-input event tap."
            }
        }
    }

    struct Callbacks: Sendable {
        let onBlockedClick: @Sendable () -> Void
        let onCircle: @Sendable () -> Void
        let onBypassActivity: @Sendable () -> Void
    }

    private struct State {
        var isGuarded = false
        var isBypassed = false
        var circleEnabled = true
        var circleDetector = PointerCircleDetector()
        var circleCallbackPending = false
        var lastActivityCallbackAt: TimeInterval = 0
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

        let eventTypes: [CGEventType] = [
            .leftMouseDown, .leftMouseUp,
            .rightMouseDown, .rightMouseUp,
            .otherMouseDown, .otherMouseUp,
            .mouseMoved,
            .leftMouseDragged, .rightMouseDragged, .otherMouseDragged,
            .scrollWheel,
            .keyDown,
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
                callback: pointerEventTapCallback,
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

    func setGuarded(_ isGuarded: Bool, circleEnabled: Bool) {
        lock.withLock {
            state.isGuarded = isGuarded
            state.isBypassed = false
            state.circleEnabled = circleEnabled
            state.circleDetector = PointerCircleDetector()
            state.circleCallbackPending = false
        }
    }

    func setBypassed() {
        lock.withLock {
            state.isGuarded = false
            state.isBypassed = true
            state.circleDetector = PointerCircleDetector()
            state.circleCallbackPending = false
            state.lastActivityCallbackAt = 0
        }
    }

    func setInactive() {
        lock.withLock {
            state = State(circleEnabled: state.circleEnabled)
        }
    }

    fileprivate func handle(type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let eventTap {
                CGEvent.tapEnable(tap: eventTap, enable: true)
            }
            return Unmanaged.passUnretained(event)
        }

        let sourcePID = event.getIntegerValueField(.eventSourceUnixProcessID)
        guard sourcePID == 0 else {
            return Unmanaged.passUnretained(event)
        }

        enum Action {
            case pass
            case suppress
            case blockedClick
            case circle
            case bypassActivity
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
            case .leftMouseDown, .rightMouseDown, .otherMouseDown:
                return .blockedClick
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
        case .blockedClick:
            callbacks.onBlockedClick()
            return nil
        case .circle:
            callbacks.onCircle()
            return Unmanaged.passUnretained(event)
        case .bypassActivity:
            callbacks.onBypassActivity()
            return Unmanaged.passUnretained(event)
        }
    }
}

private func pointerEventTapCallback(
    proxy: CGEventTapProxy,
    type: CGEventType,
    event: CGEvent,
    userInfo: UnsafeMutableRawPointer?
) -> Unmanaged<CGEvent>? {
    guard let userInfo else { return Unmanaged.passUnretained(event) }
    return Unmanaged<PointerGuard>.fromOpaque(userInfo).takeUnretainedValue().handle(
        type: type,
        event: event
    )
}
