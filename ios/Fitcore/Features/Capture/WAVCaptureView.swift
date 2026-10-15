import AVFoundation
import SwiftUI
import UIKit

struct WAVCaptureView: View {
    @StateObject private var capture: WAVCaptureController
    @State private var localConsent = false
    @State private var player: AVAudioPlayer?
    @State private var playingID: String?
    @State private var share: CaptureShare?
    @State private var pendingDelete: CapturedWAV?
    @State private var playbackError: String?
    @State private var playbackSessionActive = false

    init() {
        let directory = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("FitcoreWAVCaptures", isDirectory: true)
        #if targetEnvironment(simulator)
        let simulated = true
        #else
        let simulated = false
        #endif
        _capture = StateObject(wrappedValue: WAVCaptureController(
            backend: IPhoneMicrophoneBackend(), storageDirectory: directory, isSimulated: simulated
        ))
    }

    var body: some View {
        Form {
            Section {
                Label("iPhone 麦克风", systemImage: "mic.fill")
                #if targetEnvironment(simulator)
                Text("当前为模拟器，导出文件会带模拟器标记，不能计入真人真机验收。")
                    .font(.caption).foregroundStyle(.orange)
                #endif
                Text("用于准备训练语料。录音先保存在本机，由你选择播放或导出，不会自动上传或生成训练记录。")
                    .font(.footnote).foregroundStyle(.secondary)
                Toggle("我同意录制并保存在本机", isOn: $localConsent)
                    .disabled(capture.isBusy)
                    .accessibilityIdentifier("wav.localConsent")
                Text("团队共享、云端模型处理的许可在 D01 授权登记中分别填写；这里的同意仅限本机录音。")
                    .font(.caption).foregroundStyle(.secondary)
            }

            Section("录制一段") {
                Text(statusText).accessibilityIdentifier("wav.status")
                if capture.phase == .recording, let start = capture.startedAt {
                    TimelineView(.periodic(from: start, by: 0.5)) { context in
                        Text(String(format: "录音 %.1f 秒", max(0, context.date.timeIntervalSince(start))))
                            .font(.title2.monospacedDigit()).foregroundStyle(.red)
                    }
                }
                if capture.phase == .recording {
                    Button("停止并校验") { capture.stop() }
                        .accessibilityIdentifier("wav.stop")
                    Button("取消本段", role: .destructive) { capture.cancel() }
                } else if capture.isBusy {
                    ProgressView()
                    Button("取消本段", role: .destructive) { capture.cancel() }
                } else {
                    Button(capture.recordings.isEmpty ? "开始录音" : "录制新的一段") {
                        stopPlayback()
                        Task { await capture.start(localConsent: localConsent) }
                    }
                    .disabled(!localConsent)
                    .accessibilityIdentifier("wav.start")
                }
                if capture.needsPermissionSettings {
                    Button("打开 iPhone 设置") {
                        guard let url = URL(string: UIApplication.openSettingsURLString) else { return }
                        UIApplication.shared.open(url)
                    }
                }
                Text("建议每段 5–20 秒，说完自然结束。最长录制 200 秒；静音、格式错误或被中断的片段不会显示为有效录音。")
                    .font(.caption).foregroundStyle(.secondary)
            }

            Section("已录制 · \(capture.recordings.count) 段") {
                if capture.recordings.isEmpty {
                    Text("录完并通过校验后，可在这里播放和导出。")
                        .foregroundStyle(.secondary)
                }
                ForEach(capture.recordings) { recording in
                    VStack(alignment: .leading, spacing: 8) {
                        Text(recording.metadata.recordedAt, format: .dateTime.month().day().hour().minute().second())
                            .font(.headline)
                        Text(String(format: "%.1f 秒 · 16kHz · 单声道 · PCM16", recording.metadata.inspection.durationSeconds))
                            .font(.subheadline).foregroundStyle(.secondary)
                        Text(recording.id).font(.caption2.monospaced()).textSelection(.enabled)
                        if recording.metadata.isSimulated {
                            Text("模拟器样本").font(.caption).foregroundStyle(.orange)
                        }
                        HStack(spacing: 22) {
                            Button(playingID == recording.id ? "停止播放" : "播放") { play(recording) }
                                .buttonStyle(.borderless)
                            Button("导出 WAV 与信息") {
                                stopPlayback()
                                let urls = capture.exportURLs(for: recording)
                                if !urls.isEmpty { share = CaptureShare(urls: urls) }
                            }.buttonStyle(.borderless)
                            Button("删除", role: .destructive) { pendingDelete = recording }
                                .buttonStyle(.borderless)
                        }.disabled(capture.isBusy)
                    }.padding(.vertical, 4)
                }
                Text("每次录制使用新编号，保留之前的有效原文件。导出包含 WAV 和对应 JSON；请选择你批准的保存位置或接收人。")
                    .font(.caption).foregroundStyle(.secondary)
            }
            if let playbackError {
                Section { Text(playbackError).foregroundStyle(.red) }
            }
        }
        .navigationTitle("手机 WAV 采集")
        .navigationBarTitleDisplayMode(.inline)
        .navigationBarBackButtonHidden(capture.isBusy)
        .sheet(item: $share) { item in CaptureShareSheet(urls: item.urls) }
        .confirmationDialog("删除这一段录音及其信息？", isPresented: Binding(
            get: { pendingDelete != nil }, set: { if !$0 { pendingDelete = nil } }
        ), titleVisibility: .visible) {
            Button("删除", role: .destructive) {
                if let pendingDelete { stopPlayback(); capture.delete(pendingDelete) }
                pendingDelete = nil
            }
            Button("取消", role: .cancel) { pendingDelete = nil }
        }
        .onReceive(NotificationCenter.default.publisher(for: UIApplication.didEnterBackgroundNotification)) { _ in
            stopPlayback()
            capture.interrupt(reason: "App 已进入后台")
        }
        .onDisappear {
            stopPlayback()
            if capture.isBusy { capture.cancel() }
        }
        .task(id: playingID) {
            guard let id = playingID else { return }
            while player?.isPlaying == true {
                do { try await Task.sleep(for: .milliseconds(250)) } catch { return }
            }
            if playingID == id { stopPlayback() }
        }
    }

