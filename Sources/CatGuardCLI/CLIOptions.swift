import Foundation

struct CLIOptions: Sendable {
    var command = "status"
    var cameraName: String?
    var allowBuiltInCamera = false
    var confidenceThreshold: Float = 0.6
    var sampleInterval: TimeInterval = 5
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

            case "--interval":
                index += 1
                guard index < arguments.count,
                      let value = TimeInterval(arguments[index]),
                      value > 0
                else {
                    throw CLIError.invalidArguments("--interval must be greater than zero")
                }
                options.sampleInterval = value

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

enum CLIError: LocalizedError {
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

func printUsage() {
    print(
        """
        CatGuard presence indicator

        Usage:
          catguard status [--camera NAME] [--threshold 0...1] [--timeout SECONDS]
                          [--allow-built-in]
          catguard monitor [--interval SECONDS] [--camera NAME]
                           [--threshold 0...1] [--timeout SECONDS]
                           [--allow-built-in]
          catguard help

        The monitor displays only the current in-memory sample and the latest 10
        detection results. Frames are never saved or recorded. This milestone does
        not disconnect input devices or run a background daemon.
        """
    )
}
