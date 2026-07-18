@preconcurrency import AppKit
import Combine
import CoreImage
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
        case .waiting: "WAITING FOR FIRST SAMPLE"
        case .analyzing: "ANALYZING"
        case .human: "HUMAN DETECTED"
        case .noHuman: "NO HUMAN IN THIS SAMPLE"
        case .error: "CAMERA OR DETECTOR ERROR"
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

private struct DetectionRecord: Identifiable {
    let id = UUID()
    let timestamp: Date
    let humanDetected: Bool
    let confidence: Float
    let duration: TimeInterval
}

private struct MonitorSampleResult: @unchecked Sendable {
    let cameraName: String?
    let confidence: Float?
    let duration: TimeInterval
    let errorMessage: String?
    let frameImage: CGImage?
}

private final class MonitorSampler: @unchecked Sendable {
    private let imageContext = CIContext(options: [.cacheIntermediates: false])
    private let options: CLIOptions
    private let queue = DispatchQueue(label: "dk.catguard.monitor", qos: .utility)

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

                do {
                    let confidence = try HumanDetector.confidence(in: cameraSample.pixelBuffer)
                    let result = MonitorSampleResult(
                        cameraName: cameraSample.cameraName,
                        confidence: confidence,
                        duration: Date().timeIntervalSince(startedAt),
                        errorMessage: nil,
                        frameImage: frameImage
                    )
                    Task { @MainActor in completion(result) }
                } catch {
                    let result = MonitorSampleResult(
                        cameraName: cameraSample.cameraName,
                        confidence: nil,
                        duration: Date().timeIntervalSince(startedAt),
                        errorMessage: error.localizedDescription,
                        frameImage: frameImage
                    )
                    Task { @MainActor in completion(result) }
                }
            } catch {
                let result = MonitorSampleResult(
                    cameraName: nil,
                    confidence: nil,
                    duration: Date().timeIntervalSince(startedAt),
                    errorMessage: error.localizedDescription,
                    frameImage: nil
                )
                Task { @MainActor in completion(result) }
            }
        }
    }

    private func makeImage(from pixelBuffer: CVPixelBuffer) -> CGImage? {
        let image = CIImage(cvPixelBuffer: pixelBuffer)
        return imageContext.createCGImage(image, from: image.extent)
    }
}

@MainActor
private final class MonitorViewModel: NSObject, ObservableObject {
    @Published private(set) var cameraName = "External camera"
    @Published private(set) var confidence: Float?
    @Published private(set) var errorMessage: String?
    @Published private(set) var frameImage: CGImage?
    @Published private(set) var history: [DetectionRecord] = []
    @Published private(set) var status: MonitorStatus = .waiting

    let confidenceThreshold: Float
    let sampleInterval: TimeInterval

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

        confidence = result.confidence
        errorMessage = result.errorMessage

        if let confidence = result.confidence {
            let humanDetected = confidence >= confidenceThreshold
            status = humanDetected ? .human : .noHuman
            history.insert(
                DetectionRecord(
                    timestamp: Date(),
                    humanDetected: humanDetected,
                    confidence: confidence,
                    duration: result.duration
                ),
                at: 0
            )
            history = Array(history.prefix(10))
            writeLog(
                "sample=\(humanDetected ? "HUMAN" : "NO_HUMAN") "
                    + String(format: "confidence=%.3f duration=%.1fs", confidence, result.duration)
                    + " camera=\(cameraName)"
            )
        } else {
            status = .error
            writeLog("sample=ERROR error=\(result.errorMessage ?? "unknown error")")
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

    private func writeLog(_ message: String) {
        let timestamp = ISO8601DateFormatter().string(from: Date())
        guard let data = "\(timestamp) \(message)\n".data(using: .utf8) else { return }
        try? FileHandle.standardOutput.write(contentsOf: data)
    }
}

private struct MonitorView: View {
    @ObservedObject var model: MonitorViewModel

