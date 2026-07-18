@preconcurrency import AVFoundation
import CoreMedia
import Foundation

struct CameraSample: @unchecked Sendable {
    let cameraName: String
    let pixelBuffer: CVPixelBuffer
}

final class SingleFrameReceiver: NSObject, AVCaptureVideoDataOutputSampleBufferDelegate, @unchecked Sendable {
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

enum CameraProbe {
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
