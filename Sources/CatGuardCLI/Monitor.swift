@preconcurrency import AppKit
import Combine
import CoreImage
import CoreVideo
import Foundation
import SwiftUI

private enum MonitorStatus: Equatable {
    case waiting
    case analyzing
    case human
    case noHuman
    case error

    var title: String {
        switch self {
        case .waiting: "WAITING"
        case .analyzing: "ANALYZING"
        case .human: "HUMAN"
        case .noHuman: "NO HUMAN"
        case .error: "ERROR"
        }
    }

    var color: Color {
        switch self {
        case .waiting: .secondary
        case .analyzing: .orange
        case .human: .green
        case .noHuman: .red
        case .error: .orange
        }
    }
}

private enum LightQuality: String, Sendable {
    case usable = "USABLE LIGHT"
    case dim = "DIM"
    case tooDark = "TOO DARK"

    init(meanLuma: Double) {
        if meanLuma >= 0.03 {
            self = .usable
        } else if meanLuma >= 0.005 {
            self = .dim
        } else {
            self = .tooDark
        }
    }

    var color: Color {
        switch self {
        case .usable: .green
        case .dim: .orange
        case .tooDark: .red
        }
    }
}

private struct DetectionRecord: Identifiable {
    let id = UUID()
    let timestamp: Date
    let standardConfidence: Float
    let nightConfidence: Float?
    let meanLuma: Double
    let duration: TimeInterval
}

private struct MonitorSampleResult: @unchecked Sendable {
    let cameraName: String?
    let standardConfidence: Float?
    let nightConfidence: Float?
    let meanLuma: Double?
    let duration: TimeInterval
    let errorMessage: String?
    let frameImage: CGImage?
    let nightFrameImage: CGImage?
}

private final class MonitorLogger: @unchecked Sendable {
    static let shared = MonitorLogger()

    private let lock = NSLock()

    func write(_ message: String) {
        let timestamp = ISO8601DateFormatter().string(from: Date())
        guard let data = "\(timestamp) \(message)\n".data(using: .utf8) else { return }

        lock.lock()
        defer { lock.unlock() }
        try? FileHandle.standardOutput.write(contentsOf: data)
    }
}

private final class MonitorSampler: @unchecked Sendable {
    private let imageContext = CIContext(options: [.cacheIntermediates: false])
    private let options: CLIOptions
    private let queue = DispatchQueue(label: "dk.catguard.monitor.camera", qos: .utility)

    init(options: CLIOptions) {
        self.options = options
    }

    func sample(
        completion: @escaping @MainActor @Sendable (MonitorSampleResult) -> Void
    ) {
        queue.async { [self] in
            let startedAt = Date()

            do {
                let cameraSample = try CameraProbe.captureFrame(options: options)
                let frameImage = makeImage(from: cameraSample.pixelBuffer)
                let meanLuma = calculateMeanLuma(in: cameraSample.pixelBuffer)
                let standardConfidence = try HumanDetector.confidence(in: cameraSample.pixelBuffer)

                var nightConfidence: Float?
                var nightFrameImage: CGImage?
                if meanLuma < 0.03,
                   let nightBuffer = makeNightEnhancedBuffer(
                       from: cameraSample.pixelBuffer,
                       meanLuma: meanLuma
                   )
                {
                    nightFrameImage = makeImage(from: nightBuffer)
                    nightConfidence = try HumanDetector.confidence(in: nightBuffer)
                }

                let result = MonitorSampleResult(
                    cameraName: cameraSample.cameraName,
                    standardConfidence: standardConfidence,
                    nightConfidence: nightConfidence,
                    meanLuma: meanLuma,
                    duration: Date().timeIntervalSince(startedAt),
                    errorMessage: nil,
                    frameImage: frameImage,
                    nightFrameImage: nightFrameImage
                )
                Task { @MainActor in completion(result) }
            } catch {
                let result = MonitorSampleResult(
                    cameraName: nil,
                    standardConfidence: nil,
                    nightConfidence: nil,
                    meanLuma: nil,
                    duration: Date().timeIntervalSince(startedAt),
                    errorMessage: error.localizedDescription,
                    frameImage: nil,
                    nightFrameImage: nil
                )
                Task { @MainActor in completion(result) }
            }
        }
    }