    var body: some View {
        HStack(alignment: .top, spacing: 20) {
            VStack(alignment: .leading, spacing: 14) {
                frame
                currentResult
                diagnostics
            }
            .frame(minWidth: 640)

            history
                .frame(width: 285)
        }
        .padding(20)
        .frame(minWidth: 980, minHeight: 700)
        .background(Color(nsColor: .windowBackgroundColor))
    }

    private var frame: some View {
        ZStack {
            Color.black

            if let frameImage = model.frameImage {
                Image(decorative: frameImage, scale: 1)
                    .resizable()
                    .scaledToFit()
            } else {
                VStack(spacing: 10) {
                    ProgressView()
                    Text("Waiting for the first camera sample…")
                        .foregroundStyle(.secondary)
                }
            }
        }
        .aspectRatio(4 / 3, contentMode: .fit)
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .overlay {
            RoundedRectangle(cornerRadius: 12)
                .stroke(model.status.color, lineWidth: 4)
        }
    }

    private var currentResult: some View {
        HStack(spacing: 12) {
            Circle()
                .fill(model.status.color)
                .frame(width: 18, height: 18)

            Text(model.status.title)
                .font(.title2.weight(.bold))
                .foregroundStyle(model.status.color)

            Spacer()

            if let confidence = model.confidence {
                Text(String(format: "confidence %.3f", confidence))
                    .font(.system(.body, design: .monospaced).weight(.semibold))
            }
        }
        .padding(14)
        .background(model.status.color.opacity(0.12), in: RoundedRectangle(cornerRadius: 10))
    }

    private var diagnostics: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(model.cameraName)
                .font(.headline)
            Text(
                "Sampling every \(model.sampleInterval.formatted(.number.precision(.fractionLength(0...1))))s · "
                    + "human threshold \(model.confidenceThreshold.formatted(.number.precision(.fractionLength(2))))"
            )
            .foregroundStyle(.secondary)
            Text("Safety state remains UNCERTAIN and physical input remains ENABLED in monitor mode.")
                .font(.callout.weight(.semibold))

            if let errorMessage = model.errorMessage {
                Text(errorMessage)
                    .foregroundStyle(.orange)
            }
        }
    }

    private var history: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Last 10 detections")
                .font(.title3.weight(.bold))

            if model.history.isEmpty {
                Text("Results will appear here after each analyzed sample.")
                    .foregroundStyle(.secondary)
            } else {
                ScrollView {
                    LazyVStack(spacing: 8) {
                        ForEach(model.history) { record in
                            HStack(spacing: 10) {
                                Circle()
                                    .fill(record.humanDetected ? Color.green : Color.red)
                                    .frame(width: 12, height: 12)

                                VStack(alignment: .leading, spacing: 2) {
                                    Text(record.humanDetected ? "Human" : "No human")
                                        .fontWeight(.semibold)
                                    Text(record.timestamp, style: .time)
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }

                                Spacer()

                                VStack(alignment: .trailing, spacing: 2) {
                                    Text(String(format: "%.3f", record.confidence))
                                        .font(.system(.callout, design: .monospaced))
                                    Text(String(format: "%.1fs", record.duration))
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                            }
                            .padding(10)
                            .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 8))
                        }
                    }
                }
            }

            Spacer()

            Text("Frames are held in memory only. Detection history contains metadata, never images.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }
}

@MainActor
private final class MonitorAppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
    private let viewModel: MonitorViewModel
    private var window: NSWindow?

    init(options: CLIOptions) {
        viewModel = MonitorViewModel(options: options)
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1040, height: 740),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "CatGuard Presence Monitor"
        window.center()
        window.contentViewController = NSHostingController(rootView: MonitorView(model: viewModel))
        window.delegate = self
        window.isReleasedWhenClosed = false
        window.makeKeyAndOrderFront(nil)
        self.window = window

        NSApplication.shared.activate(ignoringOtherApps: true)
        viewModel.start()
    }

    func windowWillClose(_ notification: Notification) {
        viewModel.stop()
        NSApplication.shared.terminate(nil)
    }

    func applicationWillTerminate(_ notification: Notification) {
        viewModel.stop()
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
