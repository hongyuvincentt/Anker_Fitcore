#if os(iOS)
import AVFoundation
import Combine
import Foundation

@MainActor
final class IPhoneMicrophoneBackend: NSObject, MicrophoneCaptureBackend, AVAudioRecorderDelegate {
    var eventHandler: (@MainActor (MicrophoneCaptureEvent) -> Void)?
    private var recorder: AVAudioRecorder?
    private var activeID: UUID?
    private var subscriptions = Set<AnyCancellable>()
    private var previousSession: (AVAudioSession.Category, AVAudioSession.Mode, AVAudioSession.CategoryOptions)?

    override init() {
        super.init()
        NotificationCenter.default.publisher(for: AVAudioSession.interruptionNotification)
            .receive(on: RunLoop.main)
            .sink { [weak self] note in
                guard let value = note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt,
                      value == AVAudioSession.InterruptionType.began.rawValue else { return }
                self?.interrupted("系统音频中断")
            }.store(in: &subscriptions)
        NotificationCenter.default.publisher(for: AVAudioSession.routeChangeNotification)
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                guard self?.activeID != nil else { return }
                let inputs = AVAudioSession.sharedInstance().currentRoute.inputs
                if !inputs.contains(where: { $0.portType == .builtInMic }) {
                    self?.interrupted("麦克风输入发生变化")
                }
            }.store(in: &subscriptions)
    }

    func requestPermission() async -> Bool {
        await AVAudioApplication.requestRecordPermission()
    }

    func startRecording(to url: URL, recordingID: UUID) throws {
        guard recorder == nil else { throw RecordingError.alreadyRecording }
        let session = AVAudioSession.sharedInstance()
        previousSession = (session.category, session.mode, session.categoryOptions)
        do {
            try session.setCategory(.playAndRecord, mode: .default, options: [.defaultToSpeaker])
            try session.setPreferredSampleRate(16_000)
            try session.setActive(true)
            guard let microphone = session.availableInputs?.first(where: { $0.portType == .builtInMic }) else {
                throw RecordingError.noBuiltInMicrophone
            }
            try session.setPreferredInput(microphone)
            let settings: [String: Any] = [
                AVFormatIDKey: Int(kAudioFormatLinearPCM),
                AVSampleRateKey: 16_000.0,
                AVNumberOfChannelsKey: 1,
                AVLinearPCMBitDepthKey: 16,
                AVLinearPCMIsFloatKey: false,
                AVLinearPCMIsBigEndianKey: false,
                AVLinearPCMIsNonInterleaved: false
            ]
            let candidate = try AVAudioRecorder(url: url, settings: settings)
            candidate.delegate = self
            recorder = candidate
            activeID = recordingID
            // 200s of PCM16 mono 16kHz stays below the 7,000,000-byte limit.
            guard candidate.record(forDuration: 200) else { throw RecordingError.unableToStart }
        } catch {
            recorder?.delegate = nil
            recorder?.stop()
            recorder = nil
            activeID = nil
            restoreSession()
            throw error
        }
    }

    func stopRecording() { recorder?.stop() }

    func cancelRecording() {
        recorder?.delegate = nil
        recorder?.stop()
        recorder = nil
        activeID = nil
        restoreSession()
    }

    nonisolated func audioRecorderDidFinishRecording(_ recorder: AVAudioRecorder, successfully flag: Bool) {
        let url = recorder.url
        Task { @MainActor [weak self] in self?.completed(url: url, successfully: flag, error: nil) }
    }

    nonisolated func audioRecorderEncodeErrorDidOccur(_ recorder: AVAudioRecorder, error: Error?) {
        let url = recorder.url
        let message = error?.localizedDescription ?? "音频编码失败"
        Task { @MainActor [weak self] in self?.completed(url: url, successfully: false, error: message) }
    }

    private func completed(url: URL, successfully: Bool, error: String?) {
        guard recorder?.url == url, let id = activeID else { return }
        recorder?.delegate = nil
        recorder = nil
        activeID = nil
        restoreSession()
        eventHandler?(.finished(recordingID: id, successfully: successfully, errorDescription: error))
    }

    private func interrupted(_ reason: String) {
        guard let id = activeID else { return }
        cancelRecording()
        eventHandler?(.interrupted(recordingID: id, reason: reason))
    }

    private func restoreSession() {
        let session = AVAudioSession.sharedInstance()
        try? session.setActive(false, options: .notifyOthersOnDeactivation)
        if let previousSession {
            try? session.setCategory(previousSession.0, mode: previousSession.1, options: previousSession.2)
        }
        previousSession = nil
    }

    private enum RecordingError: LocalizedError {
        case alreadyRecording, noBuiltInMicrophone, unableToStart
        var errorDescription: String? {
            switch self {
            case .alreadyRecording: return "已有一段录音正在进行。"
            case .noBuiltInMicrophone: return "未找到 iPhone 内建麦克风，请检查音频设备。"
            case .unableToStart: return "无法启动麦克风录音。"
            }
        }
    }
}
#endif