    private var statusText: String {
        switch capture.phase {
        case .idle: return "准备好后，点击开始录音。"
        case .requestingPermission: return "正在申请麦克风权限…"
        case .recording: return "正在录音"
        case .validating: return "正在完成录音并检查文件…"
        case .ready: return "录音已通过本地格式、静音和完整性检查。"
        case .failed(let message): return message
        }
    }

    private func play(_ recording: CapturedWAV) {
        if playingID == recording.id { stopPlayback(); return }
        stopPlayback()
        guard let url = capture.exportURLs(for: recording).first else { return }
        do {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.playback)
            try session.setActive(true)
            playbackSessionActive = true
            let candidate = try AVAudioPlayer(contentsOf: url)
            guard candidate.play() else { throw CocoaError(.fileReadCorruptFile) }
            player = candidate
            playingID = recording.id
            playbackError = nil
        } catch {
            stopPlayback()
            playbackError = "无法播放：\(error.localizedDescription)"
        }
    }

    private func stopPlayback() {
        player?.stop()
        player = nil
        playingID = nil
        if playbackSessionActive {
            try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
            playbackSessionActive = false
        }
    }
}

private struct CaptureShare: Identifiable {
    let id = UUID()
    let urls: [URL]
}

private struct CaptureShareSheet: UIViewControllerRepresentable {
    let urls: [URL]
    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: urls, applicationActivities: nil)
    }
    func updateUIViewController(_ uiViewController: UIActivityViewController, context: Context) {}
}
