import Darwin
import Foundation

private final class ArmReply: @unchecked Sendable {
    let call: (Bool, String?) -> Void
    init(_ call: @escaping (Bool, String?) -> Void) { self.call = call }
}

private final class DisarmReply: @unchecked Sendable {
    let call: (Int) -> Void
    init(_ call: @escaping (Int) -> Void) { self.call = call }
}

private final class HeartbeatReply: @unchecked Sendable {
    let call: (Bool, Int, Bool, String?) -> Void
    init(_ call: @escaping (Bool, Int, Bool, String?) -> Void) { self.call = call }
}

final class HelperService: NSObject, CatGuardHelperProtocol, @unchecked Sendable {
    private let queue = DispatchQueue(label: "com.oanaffg.CatGuard.Helper.state")
    private let keyboard: KeyboardDeviceController
    private var lastHeartbeat = Date.distantPast
    private var rescuePhraseTriggered = false
    private var latestError: String?
    private var watchdog: DispatchSourceTimer?

    override init() {
        keyboard = KeyboardDeviceController(queue: queue)
        super.init()
        keyboard.onRescuePhrase = { [weak self] in
            guard let self else { return }
            keyboard.disarm()
            rescuePhraseTriggered = true
        }
        startWatchdog()
    }

    func arm(rescuePhrase: String, reply: @escaping (Bool, String?) -> Void) {
        let reply = ArmReply(reply)
        queue.async { [self] in
            do {
                try keyboard.arm(rescuePhrase: rescuePhrase)
                lastHeartbeat = Date()
                rescuePhraseTriggered = false
                latestError = nil
                reply.call(true, nil)
            } catch {
                latestError = error.localizedDescription
                keyboard.disarm()
                reply.call(false, latestError)
                if let keyboardError = error as? KeyboardDeviceController.Error,
                    keyboardError.requiresFreshProcessForInputMonitoring
                {
                    queue.asyncAfter(deadline: .now() + 0.25) {
                        exit(EXIT_SUCCESS)
                    }
                }
            }
        }
    }

    func disarm(reply: @escaping (Int) -> Void) {
        let reply = DisarmReply(reply)
        queue.async { [self] in
            let blockedInputCount = keyboard.drainBlockedInputCount()
            keyboard.disarm()
            rescuePhraseTriggered = false
            latestError = nil
            reply.call(blockedInputCount)
        }
    }

    func heartbeat(
        reply: @escaping (Bool, Int, Bool, String?) -> Void
    ) {
        let reply = HeartbeatReply(reply)
        queue.async { [self] in
            lastHeartbeat = Date()
            let didTriggerRescue = rescuePhraseTriggered
            rescuePhraseTriggered = false
            reply.call(
                keyboard.isGuarded,
                keyboard.drainBlockedInputCount(),
                didTriggerRescue,
                latestError
            )
        }
    }

    private func startWatchdog() {
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + 1, repeating: 1)
        timer.setEventHandler { [weak self] in
            guard let self,
                keyboard.isGuarded,
                Date().timeIntervalSince(lastHeartbeat) > 3
            else { return }
            keyboard.disarm()
            latestError = "App heartbeat stopped; keyboard input was restored."
        }
        timer.resume()
        watchdog = timer
    }
}
