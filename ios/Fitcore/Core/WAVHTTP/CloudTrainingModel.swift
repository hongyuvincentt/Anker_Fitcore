import Combine
import Foundation

/// Drives the cloud WAV training chain on top of the LHY-03 client: session
/// creation, sequenced uploads (202 = accepted only), job polling, facts /
/// pending / events with server-side identity, finish draining, and review.
///
/// Presentation rules enforced here:
/// - Official training sets come ONLY from Facts/Review responses; an upload
///   202, job `done`, a transcript, or committed candidates never add a record
///   card by themselves.
/// - Facts dedup by fact id, events dedup by event_seq, pending dedup by a
///   stable pending key — refreshing can never duplicate cards.
/// - Each logical recording keeps exactly one upload identity; a retry reuses
///   the same utterance_id, sequence and bytes (WAVSessionUploader), and
///   re-submitting a recording that was already handed to the model is ignored,
///   so page refreshes or re-entry never regenerate an upload identity.
/// - Decode failures surface as errors; they are never presented as "no
///   pending content" and never clear previously fetched records.
@MainActor
final class CloudTrainingModel: ObservableObject {
    // MARK: - State

    enum Phase: Equatable {
        case idle
        case creatingSession
        case ready
        /// Finish accepted (202); the cloud is still draining accepted audio.
        case finishing
        /// Finish answered 409 awaiting_audio with missing sequences.
        case awaitingAudio([Int])
        case finished
        case failed(CloudFailure)
    }

    struct CloudFailure: Equatable, Sendable {
        enum Kind: Equatable, Sendable {
            case unauthorized
            case timeout
            case decoding
            case conflict
            case transport
            case rejected
            case serverRetryExhausted
            case other
        }

        let kind: Kind
        let message: String

        /// A retry may repeat the exact same request identity (never a new id).
        var retryWithSameIdentity: Bool {
            kind == .transport || kind == .timeout
        }

        init(_ error: BackendHTTPError) {
            switch error {
            case .unauthorized:
                kind = .unauthorized
            case .pollTimeout:
                kind = .timeout
            case .transport, .serverUnavailable, .retryBudgetExhausted:
                kind = .transport
            case .decodingFailed:
                kind = .decoding
            case .uploadConflict, .sessionAlreadyExists, .eventCursorConflict,
                 .pendingConflict, .finishConflict, .finishRangeExcludesAccepted, .conflict:
                kind = .conflict
            case .requestRejected:
                kind = .rejected
            case .serverRetryExhausted:
                kind = .serverRetryExhausted
            default:
                kind = .other
            }
            message = error.errorDescription ?? "未知错误"
        }

        init(kind: Kind, message: String) {
            self.kind = kind
            self.message = message
        }
    }

    struct UtteranceProgress: Identifiable, Equatable, Sendable {
        enum State: Equatable, Sendable {
            case uploading
            /// 202 persisted — explicitly NOT a training record yet.
            case accepted
            /// Job is queued/running; the string is the server job status.
            case processing(String)
            case done(decision: FactDecision?, finalText: String?, reason: String?)
            case failed(CloudFailure)
        }

        let id: String
        let sequence: Int
        let sha256: String
        var state: State
        var sourceAssurance: String?
        var speakerVerification: String?
    }

    @Published private(set) var phase: Phase = .idle
    @Published private(set) var sessionID: String?
    @Published private(set) var utterances: [UtteranceProgress] = []
    @Published private(set) var facts: [TrainingFactDTO] = []
    @Published private(set) var pendingItems: [PendingItem] = []
    @Published private(set) var events: [PersistentEvent] = []
    @Published private(set) var review: SessionReviewDTO?
    @Published private(set) var reviewNotReady = false
    @Published private(set) var lastFailure: CloudFailure?
    /// Failure of the latest facts/pending/events refresh only (distinct from
    /// upload or polling failures, so the records UI never blames an upload).
    @Published private(set) var recordsFailure: CloudFailure?
    @Published private(set) var isRefreshingRecords = false
    /// True when an upload itself failed and the uploader still holds the
    /// original identity — the "retry with original identity" action applies.
    @Published private(set) var canRetryUploadWithOriginalIdentity = false

    let client: BackendHTTPClient
    let isMock: Bool

    private let jobPollInterval: Duration
    private let jobPollTimeout: Duration
    private let drainTimeout: Duration

