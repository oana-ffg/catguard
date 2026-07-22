import CatGuardCore
import CoreGraphics
import Dispatch
import Foundation
import IOKit.hid
import IOKit.hidsystem

private enum HIDTestError: LocalizedError {
    case invalidArguments
    case managerOpenFailed(IOReturn)
    case noDevices
    case noEligibleDevices
    case noDevicesSeized
    case requiredInputCollectionNotSeized(String)
    case noTrackpadReports

    var errorDescription: String? {
        switch self {
        case .invalidArguments:
            return
                "Usage: catguard-hid-test --list | --seize [--duration SECONDS] | --trackpad-probe [--duration SECONDS] [--collection USAGE_PAGE USAGE --duration SECONDS] | --event-tap-probe [--duration SECONDS] | --event-tap-block-physical [--duration SECONDS] | --attention-cue"
        case .managerOpenFailed(let result):
            return "Could not open IOHIDManager (IOReturn \(result))."
        case .noDevices:
            return "IOHIDManager returned no devices."
        case .noEligibleDevices:
            return "No external Bluetooth keyboard or trackpad matched the safety filter."
        case .noDevicesSeized:
            return "The eligible devices were found, but none could be seized. Check Input Monitoring permission."
        case .requiredInputCollectionNotSeized(let kind):
            return "The \(kind) input collection could not be seized; all partial seizures were released."
        case .noTrackpadReports:
            return "No trackpad collection could be opened for report capture."
        }
    }
}

private struct Options {
    enum Action {
        case list
        case seize
        case trackpadProbe(usagePage: Int, usage: Int)
        case eventTapProbe
        case eventTapBlockPhysical
        case attentionCue
    }

    let action: Action
    let duration: TimeInterval

    static func parse(_ arguments: [String]) throws -> Options {
        guard let command = arguments.first else { throw HIDTestError.invalidArguments }

        switch command {
        case "--list":
            guard arguments.count == 1 else { throw HIDTestError.invalidArguments }
            return Options(action: .list, duration: 0)

        case "--seize":
            if arguments.count == 1 {
                return Options(action: .seize, duration: 600)
            }

            guard arguments.count == 3,
                arguments[1] == "--duration",
                let duration = TimeInterval(arguments[2]),
                (1...600).contains(duration)
            else {
                throw HIDTestError.invalidArguments
            }
            return Options(action: .seize, duration: duration)

        case "--trackpad-probe":
            if arguments.count == 1 {
                return Options(
                    action: .trackpadProbe(
                        usagePage: kHIDPage_GenericDesktop,
                        usage: kHIDUsage_GD_Mouse
                    ),
                    duration: 30
                )
            }

            if arguments.count == 3,
                arguments[1] == "--duration",
                let duration = TimeInterval(arguments[2]),
                (1...60).contains(duration)
            {
                return Options(
                    action: .trackpadProbe(
                        usagePage: kHIDPage_GenericDesktop,
                        usage: kHIDUsage_GD_Mouse
                    ),
                    duration: duration
                )
            }

            guard arguments.count == 6,
                arguments[1] == "--collection",
                let usagePage = Int(arguments[2]),
                let usage = Int(arguments[3]),
                arguments[4] == "--duration",
                let duration = TimeInterval(arguments[5]),
                (1...60).contains(duration)
            else {
                throw HIDTestError.invalidArguments
            }
            return Options(
                action: .trackpadProbe(usagePage: usagePage, usage: usage),
                duration: duration
            )

        case "--event-tap-probe":
            if arguments.count == 1 {
                return Options(action: .eventTapProbe, duration: 30)
            }

            guard arguments.count == 3,
                arguments[1] == "--duration",
                let duration = TimeInterval(arguments[2]),
                (1...60).contains(duration)
            else {
                throw HIDTestError.invalidArguments
            }
            return Options(action: .eventTapProbe, duration: duration)

        case "--event-tap-block-physical":
            if arguments.count == 1 {
                return Options(action: .eventTapBlockPhysical, duration: 60)
            }

            guard arguments.count == 3,
                arguments[1] == "--duration",
                let duration = TimeInterval(arguments[2]),
                (1...120).contains(duration)
            else {
                throw HIDTestError.invalidArguments
            }
            return Options(action: .eventTapBlockPhysical, duration: duration)

        case "--attention-cue":
            guard arguments.count == 1 else { throw HIDTestError.invalidArguments }
            return Options(action: .attentionCue, duration: 0)

        default:
            throw HIDTestError.invalidArguments
        }
    }
}

