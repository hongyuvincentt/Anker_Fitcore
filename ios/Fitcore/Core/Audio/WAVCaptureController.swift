import Combine
import Foundation

enum MicrophoneCaptureEvent: Sendable {
    case finished(recordingID: UUID, successfully: Bool, errorDescription: String?)
    case interrupted(recordingID: UUID, reason: String)
}

@MainActor
protocol MicrophoneCaptureBackend: AnyObject {
    var eventHandler: (@MainActor (MicrophoneCaptureEvent) -> Void)? { get set }
    func requestPermission() async -> Bool
    func startRecording(to url: URL, recordingID: UUID) throws
    func stopRecording()
    func cancelRecording()
}

struct WAVCaptureMetadata: Codable, Equatable, Sendable {
    let schemaVersion: Int
    let recordingID: String
    let utteranceID: String
    let recordedAt: Date
    let completedAt: Date
    let deviceType: String
    let recordingSource: String
    let isSimulated: Bool
    let localRecordingConsent: Bool
    let fileName: String
    let inspection: WAVInspection

    enum CodingKeys: String, CodingKey {
        case schemaVersion = "schema_version"
        case recordingID = "recording_id"
        case utteranceID = "utterance_id"
        case recordedAt = "recorded_at"
        case completedAt = "completed_at"
        case deviceType = "device_type"
        case recordingSource = "recording_source"
        case isSimulated = "is_simulated"
        case localRecordingConsent = "local_recording_consent"
        case fileName = "file_name"
        case inspection
    }
}

struct CapturedWAV: Identifiable, Equatable, Sendable {
    var id: String { metadata.recordingID }
    let fileURL: URL
    let metadataURL: URL
    let metadata: WAVCaptureMetadata
}

/// Owns local recording identity and acceptance. No network or training facts.
@MainActor
final class WAVCaptureController: ObservableObject {
    enum Phase: Equatable {
        case idle, requestingPermission, recording, validating, ready
        case failed(String)
    }

    @Published private(set) var phase: Phase = .idle
    @Published private(set) var recordings: [CapturedWAV] = []
    @Published private(set) var startedAt: Date?
    @Published private(set) var needsPermissionSettings = false

    var isBusy: Bool {
        switch phase {
        case .requestingPermission, .recording, .validating: return true
        default: return false
        }
    }

    private struct ActiveCapture {
        let id: UUID
        let fileURL: URL
        let recordedAt: Date
    }

    private let backend: any MicrophoneCaptureBackend
    private let storageDirectory: URL
    private let isSimulated: Bool
    private var permissionRequestID: UUID?
    private var active: ActiveCapture?

    init(backend: any MicrophoneCaptureBackend, storageDirectory: URL, isSimulated: Bool) {
        self.backend = backend
        self.storageDirectory = storageDirectory.standardizedFileURL
        self.isSimulated = isSimulated
        backend.eventHandler = { [weak self] event in self?.receive(event) }
        reload()
    }

    func start(localConsent: Bool) async {
        guard !isBusy else { return }
        guard localConsent else {
            phase = .failed("请先确认同意本机录音。")
            return
        }
        needsPermissionSettings = false
        let requestID = UUID()
        permissionRequestID = requestID
        phase = .requestingPermission
        let allowed = await backend.requestPermission()
        guard permissionRequestID == requestID else { return }
        permissionRequestID = nil
        guard allowed else {
            needsPermissionSettings = true
            phase = .failed("麦克风权限未开启，请在 iPhone 设置中允许 Fitcore 使用麦克风。")
            return
        }
        do {
            let id = UUID()
            let folder = storageDirectory.appendingPathComponent(id.uuidString, isDirectory: true)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let file = folder.appendingPathComponent(id.uuidString + ".wav")
            let capture = ActiveCapture(id: id, fileURL: file, recordedAt: Date())
            active = capture
            startedAt = capture.recordedAt
            phase = .recording
            try backend.startRecording(to: file, recordingID: id)
        } catch {
            active = nil
            startedAt = nil
            phase = .failed("无法开始录音：\(error.localizedDescription)")
        }
    }

    func stop() {
        guard phase == .recording else { return }
        phase = .validating
        backend.stopRecording()
        // Accept only the recorder's completion callback, never merely its URL.
    }

    func cancel() {
        permissionRequestID = nil
        let cancelled = active
        active = nil
        startedAt = nil
        backend.cancelRecording()
        // This is the one explicitly cancelled, app-owned recording, not a sweep.
        if let cancelled { try? FileManager.default.removeItem(at: cancelled.fileURL) }
        phase = .idle
    }

    func interrupt(reason: String) {
        if let active {
            receive(.interrupted(recordingID: active.id, reason: reason))
        } else if phase == .requestingPermission {
            cancel()
        }
    }

