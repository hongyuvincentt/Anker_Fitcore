import Foundation

@MainActor
final class MockRecorderGateway: RecorderGateway, MockRecorderControlling {
    var onEvent: ((RecorderEvent) -> Void)?
    private var connected = false
    private var recording = false

    func connect() async throws -> RecorderDevice {
        try await Task.sleep(for: .milliseconds(450))
        connected = true
        return RecorderDevice(
            name: "Soundcore Work · D3200", batteryPercent: 86, isSimulated: true,
            powerState: .on)
    }

    func disconnect() {
        connected = false
        recording = false
        onEvent?(.disconnected)
    }

    func simulateHardwareStart() {
        guard connected, !recording else { return }
        recording = true
        onEvent?(.recordingStarted)
    }

    func simulateHardwareStop() {
        guard recording else { return }
        recording = false
        onEvent?(.recordingStopped)
        // Only a Mock has nothing to drain. The real adapter must wait for transfer completion.
        onEvent?(.transferDrained)
    }
}