private struct DeviceDescription {
    let device: IOHIDDevice
    let registryID: UInt64
    let product: String
    let manufacturer: String
    let transport: String
    let vendorID: Int?
    let productID: Int?
    let usagePage: Int?
    let usage: Int?

    var isEligibleExternalInput: Bool {
        let normalizedTransport = transport.lowercased()
        let normalizedProduct = product.lowercased()

        guard normalizedTransport.contains("bluetooth") else { return false }
        guard normalizedProduct.contains("keyboard") || normalizedProduct.contains("trackpad") else {
            return false
        }

        // Restrict this experiment to Apple peripherals. This deliberately
        // excludes internal SPI/USB input devices and unrelated Bluetooth HID.
        return manufacturer.localizedCaseInsensitiveContains("Apple") || vendorID == 0x05AC
    }

    var summary: String {
        let vendor = vendorID.map(String.init) ?? "unknown"
        let productID = productID.map(String.init) ?? "unknown"
        let usagePage = usagePage.map(String.init) ?? "unknown"
        let usage = usage.map(String.init) ?? "unknown"
        return
            "id=\(registryID) product=\(product.debugDescription) manufacturer=\(manufacturer.debugDescription) transport=\(transport.debugDescription) vendor=\(vendor) productID=\(productID) usagePage=\(usagePage) usage=\(usage)"
    }

    var isPrimaryKeyboardCollection: Bool {
        usagePage == kHIDPage_GenericDesktop && usage == kHIDUsage_GD_Keyboard
    }

    var isPrimaryPointingCollection: Bool {
        usagePage == kHIDPage_GenericDesktop && usage == kHIDUsage_GD_Mouse
    }
}

private final class RescueSequenceDetector {
    private var matcher = RescueSequenceMatcher(sequence: "rescue", maximumGap: 2)
    private let onMatch: () -> Void

    init(onMatch: @escaping () -> Void) {
        self.onMatch = onMatch
    }

    func observe(_ value: IOHIDValue) {
        guard IOHIDValueGetIntegerValue(value) != 0 else { return }

        let element = IOHIDValueGetElement(value)
        guard IOHIDElementGetUsagePage(element) == kHIDPage_KeyboardOrKeypad else { return }

        let usage = IOHIDElementGetUsage(element)
        guard usage >= 4, usage <= 29,
            let scalar = UnicodeScalar(97 + Int(usage) - 4)
        else {
            return
        }

        if matcher.observe(Character(String(scalar))) {
            onMatch()
        }
    }
}

private func rescueInputCallback(
    context: UnsafeMutableRawPointer?,
    result: IOReturn,
    sender: UnsafeMutableRawPointer?,
    value: IOHIDValue
) {
    guard result == kIOReturnSuccess, let context else { return }
    Unmanaged<RescueSequenceDetector>.fromOpaque(context).takeUnretainedValue().observe(value)
}

private final class TrackpadValueProbe {
    let description: DeviceDescription
    private(set) var valueCount = 0
    private(set) var motionValueCount = 0
    private var seenValueShapes: Set<String> = []
    private var lastUnparsedSample = DispatchTime(uptimeNanoseconds: 0)
    private var cumulativeX = 0
    private var cumulativeY = 0
    private var lastMotionSample = DispatchTime(uptimeNanoseconds: 0)

    init(description: DeviceDescription) {
        self.description = description
    }

