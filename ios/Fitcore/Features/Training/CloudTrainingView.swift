import SwiftUI
import UIKit

/// LHY-04: the cloud WAV training chain, end to end, on the frozen V1.1 HTTP
/// contract. Five slices: prepare, record/upload, records (facts + pending),
/// finish, review. This round runs entirely against the in-app offline Mock
/// backend — no request leaves the machine, no real token, no real audio.
struct CloudTrainingView: View {
    @EnvironmentObject private var store: AppStore

    var body: some View {
        // The model is app-scoped (owned by the store), so leaving and
        // returning to this page never regenerates session or upload
        // identities; the content view observes it directly.
        CloudTrainingContent(model: store.cloudTraining)
    }
}

/// Internal (not private) so the offline screenshot tour can render the exact
/// production view for LHY-04 evidence capture.
struct CloudTrainingContent: View {
    @ObservedObject var model: CloudTrainingModel
    @StateObject private var capture: WAVCaptureController
    @State private var localConsent = false
    @State private var scenarioName = "常规 · 提交并复盘"
    @State private var showResetConfirmation = false
    @State private var submitError: String?

    init(model: CloudTrainingModel, scenarioName: String = "常规 · 提交并复盘") {
        self.model = model
        _scenarioName = State(initialValue: scenarioName)
        let directory = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("FitcoreCloudTrainingWAVs", isDirectory: true)
        #if targetEnvironment(simulator)
        let simulated = true
        #else
        let simulated = false
        #endif
        _capture = StateObject(wrappedValue: WAVCaptureController(
            backend: IPhoneMicrophoneBackend(), storageDirectory: directory, isSimulated: simulated
        ))
    }

