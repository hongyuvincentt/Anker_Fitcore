import Foundation
import XCTest
@testable import WAVCaptureKit

@MainActor
private final class FakeMicrophone: MicrophoneCaptureBackend {
    var eventHandler: (@MainActor (MicrophoneCaptureEvent) -> Void)?
    var permitted = true
    var permissionRequests = 0
    var startCount = 0
    var stopCount = 0
    var shouldFailStart = false
    var permissionWaiter: CheckedContinuation<Bool, Never>?
    var holdPermission = false
    var activeID: UUID?
    var activeURL: URL?

    func requestPermission() async -> Bool {
        permissionRequests += 1
        if holdPermission {
            return await withCheckedContinuation { permissionWaiter = $0 }
        }
        return permitted
    }

    func startRecording(to url: URL, recordingID: UUID) throws {
        if shouldFailStart { throw CocoaError(.fileWriteUnknown) }
        startCount += 1
        activeID = recordingID
        activeURL = url
    }

    func stopRecording() { stopCount += 1 }
    func cancelRecording() { activeID = nil; activeURL = nil }

    func finish(data: Data) throws {
        let id = try XCTUnwrap(activeID)
        try data.write(to: XCTUnwrap(activeURL))
        eventHandler?(.finished(recordingID: id, successfully: true, errorDescription: nil))
    }
}

final class WAVCaptureControllerTests: XCTestCase {
    @MainActor
    func testConsentIsRequiredBeforePermissionOrRecording() async throws {
        let (controller, mic, _) = try makeController()
        await controller.start(localConsent: false)
        XCTAssertEqual(mic.permissionRequests, 0)
        XCTAssertEqual(mic.startCount, 0)
        XCTAssertTrue(controller.recordings.isEmpty)
        guard case .failed = controller.phase else { return XCTFail("Consent rejection must be visible") }
    }

    @MainActor
    func testPermissionDenialDoesNotCreateValidRecording() async throws {
        let (controller, mic, _) = try makeController()
        mic.permitted = false
        await controller.start(localConsent: true)
        XCTAssertEqual(mic.startCount, 0)
        XCTAssertTrue(controller.needsPermissionSettings)
        XCTAssertTrue(controller.recordings.isEmpty)
    }

    @MainActor
    func testCancellingWhilePermissionIsPendingCannotStartLater() async throws {
        let (controller, mic, _) = try makeController()
        mic.holdPermission = true
        let request = Task { await controller.start(localConsent: true) }
        while mic.permissionWaiter == nil { await Task.yield() }
        controller.cancel()
        mic.permissionWaiter?.resume(returning: true)
        await request.value
        XCTAssertEqual(mic.startCount, 0)
        XCTAssertEqual(controller.phase, .idle)
    }

    @MainActor
    func testDuplicateStartCannotReplaceAnActiveRecording() async throws {
        let (controller, mic, _) = try makeController()
        await controller.start(localConsent: true)
        let id = mic.activeID
        await controller.start(localConsent: true)
        XCTAssertEqual(mic.startCount, 1)
        XCTAssertEqual(mic.permissionRequests, 1)
        XCTAssertEqual(mic.activeID, id)
        XCTAssertEqual(controller.phase, .recording)
    }

