import Foundation
import XCTest
@testable import WAVHTTPKit

/// Scripted transport: intercepts every request (nothing leaves the machine),
/// replays the scripted steps in order, and records the exact requests sent.
actor ScriptedTransport: HTTPTransport {
    enum Step: Sendable {
        case respond(status: Int, body: Data)
        case fail(any Error)
    }

    struct RecordedCall: Sendable {
        let method: String
        let url: String
        let authorization: String?
        let contentType: String?
        let accept: String?
        let body: Data?
    }

    private var steps: [Step]
    private(set) var recorded: [RecordedCall] = []

    init(steps: [Step]) {
        self.steps = steps
    }

    func send(_ request: URLRequest) async throws -> (data: Data, response: HTTPURLResponse) {
        recorded.append(RecordedCall(
            method: request.httpMethod ?? "",
            url: request.url?.absoluteString ?? "",
            authorization: request.value(forHTTPHeaderField: "Authorization"),
            contentType: request.value(forHTTPHeaderField: "Content-Type"),
            accept: request.value(forHTTPHeaderField: "Accept"),
            body: request.httpBody
        ))
        guard !steps.isEmpty else {
            throw BackendHTTPError.transport("测试脚本已用尽")
        }
        let step = steps.removeFirst()
        switch step {
        case .respond(let status, let body):
            let response = HTTPURLResponse(
                url: request.url ?? URL(string: "https://backend.example.test")!,
                statusCode: status,
                httpVersion: "HTTP/1.1",
                headerFields: ["Content-Type": "application/json"]
            )!
            return (body, response)
        case .fail(let error):
            throw error
        }
    }
}

// MARK: - Synthetic WAV fixture (clearly synthetic; no private audio is read)

enum SyntheticWAV {
    /// 16 kHz / mono / PCM16 WAV with alternating ±amplitude samples (non-silent).
    /// Each frame is one 16-bit sample (2 bytes), per the PCM16 contract.
    static func data(frames: Int, amplitude: Int16 = 16_384) -> Data {
        var pcm = Data(capacity: frames * 2)
        let pattern: [UInt8] = [UInt8(amplitude & 0xFF), UInt8((amplitude >> 8) & 0xFF),
                                UInt8((~amplitude) & 0xFF), UInt8(((~amplitude) >> 8) & 0xFF)]
        let fullPairs = frames / 2
        for _ in 0..<fullPairs { pcm.append(contentsOf: pattern) }
        if frames % 2 == 1 { pcm.append(contentsOf: pattern.prefix(2)) }
        return container(pcm: pcm)
    }

    static func silence(frames: Int) -> Data {
        container(pcm: Data(count: frames * 2))
    }

    static func data(fileBytes: Int) -> Data {
        // Exact total file size, non-silent pattern padding.
        let pcmBytes = fileBytes - 44
        return data(frames: pcmBytes / 2)
    }

    private static func container(pcm: Data) -> Data {
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
}

// MARK: - Multipart parsing (test-side, independent of the encoder)

struct MultipartPart {
    let name: String
    let filename: String?
    let contentType: String?
    let body: Data
}

func parseMultipart(_ body: Data, contentTypeHeader: String) -> [MultipartPart] {
    guard let boundaryRange = contentTypeHeader.range(of: "boundary=") else { return [] }
    let boundary = String(contentTypeHeader[boundaryRange.upperBound...])
    let opening = Data("--\(boundary)\r\n".utf8)
    let marker = Data("\r\n--\(boundary)".utf8)
    guard body.starts(with: opening) else { return [] }
    var remainder = Data(body.dropFirst(opening.count))
    var parts: [MultipartPart] = []
    while !remainder.isEmpty {
        // Each part ends right before the "\r\n--boundary" separator that
        // either introduces the next part or closes the body ("--boundary--").
        guard let markerRange = remainder.range(of: marker) else { return parts }
        let partBlob = remainder[remainder.startIndex..<markerRange.lowerBound]
        guard let headerEnd = partBlob.range(of: Data("\r\n\r\n".utf8)) else { return parts }
        let headers = String(decoding: partBlob[partBlob.startIndex..<headerEnd.lowerBound], as: UTF8.self)
        var name = ""
        var filename: String?
        var partContentType: String?
        for line in headers.components(separatedBy: "\r\n") {
            if let range = line.range(of: "name=\"") {
                name = String(line[range.upperBound...].prefix(while: { $0 != "\"" }))
            }
            if let range = line.range(of: "filename=\"") {
                filename = String(line[range.upperBound...].prefix(while: { $0 != "\"" }))
            }
            if let range = line.range(of: "Content-Type: ") {
                partContentType = String(line[range.upperBound...])
            }
        }
        parts.append(MultipartPart(
            name: name,
            filename: filename,
            contentType: partContentType,
            body: partBlob[headerEnd.upperBound..<partBlob.endIndex]
        ))
        let afterMarker = remainder[markerRange.upperBound...]
        if afterMarker.starts(with: Data("--".utf8)) { return parts }
        remainder = Data(afterMarker.dropFirst(2))
    }
    return parts
}

// MARK: - Client factory + sanitized contract fixtures

enum TestSupport {
    static let testToken = "offline-test-token-not-a-real-credential"

    static func makeClient(_ steps: [ScriptedTransport.Step]) throws -> (BackendHTTPClient, ScriptedTransport) {
        let transport = ScriptedTransport(steps: steps)
        let configuration = try BackendHTTPConfiguration(
            baseURL: URL(string: "https://backend.example.test")!,
            accessToken: testToken
        )
        return (BackendHTTPClient(configuration: configuration, transport: transport), transport)
    }