    private func makeImage(from pixelBuffer: CVPixelBuffer) -> CGImage? {
        let image = CIImage(cvPixelBuffer: pixelBuffer)
        return imageContext.createCGImage(image, from: image.extent)
    }

    private func calculateMeanLuma(in pixelBuffer: CVPixelBuffer) -> Double {
        CVPixelBufferLockBaseAddress(pixelBuffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, .readOnly) }

        guard let baseAddress = CVPixelBufferGetBaseAddress(pixelBuffer) else { return 0 }
        let width = CVPixelBufferGetWidth(pixelBuffer)
        let height = CVPixelBufferGetHeight(pixelBuffer)
        let bytesPerRow = CVPixelBufferGetBytesPerRow(pixelBuffer)
        let bytes = baseAddress.assumingMemoryBound(to: UInt8.self)
        let stride = 4
        var lumaSum = 0.0
        var sampleCount = 0

        for y in Swift.stride(from: 0, to: height, by: stride) {
            let row = bytes.advanced(by: y * bytesPerRow)
            for x in Swift.stride(from: 0, to: width, by: stride) {
                let pixel = row.advanced(by: x * 4)
                let blue = Double(pixel[0])
                let green = Double(pixel[1])
                let red = Double(pixel[2])
                lumaSum += (0.0722 * blue) + (0.7152 * green) + (0.2126 * red)
                sampleCount += 1
            }
        }

        guard sampleCount > 0 else { return 0 }
        return lumaSum / (Double(sampleCount) * 255)
    }

    private func makeNightEnhancedBuffer(
        from pixelBuffer: CVPixelBuffer,
        meanLuma: Double
    ) -> CVPixelBuffer? {
        let width = CVPixelBufferGetWidth(pixelBuffer)
        let height = CVPixelBufferGetHeight(pixelBuffer)
        let attributes: [CFString: Any] = [
            kCVPixelBufferCGImageCompatibilityKey: true,
            kCVPixelBufferCGBitmapContextCompatibilityKey: true,
        ]
        var outputBuffer: CVPixelBuffer?
        let status = CVPixelBufferCreate(
            kCFAllocatorDefault,
            width,
            height,
            kCVPixelFormatType_32BGRA,
            attributes as CFDictionary,
            &outputBuffer
        )
        guard status == kCVReturnSuccess, let outputBuffer else { return nil }

        let targetLuma = 0.18
        let exposure = min(6, max(0, log2(targetLuma / max(meanLuma, 0.001))))
        let source = CIImage(cvPixelBuffer: pixelBuffer)
        let enhanced = source
            .applyingFilter("CIExposureAdjust", parameters: [kCIInputEVKey: exposure])
            .applyingFilter("CIGammaAdjust", parameters: ["inputPower": 0.7])
            .applyingFilter(
                "CIColorControls",
                parameters: [
                    kCIInputContrastKey: 1.2,
                    kCIInputSaturationKey: 0.7,
                ]
            )

        imageContext.render(
            enhanced,
            to: outputBuffer,
            bounds: source.extent,
            colorSpace: CGColorSpaceCreateDeviceRGB()
        )
        return outputBuffer
    }
}

@MainActor
private final class MonitorViewModel: NSObject, ObservableObject {
    @Published private(set) var cameraName = "External camera"
    @Published private(set) var standardConfidence: Float?
    @Published private(set) var nightConfidence: Float?
    @Published private(set) var meanLuma: Double?
    @Published private(set) var errorMessage: String?
    @Published private(set) var frameImage: CGImage?
    @Published private(set) var nightFrameImage: CGImage?
    @Published private(set) var history: [DetectionRecord] = []
    @Published private(set) var status: MonitorStatus = .waiting

    let confidenceThreshold: Float
    let sampleInterval: TimeInterval

    var lightQuality: LightQuality? {
        meanLuma.map(LightQuality.init(meanLuma:))
    }

