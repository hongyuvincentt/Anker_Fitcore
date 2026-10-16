import CryptoKit
import Foundation

/// Offline scripted backend for the cloud training chain. It answers the same
/// routes as the frozen V1.1 contract and keeps every byte of state in memory;
/// no request ever leaves the machine. It powers the in-app Mock mode and the
/// offline CloudTrainingModel tests, and is the only "server" this round uses.
///
/// Honest-Mock rules:
/// - `speaker_verification` is always "not_performed"; deferred uploads surface
///   `SOURCE_UNCERTAIN`. The mock never fabricates a verified identity.
/// - Pending items expose only the confirmed fields (id, status) — the rest of
///   the item shape is a documented gap (GAP-PENDING-SHAPE).
/// - Scenario presets only inject contract-documented failures (503, 401,
///   malformed JSON, awaiting_audio, review 409); they never simulate trust
///   switches or server-side verification.
actor MockCloudBackend: HTTPTransport {
    struct Scenario: Sendable, Equatable {
        /// The first accepted upload finishes DEFER with a SOURCE_UNCERTAIN
        /// pending item instead of a committed fact.
        var deferFirstUtterance = false
        /// Upload attempts that answer 503 before the same identity succeeds.
        var uploadFailuresBeforeSuccess = 0
        /// Every /v1/* request answers 401 (configuration/permission demo).
        var respondUnauthorized = false
        /// facts/pending GET answers with malformed JSON (decode demo).
        var recordsDecodeFailure = false
        /// The first finish POST answers 409 awaiting_audio with these
        /// sequences; re-POSTing the same finish_id then completes.
        var finishMissingSequences: [Int] = []
        /// Review GET answers 409 this many times before succeeding.
        var reviewNotReadyPolls = 0
        /// Jobs never leave `queued` (client poll-timeout demo).
        var jobsNeverComplete = false

        static let normal = Scenario()
        static let deferPending = Scenario(deferFirstUtterance: true)
        static let uploadRetryExhausted = Scenario(uploadFailuresBeforeSuccess: 3)
        static let unauthorized = Scenario(respondUnauthorized: true)
        static let recordsMalformed = Scenario(recordsDecodeFailure: true)
        static let finishAwaitingAudio = Scenario(finishMissingSequences: [1])
        static let reviewDelayed = Scenario(reviewNotReadyPolls: 2)
        static let jobsStuck = Scenario(jobsNeverComplete: true)
    }

    struct RecordedRequest: Sendable, Equatable {
        let method: String
        let path: String
        let query: String?
        let bodySHA256: String?
        let bodyByteCount: Int
    }

    private struct MockUpload {
        let utteranceID: String
        let sequence: Int
        let sha256: String
        var attempts = 0
        var polls = 0
        var finished = false
        var deferred = false
    }

    private struct MockSession {
        var uploads: [MockUpload] = []
        var facts: [[String: Any]] = []
        var pending: [[String: Any]] = []
        var events: [[String: Any]] = []
        var nextFactID = 1
        var nextPendingID = 1
        var nextEventSeq = 1
        var finishPOSTs = 0
        var finishRequested = false
        var finishGETs = 0
        var finishAwaitingReported = false
        var finishComplete = false
        var reviewPolls = 0
    }

    private var scenario = Scenario.normal
    private var sessions: [String: MockSession] = [:]
    private(set) var recorded: [RecordedRequest] = []

    private let createdAt = "2026-10-16T00:00:00Z"

    // MARK: - Test/demo controls

    func configure(_ scenario: Scenario) {
        self.scenario = scenario
    }

    func currentScenario() -> Scenario { scenario }

    /// Number of accepted uploads for a session (test assertions).
    func acceptedUploadCount(sessionID: String) -> Int {
        sessions[sessionID]?.uploads.count ?? 0
    }

    // MARK: - HTTPTransport

    nonisolated func send(_ request: URLRequest) async throws -> (data: Data, response: HTTPURLResponse) {
        let body = request.httpBody ?? Data()
        let sha = Data(SHA256.hash(data: body)).map { String(format: "%02x", $0) }.joined()
        let path = request.url?.path ?? "/"
        let query = request.url?.query
        let contentType = request.value(forHTTPHeaderField: "Content-Type")
        await record(RecordedRequest(
            method: request.httpMethod ?? "",
            path: path,
            query: query,
            bodySHA256: body.isEmpty ? nil : sha,
            bodyByteCount: body.count
        ))
        let status: Int
        let payload: Data
        do {
            (status, payload) = try await handle(
                method: request.httpMethod ?? "",
                path: path,
                query: query,
                contentType: contentType,
                body: body
            )
        } catch {
            throw BackendHTTPError.transport("Mock 后端内部错误")
        }
        let response = HTTPURLResponse(
            url: request.url ?? URL(string: "https://mock.fitcore.local")!,
            statusCode: status,
            httpVersion: "HTTP/1.1",
            headerFields: ["Content-Type": "application/json"]
        )!
        return (payload, response)
    }

    private func record(_ request: RecordedRequest) {
        recorded.append(request)
    }

    // MARK: - Routing

    private func handle(method: String, path: String, query: String?, contentType: String?, body: Data) throws -> (Int, Data) {
        if path == "/health" {
            return (200, json(["status": "ok", "model_provider": "mock"]))
        }
        guard path.hasPrefix("/v1/") else {
            return (404, json(["detail": "NOT_FOUND"]))
        }
        if scenario.respondUnauthorized {
            return (401, json(["detail": "MOCK_SCENARIO_UNAUTHORIZED"]))
        }
        // "/v1/sessions" → ["v1", "sessions"]; "/v1/sessions/ID" → 3 parts;
        // "/v1/sessions/ID/facts" → 4 parts (split drops the leading empty).
        let parts = path.split(separator: "/").map(String.init)
        let sessionID = parts.count > 2 ? parts[2] : ""
        let route = parts.count > 3 ? parts[3...].joined(separator: "/") : ""

        if method == "POST", parts.count == 2, parts[1] == "sessions" {
            return try createSession(body: body)
        }
        if method == "GET", parts.count == 3, parts[1] == "sessions" {
            return try sessionContext(sessionID: sessionID)
        }
        guard var session = sessions[sessionID] else {
            return (404, json(["detail": "SESSION_NOT_FOUND"]))
        }
        // Persist any mutation below back into the session store.
        defer { sessions[sessionID] = session }

        if method == "POST", route == "audio-jobs" {
            return try acceptUpload(&session, sessionID: sessionID, contentType: contentType, body: body)
        }
        if method == "GET", route.hasPrefix("audio-jobs/") {
            return try jobStatus(&session, sessionID: sessionID, utteranceID: String(route.dropFirst("audio-jobs/".count)))
        }
        if method == "GET", route == "facts" {
            if scenario.recordsDecodeFailure {
                return (200, Data("{{not-json".utf8))
            }
            return (200, json(session.facts))
        }
        if method == "GET", route == "pending" {
            if scenario.recordsDecodeFailure {
                return (200, Data("{{not-json".utf8))
            }
            return (200, json(session.pending))
        }
        if method == "GET", route == "events" {
            return try eventsPage(session: session, query: query)
        }
        if method == "POST", route == "finish" {
            return try finishPOST(&session, sessionID: sessionID, body: body)
        }
        if method == "GET", route == "finish" {
            return try finishGET(&session, sessionID: sessionID)
        }
        if method == "GET", route == "review" {
            return try review(&session, sessionID: sessionID)
        }
        return (404, json(["detail": "NOT_FOUND"]))
    }

    // MARK: - Session

    private func createSession(body: Data) throws -> (Int, Data) {
        let request = try JSONSerialization.jsonObject(with: body) as? [String: Any]
        guard let sessionID = request?["session_id"] as? String, !sessionID.isEmpty else {
            return (422, json(["detail": "INVALID_SESSION_ID"]))
        }
        guard sessions[sessionID] == nil else {
            return (409, json(["detail": "SESSION_ALREADY_EXISTS"]))
        }
        sessions[sessionID] = MockSession()
        return (201, sessionContextJSON(sessionID: sessionID))
    }

    private func sessionContext(sessionID: String) throws -> (Int, Data) {
        guard sessions[sessionID] != nil else {
            return (404, json(["detail": "SESSION_NOT_FOUND"]))
        }
        return (200, sessionContextJSON(sessionID: sessionID))
    }

    private func sessionContextJSON(sessionID: String) -> Data {
        json([
            "session_id": sessionID,
            "version": 0,
            "status": "active",
            "active_exercise_instance_id": NSNull(),
            "active_exercise_name": NSNull(),
            "last_completed_set_id": NSNull(),
            "last_reported_weight": NSNull(),
            "next_set_plan": NSNull(),
        ])
    }

    // MARK: - Upload

    private func acceptUpload(_ session: inout MockSession, sessionID: String, contentType: String?, body: Data) throws -> (Int, Data) {
        guard let contentType else {
            return (422, json(["detail": "MISSING_CONTENT_TYPE"]))
        }
        let parts = parseMultipart(body: body, contentType: contentType)
        guard let utteranceID = parts.utteranceID, let sequence = parts.sequence, let file = parts.fileBytes else {
            return (422, json(["detail": "MULTIPART_FIELDS_MISSING"]))
        }
        let sha = Data(SHA256.hash(data: file)).map { String(format: "%02x", $0) }.joined()

        if let index = session.uploads.firstIndex(where: { $0.utteranceID == utteranceID }) {
            // Same id must carry the same content; otherwise a contract 409.
            guard session.uploads[index].sha256 == sha, session.uploads[index].sequence == sequence else {
                return (409, json(["detail": "UPLOAD_IDENTITY_CONFLICT"]))
            }
            session.uploads[index].attempts += 1
        } else {
            if session.uploads.contains(where: { $0.sequence == sequence }) {
                return (409, json(["detail": "SEQUENCE_CONFLICT"]))
            }
            session.uploads.append(MockUpload(utteranceID: utteranceID, sequence: sequence, sha256: sha, attempts: 1))
        }
        let uploadIndex = session.uploads.firstIndex { $0.utteranceID == utteranceID }!
        // Contract-documented retryable failure: 503 answered until the same
        // identity has been attempted enough times.
        if session.uploads[uploadIndex].attempts <= scenario.uploadFailuresBeforeSuccess {
            return (503, json(["detail": "MOCK_SCENARIO_UNAVAILABLE"]))
        }
        return (202, json([
            "acceptance": "persisted",
            "speaker_verification": "not_performed",
            "source_assurance": "SOURCE_UNCERTAIN",
            "job": jobJSON(sessionID: sessionID, upload: session.uploads[uploadIndex], status: "queued"),
        ]))
    }

    // MARK: - Job status

    private func jobStatus(_ session: inout MockSession, sessionID: String, utteranceID: String) throws -> (Int, Data) {
        guard let index = session.uploads.firstIndex(where: { $0.utteranceID == utteranceID }) else {
            return (404, json(["detail": "JOB_NOT_FOUND"]))
        }
        session.uploads[index].polls += 1
        let statuses = ["queued", "asr_running", "final_ready", "llm_running", "done"]
        let status = scenario.jobsNeverComplete
            ? "queued"
            : statuses[min(session.uploads[index].polls, statuses.count - 1)]

        // Finalize the outcome exactly once, when done is first reported.
        if status == "done", !session.uploads[index].finished {
            session.uploads[index].finished = true
            let upload = session.uploads[index]
            let setNumber = session.facts.count + 1
            appendEvent(&session, type: "TRANSCRIPT_FINAL", utteranceID: upload.utteranceID,
                        payload: ["final_text": "第\(setNumber)组 卧推 60公斤 10次"])
            if scenario.deferFirstUtterance && upload.sequence == 0 {
                session.uploads[index].deferred = true
                let pendingID = session.nextPendingID
                session.nextPendingID += 1
                // GAP-PENDING-SHAPE: only confirmed fields (id, status) are emitted.
                session.pending.append(["id": pendingID, "status": "open"])
                appendEvent(&session, type: "OPERATION_DEFERRED", utteranceID: upload.utteranceID,
                            payload: ["reason": "SOURCE_UNCERTAIN", "pending_id": pendingID])
            } else {
                let factID = session.nextFactID
                session.nextFactID += 1
                session.facts.append([
                    "id": factID,
                    "exercise_instance_id": factID,
                    "exercise": "卧推",
                    "set_number": setNumber,
                    "weight_kg": 60,
                    "reps": 10,
                    "weight_provenance": "reported",
                    "weight_source_fact_id": NSNull(),
                    "source_utterance_id": upload.utteranceID,
                ])
                appendEvent(&session, type: "FACT_COMMITTED", utteranceID: upload.utteranceID,
                            payload: ["fact_id": factID])
            }
        }

        let upload = session.uploads[index]
        var finalText: String?
        var outcome: [String: Any]?
        if status == "done" {
            let decision = upload.deferred ? "DEFER" : "COMMIT"
            finalText = upload.deferred ? "第\(upload.sequence + 1)段口述需要来源确认" : "第\(session.facts.count)组 卧推 60公斤 10次"
            outcome = [
                "utterance_id": upload.utteranceID,
                "decision": decision,
                "context_version": session.facts.count,
                "committed": upload.deferred ? NSNull() : [[
                    "type": "create_set",
                    "id": session.nextFactID - 1,
                    "exercise_instance_id": session.nextFactID - 1,
                    "exercise": "卧推",
                    "set_number": session.facts.count,
                    "weight_kg": 60,
                    "reps": 10,
                    "weight_provenance": "reported",
                    "note": NSNull(),
                ]],
                "reason": upload.deferred ? "SOURCE_UNCERTAIN" : NSNull(),
                "semantic_diagnostics": NSNull(),
                "reparse": NSNull(),
            ]
        }
        return (200, json([
            "speaker_verification": "not_performed",
            "automatic_retry_exhausted": false,
            "job": jobJSON(
                sessionID: sessionID,
                upload: upload,
                status: status,
                finalText: finalText,
                outcome: outcome
            ),
        ]))
    }

    // MARK: - Events

    private func eventsPage(session: MockSession, query: String?) throws -> (Int, Data) {
        var after = 0
        var limit = 100
        if let query {
            for pair in query.split(separator: "&") {
                let kv = pair.split(separator: "=", maxSplits: 1).map(String.init)
                if kv.count == 2 {
                    if kv[0] == "after" { after = Int(kv[1]) ?? after }
                    if kv[0] == "limit" { limit = Int(kv[1]) ?? limit }
                }
            }
        }
        guard after >= 0, (1...100).contains(limit) else {
            return (422, json(["detail": "INVALID_CURSOR"]))
        }
        let matched = session.events.filter { ($0["event_seq"] as? Int ?? 0) > after }
        let page = Array(matched.prefix(limit))
        let nextCursor = page.last?["event_seq"] as? Int ?? after
        return (200, json([
            "events": page,
            "next_cursor": nextCursor,
            "has_more": matched.count > page.count,
        ]))
    }

    // MARK: - Finish / review

    private func finishPOST(_ session: inout MockSession, sessionID: String, body: Data) throws -> (Int, Data) {
        let request = try JSONSerialization.jsonObject(with: body) as? [String: Any]
        let finishID = request?["finish_id"] as? String ?? ""
        let lastSequence = request?["last_sequence"] as? Int ?? -1
        session.finishPOSTs += 1
        // awaiting_audio stays 409 until the missing sequences are actually
        // uploaded; re-POSTing the same finish_id alone never completes it.
        if !session.finishComplete, !scenario.finishMissingSequences.isEmpty {
            let missing = scenario.finishMissingSequences.filter { seq in
                !session.uploads.contains(where: { $0.sequence == seq })
            }
            if !missing.isEmpty {
                session.finishAwaitingReported = true
                return (409, json([
                    "session_id": sessionID,
                    "finish_id": finishID,
                    "last_sequence": lastSequence,
                    "state": "awaiting_audio",
                    "complete": false,
                    "acceptance_closed": false,
                    "missing_sequences": missing,
                    "missing_count": missing.count,
                    "unfinished": missing.map { seq in
                        [
                            "utterance_id": "mock-missing-\(seq)",
                            "sequence": seq,
                            "audio_sha256": "0",
                            "status": "queued",
                            "error_type": NSNull(),
                        ] as [String: Any]
                    },
                    "accepted_count": session.uploads.count,
                    "ready_to_finalize": false,
                    "review": NSNull(),
                ]))
            }
        }
        // POST answers 202 draining until the finalize barrier is done; the
        // GET poll below completes it (contract draining path).
        session.finishRequested = true
        if session.finishComplete {
            return (200, finishJSON(session: session, sessionID: sessionID, finishID: finishID, lastSequence: lastSequence))
        }
        return (202, finishJSON(session: session, sessionID: sessionID, finishID: finishID, lastSequence: lastSequence))
    }

    private func finishGET(_ session: inout MockSession, sessionID: String) throws -> (Int, Data) {
        guard session.finishRequested else {
            return (404, json(["detail": "FINISH_NOT_STARTED"]))
        }
        session.finishGETs += 1
        if session.finishGETs >= 2 { session.finishComplete = true }
        return (200, finishJSON(
            session: session, sessionID: sessionID,
            finishID: "status", lastSequence: session.uploads.count - 1
        ))
    }

    private func finishJSON(session: MockSession, sessionID: String, finishID: String, lastSequence: Int) -> Data {
        json([
            "session_id": sessionID,
            "finish_id": finishID,
            "last_sequence": lastSequence,
            "state": session.finishComplete ? "finished" : "draining",
            "complete": session.finishComplete,
            "acceptance_closed": session.finishComplete,
            "missing_sequences": [] as [Int],
            "missing_count": 0,
            "unfinished": [] as [[String: Any]],
            "accepted_count": session.uploads.count,
            "ready_to_finalize": session.finishComplete,
            // The envelope only carries a review when one would be served by
            // GET /review as well (reviewDelayed keeps it a separate 409 path).
            "review": session.finishComplete && scenario.reviewNotReadyPolls == 0
                ? reviewJSON(session: session, sessionID: sessionID) : NSNull(),
        ])
    }

    private func review(_ session: inout MockSession, sessionID: String) throws -> (Int, Data) {
        guard session.finishComplete else {
            return (409, json(["detail": "SESSION_NOT_FINISHED"]))
        }
        session.reviewPolls += 1
        if session.reviewPolls <= scenario.reviewNotReadyPolls {
            return (409, json(["detail": "SESSION_NOT_FINISHED"]))
        }
        return (200, json(reviewJSON(session: session, sessionID: sessionID)))
    }

    private func reviewJSON(session: MockSession, sessionID: String) -> [String: Any] {
        [
            "session_id": sessionID,
            "context_version": session.facts.count,
            "total_sets": session.facts.count,
            "total_reps": session.facts.reduce(0) { $0 + (($1["reps"] as? NSNumber)?.intValue ?? 0) },
            "volume_kg_reps": session.facts.reduce(0.0) {
                let weight = ($1["weight_kg"] as? NSNumber)?.doubleValue ?? 0
                let reps = ($1["reps"] as? NSNumber)?.intValue ?? 0
                return $0 + weight * Double(reps)
            },
            "pending_count": session.pending.count,
            "facts": session.facts,
        ]
    }

    // MARK: - Helpers

    private func appendEvent(_ session: inout MockSession, type: String, utteranceID: String, payload: [String: Any]) {
        let seq = session.nextEventSeq
        session.nextEventSeq += 1
        session.events.append([
            "event_seq": seq,
            "event_id": "mock-evt-\(seq)",
            "type": type,
            "utterance_id": utteranceID,
            "payload": payload,
            "created_at": createdAt,
        ])
    }

    private func jobJSON(
        sessionID: String,
        upload: MockUpload,
        status: String,
        finalText: String? = nil,
        outcome: [String: Any]? = nil
    ) -> [String: Any] {
        [
            "session_id": sessionID,
            "utterance_id": upload.utteranceID,
            "sequence": upload.sequence,
            "audio_sha256": upload.sha256,
            "audio_source": "iphone_mic",
            "source_type": "SOURCE_UNCERTAIN",
            "speaker_status": "unknown",
            "status": status,
            "final_text": finalText ?? NSNull(),
            "asr_attempts": 1,
            "llm_attempts": 1,
            "error_type": NSNull(),
            "audio_metadata": [
                "sample_rate": 16000,
                "channels": 1,
                "bits_per_sample": 16,
                "frames": 16000,
                "duration_seconds": 1.0,
                "rms_dbfs": -12.0,
                "peak_dbfs": -6.0,
                "clipped_fraction": 0,
                "non_silent": true,
            ] as [String: Any],
            "outcome": outcome ?? NSNull(),
            "asr_diagnostics": NSNull(),
        ]
    }

    private func json(_ object: Any) -> Data {
        (try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])) ?? Data("{}".utf8)
    }
}

