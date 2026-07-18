import CatGuardCore
import Foundation

@MainActor
private func run() -> Int32 {
    do {
        let options = try CLIOptions.parse(CommandLine.arguments)
        switch options.command {
        case "help":
            printUsage()
            return 0

        case "monitor":
            return runMonitor(options: options)

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
    } catch let CLIError.invalidArguments(message) {
        fputs("error: \(message)\n\n", stderr)
        printUsage()
        return 64
    } catch {
        fputs("CatGuard: UNCERTAIN\n", stderr)
        fputs("camera: UNAVAILABLE\n", stderr)
        fputs("physical input: ENABLED (fail-safe)\n", stderr)
        fputs("error: \(error.localizedDescription)\n", stderr)
        return 3
    }
}

exit(run())