    var nightStatus: MonitorStatus {
        guard let nightConfidence else { return .waiting }
        return nightConfidence >= confidenceThreshold ? .human : .noHuman
    }

    private var isActive = false
    private var timer: Timer?
    private let sampler: MonitorSampler

    init(options: CLIOptions) {
        confidenceThreshold = options.confidenceThreshold
        sampleInterval = options.sampleInterval
        sampler = MonitorSampler(options: options)
    }

    func start() {
        guard !isActive else { return }
        isActive = true
        performSample()
    }

    func stop() {
        isActive = false
        timer?.invalidate()
        timer = nil
    }

    private func performSample() {
        guard isActive else { return }
        timer = nil
        status = .analyzing
        errorMessage = nil

        sampler.sample { [weak self] result in
            self?.handle(result)
        }
    }

    private func handle(_ result: MonitorSampleResult) {
        guard isActive else { return }

        if let cameraName = result.cameraName {
            self.cameraName = cameraName
        }
        if let frameImage = result.frameImage {
            self.frameImage = frameImage
        }

        nightFrameImage = result.nightFrameImage
        standardConfidence = result.standardConfidence
        nightConfidence = result.nightConfidence
        meanLuma = result.meanLuma
        errorMessage = result.errorMessage

        if let standardConfidence = result.standardConfidence,
           let meanLuma = result.meanLuma
        {
            let humanDetected = standardConfidence >= confidenceThreshold
            status = humanDetected ? .human : .noHuman
            history.insert(
                DetectionRecord(
                    timestamp: Date(),
                    standardConfidence: standardConfidence,
                    nightConfidence: result.nightConfidence,
                    meanLuma: meanLuma,
                    duration: result.duration
                ),
                at: 0
            )
            history = Array(history.prefix(10))

            let nightText = result.nightConfidence.map {
                String(format: "%.3f", $0)
            } ?? "not_run"
            MonitorLogger.shared.write(
                "camera standard=\(humanDetected ? "HUMAN" : "NO_HUMAN") "
                    + String(format: "confidence=%.3f night=%@ luma=%.4f duration=%.1fs", standardConfidence, nightText, meanLuma, result.duration)
                    + " quality=\(LightQuality(meanLuma: meanLuma).rawValue.replacingOccurrences(of: " ", with: "_"))"
            )
        } else {
            status = .error
            MonitorLogger.shared.write("camera error=\(result.errorMessage ?? "unknown error")")
        }

        let nextDelay = max(0.25, sampleInterval - result.duration)
        timer = Timer.scheduledTimer(
            timeInterval: nextDelay,
            target: self,
            selector: #selector(sampleTimerFired),
            userInfo: nil,
            repeats: false
        )
    }

    @objc private func sampleTimerFired() {
        performSample()
    }
}

private struct BluetoothSampleResult: Sendable {
    let devices: [BluetoothDeviceSnapshot]
    let duration: TimeInterval
    let errorMessage: String?
}

private struct BluetoothReading: Identifiable {
    let id = UUID()
    let timestamp: Date
    let rssi: Int
}

private final class BluetoothSampler: @unchecked Sendable {
    private let queue = DispatchQueue(label: "dk.catguard.monitor.bluetooth", qos: .utility)

    func sample(
        completion: @escaping @MainActor @Sendable (BluetoothSampleResult) -> Void
    ) {
        queue.async {
            let startedAt = Date()
            do {
                let devices = try BluetoothProbe.snapshot()
                let result = BluetoothSampleResult(
                    devices: devices,
                    duration: Date().timeIntervalSince(startedAt),
                    errorMessage: nil
                )
                Task { @MainActor in completion(result) }
            } catch {
                let result = BluetoothSampleResult(
                    devices: [],
                    duration: Date().timeIntervalSince(startedAt),
                    errorMessage: error.localizedDescription
                )
                Task { @MainActor in completion(result) }
            }
        }
    }
}

@MainActor
private final class BluetoothViewModel: NSObject, ObservableObject {
    @Published private(set) var devices: [BluetoothDeviceSnapshot] = []
    @Published private(set) var errorMessage: String?
    @Published private(set) var isSampling = false
    @Published private(set) var lastUpdated: Date?