    func observe(value: IOHIDValue) {
        valueCount += 1
        let element = IOHIDValueGetElement(value)
        let usagePage = IOHIDElementGetUsagePage(element)
        let usage = IOHIDElementGetUsage(element)
        let reportID = IOHIDElementGetReportID(element)
        let length = IOHIDValueGetLength(value)
        let shape = "\(usagePage):\(usage):\(reportID):\(length)"

        if seenValueShapes.insert(shape).inserted {
            print(
                "TRACKPAD_VALUE_SHAPE collection=\(description.registryID) usagePage=\(usagePage) usage=\(usage) reportID=0x\(String(reportID, radix: 16)) length=\(length)"
            )
        }

        if usagePage == kHIDPage_GenericDesktop,
            usage == kHIDUsage_GD_X || usage == kHIDUsage_GD_Y
        {
            motionValueCount += 1
            let delta = IOHIDValueGetIntegerValue(value)
            if usage == kHIDUsage_GD_X {
                cumulativeX += delta
            } else {
                cumulativeY += delta
            }

            let now = DispatchTime.now()
            guard now.uptimeNanoseconds - lastMotionSample.uptimeNanoseconds >= 100_000_000 else {
                return
            }
            lastMotionSample = now
            print("TRACKPAD_POINTER_SAMPLE x=\(cumulativeX) y=\(cumulativeY)")
            fflush(stdout)
            return
        }

        guard usagePage >= 0xff00, length > 1 else {
            return
        }
        let bytes = IOHIDValueGetBytePtr(value)

        let now = DispatchTime.now()
        guard now.uptimeNanoseconds - lastUnparsedSample.uptimeNanoseconds >= 250_000_000 else {
            return
        }
        lastUnparsedSample = now
        let prefixLength = min(length, 20)
        let prefix = (0..<prefixLength)
            .map { String(format: "%02x", bytes[$0]) }
            .joined(separator: " ")
        print(
            "TRACKPAD_VALUE_SAMPLE collection=\(description.registryID) usagePage=\(usagePage) usage=\(usage) reportID=0x\(String(reportID, radix: 16)) length=\(length) prefix=\(prefix)"
        )
        fflush(stdout)
    }

}

private func hidAccessDescription(_ access: IOHIDAccessType) -> String {
    switch access {
    case kIOHIDAccessTypeGranted:
        return "granted"
    case kIOHIDAccessTypeDenied:
        return "denied"
    case kIOHIDAccessTypeUnknown:
        return "unknown"
    default:
        return "unexpected(\(access.rawValue))"
    }
}

private func trackpadValueCallback(
    context: UnsafeMutableRawPointer?,
    result: IOReturn,
    sender: UnsafeMutableRawPointer?,
    value: IOHIDValue
) {
    guard result == kIOReturnSuccess, let context else { return }
    Unmanaged<TrackpadValueProbe>
        .fromOpaque(context)
        .takeUnretainedValue()
        .observe(value: value)
}

private final class EventTapProbe {
    private var suppressPhysicalEvents: Bool
    private(set) var eventCount = 0
    private var sourceCounts: [Int64: Int] = [:]
    private var lastSample = DispatchTime(uptimeNanoseconds: 0)
    private var circleDetector = PointerCircleDetector()
    private var circleDetected = false

    init(suppressPhysicalEvents: Bool) {
        self.suppressPhysicalEvents = suppressPhysicalEvents
    }