    static func fastRetryConfiguration(baseURL: URL = URL(string: "https://backend.example.test")!) throws -> BackendHTTPConfiguration {
        var configuration = try BackendHTTPConfiguration(baseURL: baseURL, accessToken: testToken)
        configuration.retryAttempts = 3
        configuration.retryDelay = .milliseconds(1)
        return configuration
    }

    // Fixtures below are transcribed from the sanitized samples in
    // STABLE_BASELINE_WAV_HTTP_REPORT_2026-10-15.md (fitcore v1.1, 2026-10-15).
    // They are contract fixtures, not recordings of this run and not real audio.

    static func jobJSON(
        status: String,
        finalText: String? = "卧推60公斤做了8个。",
        utterance: String = "u0",
        sequence: Int = 0,
        decision: String? = "COMMIT"
    ) -> String {
        let outcome: String
        if let decision {
            outcome = """
            "outcome": {"utterance_id": "\(utterance)", "decision": "\(decision)", "context_version": 1,
              "committed": [{"type": "SET_COMPLETED", "id": 1, "exercise_instance_id": 1,
                "exercise": "bench_press", "set_number": 1, "weight_kg": 60.0, "reps": 8,
                "weight_provenance": "EXPLICIT"}],
              "reason": null, "semantic_diagnostics": [], "reparse": null},
            """
        } else {
            outcome = ""
        }
        let finalTextJSON = finalText.map { "\"\($0)\"" } ?? "null"
        return """
        {"session_id": "s-test", "utterance_id": "\(utterance)", "sequence": \(sequence),
        "audio_sha256": "cf95fe997c5100ab3ba90e8ec0af94b263e93990efda441fa5b33f86852e6337",
        "audio_source": "http_authorized_test:http_acceptance", "source_type": "authenticated_audio",
        "speaker_status": "VERIFIED_USER", "status": "\(status)", "final_text": \(finalTextJSON),
        "asr_attempts": 1, "llm_attempts": 1, "error_type": null,
        "audio_metadata": {"sample_rate": 16000, "channels": 1, "bits_per_sample": 16, "frames": 80000,
          "duration_seconds": 5.0, "rms_dbfs": -23.7, "peak_dbfs": -2.53, "clipped_fraction": 0.0,
          "non_silent": true},
        \(outcome)"asr_diagnostics": {"transcript": "卧推60公斤做了8个。", "audio_duration_seconds": 5.0,
          "provider_duration_seconds": 2.0, "elapsed_ms": 4369, "http_status": 200}}
        """
    }

    static func uploadAcceptedJSON(status: String = "queued", sequence: Int = 0) -> String {
        """
        {"acceptance": "persisted", "speaker_verification": "not_performed",
        "source_assurance": "server_authorized_test", "job": \(jobJSON(status: status, finalText: nil, sequence: sequence, decision: nil))}
        """
    }

    static func jobStatusJSON(status: String, exhausted: Bool = false, decision: String? = "COMMIT") -> String {
        """
        {"speaker_verification": "not_performed", "automatic_retry_exhausted": \(exhausted),
        "job": \(jobJSON(status: status, decision: decision))}
        """
    }

    static let factsJSON = """
    [{"id": 1, "exercise_instance_id": 1, "exercise": "bench_press", "set_number": 1,
    "weight_kg": 60.0, "reps": 8, "weight_provenance": "EXPLICIT",
    "weight_source_fact_id": null, "source_utterance_id": "u0"}]
    """

    static let reviewJSON = """
    {"session_id": "s-test", "context_version": 2, "total_sets": 1, "total_reps": 8,
    "volume_kg_reps": 480.0, "pending_count": 0, "facts": \(factsJSON)}
    """

    static func finishJSON(
        state: String,
        complete: Bool,
        acceptanceClosed: Bool,
        missing: [Int] = [],
        unfinished: String = "[]",
        review: String? = nil
    ) -> String {
        """
        {"session_id": "s-test", "finish_id": "f-test", "last_sequence": 0, "state": "\(state)",
        "complete": \(complete), "acceptance_closed": \(acceptanceClosed),
        "missing_sequences": \(missing), "missing_count": \(missing.count),
        "unfinished": \(unfinished), "accepted_count": 1, "ready_to_finalize": false,
        "review": \(review ?? "null")}
        """
    }

    static let eventsJSON = """
    {"events": [{"event_seq": 1, "event_id": "s-test:event:1", "type": "TRANSCRIPT_FINAL",
    "utterance_id": "u0", "payload": {"text": "卧推60公斤做了8个。", "sequence": 0},
    "created_at": "2026-10-15 03:26:52"},
    {"event_seq": 2, "event_id": "s-test:event:2", "type": "FACT_COMMITTED",
    "utterance_id": "u0", "payload": {"decision": "COMMIT", "context_version": 1},
    "created_at": "2026-10-15 03:26:59"}], "next_cursor": 2, "has_more": false}
    """

    static let pendingJSON = """
    [{"id": 7, "status": "open", "utterance_id": "u1", "reason": "SOURCE_UNCERTAIN"},
    {"id": 8, "status": "resolved", "utterance_id": "u2"}]
    """
}

func body(_ json: String) -> Data { Data(json.utf8) }

func errorText(_ error: Error) -> String {
    (error as? LocalizedError)?.errorDescription ?? String(describing: error)
}