    let sampleInterval: TimeInterval = 10

    private var histories: [String: [BluetoothReading]] = [:]
    private var isActive = false
    private var timer: Timer?
    private let sampler = BluetoothSampler()

    func history(for device: BluetoothDeviceSnapshot) -> [BluetoothReading] {
        histories[device.name] ?? []
    }

    func start() {
        guard !isActive else { return }
        isActive = true
        performSample()
    }

    func stop() {
        isActive = false
        timer?.invalidate()
        timer = nil
    }

    private func performSample() {
        guard isActive else { return }
        timer = nil
        isSampling = true

        sampler.sample { [weak self] result in
            self?.handle(result)
        }
    }

    private func handle(_ result: BluetoothSampleResult) {
        guard isActive else { return }

        isSampling = false
        errorMessage = result.errorMessage
        if result.errorMessage == nil {
            devices = result.devices
            lastUpdated = Date()

            for device in result.devices {
                guard let rssi = device.rssi else { continue }
                var readings = histories[device.name] ?? []
                readings.append(BluetoothReading(timestamp: Date(), rssi: rssi))
                histories[device.name] = Array(readings.suffix(10))
            }

            let connectedCount = result.devices.count(where: \.isConnected)
            let liveRSSICount = result.devices.count { $0.rssi != nil }
            MonitorLogger.shared.write(
                "bluetooth connected=\(connectedCount) live_rssi=\(liveRSSICount) duration="
                    + String(format: "%.1fs", result.duration)
            )
        } else {
            MonitorLogger.shared.write("bluetooth error=\(result.errorMessage ?? "unknown error")")
        }

        let nextDelay = max(1, sampleInterval - result.duration)
        timer = Timer.scheduledTimer(
            timeInterval: nextDelay,
            target: self,
            selector: #selector(sampleTimerFired),
            userInfo: nil,
            repeats: false
        )
    }

    @objc private func sampleTimerFired() {
        performSample()
    }
}

private struct MonitorView: View {
    @ObservedObject var bluetoothModel: BluetoothViewModel
    @ObservedObject var cameraModel: MonitorViewModel

    var body: some View {
        HStack(alignment: .top, spacing: 18) {
            cameraSection
                .frame(minWidth: 760)

            cameraHistory
                .frame(width: 300)

            bluetoothSection
                .frame(width: 360)
        }
        .padding(18)
        .frame(minWidth: 1480, minHeight: 820)
        .background(Color(nsColor: .windowBackgroundColor))
    }

