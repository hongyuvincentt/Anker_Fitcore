import Foundation

// MARK: - Configuration

/// Base URL and credentials are injected; offline tests never need real values.
/// The token is the private FITCORE_HTTP_API_TOKEN (never a MODEL_API_KEY), is
/// not hardcoded, and never appears in logs, error descriptions, or test output.
struct BackendHTTPConfiguration: Sendable, Equatable {
    enum ValidationError: LocalizedError, Equatable {
        case invalidBaseURL
        case invalidToken

        var errorDescription: String? {
            switch self {
            case .invalidBaseURL: return "后端地址必须是不含用户名、密码、查询参数的 HTTPS 地址。"
            case .invalidToken: return "请注入 Fitcore HTTP 访问令牌（不是模型 API Key）。"
            }
        }
    }

    let baseURL: URL
    let accessToken: String
    var requestTimeout: TimeInterval = 20
    /// Total attempts per idempotent call (1 = no automatic retry).
    var retryAttempts: Int = 3
    var retryDelay: Duration = .milliseconds(200)

    init(baseURL: URL, accessToken: String) throws {
        let trimmedToken = accessToken.trimmingCharacters(in: .whitespacesAndNewlines)
        guard baseURL.scheme == "https",
              let host = baseURL.host, !host.isEmpty,
              baseURL.user == nil, baseURL.password == nil,
              baseURL.query == nil, baseURL.fragment == nil,
              baseURL.path.isEmpty || baseURL.path == "/" else {
            throw ValidationError.invalidBaseURL
        }
        guard !trimmedToken.isEmpty, !trimmedToken.contains("\n"), !trimmedToken.contains("\r") else {
            throw ValidationError.invalidToken
        }
        // Normalize away a trailing slash so appended paths never double up.
        var components = URLComponents()
        components.scheme = "https"
        components.host = host
        if let port = baseURL.port { components.port = port }
        guard let normalized = components.url else { throw ValidationError.invalidBaseURL }
        self.baseURL = normalized
        self.accessToken = trimmedToken
    }
}

// MARK: - Transport

/// Injectable transport so contract tests intercept every network byte and no
/// request ever leaves the machine. Production uses URLSession.
protocol HTTPTransport: Sendable {
    func send(_ request: URLRequest) async throws -> (data: Data, response: HTTPURLResponse)
}

struct URLSessionTransport: HTTPTransport {
    let session: URLSession

    init(session: URLSession = .shared) {
        self.session = session
    }

    func send(_ request: URLRequest) async throws -> (data: Data, response: HTTPURLResponse) {
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw BackendHTTPError.transport("非 HTTP 响应")
        }
        return (data, http)
    }
}

// MARK: - Errors

enum BackendHTTPError: LocalizedError, Sendable, Equatable {
    case invalidConfiguration(String)
    /// Local pre-send validation (WAV format, sizes, field lengths).
    case invalidUpload(String)
    /// Local query/path parameter validation.
    case invalidParameters(String)
    case unauthorized
    case notFound
    case payloadTooLarge
    /// HTTP 422; the string is the server detail code, never a body dump.
    case requestRejected(String?)
    /// HTTP 503 — retryable with the exact same request identity.
    case serverUnavailable
    /// Network/timeout failure — retryable with the exact same request bytes.
    case transport(String)
    case retryBudgetExhausted(String)
    case sessionAlreadyExists(String)
    /// 409 on upload: same id different bytes, same sequence different id, or
    /// AUDIO_ACCEPTANCE_CLOSED after finish. Never resolved by changing ids.
    case uploadConflict(String?)
    case eventCursorConflict(String?)
    case pendingConflict(String?)
    case finishAwaitingAudio([Int])
    case finishRangeExcludesAccepted
    case finishConflict(String?)
    case reviewNotFinished(String?)
    case conflict(String?)
    case serverRetryExhausted(String)
    case pollTimeout(String)
    case decodingFailed(String)
    case unexpectedStatus(Int, String)

