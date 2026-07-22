import Foundation

struct BluetoothDeviceSnapshot: Identifiable, Sendable {
    let name: String
    let isConnected: Bool
    let rssi: Int?

    var id: String { name }
}

enum BluetoothProbeError: LocalizedError {
    case commandFailed(Int32)
    case invalidOutput

    var errorDescription: String? {
        switch self {
        case let .commandFailed(status):
            "Bluetooth diagnostics exited with status \(status)"
        case .invalidOutput:
            "macOS returned malformed Bluetooth diagnostics"
        }
    }
}

enum BluetoothProbe {
    static func snapshot() throws -> [BluetoothDeviceSnapshot] {
        let process = Process()
        let output = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/sbin/system_profiler")
        process.arguments = ["SPBluetoothDataType", "-json"]
        process.standardOutput = output
        process.standardError = Pipe()

        try process.run()
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()

        guard process.terminationStatus == 0 else {
            throw BluetoothProbeError.commandFailed(process.terminationStatus)
        }

        return try parse(data: data)
    }

    private static func parse(data: Data) throws -> [BluetoothDeviceSnapshot] {
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let reports = root["SPBluetoothDataType"] as? [[String: Any]],
              let report = reports.first
        else {
            throw BluetoothProbeError.invalidOutput
        }

        var devices: [BluetoothDeviceSnapshot] = []
        devices += parseDevices(report["device_connected"], connected: true)
        devices += parseDevices(report["device_not_connected"], connected: false)

        return devices.sorted {
            if $0.isConnected != $1.isConnected {
                return $0.isConnected && !$1.isConnected
            }
            return $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
        }
    }

    private static func parseDevices(_ value: Any?, connected: Bool) -> [BluetoothDeviceSnapshot] {
        guard let deviceEntries = value as? [[String: Any]] else { return [] }

        return deviceEntries.flatMap { entry in
            entry.compactMap { name, rawProperties in
                guard let properties = rawProperties as? [String: Any] else { return nil }
                let rssi = connected
                    ? (properties["device_rssi"] as? String).flatMap(Int.init)
                    : nil

                return BluetoothDeviceSnapshot(
                    name: name,
                    isConnected: connected,
                    rssi: rssi
                )
            }
        }
    }
}