    private var uploader: WAVSessionUploader?
    private var finishID = UUID().uuidString
    private var epoch = 0
    private var submittedRecordingIDs: Set<String> = []
    private var eventCursor = 0
    private var pendingKeys: Set<String> = []
    private var factIDs: Set<Int> = []
    private var maxEventSeq = 0
    private var pollTasks: [String: Task<Void, Never>] = [:]
    private var refreshTask: Task<Void, Never>?
    private var finishTask: Task<Void, Never>?

    var mockBackend: MockCloudBackend? {
        client.transport as? MockCloudBackend
    }

    // MARK: - Derived state for the UI

    var hasUploadInFlight: Bool {
        utterances.contains { if case .uploading = $0.state { return true }; return false }
    }

    var hasFailedRetryableUpload: Bool {
        utterances.contains {
            if case .failed(let failure) = $0.state { return failure.retryWithSameIdentity }
            return false
        }
    }

    var hasProcessingUtterance: Bool {
        utterances.contains {
            switch $0.state {
            case .uploading, .accepted, .processing: return true
            default: return false
            }
        }
    }

    var hasCompletedUtterance: Bool {
        utterances.contains { if case .done = $0.state { return true }; return false }
    }

    /// The stable finish identity for the current session (never regenerated by
    /// retries; only a new session gets a new finish_id).
    var currentFinishID: String { finishID }

    // MARK: - Init

    init(
        client: BackendHTTPClient,
        jobPollInterval: Duration = .milliseconds(300),
        jobPollTimeout: Duration = .seconds(8),
        drainTimeout: Duration = .seconds(10)
    ) {
        self.client = client
        self.isMock = client.transport is MockCloudBackend
        self.jobPollInterval = jobPollInterval
        self.jobPollTimeout = jobPollTimeout
        self.drainTimeout = drainTimeout
    }

    /// Mock-only factory for this round: an offline scripted backend, no real
    /// endpoint, no real token. The token below is a placeholder and never a
    /// credential.
    static func mock(jobPollTimeout: Duration = .seconds(8)) -> CloudTrainingModel {
        let configuration = try! BackendHTTPConfiguration(
            baseURL: URL(string: "https://mock.fitcore.local")!,
            accessToken: "mock-offline-placeholder"
        )
        let backend = MockCloudBackend()
        return CloudTrainingModel(
            client: BackendHTTPClient(configuration: configuration, transport: backend),
            jobPollTimeout: jobPollTimeout
        )
    }

    /// Deterministic, clearly-synthetic non-silent WAV (16 kHz / mono / PCM16)
    /// for offline Mock demos and tests. It is generated from a fixed numeric
    /// pattern and is never derived from a real person's voice.
    static func syntheticDemoWAV(durationSeconds: Double = 1.0, amplitude: Int16 = 12_000) -> Data {
        let frames = max(1, Int(16_000 * durationSeconds))
        var pcm = Data(capacity: frames * 2)
        let pattern: [UInt8] = [UInt8(amplitude & 0xFF), UInt8((amplitude >> 8) & 0xFF),
                                UInt8((~amplitude) & 0xFF), UInt8(((~amplitude) >> 8) & 0xFF)]
        for _ in 0..<(frames / 2) { pcm.append(contentsOf: pattern) }
        if frames % 2 == 1 { pcm.append(contentsOf: pattern.prefix(2)) }
        var data = Data()
        func appendUInt32(_ value: UInt32) {
            withUnsafeBytes(of: value.littleEndian) { data.append(contentsOf: $0) }
        }
        func appendUInt16(_ value: UInt16) {
            withUnsafeBytes(of: value.littleEndian) { data.append(contentsOf: $0) }
        }
        data.append(Data("RIFF".utf8))
        appendUInt32(UInt32(36 + pcm.count))
        data.append(Data("WAVE".utf8))
        data.append(Data("fmt ".utf8))
        appendUInt32(16)
        appendUInt16(1)          // PCM
        appendUInt16(1)          // mono
        appendUInt32(16_000)     // sample rate
        appendUInt32(32_000)     // byte rate
        appendUInt16(2)          // block align
        appendUInt16(16)         // bits per sample
        data.append(Data("data".utf8))
        appendUInt32(UInt32(pcm.count))
        data.append(pcm)
        return data
    }

    // MARK: - Session

    func hasSubmitted(recordingID: String) -> Bool {
        submittedRecordingIDs.contains(recordingID)
    }

