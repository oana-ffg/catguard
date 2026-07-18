import CoreMedia
import CoreML
import Foundation
@preconcurrency import Vision

final class LockedValue<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Value

    init(_ value: Value) {
        self.value = value
    }

    func get() -> Value {
        lock.lock()
        defer { lock.unlock() }
        return value
    }

    func set(_ newValue: Value) {
        lock.lock()
        defer { lock.unlock() }
        value = newValue
    }
}

final class HumanDetectionTask: @unchecked Sendable {
    private let request: VNDetectHumanRectanglesRequest
    private let handler: VNImageRequestHandler
    private let result = LockedValue<Result<Float, Error>?>(nil)
    let completed = DispatchSemaphore(value: 0)

    init(pixelBuffer: CVPixelBuffer) throws {
        request = VNDetectHumanRectanglesRequest()
        request.upperBodyOnly = true
        handler = VNImageRequestHandler(cvPixelBuffer: pixelBuffer, orientation: .up)

        for (stage, devices) in try request.supportedComputeStageDevices {
            guard let cpu = devices.first(where: { device in
                if case .cpu = device { return true }
                return false
            }) else { continue }

            request.setComputeDevice(cpu, for: stage)
        }
    }

    func run() {
        defer { completed.signal() }

        do {
            try handler.perform([request])
            result.set(.success(request.results?.map(\.confidence).max() ?? 0))
        } catch {
            result.set(.failure(error))
        }
    }

    func cancel() {
        request.cancel()
    }

    func confidence() throws -> Float {
        guard let result = result.get() else { throw CLIError.visionTimedOut }
        return try result.get()
    }
}

enum HumanDetector {
    static func confidence(
        in pixelBuffer: CVPixelBuffer,
        timeout: TimeInterval = 15
    ) throws -> Float {
        let task = try HumanDetectionTask(pixelBuffer: pixelBuffer)
        DispatchQueue.global(qos: .utility).async {
            task.run()
        }

        guard task.completed.wait(timeout: .now() + timeout) == .success else {
            task.cancel()
            throw CLIError.visionTimedOut
        }

        return try task.confidence()
    }
}
