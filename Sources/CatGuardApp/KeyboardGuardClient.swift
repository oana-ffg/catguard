import Foundation
import Security
import ServiceManagement

private final class ContinuationBox<Value: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Value, any Swift.Error>?

    init(_ continuation: CheckedContinuation<Value, any Swift.Error>) {
        self.continuation = continuation
    }

    func resume(returning value: Value) {
        lock.withLock {
            continuation?.resume(returning: value)
            continuation = nil
        }
    }

    func resume(throwing error: any Swift.Error) {
        lock.withLock {
            continuation?.resume(throwing: error)
            continuation = nil
        }
    }
}

@MainActor
final class KeyboardGuardClient {
    struct Heartbeat: Sendable {
        let isGuarded: Bool
        let blockedKeyboardInputs: Int
        let rescuePhraseTriggered: Bool
        let errorMessage: String?
    }

    enum Error: LocalizedError {
        case connectionFailed(String)
        case helperRejectedArm(String)
        case authorizationFailed(OSStatus)
        case installationFailed(String)

        var errorDescription: String? {
            switch self {
            case .connectionFailed(let message):
                "Keyboard helper unavailable: \(message)"
            case .helperRejectedArm(let message):
                message
            case .authorizationFailed(let status):
                "Administrator authorization failed (OSStatus \(status))."
            case .installationFailed(let message):
                "Keyboard helper installation failed: \(message)"
            }
        }
    }

    private var connection: NSXPCConnection?

    func start() {
        connect()
    }

    func install() throws {
        var authorization: AuthorizationRef?
        let createStatus = AuthorizationCreate(nil, nil, [], &authorization)
        guard createStatus == errAuthorizationSuccess, let authorization else {
            throw Error.authorizationFailed(createStatus)
        }
        defer { AuthorizationFree(authorization, []) }

        let copyStatus = kSMRightBlessPrivilegedHelper.withCString { rightName in
            var item = AuthorizationItem(
                name: rightName,
                valueLength: 0,
                value: nil,
                flags: 0
            )
            return withUnsafeMutablePointer(to: &item) { itemPointer in
                var rights = AuthorizationRights(count: 1, items: itemPointer)
                return AuthorizationCopyRights(
                    authorization,
                    &rights,
                    nil,
                    [.interactionAllowed, .extendRights, .preAuthorize],
                    nil
                )
            }
        }
        guard copyStatus == errAuthorizationSuccess else {
            throw Error.authorizationFailed(copyStatus)
        }

        var unmanagedError: Unmanaged<CFError>?
        let installed = SMJobBless(
            kSMDomainSystemLaunchd,
            CatGuardHelperConstants.machServiceName as CFString,
            authorization,
            &unmanagedError
        )
        guard installed else {
            let message =
                unmanagedError?
                .takeRetainedValue()
                .localizedDescription ?? "SMJobBless returned no error details."
            throw Error.installationFailed(message)
        }

        reconnect()
    }

    func arm(rescuePhrase: String) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Swift.Error>) in
            let box = ContinuationBox(continuation)
            scheduleTimeout(for: box, operation: "arming")
            guard
                let proxy = remoteProxy(onError: { error in
                    box.resume(throwing: Error.connectionFailed(error.localizedDescription))
                })
            else {
                box.resume(throwing: Error.connectionFailed("Could not create an authenticated XPC proxy."))
                return
            }
            proxy.arm(rescuePhrase: rescuePhrase) { succeeded, message in
                if succeeded {
                    box.resume(returning: ())
                } else {
                    box.resume(
                        throwing: Error.helperRejectedArm(message ?? "The helper could not guard the keyboard.")
                    )
                }
            }
        }
    }

    func disarm() async -> Int {
        (try? await withCheckedThrowingContinuation { continuation in
            let box = ContinuationBox(continuation)
            scheduleTimeout(for: box, operation: "disarming")
            guard
                let proxy = remoteProxy(onError: { error in
                    box.resume(throwing: Error.connectionFailed(error.localizedDescription))
                })
            else {
                box.resume(throwing: Error.connectionFailed("Could not create an authenticated XPC proxy."))
                return
            }
            proxy.disarm { blockedKeyboardInputs in
                box.resume(returning: blockedKeyboardInputs)
            }
        }) ?? 0
    }

    func heartbeat() async throws -> Heartbeat {
        return try await withCheckedThrowingContinuation { continuation in
            let box = ContinuationBox(continuation)
            scheduleTimeout(for: box, operation: "checking status")
            guard
                let proxy = remoteProxy(onError: { error in
                    box.resume(throwing: Error.connectionFailed(error.localizedDescription))
                })
            else {
                box.resume(throwing: Error.connectionFailed("Could not create an authenticated XPC proxy."))
                return
            }
            proxy.heartbeat { isGuarded, count, rescueTriggered, errorMessage in
                box.resume(
                    returning: Heartbeat(
                        isGuarded: isGuarded,
                        blockedKeyboardInputs: count,
                        rescuePhraseTriggered: rescueTriggered,
                        errorMessage: errorMessage
                    )
                )
            }
        }
    }

    func stop() async {
        _ = await disarm()
        connection?.invalidate()
        self.connection = nil
    }

    private func scheduleTimeout<Value: Sendable>(
        for box: ContinuationBox<Value>,
        operation: String
    ) {
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 3) {
            box.resume(
                throwing: Error.connectionFailed("Timed out while \(operation) the helper.")
            )
        }
    }

    private func remoteProxy(
        onError: @escaping @Sendable (any Swift.Error) -> Void
    ) -> CatGuardHelperProtocol? {
        if connection == nil {
            connect()
        }
        return connection?.remoteObjectProxyWithErrorHandler(onError) as? CatGuardHelperProtocol
    }

    private func reconnect() {
        connection?.invalidate()
        connection = nil
        connect()
    }

    private func connect() {
        let connection = NSXPCConnection(
            machServiceName: CatGuardHelperConstants.machServiceName,
            options: .privileged
        )
        connection.setCodeSigningRequirement(CatGuardHelperConstants.helperCodeSigningRequirement)
        connection.remoteObjectInterface = NSXPCInterface(with: CatGuardHelperProtocol.self)
        connection.invalidationHandler = { [weak self, weak connection] in
            Task { @MainActor in
                guard self?.connection === connection else { return }
                self?.connection = nil
            }
        }
        connection.activate()
        self.connection = connection
    }
}
