import Foundation

enum RecorderEvent: Sendable {
    /// Emitted after a verified connection, including a known device reconnecting.
    case connected(RecorderDevice)
    /// A complete, current snapshot. Missing telemetry remains unknown.
    case deviceStateChanged(RecorderDevice)
    case recordingStarted
    case audioPacket(AudioPacket)
    case recordingStopped
    case transferDrained
    case disconnected
}

@MainActor
protocol RecorderGateway: AnyObject {
    var onEvent: ((RecorderEvent) -> Void)? { get set }
    func connect() async throws -> RecorderDevice
    func disconnect()
}

/// These controls belong to the simulator only. They are not remote start/stop SDK APIs.
@MainActor
protocol MockRecorderControlling: AnyObject {
    func simulateHardwareStart()
    func simulateHardwareStop()
}
