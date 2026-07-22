import Foundation

final class HelperListenerDelegate: NSObject, NSXPCListenerDelegate {
    private let service = HelperService()

    func listener(_ listener: NSXPCListener, shouldAcceptNewConnection connection: NSXPCConnection) -> Bool {
        connection.setCodeSigningRequirement(CatGuardHelperConstants.appCodeSigningRequirement)
        connection.exportedInterface = NSXPCInterface(with: CatGuardHelperProtocol.self)
        connection.exportedObject = service
        connection.activate()
        return true
    }
}

let delegate = HelperListenerDelegate()
let listener = NSXPCListener(machServiceName: CatGuardHelperConstants.machServiceName)
listener.delegate = delegate
listener.activate()
RunLoop.main.run()