    func observe(type: CGEventType, event: CGEvent) -> Bool {
        eventCount += 1
        let sourcePID = event.getIntegerValueField(.eventSourceUnixProcessID)
        sourceCounts[sourcePID, default: 0] += 1
        let deltaX = event.getIntegerValueField(.mouseEventDeltaX)
        let deltaY = event.getIntegerValueField(.mouseEventDeltaY)

        if suppressPhysicalEvents,
            sourcePID == 0,
            Self.isPointerMotion(type),
            circleDetector.observe(
                deltaX: Double(deltaX),
                deltaY: Double(deltaY),
                at: Double(event.timestamp) / 1_000_000_000
            )
        {
            suppressPhysicalEvents = false
            circleDetected = true
            if let metrics = circleDetector.latestMetrics {
                print(
                    "CIRCLE_DETECTED samples=\(metrics.sampleCount) duration=\(String(format: "%.3f", metrics.duration)) width=\(String(format: "%.1f", metrics.width)) height=\(String(format: "%.1f", metrics.height)) closureRatio=\(String(format: "%.3f", metrics.closureRatio)) areaRatio=\(String(format: "%.3f", metrics.areaRatio)) pathRatio=\(String(format: "%.3f", metrics.pathRatio))"
                )
            } else {
                print("CIRCLE_DETECTED")
            }
            fflush(stdout)
        }

        let now = DispatchTime.now()
        guard now.uptimeNanoseconds - lastSample.uptimeNanoseconds >= 100_000_000 else {
            return suppressPhysicalEvents && sourcePID == 0
        }
        lastSample = now

        let sourceUserID = event.getIntegerValueField(.eventSourceUserID)
        let sourceStateID = event.getIntegerValueField(.eventSourceStateID)
        print(
            "EVENT_TAP_SAMPLE type=\(type.rawValue) sourcePID=\(sourcePID) sourceUserID=\(sourceUserID) sourceStateID=\(sourceStateID) deltaX=\(deltaX) deltaY=\(deltaY)"
        )
        fflush(stdout)
        return suppressPhysicalEvents && sourcePID == 0
    }

    func printSummary() {
        let sources =
            sourceCounts
            .sorted { $0.key < $1.key }
            .map { "\($0.key):\($0.value)" }
            .joined(separator: ",")
        let summary =
            "EVENT_TAP_COUNTS events=\(eventCount) sources=\(sources) circleDetected=\(circleDetected) suppressionActive=\(suppressPhysicalEvents)"
        print(summary)
        let summaryPath = "/tmp/catguard-event-tap-summary.log"
        try? summary.write(toFile: summaryPath, atomically: true, encoding: .utf8)
        print("EVENT_TAP_SUMMARY_PATH \(summaryPath)")
    }

    private static func isPointerMotion(_ type: CGEventType) -> Bool {
        switch type {
        case .mouseMoved, .leftMouseDragged, .rightMouseDragged, .otherMouseDragged:
            return true
        default:
            return false
        }
    }
}

private func eventTapCallback(
    proxy: CGEventTapProxy,
    type: CGEventType,
    event: CGEvent,
    userInfo: UnsafeMutableRawPointer?
) -> Unmanaged<CGEvent>? {
    guard type != .tapDisabledByTimeout,
        type != .tapDisabledByUserInput,
        let userInfo
    else {
        return Unmanaged.passUnretained(event)
    }

    let shouldSuppress = Unmanaged<EventTapProbe>
        .fromOpaque(userInfo)
        .takeUnretainedValue()
        .observe(type: type, event: event)
    if shouldSuppress {
        return nil
    }
    return Unmanaged.passUnretained(event)
}

private func eventMask(_ types: [CGEventType]) -> CGEventMask {
    types.reduce(CGEventMask(0)) { mask, type in
        mask | (CGEventMask(1) << type.rawValue)
    }
}

private func performCue(sound: String, color: (red: Float, green: Float, blue: Float)) {
    let soundPlayer = Process()
    soundPlayer.executableURL = URL(fileURLWithPath: "/usr/bin/afplay")
    soundPlayer.arguments = ["/System/Library/Sounds/\(sound).aiff"]
    try? soundPlayer.run()

    var token = CGDisplayFadeReservationToken(kCGDisplayFadeReservationInvalidToken)
    guard CGAcquireDisplayFadeReservation(1, &token) == .success else { return }
    defer { CGReleaseDisplayFadeReservation(token) }

    CGDisplayFade(
        token,
        0.05,
        Float(kCGDisplayBlendNormal),
        Float(kCGDisplayBlendSolidColor),
        color.red,
        color.green,
        color.blue,
        1
    )
    usleep(80_000)
    CGDisplayFade(
        token,
        0.12,
        Float(kCGDisplayBlendSolidColor),
        Float(kCGDisplayBlendNormal),
        color.red,
        color.green,
        color.blue,
        1
    )
}