    @MainActor
    func testValidCompletionPersistsIdentityMetadataAndReloads() async throws {
        let (controller, mic, directory) = try makeController()
        await controller.start(localConsent: true)
        let id = try XCTUnwrap(mic.activeID)
        controller.stop()
        XCTAssertEqual(controller.phase, .validating)
        XCTAssertEqual(mic.stopCount, 1)
        try mic.finish(data: audibleWAV())
        XCTAssertEqual(controller.phase, .ready)
        let recording = try XCTUnwrap(controller.recordings.first)
        XCTAssertEqual(recording.metadata.recordingID, id.uuidString)
        XCTAssertEqual(recording.metadata.utteranceID, id.uuidString)
        XCTAssertTrue(recording.metadata.localRecordingConsent)
        XCTAssertEqual(recording.metadata.inspection.sampleRate, 16_000)
        XCTAssertEqual(controller.exportURLs(for: recording).count, 2)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: recording.metadataURL)) as? [String: Any])
        XCTAssertEqual(json["recording_id"] as? String, id.uuidString)
        XCTAssertEqual(json["recording_source"] as? String, "iphone_microphone")
        XCTAssertEqual(json["is_simulated"] as? Bool, false)
        XCTAssertNil(json["aws_model_processing_allowed"])
        let reloaded = WAVCaptureController(backend: FakeMicrophone(), storageDirectory: directory, isSimulated: false)
        XCTAssertEqual(reloaded.recordings.map(\.id), [id.uuidString])
    }

    @MainActor
    func testSilenceCannotBecomeAValidExport() async throws {
        let (controller, mic, _) = try makeController()
        await controller.start(localConsent: true)
        try mic.finish(data: audibleWAV(silent: true))
        guard case .failed = controller.phase else { return XCTFail("Silence must fail validation") }
        XCTAssertTrue(controller.recordings.isEmpty)
    }

    @MainActor
    func testInterruptionAndLateCompletionCannotCreateSuccess() async throws {
        let (controller, mic, _) = try makeController()
        await controller.start(localConsent: true)
        let id = try XCTUnwrap(mic.activeID)
        let url = try XCTUnwrap(mic.activeURL)
        try audibleWAV().write(to: url)
        mic.eventHandler?(.interrupted(recordingID: id, reason: "测试音频中断"))
        mic.eventHandler?(.finished(recordingID: id, successfully: true, errorDescription: nil))
        guard case .failed = controller.phase else { return XCTFail("Interrupted audio must not be accepted") }
        XCTAssertTrue(controller.recordings.isEmpty)
    }

    @MainActor
    func testReRecordingPreservesEarlierOriginalAndUsesNewID() async throws {
        let (controller, mic, _) = try makeController()
        await controller.start(localConsent: true)
        try mic.finish(data: audibleWAV())
        let first = try XCTUnwrap(controller.recordings.first)
        let original = try Data(contentsOf: first.fileURL)
        await controller.start(localConsent: true)
        try mic.finish(data: audibleWAV())
        XCTAssertEqual(controller.recordings.count, 2)
        XCTAssertNotEqual(controller.recordings[0].id, first.id)
        XCTAssertEqual(try Data(contentsOf: first.fileURL), original)
    }

    @MainActor
    func testChangedAudioIsRejectedBeforeSharing() async throws {
        let (controller, mic, _) = try makeController()
        await controller.start(localConsent: true)
        try mic.finish(data: audibleWAV())
        let recording = try XCTUnwrap(controller.recordings.first)
        var changed = try Data(contentsOf: recording.fileURL)
        changed[44] ^= 1
        try changed.write(to: recording.fileURL)
        XCTAssertTrue(controller.exportURLs(for: recording).isEmpty)
        guard case .failed = controller.phase else { return XCTFail("Changed original must be reported") }
    }

    @MainActor
    func testSimulatorMetadataIsAlwaysExplicit() async throws {
        let mic = FakeMicrophone()
        let controller = WAVCaptureController(backend: mic, storageDirectory: try temporaryDirectory(), isSimulated: true)
        await controller.start(localConsent: true)
        try mic.finish(data: audibleWAV())
        XCTAssertEqual(controller.recordings.first?.metadata.isSimulated, true)
    }

    @MainActor
    func testReloadRejectsChangedInspectionEvenWhenAudioHashMatches() async throws {
        let (controller, mic, directory) = try makeController()
        await controller.start(localConsent: true)
        try mic.finish(data: audibleWAV())
        let recording = try XCTUnwrap(controller.recordings.first)
        var json = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: recording.metadataURL)) as? [String: Any])
        var inspection = try XCTUnwrap(json["inspection"] as? [String: Any])
        inspection["frame_count"] = 999
        inspection["duration_seconds"] = 99.0
        json["inspection"] = inspection
        try JSONSerialization.data(withJSONObject: json).write(to: recording.metadataURL)
        let reloaded = WAVCaptureController(backend: FakeMicrophone(), storageDirectory: directory, isSimulated: false)
        XCTAssertTrue(reloaded.recordings.isEmpty, "Persisted inspection must match the actual WAV, not just its SHA")
    }

    @MainActor
    private func makeController() throws -> (WAVCaptureController, FakeMicrophone, URL) {
        let directory = try temporaryDirectory()
        let mic = FakeMicrophone()
        return (WAVCaptureController(backend: mic, storageDirectory: directory, isSimulated: false), mic, directory)
    }

    private func temporaryDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("fitcore-capture-tests-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    private func audibleWAV(silent: Bool = false) -> Data {
        var data = Data()
        func ascii(_ s: String) { data.append(contentsOf: s.utf8) }
        func le16(_ n: UInt16) { data.append(UInt8(n & 255)); data.append(UInt8(n >> 8)) }
        func le32(_ n: UInt32) { for shift in stride(from: 0, to: 32, by: 8) { data.append(UInt8((n >> shift) & 255)) } }
        let frames: UInt32 = 1600
        ascii("RIFF"); le32(36 + frames * 2); ascii("WAVEfmt "); le32(16)
        le16(1); le16(1); le32(16_000); le32(32_000); le16(2); le16(16)
        ascii("data"); le32(frames * 2)
        for index in 0..<Int(frames) { le16(silent ? 0 : UInt16(bitPattern: Int16(index.isMultiple(of: 2) ? 4000 : -4000))) }
        return data
    }
}