    private var cameraSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 12) {
                frameCard(
                    title: "Original frame",
                    subtitle: "Standard Vision input",
                    image: cameraModel.frameImage,
                    status: cameraModel.status
                )
                frameCard(
                    title: "Night enhanced",
                    subtitle: cameraModel.nightFrameImage == nil
                        ? "Activates below 3% mean luminance"
                        : "Exposure + gamma; analyzed separately",
                    image: cameraModel.nightFrameImage,
                    status: cameraModel.nightStatus
                )
            }

            HStack(spacing: 10) {
                resultCard(
                    title: "Standard",
                    status: cameraModel.status,
                    confidence: cameraModel.standardConfidence
                )
                resultCard(
                    title: "Night",
                    status: cameraModel.nightStatus,
                    confidence: cameraModel.nightConfidence
                )
                lightCard
            }

            VStack(alignment: .leading, spacing: 5) {
                Text(cameraModel.cameraName)
                    .font(.headline)
                Text(
                    "Camera every \(cameraModel.sampleInterval.formatted(.number.precision(.fractionLength(0...1))))s · "
                        + "threshold \(cameraModel.confidenceThreshold.formatted(.number.precision(.fractionLength(2))))"
                )
                .foregroundStyle(.secondary)
                Text("Debug signals are independent. Safety remains UNCERTAIN and input remains ENABLED.")
                    .font(.callout.weight(.semibold))

                if let errorMessage = cameraModel.errorMessage {
                    Text(errorMessage)
                        .foregroundStyle(.orange)
                }
            }
        }
    }

    private func frameCard(
        title: String,
        subtitle: String,
        image: CGImage?,
        status: MonitorStatus
    ) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.headline)
            Text(subtitle)
                .font(.caption)
                .foregroundStyle(.secondary)

            ZStack {
                Color.black
                if let image {
                    Image(decorative: image, scale: 1)
                        .resizable()
                        .scaledToFit()
                } else if status == .analyzing || cameraModel.frameImage == nil {
                    ProgressView()
                } else {
                    Text("Not needed for this frame")
                        .foregroundStyle(.secondary)
                }
            }
            .aspectRatio(4 / 3, contentMode: .fit)
            .clipShape(RoundedRectangle(cornerRadius: 10))
            .overlay {
                RoundedRectangle(cornerRadius: 10)
                    .stroke(status.color, lineWidth: 3)
            }
        }
    }

    private func resultCard(
        title: String,
        status: MonitorStatus,
        confidence: Float?
    ) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            HStack(spacing: 7) {
                Circle()
                    .fill(status.color)
                    .frame(width: 12, height: 12)
                Text(status.title)
                    .fontWeight(.bold)
                    .foregroundStyle(status.color)
            }
            Text(confidence.map { String(format: "confidence %.3f", $0) } ?? "not run")
                .font(.system(.caption, design: .monospaced))
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(10)
        .background(status.color.opacity(0.12), in: RoundedRectangle(cornerRadius: 9))
    }

    private var lightCard: some View {
        let quality = cameraModel.lightQuality
        let color = quality?.color ?? Color.secondary

        return VStack(alignment: .leading, spacing: 4) {
            Text("Image quality")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            HStack(spacing: 7) {
                Circle()
                    .fill(color)
                    .frame(width: 12, height: 12)
                Text(quality?.rawValue ?? "WAITING")
                    .fontWeight(.bold)
                    .foregroundStyle(color)
            }
            Text(cameraModel.meanLuma.map { String(format: "mean luma %.2f%%", $0 * 100) } ?? "not sampled")
                .font(.system(.caption, design: .monospaced))
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(10)
        .background(color.opacity(0.12), in: RoundedRectangle(cornerRadius: 9))
    }

    private var cameraHistory: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Camera · last 10")
                .font(.title3.weight(.bold))

            if cameraModel.history.isEmpty {
                Text("Results appear after each sample.")
                    .foregroundStyle(.secondary)
            } else {
                ScrollView {
                    LazyVStack(spacing: 7) {
                        ForEach(cameraModel.history) { record in
                            let standardHuman = record.standardConfidence >= cameraModel.confidenceThreshold
                            let nightHuman = record.nightConfidence.map {
                                $0 >= cameraModel.confidenceThreshold
                            }

                            VStack(alignment: .leading, spacing: 5) {
                                HStack {
                                    Text(record.timestamp, style: .time)
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                    Spacer()
                                    Text(String(format: "%.1fs", record.duration))
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                                historySignal(
                                    label: "Standard",
                                    confidence: record.standardConfidence,
                                    detected: standardHuman
                                )
                                if let nightConfidence = record.nightConfidence,
                                   let nightHuman
                                {
                                    historySignal(
                                        label: "Night",
                                        confidence: nightConfidence,
                                        detected: nightHuman
                                    )
                                }
                                Text(String(format: "luma %.2f%%", record.meanLuma * 100))
                                    .font(.system(.caption2, design: .monospaced))
                                    .foregroundStyle(.secondary)
                            }
                            .padding(9)
                            .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 8))
                        }
                    }
                }
            }

            Spacer()

            Text("Images remain in memory only; history is metadata.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private func historySignal(
        label: String,
        confidence: Float,
        detected: Bool
    ) -> some View {
        HStack(spacing: 6) {
            Circle()
                .fill(detected ? Color.green : Color.red)
                .frame(width: 9, height: 9)
            Text(label)
            Spacer()
            Text(String(format: "%.3f", confidence))
                .font(.system(.caption, design: .monospaced))
        }
        .font(.caption)
    }

    private var bluetoothSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Bluetooth proximity")
                    .font(.title3.weight(.bold))
                Spacer()
                if bluetoothModel.isSampling {
                    ProgressView()
                        .controlSize(.small)
                }
            }

            Text("Experimental · raw RSSI trend, not physical distance")
                .font(.caption)
                .foregroundStyle(.secondary)

            if let errorMessage = bluetoothModel.errorMessage {
                Text(errorMessage)
                    .foregroundStyle(.orange)
            }

            ScrollView {
                LazyVStack(spacing: 8) {
                    ForEach(bluetoothModel.devices) { device in
                        bluetoothDeviceCard(device)
                    }
                }
            }

            if let lastUpdated = bluetoothModel.lastUpdated {
                Text("Updated \(lastUpdated, style: .relative) · every 10s")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Text("Disconnected-device RSSI is discarded as stale. Connected devices without RSSI remain connection-only signals.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private func bluetoothDeviceCard(_ device: BluetoothDeviceSnapshot) -> some View {
        let readings = bluetoothModel.history(for: device)

        return VStack(alignment: .leading, spacing: 7) {
            HStack(spacing: 7) {
                Circle()
                    .fill(device.isConnected ? Color.blue : Color.secondary)
                    .frame(width: 10, height: 10)
                Text(device.name)
                    .fontWeight(.semibold)
                    .lineLimit(1)
                Spacer()
                Text(device.isConnected ? "connected" : "offline")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            if let rssi = device.rssi {
                HStack {
                    Text("\(rssi) dBm")
                        .font(.system(.body, design: .monospaced).weight(.bold))
                    Text(rssiBand(rssi))
                        .foregroundStyle(rssiColor(rssi))
                    Spacer()
                    if readings.count > 1 {
                        let values = readings.map(\.rssi)
                        Text("range \(values.min() ?? rssi)…\(values.max() ?? rssi)")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }

                HStack(spacing: 4) {
                    ForEach(readings) { reading in
                        Circle()
                            .fill(rssiColor(reading.rssi))
                            .frame(width: 9, height: 9)
                            .help("\(reading.rssi) dBm at \(reading.timestamp.formatted(date: .omitted, time: .standard))")
                    }
                }
            } else {
                Text(device.isConnected ? "RSSI unavailable" : "No live signal")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(10)
        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 8))
    }

    private func rssiBand(_ rssi: Int) -> String {
        if rssi >= -55 { return "strong" }
        if rssi >= -70 { return "moderate" }
        return "weak"
    }

    private func rssiColor(_ rssi: Int) -> Color {
        if rssi >= -55 { return .green }
        if rssi >= -70 { return .orange }
        return .red
    }
}

@MainActor
private final class MonitorAppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
    private let bluetoothViewModel = BluetoothViewModel()
    private let cameraViewModel: MonitorViewModel
    private var window: NSWindow?

    init(options: CLIOptions) {
        cameraViewModel = MonitorViewModel(options: options)
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1480, height: 860),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "CatGuard Sensor Monitor"
        window.center()
        window.contentViewController = NSHostingController(
            rootView: MonitorView(
                bluetoothModel: bluetoothViewModel,
                cameraModel: cameraViewModel
            )
        )
        window.delegate = self
        window.isReleasedWhenClosed = false
        window.makeKeyAndOrderFront(nil)
        self.window = window

        NSApplication.shared.activate(ignoringOtherApps: true)
        bluetoothViewModel.start()
        cameraViewModel.start()
    }

    func windowWillClose(_ notification: Notification) {
        stopMonitoring()
        NSApplication.shared.terminate(nil)
    }

    func applicationWillTerminate(_ notification: Notification) {
        stopMonitoring()
    }

    private func stopMonitoring() {
        bluetoothViewModel.stop()
        cameraViewModel.stop()
    }
}

@MainActor
func runMonitor(options: CLIOptions) -> Int32 {
    let application = NSApplication.shared
    let delegate = MonitorAppDelegate(options: options)
    application.delegate = delegate
    application.setActivationPolicy(.regular)
    application.run()
    return 0
}