private func probeEventTap(duration: TimeInterval, suppressPhysicalEvents: Bool) throws {
    let probe = EventTapProbe(suppressPhysicalEvents: suppressPhysicalEvents)
    let mask = eventMask([
        .mouseMoved,
        .leftMouseDown,
        .leftMouseUp,
        .rightMouseDown,
        .rightMouseUp,
        .otherMouseDown,
        .otherMouseUp,
        .leftMouseDragged,
        .rightMouseDragged,
        .otherMouseDragged,
        .scrollWheel,
    ])

    print("CG_LISTEN_ACCESS granted=\(CGPreflightListenEventAccess()) euid=\(geteuid())")
    guard
        let tap = CGEvent.tapCreate(
            tap: .cghidEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: mask,
            callback: eventTapCallback,
            userInfo: Unmanaged.passUnretained(probe).toOpaque()
        )
    else {
        throw HIDTestError.noTrackpadReports
    }

    let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
    CFRunLoopAddSource(CFRunLoopGetMain(), source, .defaultMode)
    CGEvent.tapEnable(tap: tap, enable: true)
    print("EVENT_TAP_PROBE_ACTIVE durationSeconds=\(Int(duration)) suppressPhysical=\(suppressPhysicalEvents)")
    fflush(stdout)
    performCue(sound: "Glass", color: (1, 1, 1))
    CFRunLoopRunInMode(.defaultMode, duration, false)
    CGEvent.tapEnable(tap: tap, enable: false)
    CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .defaultMode)
    probe.printSummary()
    print("EVENT_TAP_PROBE_COMPLETE")
    fflush(stdout)
}

private func stringProperty(_ key: String, from device: IOHIDDevice) -> String {
    IOHIDDeviceGetProperty(device, key as CFString) as? String ?? ""
}

private func integerProperty(_ key: String, from device: IOHIDDevice) -> Int? {
    (IOHIDDeviceGetProperty(device, key as CFString) as? NSNumber)?.intValue
}

private func describe(_ device: IOHIDDevice) -> DeviceDescription {
    var registryID: UInt64 = 0
    let service = IOHIDDeviceGetService(device)
    if service != IO_OBJECT_NULL {
        IORegistryEntryGetRegistryEntryID(service, &registryID)
    }

    return DeviceDescription(
        device: device,
        registryID: registryID,
        product: stringProperty(kIOHIDProductKey, from: device),
        manufacturer: stringProperty(kIOHIDManufacturerKey, from: device),
        transport: stringProperty(kIOHIDTransportKey, from: device),
        vendorID: integerProperty(kIOHIDVendorIDKey, from: device),
        productID: integerProperty(kIOHIDProductIDKey, from: device),
        usagePage: integerProperty(kIOHIDPrimaryUsagePageKey, from: device),
        usage: integerProperty(kIOHIDPrimaryUsageKey, from: device)
    )
}

private func enumerateDevices() throws -> [DeviceDescription] {
    let manager = IOHIDManagerCreate(kCFAllocatorDefault, IOOptionBits(kIOHIDOptionsTypeNone))
    IOHIDManagerSetDeviceMatching(manager, nil)

    let openResult = IOHIDManagerOpen(manager, IOOptionBits(kIOHIDOptionsTypeNone))
    guard openResult == kIOReturnSuccess else {
        throw HIDTestError.managerOpenFailed(openResult)
    }

    guard let deviceSet = IOHIDManagerCopyDevices(manager) as? Set<IOHIDDevice> else {
        IOHIDManagerClose(manager, IOOptionBits(kIOHIDOptionsTypeNone))
        throw HIDTestError.noDevices
    }

    // Retain the device references independently before closing the manager.
    let descriptions = deviceSet.map(describe)
    IOHIDManagerClose(manager, IOOptionBits(kIOHIDOptionsTypeNone))
    return descriptions.sorted {
        if $0.product != $1.product { return $0.product < $1.product }
        return $0.registryID < $1.registryID
    }
}

private func printEligibleDevices(_ devices: [DeviceDescription]) throws {
    let eligible = devices.filter(\.isEligibleExternalInput)
    guard !eligible.isEmpty else { throw HIDTestError.noEligibleDevices }

    print("Eligible external Bluetooth input collections:")
    for device in eligible {
        print("  \(device.summary)")
    }
}