    /// Recheck original bytes before exposing files to the system share sheet.
    func exportURLs(for recording: CapturedWAV) -> [URL] {
        guard !isBusy, recordings.contains(recording) else { return [] }
        do {
            let current = try WAVFileValidator.inspect(url: recording.fileURL)
            guard current == recording.metadata.inspection else {
                throw CaptureError.originalChanged
            }
            let stored = try Self.decoder().decode(WAVCaptureMetadata.self, from: Data(contentsOf: recording.metadataURL))
            guard stored == recording.metadata else { throw CaptureError.originalChanged }
            return [recording.fileURL, recording.metadataURL]
        } catch {
            phase = .failed("这段录音无法导出：\(error.localizedDescription)")
            return []
        }
    }

    func delete(_ recording: CapturedWAV) {
        guard !isBusy, recordings.contains(recording),
              recording.fileURL.deletingLastPathComponent().deletingLastPathComponent().standardizedFileURL == storageDirectory else { return }
        do {
            // One recording selected and confirmed by the user, including sidecar.
            try FileManager.default.removeItem(at: recording.fileURL.deletingLastPathComponent())
            recordings.removeAll { $0.id == recording.id }
            phase = recordings.isEmpty ? .idle : .ready
        } catch {
            phase = .failed("删除失败：\(error.localizedDescription)")
        }
    }

    private func receive(_ event: MicrophoneCaptureEvent) {
        switch event {
        case .interrupted(let id, let reason):
            guard let capture = active, capture.id == id else { return }
            active = nil
            startedAt = nil
            backend.cancelRecording()
            writeFailure(capture, reason: reason)
            phase = .failed("录音已中断：\(reason)。本段未计为有效样本，请重新录制。")
        case .finished(let id, let successfully, let description):
            guard let capture = active, capture.id == id else { return }
            active = nil
            startedAt = nil
            phase = .validating
            do {
                guard successfully else { throw CaptureError.recordingFailed(description ?? "音频录制未成功完成") }
                let inspection = try WAVFileValidator.inspect(url: capture.fileURL)
                let metadata = WAVCaptureMetadata(
                    schemaVersion: 1, recordingID: id.uuidString, utteranceID: id.uuidString,
                    recordedAt: capture.recordedAt, completedAt: Date(), deviceType: "iphone",
                    recordingSource: "iphone_microphone", isSimulated: isSimulated,
                    localRecordingConsent: true, fileName: capture.fileURL.lastPathComponent,
                    inspection: inspection
                )
                let metadataURL = capture.fileURL.deletingPathExtension().appendingPathExtension("metadata.json")
                let encoder = JSONEncoder()
                encoder.dateEncodingStrategy = .iso8601
                encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
                try encoder.encode(metadata).write(to: metadataURL, options: .withoutOverwriting)
                // Decode the persisted precision so later integrity comparisons match.
                let saved = try Self.decoder().decode(WAVCaptureMetadata.self, from: Data(contentsOf: metadataURL))
                recordings.insert(CapturedWAV(fileURL: capture.fileURL, metadataURL: metadataURL, metadata: saved), at: 0)
                phase = .ready
            } catch {
                writeFailure(capture, reason: error.localizedDescription)
                phase = .failed(error.localizedDescription)
            }
        }
    }

    private func reload() {
        guard let folders = try? FileManager.default.contentsOfDirectory(at: storageDirectory, includingPropertiesForKeys: [.isDirectoryKey]) else { return }
        recordings = folders.compactMap { folder in
            let name = folder.lastPathComponent
            guard UUID(uuidString: name) != nil else { return nil }
            let metadataURL = folder.appendingPathComponent(name + ".metadata.json")
            guard let data = try? Data(contentsOf: metadataURL),
                  let metadata = try? Self.decoder().decode(WAVCaptureMetadata.self, from: data),
                  metadata.recordingID == name, metadata.fileName == name + ".wav",
                  metadata.localRecordingConsent else { return nil }
            let file = folder.appendingPathComponent(metadata.fileName)
            guard let inspection = try? WAVFileValidator.inspect(url: file),
                  inspection == metadata.inspection else { return nil }
            return CapturedWAV(fileURL: file, metadataURL: metadataURL, metadata: metadata)
        }.sorted { $0.metadata.recordedAt > $1.metadata.recordedAt }
    }

    private func writeFailure(_ capture: ActiveCapture, reason: String) {
        let report = ["recording_id": capture.id.uuidString, "status": "not_accepted", "reason": reason]
        guard let data = try? JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]) else { return }
        try? data.write(to: capture.fileURL.deletingLastPathComponent().appendingPathComponent("capture-failure.json"), options: .atomic)
    }

    private static func decoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }

    private enum CaptureError: LocalizedError {
        case originalChanged
        case recordingFailed(String)
        var errorDescription: String? {
            switch self {
            case .originalChanged: return "原始文件或元数据已变化，未通过完整性检查。"
            case .recordingFailed(let reason): return reason
            }
        }
    }
}
