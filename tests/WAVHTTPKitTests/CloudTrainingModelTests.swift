import XCTest
@testable import WAVHTTPKit

/// LHY-04 offline Mock integration tests for the cloud training chain.
/// Every request is answered by the in-process MockCloudBackend — nothing
/// leaves the machine, no real token is used, and every WAV fixture is the
/// synthetic generator (never a real person's voice).
///
/// Covered state groups (mirrors the LHY-04 prompt):
/// 1. processing → official Facts (202/done/transcript never add records)
/// 2. processing → Pending (DEFER with confirmed fields only)
/// 3. upload failure + retry with the ORIGINAL identity
/// 4. 401, poll timeout, malformed records responses
/// 5. finish 202/draining and 409/awaiting_audio (+ same finish_id recovery)
/// 6. review 409 (not ready) and success
/// 7. refresh / re-entry never duplicates cards or regenerates identities
@MainActor
final class CloudTrainingModelTests: XCTestCase {

    // MARK: - Helpers

    private func makeModel(
        scenario: MockCloudBackend.Scenario = .normal,
        jobPollTimeout: Duration = .seconds(3),
        drainTimeout: Duration = .seconds(3)
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
            jobPollInterval: .milliseconds(40),
            jobPollTimeout: jobPollTimeout,
            drainTimeout: drainTimeout
        )
        return (model, backend)
    }

    @discardableResult
    private func waitUntil(
        timeout: Duration = .seconds(6),
        _ condition: @MainActor () -> Bool
    ) async -> Bool {
        let deadline = ContinuousClock.now + timeout
        while ContinuousClock.now < deadline {
            if condition() { return true }
            do { try await Task.sleep(for: .milliseconds(20)) } catch { return false }
        }
        return condition()
    }

    private func startSession(_ model: CloudTrainingModel) async throws {
        model.createSession()
        let ready = await waitUntil { model.phase == .ready }
        XCTAssertTrue(ready, "会话应进入 ready，当前 phase: \(model.phase)")
    }

    @discardableResult
    private func submitAndWaitTerminal(
        _ model: CloudTrainingModel,
        recordingID: String = UUID().uuidString
    ) async -> String {
        let wav = SyntheticWAV.data(frames: 16_000)
        _ = await model.submitRecording(recordingID: recordingID, wavData: wav)
        let settled = await waitUntil {
            guard let last = model.utterances.last else { return false }
            switch last.state {
            case .done, .failed: return true
            default: return false
            }
        }
        XCTAssertTrue(settled, "片段应达到 done/failed 终态")
        return recordingID
    }

    private func audioJobPOSTs(_ backend: MockCloudBackend) async -> [MockCloudBackend.RecordedRequest] {
        await backend.recorded.filter { $0.method == "POST" && $0.path.hasSuffix("/audio-jobs") }
    }

    private func finishRequests(_ backend: MockCloudBackend, method: String) async -> [MockCloudBackend.RecordedRequest] {
        await backend.recorded.filter { $0.method == method && $0.path.hasSuffix("/finish") }
    }

    // MARK: - 1. Processing → official Facts

    func testProcessingThenCommittedFactAppearsOnlyFromFacts() async throws {
        let (model, _) = try await makeModel()
        try await startSession(model)

        // While the job is still processing (never done), a records refresh
        // must not produce any official fact — 202/transcript are not records.
        let wav = SyntheticWAV.data(frames: 16_000)
        _ = await model.submitRecording(recordingID: "fact-probe", wavData: wav)
        let processing = await waitUntil {
            model.utterances.last.map { utterance in
                if case .processing = utterance.state { return true }
                if case .accepted = utterance.state { return true }
                return false
            } ?? false
        }
        XCTAssertTrue(processing, "片段应先进入处理中状态")
        model.refreshRecords()
        let noEarlyFact = await waitUntil { !model.isRefreshingRecords }
        XCTAssertTrue(noEarlyFact)
        XCTAssertTrue(model.facts.isEmpty, "处理中不应有正式训练组")

        // Once done with COMMIT, the fact comes from the server Facts feed.
        let done = await waitUntil {
            model.utterances.last.map { utterance in
                if case .done(let decision, _, _) = utterance.state { return decision == .commit }
                return false
            } ?? false
        }
        XCTAssertTrue(done, "片段应 done 且决策 COMMIT")
        let factAppeared = await waitUntil { model.facts.count == 1 }
        XCTAssertTrue(factAppeared, "done 后应从 Facts 获得正式训练组")
        XCTAssertEqual(model.facts.first?.exercise, "卧推")
        XCTAssertEqual(model.facts.first?.weightKg, 60)
        XCTAssertEqual(model.facts.first?.reps, 10)
        XCTAssertEqual(model.pendingItems.count, 0)
        XCTAssertFalse(model.reviewNotReady)
    }

    // MARK: - 2. Processing → Pending (DEFER)

    func testDeferredUtteranceProducesPendingWithConfirmedFieldsOnly() async throws {
        let (model, _) = try await makeModel(scenario: .deferPending)
        try await startSession(model)

        await submitAndWaitTerminal(model)
        let deferred = await waitUntil {
            model.utterances.first.map { utterance in
                if case .done(let decision, _, let reason) = utterance.state {
                    return decision == .defer && reason == "SOURCE_UNCERTAIN"
                }
                return false
            } ?? false
        }
        XCTAssertTrue(deferred, "首段应 DEFER 且原因为 SOURCE_UNCERTAIN")

        let pendingAppeared = await waitUntil { model.pendingItems.count == 1 }
        XCTAssertTrue(pendingAppeared, "DEFER 应产生一条 Pending")
        let item = try XCTUnwrap(model.pendingItems.first)
        XCTAssertEqual(item.pendingID, "1")
        XCTAssertEqual(item.status, "open")
        // GAP-PENDING-SHAPE: only id/status are confirmed fields.
        XCTAssertEqual(Set(item.fields.keys).sorted(), ["id", "status"])
        XCTAssertTrue(model.facts.isEmpty, "DEFER 不应产生正式训练组")

        // Honest source labels are preserved, never upgraded client-side.
        let first = try XCTUnwrap(model.utterances.first)
        XCTAssertEqual(first.sourceAssurance, "SOURCE_UNCERTAIN")
        XCTAssertEqual(first.speakerVerification, "not_performed")

        // A later utterance still commits normally.
        await submitAndWaitTerminal(model)
        let secondFact = await waitUntil { model.facts.count == 1 }
        XCTAssertTrue(secondFact, "第二段应正常提交 Fact")
        XCTAssertEqual(model.pendingItems.count, 1, "Pending 数量不应变化")
    }

    // MARK: - 3. Upload failure + retry with the original identity

    func testUploadFailureRetriesWithSameIdentityAndBytes() async throws {
        let (model, backend) = try await makeModel(scenario: .uploadRetryExhausted)
        try await startSession(model)

        let recordingID = "retry-probe"
        await submitAndWaitTerminal(model, recordingID: recordingID)
        let failed = await waitUntil {
            model.utterances.first.map { utterance in
                if case .failed(let failure) = utterance.state { return failure.retryWithSameIdentity }
                return false
            } ?? false
        }
        XCTAssertTrue(failed, "上传失败应可原标识重试")
        XCTAssertTrue(model.canRetryUploadWithOriginalIdentity)
        XCTAssertTrue(model.facts.isEmpty)

        await model.retryLastUpload()
        let recovered = await waitUntil {
            model.utterances.first.map { utterance in
                if case .done(let decision, _, _) = utterance.state { return decision == .commit }
                return false
            } ?? false
        }
        XCTAssertTrue(recovered, "原标识重试后应 done COMMIT")
        let factAppeared = await waitUntil { model.facts.count == 1 }
        XCTAssertTrue(factAppeared)

        // Every upload attempt carried the identical body (same utterance_id,
        // sequence, bytes): the identity was never regenerated.
        let posts = await audioJobPOSTs(backend)
        XCTAssertGreaterThanOrEqual(posts.count, 4, "3 次 503 + 1 次成功")
        let uniqueBodies = Set(posts.map { $0.bodySHA256 ?? "" })
        XCTAssertEqual(uniqueBodies.count, 1, "所有上传请求体必须字节一致")
        let sessionID = try XCTUnwrap(model.sessionID)
        let accepted = await backend.acceptedUploadCount(sessionID: sessionID)
        XCTAssertEqual(accepted, 1, "服务端只应接受一次该身份")
    }

    // MARK: - 4a. Unauthorized (401)

    func testUnauthorizedSurfacesAsFailedPhaseWithKind() async throws {
        let (model, backend) = try await makeModel(scenario: .unauthorized)
        model.createSession()
        let failed = await waitUntil {
            if case .failed(let failure) = model.phase { return failure.kind == .unauthorized }
            return false
        }
        XCTAssertTrue(failed, "401 应表现为 unauthorized 失败")
        XCTAssertNil(model.sessionID)
        let requests = await backend.recorded
        XCTAssertFalse(requests.isEmpty)
        XCTAssertTrue(requests.allSatisfy { $0.path.hasPrefix("/v1/") })
    }

    // MARK: - 4b. Poll timeout → re-query with the same identity

    func testJobPollTimeoutKeepsNoRecordsAndRequeryRecoversWithoutNewUpload() async throws {
        let (model, backend) = try await makeModel(
            scenario: .jobsStuck, jobPollTimeout: .milliseconds(400)
        )
        try await startSession(model)

        let recordingID = "timeout-probe"
        await submitAndWaitTerminal(model, recordingID: recordingID)
        let timedOut = await waitUntil {
            model.utterances.first.map { utterance in
                if case .failed(let failure) = utterance.state { return failure.kind == .timeout }
                return false
            } ?? false
        }
        XCTAssertTrue(timedOut, "Job 停滞应表现为轮询超时")
        XCTAssertFalse(model.canRetryUploadWithOriginalIdentity, "轮询失败不适用上传重试")

        // A records refresh while stuck must not invent facts.
        model.refreshRecords()
        _ = await waitUntil { !model.isRefreshingRecords }
        XCTAssertTrue(model.facts.isEmpty, "超时/停滞期间不应有正式训练组")

        // Re-query the same job after the backend recovers: no new upload.
        await backend.configure(.normal)
        model.requeryJob(utteranceID: recordingID)
        let recovered = await waitUntil {
            model.utterances.first.map { utterance in
                if case .done(let decision, _, _) = utterance.state { return decision == .commit }
                return false
            } ?? false
        }
        XCTAssertTrue(recovered, "重新查询应恢复为 done COMMIT")
        _ = await waitUntil { model.facts.count == 1 }
        let posts = await audioJobPOSTs(backend)
        XCTAssertEqual(posts.count, 1, "重新查询不得产生新的上传")
    }

    // MARK: - 4c. Malformed records responses keep old data + surface error

    func testMalformedRecordsResponseKeepsPreviousDataAndSurfacesDecodeError() async throws {
        let (model, backend) = try await makeModel()
        try await startSession(model)
        await submitAndWaitTerminal(model)
        _ = await waitUntil { model.facts.count == 1 }
        let eventsAfterFirst = model.events.count
        XCTAssertGreaterThanOrEqual(eventsAfterFirst, 2, "TRANSCRIPT_FINAL + FACT_COMMITTED")

        await backend.configure(.recordsMalformed)
        model.refreshRecords()
        let failureSurfaced = await waitUntil { model.recordsFailure != nil }
        XCTAssertTrue(failureSurfaced, "畸形响应必须显式报错")
        XCTAssertEqual(model.recordsFailure?.kind, .decoding)
        // Previous data survives; the failure is never shown as "no pending".
        XCTAssertEqual(model.facts.count, 1)
        XCTAssertEqual(model.events.count, eventsAfterFirst)

        await backend.configure(.normal)
        model.refreshRecords()
        let recovered = await waitUntil { model.recordsFailure == nil }
        XCTAssertTrue(recovered)
        XCTAssertEqual(model.facts.count, 1, "恢复正常后不产生重复卡片")
        XCTAssertEqual(model.events.count, eventsAfterFirst, "事件按 event_seq 去重")
    }

    // MARK: - 5a. Finish 202 draining → complete

    func testFinishDrainsThenCompletesWithReview() async throws {
        let (model, backend) = try await makeModel()
        try await startSession(model)
        await submitAndWaitTerminal(model)
        await submitAndWaitTerminal(model)
        _ = await waitUntil { model.facts.count == 2 }

        await model.beginFinish()
        XCTAssertEqual(model.phase, .finishing, "POST finish 202 后应处于 draining 阶段")
        let finished = await waitUntil { model.phase == .finished }
        XCTAssertTrue(finished, "draining 后应完成")
        let review = try XCTUnwrap(model.review, "完成后应拿到服务端 Review")
        XCTAssertEqual(review.totalSets, 2)
        XCTAssertEqual(review.totalReps, 20)
        XCTAssertEqual(review.volumeKgReps, 1200, accuracy: 0.001)
        XCTAssertEqual(review.pendingCount, 0)

        // The draining path really polled GET finish at least once.
        let gets = await finishRequests(backend, method: "GET")
        XCTAssertGreaterThanOrEqual(gets.count, 2, "应经历 GET finish 轮询")
        let posts = await finishRequests(backend, method: "POST")
        XCTAssertGreaterThanOrEqual(posts.count, 1)
    }

    // MARK: - 5b. Finish 409 awaiting_audio + same finish_id recovery

    func testFinishAwaitingAudioRequiresSupplementThenSameFinishID() async throws {
        let (model, backend) = try await makeModel(scenario: .finishAwaitingAudio)
        try await startSession(model)
        await submitAndWaitTerminal(model)
        _ = await waitUntil { model.facts.count == 1 }

        await model.beginFinish()
        let awaiting = await waitUntil { model.awaitingAudioSequences == [1] }
        XCTAssertTrue(awaiting, "应进入 awaiting_audio 且缺第 1 段")
        let originalFinishID = model.currentFinishID

        // Re-POST without the supplement must stay awaiting (honest mock).
        await model.retryFinish()
        let stillAwaiting = await waitUntil(timeout: .seconds(2)) { model.awaitingAudioSequences == [1] }
        XCTAssertTrue(stillAwaiting, "未补传时重试不得完成")
        XCTAssertEqual(model.currentFinishID, originalFinishID, "重试必须复用同一 finish_id")

        // Supplement the missing sequence, then the same finish_id completes.
        await submitAndWaitTerminal(model)
        _ = await waitUntil { model.facts.count == 2 }
        await model.retryFinish()
        let finished = await waitUntil { model.phase == .finished }
        XCTAssertTrue(finished, "补传后相同 finish_id 应完成")
        XCTAssertEqual(model.currentFinishID, originalFinishID)
        XCTAssertEqual(model.review?.totalSets, 2)
        let posts = await finishRequests(backend, method: "POST")
        XCTAssertGreaterThanOrEqual(posts.count, 3, "初始 + 未补传重试 + 最终重试")
    }

    // MARK: - 6. Review 409 then success

    func testReviewNotReadyThenSucceedsOnRetry() async throws {
        let (model, backend) = try await makeModel(scenario: .reviewDelayed)
        try await startSession(model)
        await submitAndWaitTerminal(model)

        await model.beginFinish()
        let finished = await waitUntil { model.phase == .finished }
        XCTAssertTrue(finished)
        let notReady = await waitUntil { model.reviewNotReady }
        XCTAssertTrue(notReady, "Review 延迟场景应先 409 未就绪")
        XCTAssertNil(model.review, "409 时不得伪造复盘")

        model.loadReview()
        _ = await waitUntil(timeout: .seconds(2)) { model.reviewNotReady }
        model.loadReview()
        let succeeded = await waitUntil { model.review != nil && !model.reviewNotReady }
        XCTAssertTrue(succeeded, "第三次获取应成功")
        XCTAssertEqual(model.review?.totalSets, 1)
        let reviewGets = await backend.recorded.filter { $0.method == "GET" && $0.path.hasSuffix("/review") }
        XCTAssertGreaterThanOrEqual(reviewGets.count, 3)
    }

    // MARK: - 7. Refresh / re-entry never duplicates or regenerates identity

    func testRefreshAndResubmitNeverDuplicateCardsOrIdentities() async throws {
        let (model, backend) = try await makeModel()
        try await startSession(model)
        let recordingID = "identity-probe"
        await submitAndWaitTerminal(model, recordingID: recordingID)
        _ = await waitUntil { model.facts.count == 1 }
        let eventsCount = model.events.count

        // Repeated refreshes (view re-entry) keep exactly one card each.
        for _ in 0..<3 { model.refreshRecords() }
        _ = await waitUntil { !model.isRefreshingRecords }
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertEqual(model.facts.count, 1)
        XCTAssertEqual(model.pendingItems.count, 0)
        XCTAssertEqual(model.events.count, eventsCount, "重复刷新不得重复事件")

        // Re-submitting the same recording is ignored — identity never regenerates.
        let wav = SyntheticWAV.data(frames: 16_000)
        let accepted = await model.submitRecording(recordingID: recordingID, wavData: wav)
        XCTAssertFalse(accepted, "同一 recording 不得二次提交")
        try await Task.sleep(for: .milliseconds(150))
        XCTAssertEqual(model.utterances.count, 1)
        let sessionID = try XCTUnwrap(model.sessionID)
        let acceptedUploads = await backend.acceptedUploadCount(sessionID: sessionID)
        XCTAssertEqual(acceptedUploads, 1, "服务端不得重复接受同一身份")

        // The chain still finishes cleanly after all the churn.
        await model.beginFinish()
        let finished = await waitUntil { model.phase == .finished }
        XCTAssertTrue(finished)
        XCTAssertEqual(model.review?.totalSets, 1)
    }

    // MARK: - Reset invalidates the old session view

    func testResetClearsStateAndNextSessionStartsFresh() async throws {
        let (model, _) = try await makeModel()
        try await startSession(model)
        await submitAndWaitTerminal(model)
        _ = await waitUntil { model.facts.count == 1 }

        model.reset()
        XCTAssertEqual(model.phase, .idle)
        XCTAssertNil(model.sessionID)
        XCTAssertTrue(model.facts.isEmpty)
        XCTAssertTrue(model.utterances.isEmpty)

        try await startSession(model)
        XCTAssertEqual(model.phase, .ready)
        XCTAssertTrue(model.facts.isEmpty, "新会话不得携带旧会话记录")
    }
}
