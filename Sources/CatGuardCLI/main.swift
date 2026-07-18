@preconcurrency import AVFoundation
import CatGuardCore
import CoreMedia
import CoreML
import Foundation
@preconcurrency import Vision

private struct CLIOptions {
    var command = "status"
    var cameraName: String?
    var allowBuiltInCamera = false
    var confidenceThreshold: Float = 0.6
    var timeout: TimeInterval = 8

    static func parse(_ arguments: [String]) throws -> CLIOptions {
        var options = CLIOptions()
        var arguments = Array(arguments.dropFirst())

        if let first = arguments.first, !first.hasPrefix("-") {
            options.command = first
            arguments.removeFirst()
        }

        var index = 0
        while index < arguments.count {
            switch arguments[index] {
            case "--allow-built-in":
                options.allowBuiltInCamera = true
            case "--camera":
                index += 1
                guard index < arguments.count else {
                    throw CLIError.invalidArguments("--camera requires part of a camera name")
                }
                options.cameraName = arguments[index]
            case "--threshold":
                index += 1
                guard index < arguments.count,
                      let value = Float(arguments[index]),
                      (0...1).contains(value)
                else {
                    throw CLIError.invalidArguments("--threshold must be between 0 and 1")
                }
                options.confidenceThreshold = value
            case "--timeout":
                index += 1
                guard index < arguments.count,
                      let value = TimeInterval(arguments[index]),
                      value > 0
                else {
                    throw CLIError.invalidArguments("--timeout must be greater than zero")
                }
                options.timeout = value
            case "-h", "--help":
                options.command = "help"
            default:
                throw CLIError.invalidArguments("unknown option: \(arguments[index])")
            }
            index += 1
        }

        return options
    }
}

private enum CLIError: LocalizedError {
    case invalidArguments(String)
    case cameraPermissionDenied
    case noCameraFound
    case cannotAddCameraInput
    case cannotAddVideoOutput
    case timedOut
    case visionTimedOut

    var errorDescription: String? {
        switch self {
        case let .invalidArguments(message): message
        case .cameraPermissionDenied:
            "camera access is denied; enable it in System Settings > Privacy & Security > Camera"
        case .noCameraFound:
            "no matching external camera was found"
        case .cannotAddCameraInput: "the selected camera could not be attached to the capture session"
        case .cannotAddVideoOutput: "the video output could not be attached to the capture session"
        case .timedOut: "the camera did not return a frame before the timeout"
        case .visionTimedOut: "human detection did not finish before the timeout"
        }
    }
}

private struct CameraSample {
    let cameraName: String
    let pixelBuffer: CVPixelBuffer
}

private final class SingleFrameReceiver: NSObject, AVCaptureVideoDataOutputSampleBufferDelegate, @unchecked Sendable {
    private let lock = NSLock()
    private let frameReady = DispatchSemaphore(value: 0)
    private var receivedPixelBuffer: CVPixelBuffer?

    func captureOutput(
        _ output: AVCaptureOutput,
        didOutput sampleBuffer: CMSampleBuffer,
        from connection: AVCaptureConnection
    ) {
        guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }

        lock.lock()
        defer { lock.unlock() }

        guard receivedPixelBuffer == nil else { return }
        receivedPixelBuffer = pixelBuffer
        frameReady.signal()
    }

    func waitForFrame(timeout: TimeInterval) -> CVPixelBuffer? {
        guard frameReady.wait(timeout: .now() + timeout) == .success else { return nil }

        lock.lock()
        defer { lock.unlock() }
        return receivedPixelBuffer
    }
}