@discardableResult
private func releaseDevices(_ devices: [DeviceDescription]) -> Double {
    let totalStart = DispatchTime.now().uptimeNanoseconds

    for description in devices.reversed() {
        let start = DispatchTime.now().uptimeNanoseconds
        let result = IOHIDDeviceClose(description.device, IOOptionBits(kIOHIDOptionsTypeNone))
        let elapsedMilliseconds = Double(DispatchTime.now().uptimeNanoseconds - start) / 1_000_000
        print(
            "RELEASED result=\(result) closeMilliseconds=\(String(format: "%.3f", elapsedMilliseconds)) \(description.summary)"
        )
    }

    let totalMilliseconds = Double(DispatchTime.now().uptimeNanoseconds - totalStart) / 1_000_000
    print("RELEASE_TIMING totalMilliseconds=\(String(format: "%.3f", totalMilliseconds)) collections=\(devices.count)")
    return totalMilliseconds
}

private func probeTrackpadReports(
    _ devices: [DeviceDescription],
    duration: TimeInterval,
    usagePage: Int,
    usage: Int
) throws {
    let listenAccess = IOHIDCheckAccess(kIOHIDRequestTypeListenEvent)
    print("HID_LISTEN_ACCESS status=\(hidAccessDescription(listenAccess)) euid=\(geteuid())")

    let trackpads = devices.filter {
        $0.isEligibleExternalInput
            && $0.product.localizedCaseInsensitiveContains("trackpad")
            && $0.usagePage == usagePage
            && $0.usage == usage
    }
    guard !trackpads.isEmpty else { throw HIDTestError.noEligibleDevices }

    var probes: [TrackpadValueProbe] = []
    for description in trackpads {
        let probe = TrackpadValueProbe(description: description)
        IOHIDDeviceSetInputValueMatching(description.device, nil)
        IOHIDDeviceRegisterInputValueCallback(
            description.device,
            trackpadValueCallback,
            Unmanaged.passUnretained(probe).toOpaque()
        )
        IOHIDDeviceScheduleWithRunLoop(
            description.device,
            CFRunLoopGetMain(),
            CFRunLoopMode.defaultMode.rawValue
        )

        let openResult = IOHIDDeviceOpen(
            description.device,
            IOOptionBits(kIOHIDOptionsTypeSeizeDevice)
        )
        guard openResult == kIOReturnSuccess else {
            IOHIDDeviceUnscheduleFromRunLoop(
                description.device,
                CFRunLoopGetMain(),
                CFRunLoopMode.defaultMode.rawValue
            )
            print("PROBE_OPEN_FAILED result=\(openResult) \(description.summary)")
            continue
        }

        probes.append(probe)
        print("PROBING \(description.summary)")
    }

    guard !probes.isEmpty else { throw HIDTestError.noTrackpadReports }

    print("TRACKPAD_PROBE_ACTIVE durationSeconds=\(Int(duration))")
    print("Draw one-finger circles; the trackpad is seized, but the keyboard remains enabled.")
    fflush(stdout)
    CFRunLoopRunInMode(.defaultMode, duration, false)

    for probe in probes.reversed() {
        print(
            "TRACKPAD_PROBE_COUNTS collection=\(probe.description.registryID) values=\(probe.valueCount) motionValues=\(probe.motionValueCount)"
        )
        IOHIDDeviceUnscheduleFromRunLoop(
            probe.description.device,
            CFRunLoopGetMain(),
            CFRunLoopMode.defaultMode.rawValue
        )
    }
    releaseDevices(probes.map(\.description))
    print("TRACKPAD_PROBE_COMPLETE")
    fflush(stdout)
}

