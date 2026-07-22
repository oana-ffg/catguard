import Foundation
import IOKit.hid
import IOKit.hidsystem

final class KeyboardDeviceController: @unchecked Sendable {
    enum Error: LocalizedError {
        case managerOpenFailed(IOReturn)
        case noExternalKeyboard
        case deviceOpenFailed(product: String, result: IOReturn)

        var requiresFreshProcessForInputMonitoring: Bool {
            switch self {
            case .managerOpenFailed(let result), .deviceOpenFailed(_, let result):
                result == kIOReturnNotPermitted
            case .noExternalKeyboard:
                false
            }
        }

        var errorDescription: String? {
            switch self {
            case .managerOpenFailed(let result):
                if result == kIOReturnNotPermitted {
                    "Input Monitoring is not enabled for the CatGuard keyboard helper."
                } else {
                    "Could not open the HID manager (IOReturn \(result))."
                }
            case .noExternalKeyboard:
                "No external physical keyboard was found."
            case .deviceOpenFailed(let product, let result):
                if result == kIOReturnNotPermitted {
                    "Input Monitoring is not enabled for the CatGuard keyboard helper."
                } else {
                    "Could not guard every input collection for \(product) (IOReturn \(result)); all input was restored."
                }
            }
        }
    }

    private struct DeviceIdentity: Hashable {
        let transport: String
        let vendorID: Int
        let productID: Int
        let locationID: Int
        let product: String
        let serialNumber: String
    }

    private struct Device {
        let hidDevice: IOHIDDevice
        let identity: DeviceIdentity
        let isPrimaryKeyboard: Bool
        let isBuiltIn: Bool

        var product: String { identity.product.isEmpty ? "external keyboard" : identity.product }
    }

    private var manager: IOHIDManager?
    private var seizedDevices: [Device] = []
    private var matcher = RescueSequenceMatcher()
    private var blockedInputCount = 0
    private let queue: DispatchQueue
    var onRescuePhrase: (() -> Void)?

    init(queue: DispatchQueue) {
        self.queue = queue
    }

    var isGuarded: Bool { !seizedDevices.isEmpty }

    func arm(rescuePhrase: String) throws {
        disarm()
        matcher = RescueSequenceMatcher(sequence: rescuePhrase, maximumGap: 2)

        let manager = IOHIDManagerCreate(kCFAllocatorDefault, IOOptionBits(kIOHIDOptionsTypeNone))
        IOHIDManagerSetDeviceMatching(manager, nil)
        let openResult = IOHIDManagerOpen(manager, IOOptionBits(kIOHIDOptionsTypeNone))
        guard openResult == kIOReturnSuccess else {
            throw Error.managerOpenFailed(openResult)
        }
        self.manager = manager

        let devices = allDevices(from: manager)
        let externalKeyboardIdentities = Set(
            devices
                .filter { $0.isPrimaryKeyboard && !$0.isBuiltIn }
                .map(\.identity)
        )
        guard !externalKeyboardIdentities.isEmpty else {
            disarm()
            throw Error.noExternalKeyboard
        }

        let targetDevices = devices.filter { externalKeyboardIdentities.contains($0.identity) }
        for device in targetDevices {
            let result = IOHIDDeviceOpen(device.hidDevice, IOOptionBits(kIOHIDOptionsTypeSeizeDevice))
            guard result == kIOReturnSuccess else {
                let product = device.product
                disarm()
                throw Error.deviceOpenFailed(product: product, result: result)
            }

            let context = Unmanaged.passUnretained(self).toOpaque()
            IOHIDDeviceRegisterInputValueCallback(device.hidDevice, keyboardInputCallback, context)
            IOHIDDeviceScheduleWithRunLoop(device.hidDevice, CFRunLoopGetMain(), CFRunLoopMode.commonModes.rawValue)
            seizedDevices.append(device)
        }

        guard seizedDevices.contains(where: \.isPrimaryKeyboard) else {
            disarm()
            throw Error.deviceOpenFailed(
                product: "external keyboard",
                result: kIOReturnError
            )
        }
    }

