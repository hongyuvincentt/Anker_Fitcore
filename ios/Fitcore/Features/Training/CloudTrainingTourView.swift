import SwiftUI

/// LHY-04 evidence capture tour. Runs ONLY when the app is launched with the
/// `--lhy04-screenshot-tour` argument: it drives the real `CloudTrainingContent`
/// through the seven required state groups entirely against the in-process
/// MockCloudBackend and shows each state ON SCREEN. Before every checkpoint it
/// writes a marker file (Documents/lhy04-tour/current-state.txt) so an
/// external `simctl io screenshot` watcher can capture the real pixels. No
/// request leaves the machine, no real token is used, and every uploaded WAV
/// is the synthetic generator (never a real person's voice). This is a
/// delivery-evidence tool, not a demo feature.
struct CloudTrainingTourView: View {
    @StateObject private var runner = TourRunner()

    var body: some View {
        Group {
            if let model = runner.activeModel {
                // A fresh stage id per checkpoint re-seeds the content view's
                // @State (scenario label) while the model keeps its state.
                CloudTrainingContent(model: model, scenarioName: runner.scenarioTitle)
                    .id(runner.stage)
            } else {
                VStack(spacing: 12) {
                    ProgressView().tint(FitcoreTheme.accent)
                    Text("LHY-04 截图巡览启动中…").font(.footnote).foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(FitcoreTheme.canvas)
            }
        }
        .task { await runner.run() }
    }
}

/// Drives one `CloudTrainingModel` per state group, publishes the model that
/// the tour view should display, and writes the marker file the external
/// screenshot watcher polls.
@MainActor
private final class TourRunner: ObservableObject {
    @Published private(set) var activeModel: CloudTrainingModel?
    @Published private(set) var scenarioTitle = "常规 · 提交并复盘"
    @Published private(set) var stage = 0

    private let directory = URL.documentsDirectory
        .appendingPathComponent("lhy04-tour", isDirectory: true)
    private var captureCount = 0

    func run() async {
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        do {
            try await prepareProcessingFactsAndFinish()
            try await pendingDefer()
            try await uploadFailureAndSameIdentityRetry()
            try await unauthorized401()
            try await pollTimeout()
            try await awaitingAudioAndRecovery()
            try await reviewNotReadyThenSuccess()
            writeMarker("DONE")
        } catch {
            writeMarker("DONE")
        }
    }

    // MARK: - State groups

    /// Groups: prepare idle→ready; processing (no official record); facts from
    /// server; records decode failure keeps data; finish 202 draining;
    /// finished + review.
    private func prepareProcessingFactsAndFinish() async throws {
        // A slow poll interval widens the transient windows (processing,
        // draining) so the external screenshot catches them mid-state.
        let (model, backend) = try await makeModel(
            .normal,
            title: "常规 · 提交并复盘",
            pollInterval: .milliseconds(1500),
            jobPollTimeout: .seconds(12)
        )
        await show("02-prepare-idle", model: model)
        model.createSession()
        _ = await waitFor("session-ready", .seconds(6)) { model.phase == .ready }
        await show("03-prepare-ready", model: model)

        _ = await model.submitRecording(recordingID: "tour-main-0", wavData: syntheticWAV())
        _ = await waitFor("processing", .seconds(6)) {
            model.utterances.last.map { utterance in
                if case .processing = utterance.state { return true }
                if case .accepted = utterance.state { return true }
                return false
            } ?? false
        }
        await show("04-processing-no-official-record", model: model)
        _ = await waitFor("done-commit", .seconds(8)) { model.hasCompletedUtterance }
        _ = await waitFor("facts-arrived", .seconds(4)) { model.facts.count == 1 }
        await show("05-facts-from-server", model: model)

        // Records decode failure must keep the previous data and surface an
        // error, never present "no pending content".
        await backend.configure(.recordsMalformed)
        model.refreshRecords()
        _ = await waitFor("records-decode-failure", .seconds(4)) { model.recordsFailure != nil }
        await show("06-records-decode-failure-keeps-data", model: model, title: "Facts/Pending 畸形响应")

        await backend.configure(.normal)
        await model.beginFinish()
        _ = await waitFor("draining", .seconds(2)) { model.phase == .finishing }
        await show("07-finish-draining-202", model: model)
        _ = await waitFor("finished", .seconds(6)) { model.phase == .finished }
        _ = await waitFor("review-ready", .seconds(4)) { model.review != nil }
        await show("08-finished-review", model: model)
    }