// MARK: - Multipart parsing

private struct ParsedMultipart {
    var utteranceID: String?
    var sequence: Int?
    var audioSource: String?
    var fileBytes: Data?
}

private func parseMultipart(body: Data, contentType: String) -> ParsedMultipart {
    var result = ParsedMultipart()
    guard let boundaryRange = contentType.range(of: "boundary=") else { return result }
    let boundary = String(contentType[boundaryRange.upperBound...]).trimmingCharacters(in: .whitespaces)
    let delimiter = Data("--\(boundary)".utf8)
    var segments = [Data]()
    var searchStart = body.startIndex
    while let range = body.range(of: delimiter, in: searchStart..<body.endIndex) {
        if range.lowerBound > searchStart {
            segments.append(body.subdata(in: searchStart..<range.lowerBound))
        }
        searchStart = range.upperBound
    }
    for segment in segments {
        guard segment.count >= 2 else { continue }
        var content = segment
        // Each part is preceded by \r\n before its boundary delimiter.
        if content.prefix(2) == Data("\r\n".utf8) { content = content.dropFirst(2) }
        guard content.first != UInt8(ascii: "-") else { continue } // closing delimiter
        guard let headerEnd = content.range(of: Data("\r\n\r\n".utf8)) else { continue }
        let headerData = content.subdata(in: content.startIndex..<headerEnd.lowerBound)
        var valueData = content.subdata(in: headerEnd.upperBound..<content.endIndex)
        // Trailing \r\n before the next delimiter belongs to the delimiter.
        if valueData.suffix(2) == Data("\r\n".utf8) { valueData = valueData.dropLast(2) }
        let header = String(decoding: headerData, as: UTF8.self)
        guard let nameRange = header.range(of: "name=\"") else { continue }
        let nameStart = nameRange.upperBound
        guard let nameEnd = header[nameStart...].range(of: "\"") else { continue }
        let name = String(header[nameStart..<nameEnd.lowerBound])
        let value = String(decoding: valueData, as: UTF8.self)
        switch name {
        case "utterance_id": result.utteranceID = value
        case "sequence": result.sequence = Int(value)
        case "audio_source": result.audioSource = value
        case "file": result.fileBytes = valueData
        default: break
        }
    }
    return result
}