    func disarm() {
        for device in seizedDevices {
            IOHIDDeviceUnscheduleFromRunLoop(
                device.hidDevice,
                CFRunLoopGetMain(),
                CFRunLoopMode.commonModes.rawValue
            )
            IOHIDDeviceClose(device.hidDevice, IOOptionBits(kIOHIDOptionsTypeNone))
        }
        seizedDevices.removeAll()

        if let manager {
            IOHIDManagerClose(manager, IOOptionBits(kIOHIDOptionsTypeNone))
        }
        manager = nil
    }

    func drainBlockedInputCount() -> Int {
        defer { blockedInputCount = 0 }
        return blockedInputCount
    }

    fileprivate func enqueue(_ value: IOHIDValue) {
        guard IOHIDValueGetIntegerValue(value) != 0 else { return }
        let element = IOHIDValueGetElement(value)
        guard IOHIDElementGetUsagePage(element) == kHIDPage_KeyboardOrKeypad else { return }
        let usage = IOHIDElementGetUsage(element)

        queue.async { [self] in
            handleKeyDown(usage: usage)
        }
    }

    private func handleKeyDown(usage: UInt32) {
        blockedInputCount += 1
        guard usage >= 4, usage <= 29,
            let scalar = UnicodeScalar(97 + Int(usage) - 4)
        else { return }

        if matcher.observe(Character(String(scalar))) {
            onRescuePhrase?()
        }
    }

    private func allDevices(from manager: IOHIDManager) -> [Device] {
        guard let deviceSet = IOHIDManagerCopyDevices(manager) as? Set<IOHIDDevice> else {
            return []
        }
        return deviceSet.compactMap(makeDevice)
    }

    private func makeDevice(_ device: IOHIDDevice) -> Device? {
        let transport = stringProperty(kIOHIDTransportKey, from: device)
        guard !transport.localizedCaseInsensitiveContains("virtual") else { return nil }

        let product = stringProperty(kIOHIDProductKey, from: device)
        guard !product.isEmpty else { return nil }

        let identity = DeviceIdentity(
            transport: transport,
            vendorID: integerProperty(kIOHIDVendorIDKey, from: device),
            productID: integerProperty(kIOHIDProductIDKey, from: device),
            locationID: integerProperty(kIOHIDLocationIDKey, from: device),
            product: product,
            serialNumber: stringProperty(kIOHIDSerialNumberKey, from: device)
        )
        let usagePage = integerProperty(kIOHIDPrimaryUsagePageKey, from: device)
        let usage = integerProperty(kIOHIDPrimaryUsageKey, from: device)

        return Device(
            hidDevice: device,
            identity: identity,
            isPrimaryKeyboard: usagePage == kHIDPage_GenericDesktop && usage == kHIDUsage_GD_Keyboard,
            isBuiltIn: boolProperty(kIOHIDBuiltInKey, from: device)
        )
    }

    private func stringProperty(_ key: String, from device: IOHIDDevice) -> String {
        IOHIDDeviceGetProperty(device, key as CFString) as? String ?? ""
    }

    private func integerProperty(_ key: String, from device: IOHIDDevice) -> Int {
        (IOHIDDeviceGetProperty(device, key as CFString) as? NSNumber)?.intValue ?? 0
    }

    private func boolProperty(_ key: String, from device: IOHIDDevice) -> Bool {
        (IOHIDDeviceGetProperty(device, key as CFString) as? NSNumber)?.boolValue ?? false
    }
}

private func keyboardInputCallback(
    context: UnsafeMutableRawPointer?,
    result: IOReturn,
    sender: UnsafeMutableRawPointer?,
    value: IOHIDValue
) {
    guard result == kIOReturnSuccess, let context else { return }
    Unmanaged<KeyboardDeviceController>.fromOpaque(context).takeUnretainedValue().enqueue(value)
}