    var errorDescription: String? {
        switch self {
        case .invalidConfiguration(let reason): return "后端配置无效：\(reason)"
        case .invalidUpload(let reason): return "上传校验未通过：\(reason)"
        case .invalidParameters(let reason): return "请求参数无效：\(reason)"
        case .unauthorized: return "访问令牌无效或权限不足（401/403），请检查私密配置。"
        case .notFound: return "会话不存在（404）。"
        case .payloadTooLarge: return "请求体过大（413）。"
        case .requestRejected(let detail): return "请求被拒绝（422）\(detail.map { "：\($0)" } ?? "")。"
        case .serverUnavailable: return "后端暂不可用（503），可用相同内容重试。"
        case .transport(let reason): return "网络传输失败：\(reason)"
        case .retryBudgetExhausted(let context): return "自动重试预算已用尽：\(context)。请勿更换 ID 规避，检查后人工处理。"
        case .sessionAlreadyExists(let sessionID): return "会话 \(sessionID) 已存在（409），可用查询恢复该会话。"
        case .uploadConflict(let detail): return "上传冲突（409）\(detail.map { "：\($0)" } ?? "")。不得更换 ID 或序号规避。"
        case .eventCursorConflict(let detail): return "事件游标冲突（409）\(detail.map { "：\($0)" } ?? "")，请刷新游标。"
        case .pendingConflict(let detail): return "Pending 确认冲突（409）\(detail.map { "：\($0)" } ?? "")，先刷新再重试。"
        case .finishAwaitingAudio(let missing): return "Finish 缺少音频片段（awaiting_audio）：缺 \(missing)。请补齐后用相同 finish_id 重试。"
        case .finishRangeExcludesAccepted: return "Finish 声明范围小于已接受的最大序号（FINISH_RANGE_EXCLUDES_ACCEPTED_AUDIO）。"
        case .finishConflict(let detail): return "Finish 冲突（409）\(detail.map { "：\($0)" } ?? "")。"
        case .reviewNotFinished(let detail): return "Review 尚未可用（409）\(detail.map { "：\($0)" } ?? "")。"
        case .conflict(let detail): return "请求冲突（409）\(detail.map { "：\($0)" } ?? "")。"
        case .serverRetryExhausted(let context): return "服务端自动重试预算已耗尽：\(context)。停止自动请求。"
        case .pollTimeout(let context): return "轮询超时：\(context)。"
        case .decodingFailed(let context): return "响应解码失败：\(context)（内容已脱敏）。"
        case .unexpectedStatus(let status, let context): return "未预期的 HTTP \(status)：\(context)。"
        }
    }

    var isTransportRetryable: Bool {
        switch self {
        case .serverUnavailable, .transport: return true
        default: return false
        }
    }
}

// MARK: - Client

/// Minimal complete client for the frozen V1.1 WAV HTTP contract.
///
/// Semantics enforced here (see reference/api/ of the handoff):
/// - 202 on upload only means persisted; training facts come from Facts/Review only.
/// - `done` still requires checking the outcome decision (COMMIT/DEFER/REJECT).
/// - Retries after 503/transport failures reuse the identical request bytes,
///   including utterance_id, sequence, audio bytes, and source metadata.
/// - 409s are surfaced as distinct errors and never auto-retried away.
/// - SOURCE_UNCERTAIN / SOURCE_NOT_VERIFIED remain visible; the client never
///   self-reports speaker_status, source_type, or voice_verified, and never
///   touches the server trust switch.
struct BackendHTTPClient: Sendable {
    let configuration: BackendHTTPConfiguration
    let transport: any HTTPTransport

    init(configuration: BackendHTTPConfiguration, transport: any HTTPTransport = URLSessionTransport()) {
        self.configuration = configuration
        self.transport = transport
    }

    // MARK: Health (no auth; does not prove model availability)

    func health() async throws -> BackendHealth {
        var request = URLRequest(url: try endpoint("health"))
        request.httpMethod = "GET"
        request.timeoutInterval = 10
        let (data, response) = try await transport.send(request)
        try throwIfFailure(response, data, context: "GET /health")
        return try decode(BackendHealth.self, from: data, context: "health")
    }

    // MARK: Sessions

    func createSession(sessionID: String) async throws -> SessionContext {
        try validatePathComponent(sessionID, label: "session_id", maxLength: 200)
        var request = try jsonRequest("POST", path: "v1/sessions", context: "POST /v1/sessions")
        request.httpBody = try Self.encoder().encode(CreateSessionRequestBody(sessionID: sessionID))
        let (data, response) = try await sendWithRetry(request, context: "POST /v1/sessions")
        switch response.statusCode {
        case 201:
            return try decode(SessionContext.self, from: data, context: "POST /v1/sessions")
        case 409:
            throw BackendHTTPError.sessionAlreadyExists(sessionID)
        default:
            try throwIfFailure(response, data, context: "POST /v1/sessions")
            throw try unexpectedSuccess(response, context: "POST /v1/sessions")
        }
    }