    /// Creates (or recovers via GET on 409) a training session. Failures are
    /// surfaced with their contract semantics; nothing is invented locally.
    func createSession() {
        guard phase == .idle || isFailedPhase else { return }
        phase = .creatingSession
        lastFailure = nil
        let sessionID = UUID().uuidString
        let capturedEpoch = epoch
        let client = self.client
        Task { [weak self] in
            do {
                let context = try await client.ensureSession(sessionID: sessionID)
                guard let self, self.epoch == capturedEpoch else { return }
                self.beginFreshSession(context: context)
            } catch let error as BackendHTTPError {
                guard let self, self.epoch == capturedEpoch else { return }
                self.phase = .failed(CloudFailure(error))
            } catch {
                guard let self, self.epoch == capturedEpoch else { return }
                self.phase = .failed(CloudFailure(kind: .other, message: "创建会话失败：已取消或未知错误"))
            }
        }
    }

    private func beginFreshSession(context: SessionContext) {
        sessionID = context.sessionID
        uploader = WAVSessionUploader(client: client, sessionID: context.sessionID)
        utterances = []
        facts = []
        pendingItems = []
        events = []
        review = nil
        reviewNotReady = false
        canRetryUploadWithOriginalIdentity = false
        submittedRecordingIDs = []
        eventCursor = 0
        pendingKeys = []
        factIDs = []
        maxEventSeq = 0
        recordsFailure = nil
        finishID = UUID().uuidString
        phase = .ready
    }

    private var isFailedPhase: Bool {
        if case .failed = phase { return true }
        return false
    }

    private var isAwaitingAudioPhase: Bool {
        if case .awaitingAudio = phase { return true }
        return false
    }

    /// Missing sequences while the server waits for supplemented audio.
    var awaitingAudioSequences: [Int]? {
        if case .awaitingAudio(let missing) = phase { return missing }
        return nil
    }

    // MARK: - Recording intake

    /// Hands one finished local recording to the cloud chain. The recording ID
    /// is its stable utterance identity; submitting the same ID again (page
    /// refresh, re-entry) is ignored, so identities are never regenerated.
    /// During awaiting_audio the missing sequences may be supplemented here.
    @discardableResult
    func submitRecording(recordingID: String, wavData: Data, audioSource: String? = nil) async -> Bool {
        guard phase == .ready || isAwaitingAudioPhase, let uploader else { return false }
        guard !hasUploadInFlight, !hasFailedRetryableUpload else { return false }
        guard !submittedRecordingIDs.contains(recordingID) else { return false }
        let inspection: WAVUploadValidator.Inspection
        do {
            inspection = try WAVUploadValidator.validate(wavData)
        } catch let error as BackendHTTPError {
            lastFailure = CloudFailure(kind: .other, message: error.errorDescription ?? "本机 WAV 预检未通过")
            return false
        } catch {
            lastFailure = CloudFailure(kind: .other, message: "本机 WAV 预检未通过")
            return false
        }
        let sequence = await uploader.currentSequence
        // Re-check after the suspension: at most one upload may be in flight.
        guard !hasUploadInFlight, !hasFailedRetryableUpload else { return false }
        submittedRecordingIDs.insert(recordingID)
        utterances.append(UtteranceProgress(
            id: recordingID,
            sequence: sequence,
            sha256: inspection.sha256,
            state: .uploading
        ))
        let capturedEpoch = epoch
        pollTasks[recordingID] = Task { [weak self] in
            await self?.uploadAndProcess(
                recordingID: recordingID,
                wavData: wavData,
                audioSource: audioSource,
                epoch: capturedEpoch
            )
        }
        return true
    }

    /// Retries the most recent unsuccessful upload with its original identity
    /// (same utterance_id, sequence, bytes, and hash).
    func retryLastUpload() async {
        guard phase == .ready || isAwaitingAudioPhase, let uploader else { return }
        guard let identity = await uploader.pendingRetryIdentity else { return }
        guard let index = utterances.firstIndex(where: { $0.id == identity.utteranceID }) else { return }
        utterances[index].state = .uploading
        canRetryUploadWithOriginalIdentity = false
        let capturedEpoch = epoch
        pollTasks[identity.utteranceID] = Task { [weak self] in
            await self?.retryUploadAndProcess(utteranceID: identity.utteranceID, epoch: capturedEpoch)
        }
    }