    /// Processing → Pending with confirmed fields only; SOURCE_UNCERTAIN is
    /// shown as-is.
    private func pendingDefer() async throws {
        let (model, _) = try await makeModel(.deferPending, title: "首段 DEFER · 产生 Pending")
        model.createSession()
        _ = await waitFor("defer-session-ready", .seconds(6)) { model.phase == .ready }
        _ = await model.submitRecording(recordingID: "tour-defer-0", wavData: syntheticWAV())
        _ = await waitFor("done-defer", .seconds(8)) {
            model.utterances.last.map { utterance in
                if case .done(let decision, _, _) = utterance.state { return decision == .defer }
                return false
            } ?? false
        }
        _ = await waitFor("pending-arrived", .seconds(4)) { model.pendingItems.count == 1 }
        await show("09-pending-defer-source-uncertain", model: model)
    }

    /// Upload failure (503×3) then a retry with the ORIGINAL identity that
    /// succeeds without ever regenerating the upload id.
    private func uploadFailureAndSameIdentityRetry() async throws {
        let (model, _) = try await makeModel(.uploadRetryExhausted, title: "上传 503×3 · 原标识重试")
        model.createSession()
        _ = await waitFor("retry-session-ready", .seconds(6)) { model.phase == .ready }
        _ = await model.submitRecording(recordingID: "tour-503-0", wavData: syntheticWAV())
        _ = await waitFor("upload-failed", .seconds(8)) {
            guard model.canRetryUploadWithOriginalIdentity else { return false }
            return model.utterances.last.map { utterance in
                if case .failed = utterance.state { return true }
                return false
            } ?? false
        }
        await show("10-upload-failed-retry-original-identity", model: model)
        await model.retryLastUpload()
        _ = await waitFor("retry-done", .seconds(8)) { model.hasCompletedUtterance }
        _ = await waitFor("retry-facts", .seconds(4)) { model.facts.count == 1 }
        await show("11-upload-retry-recovered", model: model)
    }

    /// 401/403 surfaced as a failed phase with the contract semantics.
    private func unauthorized401() async throws {
        let (model, _) = try await makeModel(.unauthorized, title: "401 · 未授权")
        model.createSession()
        _ = await waitFor("unauthorized-failed", .seconds(4)) {
            if case .failed(let failure) = model.phase { return failure.kind == .unauthorized }
            return false
        }
        await show("12-unauthorized-401", model: model)
    }

    /// Job polling timeout; recovery is a re-query with the same identity.
    private func pollTimeout() async throws {
        let (model, _) = try await makeModel(.jobsStuck, title: "Job 停在 queued · 轮询超时", jobPollTimeout: .seconds(2))
        model.createSession()
        _ = await waitFor("stuck-session-ready", .seconds(6)) { model.phase == .ready }
        _ = await model.submitRecording(recordingID: "tour-stuck-0", wavData: syntheticWAV())
        _ = await waitFor("poll-timeout", .seconds(8)) {
            model.utterances.last.map { utterance in
                if case .failed = utterance.state { return true }
                return false
            } ?? false
        }
        await show("13-poll-timeout-requery-same-identity", model: model)
    }