    func getSession(sessionID: String) async throws -> SessionContext {
        try validatePathComponent(sessionID, label: "session_id", maxLength: 200)
        let request = try jsonRequest("GET", path: "v1/sessions/\(sessionID)", context: "GET /v1/sessions")
        let (data, response) = try await sendWithRetry(request, context: "GET /v1/sessions")
        try throwIfFailure(response, data, context: "GET /v1/sessions")
        return try decode(SessionContext.self, from: data, context: "GET /v1/sessions")
    }

    /// POST first; on the documented 409 (id already exists) recover by GET,
    /// as IOS_AUDIO_CONTRACT_2026-10-15 prescribes.
    func ensureSession(sessionID: String) async throws -> SessionContext {
        do {
            return try await createSession(sessionID: sessionID)
        } catch BackendHTTPError.sessionAlreadyExists {
            return try await getSession(sessionID: sessionID)
        }
    }

    // MARK: Audio upload

    func uploadAudio(
        sessionID: String,
        utteranceID: String,
        sequence: Int,
        wavData: Data,
        audioSource: String? = nil
    ) async throws -> UploadAccepted {
        try validatePathComponent(sessionID, label: "session_id", maxLength: 200)
        try validatePathComponent(utteranceID, label: "utterance_id", maxLength: 120)
        guard sequence >= 0 else { throw BackendHTTPError.invalidUpload("sequence 不能为负数") }
        if let audioSource {
            guard (1...200).contains(audioSource.count) else {
                throw BackendHTTPError.invalidUpload("audio_source 长度须在 1–200 字符")
            }
        }
        _ = try WAVUploadValidator.validate(wavData)
        // Deterministic per upload identity: a retry of the same identity
        // reproduces byte-identical multipart bodies.
        let boundary = "fitcore-\(utteranceID)-\(sequence)"
        let body = try WAVMultipartEncoder.encode(
            boundary: boundary,
            file: wavData,
            utteranceID: utteranceID,
            sequence: sequence,
            audioSource: audioSource
        )
        var request = URLRequest(url: try endpoint("v1/sessions/\(sessionID)/audio-jobs"))
        request.httpMethod = "POST"
        request.timeoutInterval = configuration.requestTimeout
        request.setValue("Bearer \(configuration.accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.httpBody = body
        let (data, response) = try await sendWithRetry(request, context: "POST audio-jobs/\(utteranceID)")
        if response.statusCode == 409 {
            // Same id different bytes, same sequence different id, or acceptance
            // already closed — never worked around by changing ids or sequences.
            throw BackendHTTPError.uploadConflict(Self.detailCode(from: data))
        }
        try throwIfFailure(response, data, context: "POST audio-jobs/\(utteranceID)")
        return try decode(UploadAccepted.self, from: data, context: "audio-jobs/\(utteranceID)")
    }

    // MARK: Job polling

    func audioJobStatus(sessionID: String, utteranceID: String) async throws -> AudioJobStatusResponse {
        try validatePathComponent(sessionID, label: "session_id", maxLength: 200)
        try validatePathComponent(utteranceID, label: "utterance_id", maxLength: 120)
        let request = try jsonRequest(
            "GET",
            path: "v1/sessions/\(sessionID)/audio-jobs/\(utteranceID)",
            context: "GET audio-jobs"
        )
        let (data, response) = try await sendWithRetry(request, context: "GET audio-jobs/\(utteranceID)")
        try throwIfFailure(response, data, context: "GET audio-jobs/\(utteranceID)")
        return try decode(AudioJobStatusResponse.self, from: data, context: "audio-jobs/\(utteranceID)")
    }

    /// Polls until `done`, until the server reports `automatic_retry_exhausted`,
    /// or until the deadline. Cancellation stops polling immediately.
    func waitForJobCompletion(
        sessionID: String,
        utteranceID: String,
        pollInterval: Duration = .milliseconds(500),
        timeout: Duration = .seconds(120)
    ) async throws -> AudioJobStatusResponse {
        let deadline = ContinuousClock.now + timeout
        while true {
            try Task.checkCancellation()
            let status = try await audioJobStatus(sessionID: sessionID, utteranceID: utteranceID)
            if status.job.status == .done { return status }
            if status.automaticRetryExhausted {
                throw BackendHTTPError.serverRetryExhausted("\(sessionID)/\(utteranceID)")
            }
            if ContinuousClock.now >= deadline {
                throw BackendHTTPError.pollTimeout("\(sessionID)/\(utteranceID) 未在限时内 done")
            }
            do {
                try await Task.sleep(for: pollInterval)
            } catch {
                throw CancellationError()
            }
        }
    }

    // MARK: Facts / pending / events

    func facts(sessionID: String) async throws -> [TrainingFactDTO] {
        let request = try jsonRequest("GET", path: "v1/sessions/\(sessionID)/facts", context: "GET facts")
        let (data, response) = try await sendWithRetry(request, context: "GET facts")
        try throwIfFailure(response, data, context: "GET facts")
        return try decode([TrainingFactDTO].self, from: data, context: "facts")
    }

    func pending(sessionID: String) async throws -> [PendingItem] {
        let request = try jsonRequest("GET", path: "v1/sessions/\(sessionID)/pending", context: "GET pending")
        let (data, response) = try await sendWithRetry(request, context: "GET pending")
        try throwIfFailure(response, data, context: "GET pending")
        return try decode([PendingItem].self, from: data, context: "pending")
    }

    /// Resolve endpoint per IOS_AUDIO_CONTRACT (resolution_id/action/context_version).
    /// The response shape is not pinned by the provided samples and is returned
    /// verbatim as JSONValue. GAP-PENDING-RESOLVE-BODY.
    func resolvePending(
        sessionID: String,
        pendingID: String,
        resolution: PendingResolution
    ) async throws -> JSONValue {
        try validatePathComponent(pendingID, label: "pending_id", maxLength: 200)
        var request = try jsonRequest(
            "POST",
            path: "v1/sessions/\(sessionID)/pending/\(pendingID)/resolve",
            context: "POST pending resolve"
        )
        request.httpBody = try Self.encoder().encode(resolution)
        let (data, response) = try await sendWithRetry(request, context: "POST pending/\(pendingID)/resolve")
        if response.statusCode == 409 {
            // 409 means the context moved; refresh first, never blind-retry.
            throw BackendHTTPError.pendingConflict(Self.detailCode(from: data))
        }
        try throwIfFailure(response, data, context: "POST pending/\(pendingID)/resolve")
        return try decode(JSONValue.self, from: data, context: "pending resolve")
    }

    func events(sessionID: String, after: Int, limit: Int = 100) async throws -> EventsPage {
        guard after >= 0 else { throw BackendHTTPError.invalidParameters("事件游标 after 不能为负数") }
        guard (1...100).contains(limit) else { throw BackendHTTPError.invalidParameters("limit 须在 1–100") }
        guard var components = URLComponents(url: try endpoint("v1/sessions/\(sessionID)/events"), resolvingAgainstBaseURL: false) else {
            throw BackendHTTPError.invalidConfiguration("无法构造 events 地址")
        }
        components.queryItems = [
            URLQueryItem(name: "after", value: String(after)),
            URLQueryItem(name: "limit", value: String(limit))
        ]
        guard let url = components.url else { throw BackendHTTPError.invalidConfiguration("无法构造 events 地址") }
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.timeoutInterval = configuration.requestTimeout
        request.setValue("Bearer \(configuration.accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        let (data, response) = try await sendWithRetry(request, context: "GET events after=\(after)")
        if response.statusCode == 409 {
            throw BackendHTTPError.eventCursorConflict(Self.detailCode(from: data))
        }
        try throwIfFailure(response, data, context: "GET events after=\(after)")
        return try decode(EventsPage.self, from: data, context: "events after=\(after)")
    }

    // MARK: Finish / review

    func finishSession(sessionID: String, finishID: String, lastSequence: Int) async throws -> FinishResponse {
        try validatePathComponent(finishID, label: "finish_id", maxLength: 200)
        guard lastSequence >= -1 else {
            throw BackendHTTPError.invalidParameters("last_sequence 须 ≥ -1（空会话为 -1）")
        }
        var request = try jsonRequest("POST", path: "v1/sessions/\(sessionID)/finish", context: "POST finish")
        request.httpBody = try Self.encoder().encode(FinishRequestBody(finishID: finishID, lastSequence: lastSequence))
        let (data, response) = try await sendWithRetry(request, context: "POST finish/\(finishID)")
        switch response.statusCode {
        case 200, 202:
            return try decode(FinishResponse.self, from: data, context: "finish/\(finishID)")
        case 409:
            if let envelope = try? Self.decoder().decode(FinishResponse.self, from: data),
               !envelope.complete, !envelope.acceptanceClosed, !envelope.missingSequences.isEmpty {
                throw BackendHTTPError.finishAwaitingAudio(envelope.missingSequences)
            }
            let detail = Self.detailCode(from: data)
            if detail == "FINISH_RANGE_EXCLUDES_ACCEPTED_AUDIO" {
                throw BackendHTTPError.finishRangeExcludesAccepted
            }
            throw BackendHTTPError.finishConflict(detail)
        default:
            try throwIfFailure(response, data, context: "POST finish/\(finishID)")
            throw try unexpectedSuccess(response, context: "POST finish/\(finishID)")
        }
    }

    func finishStatus(sessionID: String) async throws -> FinishResponse {
        let request = try jsonRequest("GET", path: "v1/sessions/\(sessionID)/finish", context: "GET finish")
        let (data, response) = try await sendWithRetry(request, context: "GET finish")
        try throwIfFailure(response, data, context: "GET finish")
        return try decode(FinishResponse.self, from: data, context: "finish status")
    }

    /// POST finish, then poll GET finish until the worker finalizes. Re-POSTs
    /// the same finish_id when the server reports ready_to_finalize but not
    /// complete. awaiting_audio is surfaced to the caller (missing segments
    /// must be uploaded first, then the same finish_id retried).
    func drainToCompletion(
        sessionID: String,
        finishID: String,
        lastSequence: Int,
        pollInterval: Duration = .milliseconds(500),
        timeout: Duration = .seconds(180)
    ) async throws -> FinishResponse {
        let posted = try await finishSession(
            sessionID: sessionID,
            finishID: finishID,
            lastSequence: lastSequence
        )
        if posted.complete { return posted }
        let deadline = ContinuousClock.now + timeout
        while true {
            try Task.checkCancellation()
            let status = try await finishStatus(sessionID: sessionID)
            if status.complete { return status }
            if status.readyToFinalize {
                let rePosted = try await finishSession(
                    sessionID: sessionID,
                    finishID: finishID,
                    lastSequence: lastSequence
                )
                if rePosted.complete { return rePosted }
            }
            if ContinuousClock.now >= deadline {
                throw BackendHTTPError.pollTimeout("\(sessionID) finish 未在限时内完成")
            }
            do {
                try await Task.sleep(for: pollInterval)
            } catch {
                throw CancellationError()
            }
        }
    }

    func review(sessionID: String) async throws -> SessionReviewDTO {
        let request = try jsonRequest("GET", path: "v1/sessions/\(sessionID)/review", context: "GET review")
        let (data, response) = try await sendWithRetry(request, context: "GET review")
        if response.statusCode == 409 {
            throw BackendHTTPError.reviewNotFinished(Self.detailCode(from: data))
        }
        try throwIfFailure(response, data, context: "GET review")
        return try decode(SessionReviewDTO.self, from: data, context: "review")
    }

    // MARK: - Internals

    private func endpoint(_ path: String) throws -> URL {
        let url = configuration.baseURL.appendingPathComponent(path)
        guard url.scheme == "https" else {
            throw BackendHTTPError.invalidConfiguration("后端地址必须是 HTTPS")
        }
        return url
    }

    private func jsonRequest(_ method: String, path: String, context: String) throws -> URLRequest {
        var request = URLRequest(url: try endpoint(path))
        request.httpMethod = method
        request.timeoutInterval = configuration.requestTimeout
        request.setValue("Bearer \(configuration.accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if method != "GET" {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        return request
    }

    /// Sends `request`, retrying only transport failures and 503s — always the
    /// identical URLRequest, so retried uploads reuse the same multipart bytes,
    /// utterance_id, and sequence. 409/422/413/401/403/404 never auto-retry.
    private func sendWithRetry(_ request: URLRequest, context: String) async throws -> (Data, HTTPURLResponse) {
        var attempt = 0
        while true {
            do {
                try Task.checkCancellation()
                let result = try await transport.send(request)
                if result.response.statusCode == 503 {
                    // Contract: retry the exact same identity after 503.
                    throw BackendHTTPError.serverUnavailable
                }
                return result
            } catch let error as BackendHTTPError {
                guard error.isTransportRetryable, attempt + 1 < configuration.retryAttempts else {
                    if error.isTransportRetryable {
                        throw BackendHTTPError.retryBudgetExhausted(context)
                    }
                    throw error
                }
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                guard attempt + 1 < configuration.retryAttempts else {
                    throw BackendHTTPError.retryBudgetExhausted(context)
                }
            }
            attempt += 1
            do {
                try await Task.sleep(for: configuration.retryDelay)
            } catch {
                throw CancellationError()
            }
        }
    }

    private func throwIfFailure(_ response: HTTPURLResponse, _ data: Data, context: String) throws {
        guard !(200..<300).contains(response.statusCode) else { return }
        let detail = Self.detailCode(from: data)
        switch response.statusCode {
        case 401, 403: throw BackendHTTPError.unauthorized
        case 404: throw BackendHTTPError.notFound
        case 413: throw BackendHTTPError.payloadTooLarge
        case 422: throw BackendHTTPError.requestRejected(detail)
        case 503: throw BackendHTTPError.serverUnavailable
        case 409: throw BackendHTTPError.conflict(detail)
        default: throw BackendHTTPError.unexpectedStatus(response.statusCode, context)
        }
    }

    private func unexpectedSuccess(_ response: HTTPURLResponse, context: String) throws -> BackendHTTPError {
        BackendHTTPError.unexpectedStatus(response.statusCode, context)
    }

    private func decode<T: Decodable>(_ type: T.Type, from data: Data, context: String) throws -> T {
        do {
            return try Self.decoder().decode(T.self, from: data)
        } catch {
            // Redacted: never include body bytes, headers, or credentials.
            throw BackendHTTPError.decodingFailed(context)
        }
    }

    private func validatePathComponent(_ value: String, label: String, maxLength: Int) throws {
        guard !value.isEmpty, value.count <= maxLength else {
            throw BackendHTTPError.invalidParameters("\(label) 长度须在 1–\(maxLength)")
        }
        let forbidden = CharacterSet(charactersIn: "/?#\"\\%").union(.whitespacesAndNewlines)
        guard value.unicodeScalars.allSatisfy({ !forbidden.contains($0) }) else {
            throw BackendHTTPError.invalidParameters("\(label) 含非法字符")
        }
    }

    private static func detailCode(from data: Data) -> String? {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let detail = object["detail"] as? String else { return nil }
        return detail
    }

    static func decoder() -> JSONDecoder { JSONDecoder() }
    static func encoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return encoder
    }
}

// MARK: - Sequenced uploader

/// Per-session sequencing wrapper: assigns sequence numbers from 0, advances
/// only after a 202, and keeps the last in-flight identity (utterance_id,
/// sequence, bytes, hash, source) so a retry resends exactly the same upload.
actor WAVSessionUploader {
    struct UploadIdentity: Sendable, Equatable {
        let utteranceID: String
        let sequence: Int
        let sha256: String
        let audioSource: String?
    }

    private let client: BackendHTTPClient
    private let sessionID: String
    private var nextSequence = 0
    private var lastInFlight: (identity: UploadIdentity, data: Data)?

    init(client: BackendHTTPClient, sessionID: String) {
        self.client = client
        self.sessionID = sessionID
    }

    var currentSequence: Int { nextSequence }
    var pendingRetryIdentity: UploadIdentity? { lastInFlight?.identity }

    /// Uploads a new recording with the next continuous sequence.
    func upload(utteranceID: String, wavData: Data, audioSource: String? = nil) async throws -> UploadAccepted {
        let inspection = try WAVUploadValidator.validate(wavData)
        let identity = UploadIdentity(
            utteranceID: utteranceID,
            sequence: nextSequence,
            sha256: inspection.sha256,
            audioSource: audioSource
        )
        lastInFlight = (identity, wavData)
        let accepted = try await perform(identity: identity, data: wavData)
        nextSequence = identity.sequence + 1
        lastInFlight = nil
        return accepted
    }

    /// Retries the most recent unsuccessful upload with its original identity.
    func retryLastUpload() async throws -> UploadAccepted {
        guard let inFlight = lastInFlight else {
            throw BackendHTTPError.invalidUpload("没有待重试的上传")
        }
        let accepted = try await perform(identity: inFlight.identity, data: inFlight.data)
        nextSequence = inFlight.identity.sequence + 1
        lastInFlight = nil
        return accepted
    }

    private func perform(identity: UploadIdentity, data: Data) async throws -> UploadAccepted {
        try await client.uploadAudio(
            sessionID: sessionID,
            utteranceID: identity.utteranceID,
            sequence: identity.sequence,
            wavData: data,
            audioSource: identity.audioSource
        )
    }
}