    private var sessionStarted: Bool { model.sessionID != nil }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                headerCard
                prepareSection
                if model.phase == .ready || model.awaitingAudioSequences != nil {
                    recordingSection
                }
                if sessionStarted || model.phase == .finished {
                    recordsSection
                    finishSection
                }
                if model.phase == .finished {
                    reviewSection
                }
                resetSection
            }
            .padding(.horizontal, 20).padding(.top, 10).padding(.bottom, 28)
            .frame(maxWidth: 640)
            .frame(maxWidth: .infinity)
        }
        .background(FitcoreTheme.canvas)
        .navigationTitle("云端训练链")
        .navigationBarTitleDisplayMode(.inline)
        .navigationBarBackButtonHidden(capture.isBusy)
        .onChange(of: capture.recordings.count) { _, _ in submitLatestCapture() }
        .onReceive(NotificationCenter.default.publisher(for: UIApplication.didEnterBackgroundNotification)) { _ in
            capture.interrupt(reason: "App 已进入后台")
        }
        .onDisappear {
            if capture.isBusy { capture.cancel() }
        }
        .confirmationDialog("放弃本会话并重置？", isPresented: $showResetConfirmation, titleVisibility: .visible) {
            Button("放弃并重置", role: .destructive) {
                if capture.isBusy { capture.cancel() }
                model.reset()
                scenarioName = "常规 · 提交并复盘"
            }
            Button("取消", role: .cancel) { }
        } message: {
            Text("服务端已接收的内容保持在 Mock 后端；本机视图与上传身份将清空，重新开始需创建新会话。")
        }
    }

    // MARK: - Header

    private var headerCard: some View {
        FitcoreCard {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    VStack(alignment: .leading, spacing: 5) {
                        Text("FITCORE · CLOUD CHAIN").font(.system(size: 10, weight: .bold)).tracking(1.4).foregroundStyle(FitcoreTheme.muted)
                        Text("口述 → 上传 → 服务端事实 → 复盘").font(.system(size: 18, weight: .bold))
                    }
                    Spacer()
                    MockBadge()
                }
                Text("本轮为离线 Mock 集成：全部请求由本机脚本后端应答，不访问真实 AWS，不需要真实令牌，也不上传真人录音。")
                    .font(.caption).foregroundStyle(FitcoreTheme.muted).fixedSize(horizontal: false, vertical: true)
                Text("正式训练组只来自服务端 Facts / Review。上传 202、Job done、识别文本或候选结果都不会自行转成正式记录。")
                    .font(.caption.weight(.medium)).foregroundStyle(FitcoreTheme.navy)
                    .padding(10).background(FitcoreTheme.limeSoft, in: RoundedRectangle(cornerRadius: 12))
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    // MARK: - Slice 1: Prepare

    private var prepareSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            sectionTitle("1 · 训练准备", detail: "创建会话 / 准备与错误状态")
            switch model.phase {
            case .idle:
                FitcoreCard {
                    VStack(alignment: .leading, spacing: 14) {
                        Text("先创建训练会话，才能开始口述上传。").font(.subheadline).foregroundStyle(FitcoreTheme.muted)
                        Button {
                            Task { model.createSession() }
                        } label: { Label("创建训练会话", systemImage: "plus.circle.fill") }
                            .buttonStyle(PrimaryButtonStyle())
                    }
                }
            case .creatingSession:
                FitcoreCard {
                    HStack(spacing: 14) {
                        ProgressView().tint(FitcoreTheme.accent)
                        Text("正在创建会话…").font(.subheadline.weight(.semibold))
                        Spacer()
                    }
                }
            case .failed(let failure):
                failureCard(failure, retryTitle: "重试创建会话") {
                    Task { model.createSession() }
                }
            case .ready:
                sessionCard(stateText: "会话就绪 · 可以开始口述")
            case .finishing:
                sessionCard(stateText: "会话收尾中")
            case .awaitingAudio:
                sessionCard(stateText: "会话等待补传音频")
            case .finished:
                sessionCard(stateText: "会话已完成")
            }
        }
    }

    private func sessionCard(stateText: String) -> some View {
        FitcoreCard {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Label(stateText, systemImage: "checkmark.seal.fill")
                        .font(.subheadline.weight(.semibold)).foregroundStyle(FitcoreTheme.navy)
                    Spacer()
                    if model.isMock { scenarioMenu }
                }
                if let sessionID = model.sessionID {
                    Text("session_id：\(sessionID)").font(.caption.monospaced()).foregroundStyle(FitcoreTheme.muted)
                        .lineLimit(1).truncationMode(.middle)
                }
            }
        }
    }

    private var scenarioMenu: some View {
        Menu {
            ForEach(MockScenarioOption.allCases) { option in
                Button {
                    scenarioName = option.title
                    model.applyMockScenario(option.scenario)
                } label: {
                    if scenarioName == option.title { Label(option.title, systemImage: "checkmark") }
                    else { Text(option.title) }
                }
            }
        } label: {
            Label("Mock 场景 · \(scenarioName)", systemImage: "testtube.2")
                .font(.caption.weight(.semibold)).foregroundStyle(FitcoreTheme.navy)
                .padding(.horizontal, 10).padding(.vertical, 7)
                .background(FitcoreTheme.limeSoft, in: Capsule())
        }
    }

    // MARK: - Slice 2: Recording + upload

    private var recordingSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            sectionTitle("2 · 训练中", detail: "录音 / 上传 / 处理 / 失败恢复")
            if let missing = model.awaitingAudioSequences {
                FitcoreCard {
                    VStack(alignment: .leading, spacing: 10) {
                        Label("服务端等待缺失音频（awaiting_audio）", systemImage: "exclamationmark.triangle.fill")
                            .font(.subheadline.weight(.semibold)).foregroundStyle(.orange)
                        Text("缺少片段序号：\(missing.map { "第\($0)段" }.joined(separator: "、"))。请在下方补录并上传缺失片段，之后用相同 finish_id 重试结束。")
                            .font(.caption).foregroundStyle(FitcoreTheme.muted).fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
            recordingControls
            if let submitError {
                Label(submitError, systemImage: "exclamationmark.circle")
                    .font(.caption).foregroundStyle(.red)
            }
            if model.canRetryUploadWithOriginalIdentity {
                Button {
                    Task { await model.retryLastUpload() }
                } label: { Label("使用原标识重试上传（同 utterance_id / 序号 / 字节）", systemImage: "arrow.clockwise") }
                    .buttonStyle(OutlineButtonStyle())
            }
            utteranceList
        }
    }

    private var uploadBlocked: Bool {
        model.hasUploadInFlight || model.hasFailedRetryableUpload
    }

    private var recordingControls: some View {
        FitcoreCard {
            VStack(alignment: .leading, spacing: 14) {
                Toggle("我同意录制并保存在本机（仅限本机录音）", isOn: $localConsent)
                    .disabled(capture.isBusy)
                    .font(.subheadline)
                if capture.phase == .recording, let start = capture.startedAt {
                    TimelineView(.periodic(from: start, by: 0.5)) { context in
                        Text(String(format: "正在录音 %.1f 秒", max(0, context.date.timeIntervalSince(start))))
                            .font(.title3.monospacedDigit().weight(.semibold)).foregroundStyle(.red)
                    }
                } else {
                    Text(captureStatusText).font(.caption).foregroundStyle(FitcoreTheme.muted)
                }
                if capture.needsPermissionSettings {
                    Button("打开 iPhone 设置") {
                        guard let url = URL(string: UIApplication.openSettingsURLString) else { return }
                        UIApplication.shared.open(url)
                    }.font(.caption)
                }
                HStack(spacing: 10) {
                    if capture.phase == .recording {
                        Button { capture.stop() } label: { Label("停止并校验", systemImage: "stop.fill") }
                            .buttonStyle(PrimaryButtonStyle())
                    } else if capture.isBusy {
                        ProgressView().frame(maxWidth: .infinity)
                    } else {
                        Button {
                            submitError = nil
                            Task { await capture.start(localConsent: localConsent) }
                        } label: { Label("开始录音", systemImage: "mic.fill") }
                            .buttonStyle(PrimaryButtonStyle())
                            .disabled(!localConsent || uploadBlocked || model.phase == .finished)
                    }
                    if capture.isBusy || capture.phase == .recording {
                        Button(role: .destructive) { capture.cancel() } label: { Label("取消本段", systemImage: "xmark") }
                            .buttonStyle(OutlineButtonStyle())
                    }
                }
                if model.isMock {
                    Button {
                        submitError = nil
                        injectSyntheticUtterance()
                    } label: { Label("注入合成音频（Mock 演示，非真人语音）", systemImage: "waveform.badge.plus") }
                        .buttonStyle(OutlineButtonStyle())
                        .disabled(uploadBlocked || model.phase == .finished)
                    Text("合成音频由固定数值模式生成、明确非真人语音，用于离线演示完整链路；真人录音路径走上方麦克风。")
                        .font(.caption2).foregroundStyle(FitcoreTheme.muted).fixedSize(horizontal: false, vertical: true)
                }
                if uploadBlocked {
                    Text(model.hasUploadInFlight ? "有片段正在上传，请等待完成。" : "有片段未完成确认，请先重试或重新查询结果。")
                        .font(.caption).foregroundStyle(.orange)
                }
            }
        }
    }

    private var captureStatusText: String {
        switch capture.phase {
        case .idle: return "建议每段 5–20 秒，说完自然停止。录音先保存在本机，通过校验后自动提交到训练链。"
        case .requestingPermission: return "正在申请麦克风权限…"
        case .recording: return "正在录音"
        case .validating: return "正在完成录音并检查文件…"
        case .ready: return "录音已通过本地校验，等待提交。"
        case .failed(let message): return message
        }
    }

    private var utteranceList: some View {
        VStack(alignment: .leading, spacing: 10) {
            if model.utterances.isEmpty {
                Text("还没有上传片段。").font(.caption).foregroundStyle(FitcoreTheme.muted)
            } else {
                ForEach(model.utterances) { utterance in
                    utteranceCard(utterance)
                }
            }
        }
    }

    private func utteranceCard(_ utterance: CloudTrainingModel.UtteranceProgress) -> some View {
        FitcoreCard {
            VStack(alignment: .leading, spacing: 9) {
                HStack(alignment: .top) {
                    Text("第 \(utterance.sequence) 段").font(.subheadline.weight(.bold)).foregroundStyle(FitcoreTheme.navy)
                    Spacer()
                    utteranceStateBadge(utterance)
                }
                utteranceStateDetail(utterance)
                Text("sha256：\(utterance.sha256.prefix(12))…").font(.caption2.monospaced()).foregroundStyle(FitcoreTheme.muted)
                if case .failed = utterance.state {
                    Button("重新查询结果（同标识）") {
                        model.requeryJob(utteranceID: utterance.id)
                    }.font(.caption.weight(.semibold))
                }
            }
        }
    }

    private func utteranceStateBadge(_ utterance: CloudTrainingModel.UtteranceProgress) -> some View {
        let text: String
        let color: Color
        switch utterance.state {
        case .uploading: text = "上传中"; color = FitcoreTheme.muted
        case .accepted: text = "已接收 202"; color = .orange
        case .processing: text = "处理中"; color = FitcoreTheme.accent
        case .done(let decision, _, _):
            switch decision {
            case .commit: text = "已提交 COMMIT"; color = .green
            case .defer: text = "转入待确认 DEFER"; color = .orange
            case .reject: text = "被拒绝 REJECT"; color = .red
            case nil: text = "完成"; color = FitcoreTheme.navy
            }
        case .failed: text = "失败"; color = .red
        }
        return Text(text).font(.caption.weight(.bold)).padding(.horizontal, 9).padding(.vertical, 5)
            .background(color.opacity(0.12), in: Capsule()).foregroundStyle(color)
    }

    @ViewBuilder
    private func utteranceStateDetail(_ utterance: CloudTrainingModel.UtteranceProgress) -> some View {
        switch utterance.state {
        case .uploading:
            Text("正在上传本段音频…").font(.caption).foregroundStyle(FitcoreTheme.muted)
        case .accepted:
            VStack(alignment: .leading, spacing: 4) {
                Text("服务端已持久化音频（202 ≠ 训练记录），等待处理。").font(.caption).foregroundStyle(FitcoreTheme.muted)
                verificationLabels(utterance)
            }
        case .processing(let status):
            Text("服务端处理中 · \(status)").font(.caption).foregroundStyle(FitcoreTheme.muted)
        case .done(let decision, let finalText, let reason):
            VStack(alignment: .leading, spacing: 4) {
                if let finalText, !finalText.isEmpty {
                    Text("识别：\(finalText)").font(.caption).foregroundStyle(FitcoreTheme.ink)
                }
                if decision != .commit {
                    Text(reason.map { "原因：\($0)" } ?? "服务端未提交正式事实；正式记录请以 Facts / Review 为准。")
                        .font(.caption).foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true)
                }
                verificationLabels(utterance)
            }
        case .failed(let failure):
            VStack(alignment: .leading, spacing: 4) {
                Text(failure.message).font(.caption).foregroundStyle(.red).fixedSize(horizontal: false, vertical: true)
                if failure.retryWithSameIdentity {
                    Text("可用原标识重试 / 重新查询，不会生成新的上传身份。").font(.caption).foregroundStyle(FitcoreTheme.muted)
                }
            }
        }
    }

    private func verificationLabels(_ utterance: CloudTrainingModel.UtteranceProgress) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            if let verification = utterance.speakerVerification {
                Text("说话人验证：\(verification)（客户端不做说话人验证）")
            }
            if let assurance = utterance.sourceAssurance {
                Text("来源保证：\(assurance)（如实显示，不在客户端构造可信身份）")
            }
        }
        .font(.caption2).foregroundStyle(FitcoreTheme.muted).fixedSize(horizontal: false, vertical: true)
    }

    // MARK: - Slice 3: Records (facts + pending + events)

    private var recordsSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline) {
                sectionTitle("3 · 训练记录", detail: "正式 Facts 与待确认分开显示")
                Spacer()
                Button {
                    model.refreshRecords()
                } label: {
                    HStack(spacing: 5) {
                        if model.isRefreshingRecords { ProgressView().tint(FitcoreTheme.accent) }
                        Label("刷新", systemImage: "arrow.clockwise")
                    }
                }
                .font(.caption.weight(.semibold)).foregroundStyle(FitcoreTheme.navy)
                .buttonStyle(.plain)
                .disabled(model.isRefreshingRecords)
            }
            if let failure = model.recordsFailure {
                Label("记录刷新失败：\(failure.message)（已保留上次内容；解析失败不代表没有待确认内容）",
                      systemImage: "exclamationmark.triangle")
                    .font(.caption).foregroundStyle(.orange)
                    .padding(10).background(.orange.opacity(0.08), in: RoundedRectangle(cornerRadius: 12))
                    .fixedSize(horizontal: false, vertical: true)
            }
            factsCard
            pendingCard
            eventsCard
        }
    }

    private var pendingEmptyText: String {
        if case .decoding = model.recordsFailure?.kind {
            return "待确认列表解析失败，无法确认当前数量 —— 解析失败不代表没有待确认内容。"
        }
        return "当前没有待确认内容。"
    }

    private var factsCard: some View {
        FitcoreCard {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Label("正式训练组 · \(model.facts.count)", systemImage: "checkmark.seal.fill")
                        .font(.subheadline.weight(.bold)).foregroundStyle(FitcoreTheme.navy)
                    Spacer()
                    Text("仅来自服务端 Facts").font(.caption2).foregroundStyle(FitcoreTheme.muted)
                }
                if model.facts.isEmpty {
                    Text("暂无正式训练组。上传被接收（202）或识别出文本都不会计入，只有服务端提交的 Facts / Review 才是正式记录。")
                        .font(.caption).foregroundStyle(FitcoreTheme.muted).fixedSize(horizontal: false, vertical: true)
                } else {
                    ForEach(model.facts, id: \.id) { fact in
                        VStack(alignment: .leading, spacing: 4) {
                            HStack {
                                Text("第 \(fact.setNumber) 组 · \(fact.exercise)")
                                    .font(.subheadline.weight(.semibold))
                                Spacer()
                                Text("Fact #\(fact.id)").font(.caption2.monospaced()).foregroundStyle(FitcoreTheme.muted)
                            }
                            Text("\(fact.weightKg.formatted()) kg × \(fact.reps) 次 · 重量来源：\(fact.weightProvenance)")
                                .font(.caption).foregroundStyle(FitcoreTheme.muted)
                        }
                        .padding(11).background(FitcoreTheme.canvas.opacity(0.6), in: RoundedRectangle(cornerRadius: 12))
                    }
                }
            }
        }
    }

    private var pendingCard: some View {
        FitcoreCard {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Label("待确认 · \(model.pendingItems.count)", systemImage: "questionmark.circle")
                        .font(.subheadline.weight(.bold)).foregroundStyle(.orange)
                    Spacer()
                    Text("Pending 与正式记录分开").font(.caption2).foregroundStyle(FitcoreTheme.muted)
                }
                if model.pendingItems.isEmpty {
                    Text(pendingEmptyText)
                        .font(.caption).foregroundStyle(FitcoreTheme.muted).fixedSize(horizontal: false, vertical: true)
                } else {
                    ForEach(Array(model.pendingItems.enumerated()), id: \.offset) { _, item in
                        VStack(alignment: .leading, spacing: 4) {
                            Text("Pending #\(item.pendingID ?? "未提供") · 状态：\(item.status ?? "未知")")
                                .font(.caption.weight(.semibold))
                        }
                        .padding(11).background(.orange.opacity(0.07), in: RoundedRectangle(cornerRadius: 12))
                    }
                    Text("接口缺口：Pending 条目仅 id / status 已冻结（GAP-PENDING-SHAPE）；确认操作依赖未冻结的 resolve 请求体（GAP-PENDING-RESOLVE-BODY），当前显示“暂不可用”。联调条件：后端冻结 Pending item 完整字段与 resolve 请求体后开放。")
                        .font(.caption2).foregroundStyle(FitcoreTheme.muted).fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    private var eventsCard: some View {
        FitcoreCard {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Label("事件流 · \(model.events.count)", systemImage: "dot.radiowaves.left.and.right")
                        .font(.subheadline.weight(.bold)).foregroundStyle(FitcoreTheme.navy)
                    Spacer()
                    Text("按 event_seq 去重").font(.caption2).foregroundStyle(FitcoreTheme.muted)
                }
                if model.events.isEmpty {
                    Text("还没有服务端事件。").font(.caption).foregroundStyle(FitcoreTheme.muted)
                } else {
                    ForEach(model.events.suffix(6).reversed(), id: \.eventSeq) { event in
                        HStack {
                            Text("#\(event.eventSeq)").font(.caption2.monospaced()).foregroundStyle(FitcoreTheme.muted)
                            Text(event.type.rawValue).font(.caption.weight(.medium))
                            Spacer()
                            if let utteranceID = event.utteranceID {
                                Text("第…\(utteranceID.suffix(4))段").font(.caption2).foregroundStyle(FitcoreTheme.muted)
                            }
                        }
                    }
                }
            }
        }
    }

    // MARK: - Slice 4: Finish

    private var finishSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            sectionTitle("4 · 结束训练", detail: "draining / awaiting_audio / 失败恢复")
            switch model.phase {
            case .ready:
                VStack(alignment: .leading, spacing: 10) {
                    Button {
                        Task { await model.beginFinish() }
                    } label: { Label("结束训练（服务端收尾并生成复盘）", systemImage: "flag.checkered") }
                        .buttonStyle(PrimaryButtonStyle())
                        .disabled(uploadBlocked)
                    if uploadBlocked {
                        Text("有片段未完成，请先处理再结束。").font(.caption).foregroundStyle(.orange)
                    } else if model.hasProcessingUtterance {
                        Text("仍有片段在服务端处理中；结束后会等待处理完成（draining）再生成复盘。")
                            .font(.caption).foregroundStyle(FitcoreTheme.muted).fixedSize(horizontal: false, vertical: true)
                    }
                }
            case .finishing:
                FitcoreCard {
                    HStack(spacing: 14) {
                        ProgressView().tint(FitcoreTheme.accent)
                        VStack(alignment: .leading, spacing: 4) {
                            Text("服务端正在收尾（finish draining）…").font(.subheadline.weight(.semibold))
                            Text("已接受的音频仍在处理，完成后自动生成复盘。").font(.caption).foregroundStyle(FitcoreTheme.muted)
                        }
                        Spacer()
                    }
                }
            case .awaitingAudio(let missing):
                FitcoreCard {
                    VStack(alignment: .leading, spacing: 12) {
                        Label("结束被暂停：等待缺失音频（awaiting_audio）", systemImage: "hourglass")
                            .font(.subheadline.weight(.semibold)).foregroundStyle(.orange)
                        Text("缺少片段序号：\(missing.map { "第\($0)段" }.joined(separator: "、"))。请回到第 2 步补录上传，然后用相同 finish_id 重试。")
                            .font(.caption).foregroundStyle(FitcoreTheme.muted).fixedSize(horizontal: false, vertical: true)
                        Button {
                            Task { await model.retryFinish() }
                        } label: { Label("重试结束（相同 finish_id）", systemImage: "arrow.clockwise") }
                            .buttonStyle(OutlineButtonStyle())
                            .disabled(uploadBlocked)
                    }
                }
            case .finished:
                FitcoreCard {
                    Label("训练已结束 · 会话收尾完成", systemImage: "checkmark.circle.fill")
                        .font(.subheadline.weight(.semibold)).foregroundStyle(.green)
                }
            case .failed(let failure):
                failureCard(failure, retryTitle: "重试结束（相同 finish_id）") {
                    Task { await model.retryFinish() }
                }
            case .idle, .creatingSession:
                EmptyView()
            }
        }
    }

    // MARK: - Slice 5: Review

    private var reviewSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            sectionTitle("5 · 训练复盘", detail: "组数 / 次数 / 训练容量")
            if let review = model.review {
                FitcoreCard {
                    VStack(alignment: .leading, spacing: 14) {
                        HStack {
                            Label("服务端复盘已生成", systemImage: "sparkles")
                                .font(.subheadline.weight(.bold)).foregroundStyle(FitcoreTheme.navy)
                            Spacer()
                            Text("context_version \(review.contextVersion)").font(.caption2).foregroundStyle(FitcoreTheme.muted)
                        }
                        HStack(spacing: 10) {
                            reviewMetric("总组数", "\(review.totalSets)", unit: "组")
                            reviewMetric("总次数", "\(review.totalReps)", unit: "次")
                            reviewMetric("训练容量", review.volumeKgReps.formatted(.number.precision(.fractionLength(0))), unit: "kg·次")
                        }
                        Text("待确认条目：\(review.pendingCount) · 以上数字均由服务端 Review 提供，客户端不自行计算。")
                            .font(.caption).foregroundStyle(FitcoreTheme.muted).fixedSize(horizontal: false, vertical: true)
                    }
                }
            } else if model.reviewNotReady {
                FitcoreCard {
                    VStack(alignment: .leading, spacing: 12) {
                        Label("复盘尚未就绪（409）", systemImage: "clock")
                            .font(.subheadline.weight(.semibold)).foregroundStyle(.orange)
                        Text("服务端仍在整理本次训练，稍后重新获取。").font(.caption).foregroundStyle(FitcoreTheme.muted)
                        Button {
                            model.loadReview()
                        } label: { Label("重新获取复盘", systemImage: "arrow.clockwise") }
                            .buttonStyle(OutlineButtonStyle())
                    }
                }
            } else {
                FitcoreCard {
                    HStack(spacing: 14) {
                        ProgressView().tint(FitcoreTheme.accent)
                        Text("正在获取复盘…").font(.subheadline.weight(.semibold))
                        Spacer()
                    }
                }
            }
        }
    }

    private func reviewMetric(_ title: String, _ value: String, unit: String) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(title).font(.caption2).foregroundStyle(FitcoreTheme.muted)
            HStack(alignment: .firstTextBaseline, spacing: 3) {
                Text(value).font(.title3.weight(.bold)).foregroundStyle(FitcoreTheme.navy)
                Text(unit).font(.caption2).foregroundStyle(FitcoreTheme.muted)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12).background(FitcoreTheme.limeSoft, in: RoundedRectangle(cornerRadius: 14))
    }

    // MARK: - Reset

    private var resetSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Button(role: .destructive) { showResetConfirmation = true } label: {
                Label("放弃本会话，重新开始", systemImage: "trash")
            }
            .buttonStyle(OutlineButtonStyle())
            Text("重置只清空本机视图与上传身份，不伪造服务端状态；已录音文件保留在本机。")
                .font(.caption2).foregroundStyle(FitcoreTheme.muted)
        }
    }

    // MARK: - Helpers

    private func sectionTitle(_ title: String, detail: String) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title).font(.system(size: 17, weight: .bold)).foregroundStyle(FitcoreTheme.ink)
            Text(detail).font(.caption).foregroundStyle(FitcoreTheme.muted)
        }
    }

    private func failureCard(_ failure: CloudTrainingModel.CloudFailure, retryTitle: String, retry: @escaping () -> Void) -> some View {
        FitcoreCard {
            VStack(alignment: .leading, spacing: 12) {
                Label("出错：\(failure.kind.label)", systemImage: "exclamationmark.triangle.fill")
                    .font(.subheadline.weight(.semibold)).foregroundStyle(.red)
                Text(failure.message).font(.caption).foregroundStyle(FitcoreTheme.muted).fixedSize(horizontal: false, vertical: true)
                Button(action: retry) { Label(retryTitle, systemImage: "arrow.clockwise") }
                    .buttonStyle(OutlineButtonStyle())
            }
        }
    }

    /// Hands the newest validated local recording to the cloud chain. The
    /// recording ID is its stable utterance identity; re-entry or a repeated
    /// change notification can never submit it twice (model-side guard).
    private func submitLatestCapture() {
        guard let recording = capture.recordings.last else { return }
        guard !model.hasSubmitted(recordingID: recording.id) else { return }
        do {
            let data = try Data(contentsOf: recording.fileURL)
            Task {
                let accepted = await model.submitRecording(
                    recordingID: recording.id,
                    wavData: data,
                    audioSource: "iphone_mic"
                )
                if !accepted, model.lastFailure != nil {
                    submitError = model.lastFailure?.message
                }
            }
        } catch {
            submitError = "读取本机录音失败，未提交：\(error.localizedDescription)"
        }
    }

    private func injectSyntheticUtterance() {
        let recordingID = "synthetic-\(UUID().uuidString)"
        let wav = CloudTrainingModel.syntheticDemoWAV()
        Task {
            let accepted = await model.submitRecording(
                recordingID: recordingID,
                wavData: wav,
                audioSource: "synthetic_mock_demo"
            )
            if !accepted, model.lastFailure != nil {
                submitError = model.lastFailure?.message
            }
        }
    }
}