    /// Finish 409 awaiting_audio with missing sequences; the same finish_id
    /// completes only after the missing audio is supplemented.
    private func awaitingAudioAndRecovery() async throws {
        let (model, _) = try await makeModel(.finishAwaitingAudio, title: "Finish 409 · 缺音频片段")
        model.createSession()
        _ = await waitFor("await-session-ready", .seconds(6)) { model.phase == .ready }
        _ = await model.submitRecording(recordingID: "tour-await-0", wavData: syntheticWAV())
        _ = await waitFor("await-done", .seconds(8)) { model.hasCompletedUtterance }
        await model.beginFinish()
        _ = await waitFor("awaiting-audio", .seconds(4)) { model.awaitingAudioSequences == [1] }
        await show("14-finish-awaiting-audio-409", model: model)
        // Supplement the missing sequence, then the SAME finish_id completes.
        _ = await model.submitRecording(recordingID: "tour-await-1", wavData: syntheticWAV())
        _ = await waitFor("supplement-done", .seconds(8)) { model.utterances.count == 2 && model.hasCompletedUtterance }
        await model.retryFinish()
        _ = await waitFor("await-recovered", .seconds(6)) { model.phase == .finished }
        _ = await waitFor("await-review", .seconds(4)) { model.review != nil }
        await show("15-awaiting-audio-recovered-review", model: model)
    }

    /// Review 409 not-ready, then success on a later fetch.
    private func reviewNotReadyThenSuccess() async throws {
        let (model, _) = try await makeModel(.reviewDelayed, title: "Review 延迟就绪")
        model.createSession()
        _ = await waitFor("review-session-ready", .seconds(6)) { model.phase == .ready }
        _ = await model.submitRecording(recordingID: "tour-review-0", wavData: syntheticWAV())
        _ = await waitFor("review-done", .seconds(8)) { model.hasCompletedUtterance }
        await model.beginFinish()
        _ = await waitFor("review-finished", .seconds(8)) { model.phase == .finished }
        _ = await waitFor("review-not-ready", .seconds(4)) { model.reviewNotReady }
        await show("16-review-not-ready-409", model: model)
        try? await Task.sleep(for: .milliseconds(400))
        model.loadReview()
        try? await Task.sleep(for: .milliseconds(400))
        model.loadReview()
        _ = await waitFor("review-success", .seconds(4)) { model.review != nil && !model.reviewNotReady }
        await show("17-review-success-after-retry", model: model)
    }

    // MARK: - Helpers

    private func makeModel(
        _ scenario: MockCloudBackend.Scenario,
        title: String,
        pollInterval: Duration = .milliseconds(300),
        jobPollTimeout: Duration = .seconds(4)
    ) async throws -> (CloudTrainingModel, MockCloudBackend) {
        let backend = MockCloudBackend()
        await backend.configure(scenario)
        let configuration = try BackendHTTPConfiguration(
            baseURL: URL(string: "https://mock.fitcore.local")!,
            accessToken: "mock-offline-placeholder"
        )
        let client = BackendHTTPClient(configuration: configuration, transport: backend)
        let model = CloudTrainingModel(
            client: client,
            jobPollInterval: pollInterval,
            jobPollTimeout: jobPollTimeout,
            drainTimeout: .seconds(10)
        )
        // Remember the matching menu label for the on-screen scenario badge.
        scenarioTitle = title
        return (model, backend)
    }

    private func syntheticWAV() -> Data {
        CloudTrainingModel.syntheticDemoWAV()
    }

    /// Puts the model's current state on screen, signals the external
    /// screenshot watcher via the marker file, and holds the state long
    /// enough for the capture.
    private func show(_ name: String, model: CloudTrainingModel, title: String? = nil) async {
        if let title { scenarioTitle = title }
        stage += 1
        activeModel = model
        // Let SwiftUI render the new state before signalling the watcher.
        try? await Task.sleep(for: .milliseconds(250))
        writeMarker(name)
        captureCount += 1
        try? await Task.sleep(for: .milliseconds(1500))
    }

    private func writeMarker(_ name: String) {
        try? name.write(
            to: directory.appendingPathComponent("current-state.txt"),
            atomically: true,
            encoding: .utf8
        )
    }

    private func waitFor(_ label: String, _ timeout: Duration, _ condition: @MainActor () -> Bool) async -> Bool {
        let deadline = ContinuousClock.now + timeout
        while ContinuousClock.now < deadline {
            if condition() { return true }
            try? await Task.sleep(for: .milliseconds(30))
        }
        return condition()
    }
}