private enum CameraProbe {
    static func captureFrame(options: CLIOptions) throws -> CameraSample {
        try requireCameraAccess()

        let camera = try selectCamera(options: options)
        let input = try AVCaptureDeviceInput(device: camera)
        let output = AVCaptureVideoDataOutput()
        output.alwaysDiscardsLateVideoFrames = true
        output.videoSettings = [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
        ]

        let receiver = SingleFrameReceiver()
        let captureQueue = DispatchQueue(label: "dk.catguard.capture", qos: .utility)
        output.setSampleBufferDelegate(receiver, queue: captureQueue)

        let session = AVCaptureSession()
        session.beginConfiguration()
        session.sessionPreset = .vga640x480
        guard session.canAddInput(input) else { throw CLIError.cannotAddCameraInput }
        session.addInput(input)
        guard session.canAddOutput(output) else { throw CLIError.cannotAddVideoOutput }
        session.addOutput(output)
        session.commitConfiguration()

        session.startRunning()
        defer { session.stopRunning() }

        guard let pixelBuffer = receiver.waitForFrame(timeout: options.timeout) else {
            throw CLIError.timedOut
        }

        return CameraSample(cameraName: camera.localizedName, pixelBuffer: pixelBuffer)
    }

    private static func requireCameraAccess() throws {
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized:
            return
        case .notDetermined:
            let result = LockedValue(false)
            let completed = DispatchSemaphore(value: 0)
            AVCaptureDevice.requestAccess(for: .video) { granted in
                result.set(granted)
                completed.signal()
            }
            completed.wait()
            guard result.get() else { throw CLIError.cameraPermissionDenied }
        case .denied, .restricted:
            throw CLIError.cameraPermissionDenied
        @unknown default:
            throw CLIError.cameraPermissionDenied
        }
    }

    private static func selectCamera(options: CLIOptions) throws -> AVCaptureDevice {
        var deviceTypes: [AVCaptureDevice.DeviceType] = [.external]
        if options.allowBuiltInCamera {
            deviceTypes.append(.builtInWideAngleCamera)
        }

        let devices = AVCaptureDevice.DiscoverySession(
            deviceTypes: deviceTypes,
            mediaType: .video,
            position: .unspecified
        ).devices

        let matchingDevices: [AVCaptureDevice]
        if let cameraName = options.cameraName {
            matchingDevices = devices.filter {
                $0.localizedName.localizedCaseInsensitiveContains(cameraName)
            }
        } else {
            matchingDevices = devices
        }

        guard let camera = matchingDevices.first(where: { $0.deviceType == .external })
            ?? matchingDevices.first
        else {
            throw CLIError.noCameraFound
        }

        return camera
    }
}

private final class LockedValue<Value>: @unchecked Sendable {
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

private final class HumanDetectionTask: @unchecked Sendable {
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

private enum HumanDetector {
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

private func printUsage() {
    print(
        """
        CatGuard presence indicator

        Usage:
          catguard status [--camera NAME] [--threshold 0...1] [--timeout SECONDS]
                          [--allow-built-in]
          catguard help

        A single negative sample is UNCERTAIN, never AWAY. This first milestone does
        not disconnect input devices or run a background daemon.
        """
    )
}

private func run() -> Int32 {
    do {
        let options = try CLIOptions.parse(CommandLine.arguments)
        switch options.command {
        case "help":
            printUsage()
            return 0
        case "status":
            let sample = try CameraProbe.captureFrame(options: options)
            let confidence = try HumanDetector.confidence(in: sample.pixelBuffer)

            var stateMachine = PresenceStateMachine(
                configuration: .init(confidenceThreshold: options.confidenceThreshold)
            )
            let state = stateMachine.observe(.detection(confidence: confidence))

            print("CatGuard: \(state.rawValue)")
            print("camera: \(sample.cameraName)")
            print(String(format: "confidence: %.3f", confidence))
            print("physical input: ENABLED (indicator-only milestone)")
            return state == .present ? 0 : 2
        default:
            throw CLIError.invalidArguments("unknown command: \(options.command)")
        }
    } catch let error as CLIError {
        fputs("CatGuard: UNCERTAIN\n", stderr)
        fputs("camera: UNAVAILABLE\n", stderr)
        fputs("physical input: ENABLED (fail-safe)\n", stderr)
        fputs("error: \(error.localizedDescription)\n", stderr)
        return 3
    } catch {
        fputs("CatGuard: UNCERTAIN\n", stderr)
        fputs("camera: UNAVAILABLE\n", stderr)
        fputs("physical input: ENABLED (fail-safe)\n", stderr)
        fputs("error: \(error.localizedDescription)\n", stderr)
        return 3
    }
}

exit(run())