// MARK: - Mock scenario options

private struct MockScenarioOption: Identifiable {
    let title: String
    let scenario: MockCloudBackend.Scenario
    var id: String { title }

    static let allCases: [MockScenarioOption] = [
        .init(title: "常规 · 提交并复盘", scenario: .normal),
        .init(title: "首段 DEFER · 产生 Pending", scenario: .deferPending),
        .init(title: "上传 503×3 · 原标识重试", scenario: .uploadRetryExhausted),
        .init(title: "401 · 未授权", scenario: .unauthorized),
        .init(title: "Facts/Pending 畸形响应", scenario: .recordsMalformed),
        .init(title: "Finish 409 · 缺音频片段", scenario: .finishAwaitingAudio),
        .init(title: "Review 延迟就绪", scenario: .reviewDelayed),
        .init(title: "Job 停在 queued · 轮询超时", scenario: .jobsStuck),
    ]
}

private extension CloudTrainingModel.CloudFailure.Kind {
    var label: String {
        switch self {
        case .unauthorized: return "未授权（401/403）"
        case .timeout: return "超时"
        case .decoding: return "响应解析失败"
        case .conflict: return "请求冲突（409）"
        case .transport: return "网络传输失败"
        case .rejected: return "请求被拒绝"
        case .serverRetryExhausted: return "服务端重试预算耗尽"
        case .other: return "其他错误"
        }
    }
}