private func seizeEligibleDevices(_ devices: [DeviceDescription], duration: TimeInterval) throws {
    let eligible = devices.filter(\.isEligibleExternalInput)
    guard !eligible.isEmpty else { throw HIDTestError.noEligibleDevices }

    var seized: [DeviceDescription] = []
    for description in eligible {
        let result = IOHIDDeviceOpen(
            description.device,
            IOOptionBits(kIOHIDOptionsTypeSeizeDevice)
        )

        if result == kIOReturnSuccess {
            seized.append(description)
            print("SEIZED \(description.summary)")
        } else {
            print("FAILED result=\(result) \(description.summary)")
        }
    }

    guard !seized.isEmpty else { throw HIDTestError.noDevicesSeized }

    do {
        guard seized.contains(where: \.isPrimaryKeyboardCollection) else {
            throw HIDTestError.requiredInputCollectionNotSeized("keyboard")
        }
        guard seized.contains(where: \.isPrimaryPointingCollection) else {
            throw HIDTestError.requiredInputCollectionNotSeized("trackpad pointer")
        }
    } catch {
        releaseDevices(seized)
        throw error
    }

    guard let keyboard = seized.first(where: \.isPrimaryKeyboardCollection) else {
        preconditionFailure("The primary keyboard collection was validated above")
    }

    var shouldExit = false
    let requestRelease: (String) -> Void = { reason in
        guard !shouldExit else { return }
        print("\(reason) releasing all seized devices")
        fflush(stdout)
        shouldExit = true
        CFRunLoopStop(CFRunLoopGetMain())
    }
    let rescueDetector = RescueSequenceDetector {
        requestRelease("RESCUE_SEQUENCE_MATCHED")
    }
    IOHIDDeviceRegisterInputValueCallback(
        keyboard.device,
        rescueInputCallback,
        Unmanaged.passUnretained(rescueDetector).toOpaque()
    )
    IOHIDDeviceScheduleWithRunLoop(
        keyboard.device,
        CFRunLoopGetMain(),
        CFRunLoopMode.defaultMode.rawValue
    )

    let deadline = Date().addingTimeInterval(duration)
    print(
        "GUARD_ACTIVE seized=\(seized.count) releaseAt=\(ISO8601DateFormatter().string(from: deadline)) maxDurationSeconds=\(Int(duration))"
    )
    print("RESCUE_SEQUENCE type=rescue maximumGapSeconds=2")
    fflush(stdout)

    let timer = DispatchSource.makeTimerSource(queue: .main)
    timer.schedule(deadline: .now() + duration)
    timer.setEventHandler {
        requestRelease("DEADLINE_REACHED")
    }
    timer.resume()

    signal(SIGINT, SIG_IGN)
    signal(SIGTERM, SIG_IGN)

    let interruptSource = DispatchSource.makeSignalSource(signal: SIGINT, queue: .main)
    interruptSource.setEventHandler {
        requestRelease("INTERRUPTED")
    }
    interruptSource.resume()

    let terminationSource = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .main)
    terminationSource.setEventHandler {
        requestRelease("TERMINATED")
    }
    terminationSource.resume()

    while !shouldExit {
        CFRunLoopRun()
    }

    timer.cancel()
    interruptSource.cancel()
    terminationSource.cancel()

    IOHIDDeviceUnscheduleFromRunLoop(
        keyboard.device,
        CFRunLoopGetMain(),
        CFRunLoopMode.defaultMode.rawValue
    )

    releaseDevices(seized)
    print("GUARD_INACTIVE")
    fflush(stdout)
}

do {
    let options = try Options.parse(Array(CommandLine.arguments.dropFirst()))
    let devices = try enumerateDevices()

    switch options.action {
    case .list:
        try printEligibleDevices(devices)
    case .seize:
        try seizeEligibleDevices(devices, duration: options.duration)
    case .trackpadProbe(let usagePage, let usage):
        try probeTrackpadReports(
            devices,
            duration: options.duration,
            usagePage: usagePage,
            usage: usage
        )
    case .eventTapProbe:
        try probeEventTap(duration: options.duration, suppressPhysicalEvents: false)
    case .eventTapBlockPhysical:
        try probeEventTap(duration: options.duration, suppressPhysicalEvents: true)
    case .attentionCue:
        performCue(sound: "Basso", color: (1, 0.55, 0.1))
    }
} catch {
    FileHandle.standardError.write(Data("ERROR: \(error.localizedDescription)\n".utf8))
    exit(EXIT_FAILURE)
}