    private func uploadAndProcess(recordingID: String, wavData: Data, audioSource: String?, epoch: Int) async {
        guard let uploader else { return }
        do {
            let accepted = try await uploader.upload(utteranceID: recordingID, wavData: wavData, audioSource: audioSource)
            try Task.checkCancellation()
            guard self.epoch == epoch else { return }
            noteAccepted(recordingID, accepted: accepted)
            await pollJobCompletion(utteranceID: recordingID, epoch: epoch)
        } catch is CancellationError {
            // The task was cancelled (session reset); state is already cleared.
        } catch {
            guard self.epoch == epoch else { return }
            noteUploadFailure(recordingID, error)
        }
    }

    private func retryUploadAndProcess(utteranceID: String, epoch: Int) async {
        guard let uploader else { return }
        do {
            let accepted = try await uploader.retryLastUpload()
            try Task.checkCancellation()
            guard self.epoch == epoch else { return }
            noteAccepted(utteranceID, accepted: accepted)
            await pollJobCompletion(utteranceID: utteranceID, epoch: epoch)
        } catch is CancellationError {
        } catch {
            guard self.epoch == epoch else { return }
            noteUploadFailure(utteranceID, error)
        }
    }

    private func noteAccepted(_ utteranceID: String, accepted: UploadAccepted) {
        canRetryUploadWithOriginalIdentity = false
        updateUtterance(utteranceID) {
            $0.state = .accepted
            $0.sourceAssurance = accepted.sourceAssurance
            $0.speakerVerification = accepted.speakerVerification
        }
    }

    /// The upload itself failed; the uploader keeps the identity for a retry.
    private func noteUploadFailure(_ utteranceID: String, _ error: Error) {
        let failure = CloudFailure(error as? BackendHTTPError
            ?? BackendHTTPError.transport("上传失败"))
        updateUtterance(utteranceID) { $0.state = .failed(failure) }
        lastFailure = failure
        canRetryUploadWithOriginalIdentity = failure.retryWithSameIdentity
    }

    /// The upload was accepted but polling failed; recovery is a re-query of
    /// the same job, not a new upload identity.
    private func notePollFailure(_ utteranceID: String, _ error: Error) {
        let failure = CloudFailure(error as? BackendHTTPError
            ?? BackendHTTPError.transport("轮询失败"))
        updateUtterance(utteranceID) { $0.state = .failed(failure) }
        lastFailure = failure
    }

    // MARK: - Job polling

    /// Re-queries a job that previously timed out (same utterance identity).
    func requeryJob(utteranceID: String) {
        guard phase == .ready || isAwaitingAudioPhase, sessionID != nil else { return }
        if let index = utterances.firstIndex(where: { $0.id == utteranceID }),
           case .failed = utterances[index].state {
            utterances[index].state = .processing("重新查询中")
        }
        let capturedEpoch = epoch
        pollTasks[utteranceID] = Task { [weak self] in
            await self?.pollJobCompletion(utteranceID: utteranceID, epoch: capturedEpoch)
        }
    }

    private func pollJobCompletion(utteranceID: String, epoch: Int) async {
        guard let sessionID else { return }
        updateUtterance(utteranceID) {
            if case .uploading = $0.state { $0.state = .processing("queued") }
        }
        do {
            let response = try await client.waitForJobCompletion(
                sessionID: sessionID,
                utteranceID: utteranceID,
                pollInterval: jobPollInterval,
                timeout: jobPollTimeout
            )
            try Task.checkCancellation()
            guard self.epoch == epoch else { return }
            let decision = response.job.outcome?.decision
            updateUtterance(utteranceID) {
                $0.state = .done(
                    decision: decision,
                    finalText: response.job.finalText,
                    reason: response.job.outcome?.reason
                )
            }
            // Only now — after Facts may have been committed — refresh records.
            refreshRecords()
        } catch is CancellationError {
        } catch {
            guard self.epoch == epoch else { return }
            notePollFailure(utteranceID, error)
        }
    }

    // MARK: - Records (facts / pending / events)

    /// Fetches facts, pending and events with the persistent event cursor.
    /// Cancelling replaces the previous refresh; results from an old session
    /// epoch are discarded. Decode failures keep the previous data and surface
    /// an error instead of presenting "no pending content".
    func refreshRecords() {
        guard let sessionID,
              phase == .ready || isAwaitingAudioPhase || phase == .finished else { return }
        refreshTask?.cancel()
        isRefreshingRecords = true
        let capturedEpoch = epoch
        let sid = sessionID
        let client = self.client
        refreshTask = Task { [weak self] in
            var fetchFailure: CloudFailure?
            var fetchedFacts: [TrainingFactDTO]?
            var fetchedPending: [PendingItem]?
            var fetchedEvents: EventsPage?

            do {
                fetchedFacts = try await client.facts(sessionID: sid)
            } catch let error as BackendHTTPError {
                fetchFailure = CloudFailure(error)
            } catch {
                fetchFailure = CloudFailure(kind: .other, message: "Facts 刷新已取消或失败")
            }
            do {
                fetchedPending = try await client.pending(sessionID: sid)
            } catch let error as BackendHTTPError {
                fetchFailure = fetchFailure ?? CloudFailure(error)
            } catch {
                fetchFailure = fetchFailure ?? CloudFailure(kind: .other, message: "Pending 刷新已取消或失败")
            }
            do {
                var after = self?.eventCursor ?? 0
                do {
                    fetchedEvents = try await client.events(sessionID: sid, after: after)
                } catch BackendHTTPError.eventCursorConflict {
                    // Cursor moved ahead server-side: reset once and refetch.
                    after = 0
                    fetchedEvents = try await client.events(sessionID: sid, after: after)
                }
            } catch let error as BackendHTTPError {
                fetchFailure = fetchFailure ?? CloudFailure(error)
            } catch {
                fetchFailure = fetchFailure ?? CloudFailure(kind: .other, message: "刷新已取消")
            }

            guard let self, !Task.isCancelled, self.epoch == capturedEpoch, self.sessionID == sid else { return }
            self.isRefreshingRecords = false
            if let fetchedFacts {
                self.mergeFacts(fetchedFacts)
            }
            if let fetchedPending {
                self.mergePending(fetchedPending)
            }
            if let fetchedEvents {
                self.mergeEvents(fetchedEvents)
            }
            if let fetchFailure {
                self.lastFailure = fetchFailure
                self.recordsFailure = fetchFailure
            } else {
                self.recordsFailure = nil
            }
        }
    }

    private func mergeFacts(_ fetched: [TrainingFactDTO]) {
        var merged = facts
        for fact in fetched where !factIDs.contains(fact.id) {
            factIDs.insert(fact.id)
            merged.append(fact)
        }
        facts = merged
    }

    private func mergePending(_ fetched: [PendingItem]) {
        var merged = pendingItems
        for item in fetched {
            let key = Self.pendingKey(item)
            guard !pendingKeys.contains(key) else { continue }
            pendingKeys.insert(key)
            merged.append(item)
        }
        pendingItems = merged
    }

    private func mergeEvents(_ page: EventsPage) {
        var merged = events
        for event in page.events where event.eventSeq > maxEventSeq {
            maxEventSeq = event.eventSeq
            merged.append(event)
        }
        events = merged
        eventCursor = max(eventCursor, page.nextCursor)
    }

    private static func pendingKey(_ item: PendingItem) -> String {
        if let pendingID = item.pendingID { return "id:\(pendingID)" }
        // GAP-PENDING-SHAPE fallback: a stable hash over the raw fields.
        return "fields:" + item.fields.keys.sorted().compactMap { key -> String? in
            guard let value = item.fields[key] else { return nil }
            return "\(key)=\(value)"
        }.joined(separator: "|")
    }

    // MARK: - Finish

    /// Stops input and drains the cloud finish barrier: POST finish with a
    /// stable finish_id and the true last accepted sequence, then poll until
    /// complete. 202 draining keeps the phase at `.finishing`; 409
    /// awaiting_audio surfaces the missing sequences for recovery.
    func beginFinish() async {
        guard phase == .ready, let sessionID, let uploader else { return }
        guard !hasUploadInFlight else {
            lastFailure = CloudFailure(kind: .other, message: "仍有上传未完成，请等待上传结束后再结束训练。")
            return
        }
        guard !hasFailedRetryableUpload else {
            lastFailure = CloudFailure(kind: .other, message: "有片段未完成确认：请先用原标识重试上传或重新查询结果，再结束训练。")
            return
        }
        let lastSequence = max(-1, await uploader.currentSequence - 1)
        startFinishDrain(sessionID: sessionID, finishID: finishID, lastSequence: lastSequence)
    }

    /// Re-runs the finish barrier with the SAME finish_id (contract recovery
    /// for awaiting_audio once the missing audio has been supplemented, or a
    /// repeat attempt after a non-awaiting finish failure).
    func retryFinish() async {
        guard sessionID != nil, let uploader, isAwaitingAudioPhase || isFailedPhase else { return }
        guard !hasUploadInFlight, !hasFailedRetryableUpload else {
            lastFailure = CloudFailure(kind: .other, message: "补传片段尚未完成，请等待或先重试该段。")
            return
        }
        let lastSequence = max(-1, await uploader.currentSequence - 1)
        startFinishDrain(sessionID: sessionID!, finishID: finishID, lastSequence: lastSequence)
    }

    private func startFinishDrain(sessionID: String, finishID: String, lastSequence: Int) {
        phase = .finishing
        lastFailure = nil
        let capturedEpoch = epoch
        let client = self.client
        let pollInterval = jobPollInterval
        let timeout = drainTimeout
        finishTask = Task { [weak self] in
            do {
                let response = try await client.drainToCompletion(
                    sessionID: sessionID,
                    finishID: finishID,
                    lastSequence: lastSequence,
                    pollInterval: pollInterval,
                    timeout: timeout
                )
                try Task.checkCancellation()
                guard let self, self.epoch == capturedEpoch, self.sessionID == sessionID else { return }
                self.phase = .finished
                // The finish envelope may already carry the completed review.
                if let review = response.review {
                    self.review = review
                    self.reviewNotReady = false
                }
                // The final facts/events may have landed during draining.
                self.refreshRecords()
                self.loadReview()
            } catch is CancellationError {
            } catch let error as BackendHTTPError {
                guard let self, self.epoch == capturedEpoch, self.sessionID == sessionID else { return }
                if case .finishAwaitingAudio(let missing) = error {
                    self.phase = .awaitingAudio(missing)
                } else {
                    self.phase = .failed(CloudFailure(error))
                }
            } catch {
                guard let self, self.epoch == capturedEpoch, self.sessionID == sessionID else { return }
                self.phase = .failed(CloudFailure(kind: .other, message: "结束请求已取消或失败"))
            }
        }
    }

    // MARK: - Review

    /// Loads the server review. A 409 is a normal "not ready yet" state, not a
    /// hard failure; other errors surface with contract semantics.
    func loadReview() {
        guard let sessionID, phase == .finished || isAwaitingAudioPhase else { return }
        let capturedEpoch = epoch
        let sid = sessionID
        let client = self.client
        Task { [weak self] in
            do {
                let review = try await client.review(sessionID: sid)
                guard let self, self.epoch == capturedEpoch, self.sessionID == sid else { return }
                self.review = review
                self.reviewNotReady = false
            } catch BackendHTTPError.reviewNotFinished {
                guard let self, self.epoch == capturedEpoch, self.sessionID == sid else { return }
                self.reviewNotReady = true
            } catch let error as BackendHTTPError {
                guard let self, self.epoch == capturedEpoch, self.sessionID == sid else { return }
                self.lastFailure = CloudFailure(error)
            } catch {
                // Cancellation after a reset: nothing to preserve.
            }
        }
    }

    // MARK: - Scenario / reset

    func applyMockScenario(_ scenario: MockCloudBackend.Scenario) {
        guard let mockBackend else { return }
        Task { await mockBackend.configure(scenario) }
    }

    /// Discards the session view state; a new session gets fresh identities.
    func reset() {
        epoch += 1
        pollTasks.values.forEach { $0.cancel() }
        pollTasks = [:]
        refreshTask?.cancel()
        refreshTask = nil
        finishTask?.cancel()
        finishTask = nil
        uploader = nil
        sessionID = nil
        phase = .idle
        utterances = []
        facts = []
        pendingItems = []
        events = []
        review = nil
        reviewNotReady = false
        lastFailure = nil
        recordsFailure = nil
        isRefreshingRecords = false
        canRetryUploadWithOriginalIdentity = false
        submittedRecordingIDs = []
        eventCursor = 0
        pendingKeys = []
        factIDs = []
        maxEventSeq = 0
        finishID = UUID().uuidString
    }

    private func updateUtterance(_ utteranceID: String, _ transform: (inout UtteranceProgress) -> Void) {
        guard let index = utterances.firstIndex(where: { $0.id == utteranceID }) else { return }
        transform(&utterances[index])
    }
}
