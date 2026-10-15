import Foundation
import XCTest
@testable import WAVHTTPKit

/// Contract tests: configuration, health, sessions, upload (multipart, retry
/// identity, conflicts), job polling, and the sequenced uploader. All requests
/// are intercepted by ScriptedTransport; no network access happens here.
final class BackendHTTPClientTests: XCTestCase {

    // MARK: Configuration

    func testConfigurationRejectsNonHTTPSAndBadTokens() {
        XCTAssertThrowsError(try BackendHTTPConfiguration(
            baseURL: URL(string: "http://backend.example.test")!,
            accessToken: TestSupport.testToken
        )) { error in
            XCTAssertEqual(
                (error as? BackendHTTPConfiguration.ValidationError)?.errorDescription,
                "后端地址必须是不含用户名、密码、查询参数的 HTTPS 地址。"
            )
        }
        XCTAssertThrowsError(try BackendHTTPConfiguration(
            baseURL: URL(string: "https://u:p@backend.example.test/a?b=1")!,
            accessToken: TestSupport.testToken
        ))
        XCTAssertThrowsError(try BackendHTTPConfiguration(
            baseURL: URL(string: "https://backend.example.test")!,
            accessToken: "  "
        ))
        XCTAssertThrowsError(try BackendHTTPConfiguration(
            baseURL: URL(string: "https://backend.example.test")!,
            accessToken: "token\nwith-newline"
        ))
        XCTAssertNoThrow(try BackendHTTPConfiguration(
            baseURL: URL(string: "https://backend.example.test:8443/")!,
            accessToken: TestSupport.testToken
        ))
    }

    func testConfigurationNormalizesTrailingSlash() throws {
        let configuration = try BackendHTTPConfiguration(
            baseURL: URL(string: "https://backend.example.test/")!,
            accessToken: TestSupport.testToken
        )
        XCTAssertEqual(configuration.baseURL.absoluteString, "https://backend.example.test")
    }

    // MARK: Health

    func testHealthDecodesNewFieldsAndSendsNoAuthorizationHeader() async throws {
        let (client, transport) = try TestSupport.makeClient([
            .respond(status: 200, body: body(#"{"status": "ok", "model_provider": "real"}"#))
        ])
        let health = try await client.health()
        XCTAssertEqual(health.status, "ok")
        XCTAssertEqual(health.modelProvider, "real")
        // Old service/environment decoding must not be required.
        let (lenient, _) = try TestSupport.makeClient([
            .respond(status: 200, body: body(#"{"status": "ok"}"#))
        ])
        let minimal = try await lenient.health()
        XCTAssertEqual(minimal.status, "ok")
        XCTAssertEqual(minimal.modelProvider, nil)
        let call = await transport.recorded.first
        XCTAssertEqual(call?.url, "https://backend.example.test/health")
        XCTAssertNil(call?.authorization)
    }

    // MARK: Session lifecycle

    func testCreateSessionPostsBodyAndDecodes201() async throws {
        let (client, transport) = try TestSupport.makeClient([
            .respond(status: 201, body: body(#"""
            {"session_id": "s-test", "version": 0, "status": "active",
            "active_exercise_instance_id": null, "active_exercise_name": null,
            "last_completed_set_id": null, "last_reported_weight": null, "next_set_plan": null}
            """#))
        ])
        let context = try await client.createSession(sessionID: "s-test")
        XCTAssertEqual(context.sessionID, "s-test")
        XCTAssertEqual(context.version, 0)
        XCTAssertEqual(context.status, "active")
        let call = await transport.recorded.first
        XCTAssertEqual(call?.method, "POST")
        XCTAssertEqual(call?.url, "https://backend.example.test/v1/sessions")
        XCTAssertEqual(call?.authorization, "Bearer \(TestSupport.testToken)")
        XCTAssertEqual(call?.body, body(#"{"session_id":"s-test"}"#))
    }

    func testCreateSessionConflictMapsToAlreadyExists() async throws {
        let (client, transport) = try TestSupport.makeClient([
            .respond(status: 409, body: body(#"{"detail": "SESSION_EXISTS"}"#))
        ])
        do {
            _ = try await client.createSession(sessionID: "s-test")
            XCTFail("expected sessionAlreadyExists")
        } catch let error as BackendHTTPError {
            XCTAssertEqual(error, .sessionAlreadyExists("s-test"))
        }
        let count = await transport.recorded.count
        XCTAssertEqual(count, 1, "409 on session create must not be auto-retried")
    }

    func testEnsureSessionRecoversExistingSessionViaGet() async throws {
        let (client, transport) = try TestSupport.makeClient([
            .respond(status: 409, body: body(#"{"detail": "SESSION_EXISTS"}"#)),
            .respond(status: 200, body: body(#"""
            {"session_id": "s-test", "version": 3, "status": "active",
            "active_exercise_instance_id": null, "active_exercise_name": null,
            "last_completed_set_id": null, "last_reported_weight": null, "next_set_plan": null}
            """#))
        ])
        let context = try await client.ensureSession(sessionID: "s-test")
        XCTAssertEqual(context.version, 3)
        let calls = await transport.recorded
        XCTAssertEqual(calls.map(\.method), ["POST", "GET"])
        XCTAssertEqual(calls.last?.url, "https://backend.example.test/v1/sessions/s-test")
    }

    func testSessionNotFoundMapsTo404() async throws {
        let (client, _) = try TestSupport.makeClient([
            .respond(status: 404, body: body(#"{"detail": "SESSION_NOT_FOUND"}"#))
        ])
        do {
            _ = try await client.getSession(sessionID: "missing")
            XCTFail("expected notFound")
        } catch let error as BackendHTTPError {
            XCTAssertEqual(error, .notFound)
        }
    }

    // MARK: Upload: multipart contract

    func testUploadMultipartContainsExactlyTheContractFields() async throws {
        let wav = SyntheticWAV.data(frames: 100)
        let (client, transport) = try TestSupport.makeClient([
            .respond(status: 202, body: body(TestSupport.uploadAcceptedJSON()))
        ])
        let accepted = try await client.uploadAudio(
            sessionID: "s-test",
            utteranceID: "u0",
            sequence: 0,
            wavData: wav,
            audioSource: "ios_capture"
        )
        XCTAssertEqual(accepted.acceptance, "persisted")
        XCTAssertEqual(accepted.speakerVerification, "not_performed")
        XCTAssertEqual(accepted.job.status, .queued)
        XCTAssertEqual(accepted.job.finalText, nil)

        let call = await transport.recorded.first
        XCTAssertEqual(call?.method, "POST")
        XCTAssertEqual(call?.url, "https://backend.example.test/v1/sessions/s-test/audio-jobs")
        let contentType = try XCTUnwrap(call?.contentType)
        XCTAssertTrue(contentType.hasPrefix("multipart/form-data; boundary="))
        let parts = parseMultipart(try XCTUnwrap(call?.body), contentTypeHeader: contentType)
        XCTAssertEqual(parts.map(\.name), ["file", "utterance_id", "sequence", "audio_source"])
        let file = parts[0]
        XCTAssertEqual(file.filename, "u0.wav")
        XCTAssertEqual(file.contentType, "audio/wav")
        XCTAssertEqual(file.body, wav, "file part must carry the exact WAV bytes")
        XCTAssertEqual(String(decoding: parts[1].body, as: UTF8.self), "u0")
        XCTAssertEqual(String(decoding: parts[2].body, as: UTF8.self), "0")
        XCTAssertEqual(String(decoding: parts[3].body, as: UTF8.self), "ios_capture")
        // The client must never self-report trust fields the server forbids.
        let allFieldNames = parts.map(\.name).joined()
        for forbidden in ["speaker_status", "source_type", "voice_verified"] {
            XCTAssertFalse(allFieldNames.contains(forbidden), "forbidden field \(forbidden)")
        }
    }

    func testUploadOmitsOptionalAudioSourceWhenNotProvided() async throws {
        let (client, transport) = try TestSupport.makeClient([
            .respond(status: 202, body: body(TestSupport.uploadAcceptedJSON()))
        ])
        _ = try await client.uploadAudio(
            sessionID: "s-test", utteranceID: "u0", sequence: 0,
            wavData: SyntheticWAV.data(frames: 10)
        )
        let call = await transport.recorded.first
        let parts = parseMultipart(try XCTUnwrap(call?.body), contentTypeHeader: try XCTUnwrap(call?.contentType))
        XCTAssertEqual(parts.map(\.name), ["file", "utterance_id", "sequence"])
    }

    func testUploadValidatesWAVBeforeSendingAnything() async throws {
        let (client, transport) = try TestSupport.makeClient([])
        let cases: [(Data, String)] = [
            (SyntheticWAV.silence(frames: 100), "静音"),
            (SyntheticWAV.data(frames: 0), "空"),
            (Data("definitely not a wav".utf8), "WAV"),
            (SyntheticWAV.data(frames: 50).dropFirst(12), "RIFF")
        ]
        for (wav, expectedFragment) in cases {
            do {
                _ = try await client.uploadAudio(
                    sessionID: "s-test", utteranceID: "u0", sequence: 0, wavData: Data(wav)
                )
                XCTFail("expected rejection")
            } catch let error as BackendHTTPError {
                XCTAssertTrue(errorText(error).contains(expectedFragment), "unexpected: \(errorText(error))")
            }
        }
        let count = await transport.recorded.count
        XCTAssertEqual(count, 0, "invalid audio must never be sent")
    }

    func testUploadRejectsFilesOverTheContractLimit() async throws {
        let (client, transport) = try TestSupport.makeClient([])
        do {
            _ = try await client.uploadAudio(
                sessionID: "s-test", utteranceID: "u0", sequence: 0,
                wavData: SyntheticWAV.data(fileBytes: 7_000_002)
            )
            XCTFail("expected rejection")
        } catch let error as BackendHTTPError {
            XCTAssertEqual(error, .invalidUpload("WAV 文件超过 7,000,000 字节"))
        }
        let count = await transport.recorded.count
        XCTAssertEqual(count, 0)
        // Exactly at the cap the request is built (multipart stays under its own cap).
        let (atCap, capTransport) = try TestSupport.makeClient([
            .respond(status: 202, body: body(TestSupport.uploadAcceptedJSON()))
        ])
        _ = try await atCap.uploadAudio(
            sessionID: "s-test", utteranceID: "u0", sequence: 0,
            wavData: SyntheticWAV.data(fileBytes: 7_000_000)
        )
        let sent = await capTransport.recorded.first
        let bodyBytes = try XCTUnwrap(sent?.body?.count)
        XCTAssertLessThanOrEqual(bodyBytes, 7_065_536)
    }

    func testUploadValidatesIdentityFieldLengthsAndSequence() async throws {
        let (client, transport) = try TestSupport.makeClient([])
        let longID = String(repeating: "a", count: 121)
        do {
            _ = try await client.uploadAudio(
                sessionID: "s-test", utteranceID: longID, sequence: 0,
                wavData: SyntheticWAV.data(frames: 10)
            )
            XCTFail("expected rejection")
        } catch let error as BackendHTTPError {
            XCTAssertEqual(error, .invalidParameters("utterance_id 长度须在 1–120"))
        }
        do {
            _ = try await client.uploadAudio(
                sessionID: "s-test", utteranceID: "u0", sequence: -1,
                wavData: SyntheticWAV.data(frames: 10)
            )
            XCTFail("expected rejection")
        } catch let error as BackendHTTPError {
            XCTAssertEqual(error, .invalidUpload("sequence 不能为负数"))
        }
        do {
            _ = try await client.uploadAudio(
                sessionID: "s-test", utteranceID: "u0", sequence: 0,
                wavData: SyntheticWAV.data(frames: 10),
                audioSource: String(repeating: "s", count: 201)
            )
            XCTFail("expected rejection")
        } catch let error as BackendHTTPError {
            XCTAssertEqual(error, .invalidUpload("audio_source 长度须在 1–200 字符"))
        }
        let count = await transport.recorded.count
        XCTAssertEqual(count, 0)
    }

    // MARK: Upload: conflicts and errors

    func testUploadConflictVariantsAreMappedAndNeverRetried() async throws {
        let variants: [String?] = [
            "DUPLICATE_SEQUENCE_DIFFERENT_ID",
            "SAME_ID_DIFFERENT_AUDIO",
            "AUDIO_ACCEPTANCE_CLOSED"
        ]
        for detail in variants {
            let (client, transport) = try TestSupport.makeClient([
                .respond(status: 409, body: body(#"{"detail": "\#(detail ?? "CONFLICT")"}"#))
            ])
            do {
                _ = try await client.uploadAudio(
                    sessionID: "s-test", utteranceID: "u0", sequence: 0,
                    wavData: SyntheticWAV.data(frames: 10)
                )
                XCTFail("expected conflict")
            } catch let error as BackendHTTPError {
                XCTAssertEqual(error, .uploadConflict(detail))
                XCTAssertTrue(errorText(error).contains("不得更换 ID"))
            }
            let count = await transport.recorded.count
            XCTAssertEqual(count, 1, "conflicts must not auto-retry")
        }
    }

    func testUpload422And413AreMappedWithoutRetry() async throws {
        let (rejected, _) = try TestSupport.makeClient([
            .respond(status: 422, body: body(#"{"detail": "INVALID_WAV_FORMAT"}"#))
        ])
        do {
            _ = try await rejected.uploadAudio(
                sessionID: "s-test", utteranceID: "u0", sequence: 0,
                wavData: SyntheticWAV.data(frames: 10)
            )
            XCTFail("expected rejection")
        } catch let error as BackendHTTPError {
            XCTAssertEqual(error, .requestRejected("INVALID_WAV_FORMAT"))
        }
        let (tooLarge, _) = try TestSupport.makeClient([
            .respond(status: 413, body: body(#"{"detail": "FILE_TOO_LARGE"}"#))
        ])
        do {
            _ = try await tooLarge.uploadAudio(
                sessionID: "s-test", utteranceID: "u0", sequence: 0,
                wavData: SyntheticWAV.data(frames: 10)
            )
            XCTFail("expected rejection")
        } catch let error as BackendHTTPError {
            XCTAssertEqual(error, .payloadTooLarge)
        }
    }

    // MARK: Upload: retry identity

    func testUploadRetryOn503ResendsIdenticalRequest() async throws {
        let configuration = try TestSupport.fastRetryConfiguration()
        let transport = ScriptedTransport(steps: [
            .respond(status: 503, body: body(#"{"detail": "DATABASE_ERROR"}"#)),
            .respond(status: 202, body: body(TestSupport.uploadAcceptedJSON()))
        ])
        let client = BackendHTTPClient(configuration: configuration, transport: transport)
        let accepted = try await client.uploadAudio(
            sessionID: "s-test", utteranceID: "u0", sequence: 0,
            wavData: SyntheticWAV.data(frames: 10)
        )
        XCTAssertEqual(accepted.acceptance, "persisted")
        let calls = await transport.recorded
        XCTAssertEqual(calls.count, 2)
        XCTAssertEqual(calls[0].url, calls[1].url)
        XCTAssertEqual(calls[0].method, calls[1].method)
        XCTAssertEqual(calls[0].authorization, calls[1].authorization)
        XCTAssertEqual(calls[0].contentType, calls[1].contentType)
        XCTAssertEqual(calls[0].body, calls[1].body, "retry must resend byte-identical multipart")
    }

    func testUploadRetryOnTransportFailureResendsIdenticalRequest() async throws {
        let configuration = try TestSupport.fastRetryConfiguration()
        let transport = ScriptedTransport(steps: [
            .fail(URLError(.timedOut)),
            .respond(status: 202, body: body(TestSupport.uploadAcceptedJSON()))
        ])
        let client = BackendHTTPClient(configuration: configuration, transport: transport)
        let accepted = try await client.uploadAudio(
            sessionID: "s-test", utteranceID: "u0", sequence: 0,
            wavData: SyntheticWAV.data(frames: 10)
        )
        XCTAssertEqual(accepted.job.utteranceID, "u0")
        let calls = await transport.recorded
        XCTAssertEqual(calls.count, 2)
        XCTAssertEqual(calls[0].body, calls[1].body)
    }

    func testUploadRetryBudgetExhaustionStopsRetrying() async throws {
        let configuration = try TestSupport.fastRetryConfiguration()
        let transport = ScriptedTransport(steps: [
            .respond(status: 503, body: Data()),
            .respond(status: 503, body: Data()),
            .respond(status: 503, body: Data()),
            .respond(status: 503, body: Data())
        ])
        let client = BackendHTTPClient(configuration: configuration, transport: transport)
        do {
            _ = try await client.uploadAudio(
                sessionID: "s-test", utteranceID: "u0", sequence: 0,
                wavData: SyntheticWAV.data(frames: 10)
            )
            XCTFail("expected exhaustion")
        } catch let error as BackendHTTPError {
            XCTAssertEqual(error, .retryBudgetExhausted("POST audio-jobs/u0"))
        }
        let count = await transport.recorded.count
        XCTAssertEqual(count, 3, "attempts must be bounded by retryAttempts")
    }

    // MARK: Job polling

    func testJobStatusDecodesStatesAndExhaustedFlag() async throws {
        let (client, _) = try TestSupport.makeClient([
            .respond(status: 200, body: body(TestSupport.jobStatusJSON(status: "done", exhausted: true)))
        ])
        let status = try await client.audioJobStatus(sessionID: "s-test", utteranceID: "u0")
        XCTAssertEqual(status.job.status, .done)
        XCTAssertTrue(status.automaticRetryExhausted)
        XCTAssertEqual(status.job.outcome?.decision, .commit)
        XCTAssertEqual(status.job.asrAttempts, 1)
        XCTAssertEqual(status.job.llmAttempts, 1)
    }

    func testWaitForJobCompletionPollsUntilDone() async throws {
        let configuration = try TestSupport.fastRetryConfiguration()
        let transport = ScriptedTransport(steps: [
            .respond(status: 200, body: body(TestSupport.jobStatusJSON(status: "queued", decision: nil))),
            .respond(status: 200, body: body(TestSupport.jobStatusJSON(status: "asr_running", decision: nil))),
            .respond(status: 200, body: body(TestSupport.jobStatusJSON(status: "done")))
        ])
        let client = BackendHTTPClient(configuration: configuration, transport: transport)
        let final = try await client.waitForJobCompletion(
            sessionID: "s-test", utteranceID: "u0",
            pollInterval: .milliseconds(1), timeout: .seconds(2)
        )
        XCTAssertEqual(final.job.status, .done)
        XCTAssertEqual(final.job.outcome?.decision, .commit)
        let count = await transport.recorded.count
        XCTAssertEqual(count, 3)
    }

    func testWaitForJobStopsWhenServerRetryBudgetExhausted() async throws {
        let configuration = try TestSupport.fastRetryConfiguration()
        let transport = ScriptedTransport(steps: [
            .respond(status: 200, body: body(TestSupport.jobStatusJSON(status: "llm_running", exhausted: true, decision: nil))),
            .respond(status: 200, body: body(#"{"unexpected": true}"#))
        ])
        let client = BackendHTTPClient(configuration: configuration, transport: transport)
        do {
            _ = try await client.waitForJobCompletion(
                sessionID: "s-test", utteranceID: "u0",
                pollInterval: .milliseconds(1), timeout: .seconds(2)
            )
            XCTFail("expected serverRetryExhausted")
        } catch let error as BackendHTTPError {
            XCTAssertEqual(error, .serverRetryExhausted("s-test/u0"))
        }
        let count = await transport.recorded.count
        XCTAssertEqual(count, 1, "automatic_retry_exhausted must stop automatic requests")
    }

    func testWaitForJobTimesOut() async throws {
        let configuration = try TestSupport.fastRetryConfiguration()
        let transport = ScriptedTransport(steps: (0..<40).map { _ in
            ScriptedTransport.Step.respond(
                status: 200, body: body(TestSupport.jobStatusJSON(status: "queued", decision: nil))
            )
        })
        let client = BackendHTTPClient(configuration: configuration, transport: transport)
        do {
            _ = try await client.waitForJobCompletion(
                sessionID: "s-test", utteranceID: "u0",
                pollInterval: .milliseconds(5), timeout: .milliseconds(60)
            )
            XCTFail("expected pollTimeout")
        } catch let error as BackendHTTPError {
            if case .pollTimeout = error {} else { XCTFail("unexpected \(error)") }
        }
    }

    func testWaitForJobCancellationStopsPolling() async throws {
        let configuration = try TestSupport.fastRetryConfiguration()
        let transport = ScriptedTransport(steps: (0..<10).map { _ in
            ScriptedTransport.Step.respond(
                status: 200, body: body(TestSupport.jobStatusJSON(status: "queued", decision: nil))
            )
        })
        let client = BackendHTTPClient(configuration: configuration, transport: transport)
        let task = Task {
            try await client.waitForJobCompletion(
                sessionID: "s-test", utteranceID: "u0",
                pollInterval: .milliseconds(200), timeout: .seconds(10)
            )
        }
        try await Task.sleep(for: .milliseconds(50))
        task.cancel()
        do {
            _ = try await task.value
            XCTFail("expected cancellation")
        } catch is CancellationError {
            // expected
        } catch {
            XCTFail("unexpected \(error)")
        }
        let count = await transport.recorded.count
        XCTAssertEqual(count, 1, "cancellation must stop further polling")
    }

    // MARK: Sequenced uploader

    func testUploaderAssignsSequencesFromZeroAndAdvancesOnAccept() async throws {
        let configuration = try TestSupport.fastRetryConfiguration()
        let transport = ScriptedTransport(steps: [
            .respond(status: 202, body: body(TestSupport.uploadAcceptedJSON(sequence: 0))),
            .respond(status: 202, body: body(TestSupport.uploadAcceptedJSON(sequence: 1)))
        ])
        let client = BackendHTTPClient(configuration: configuration, transport: transport)
        let uploader = WAVSessionUploader(client: client, sessionID: "s-test")
        let first = try await uploader.upload(utteranceID: "u0", wavData: SyntheticWAV.data(frames: 10))
        XCTAssertEqual(first.job.sequence, 0)
        let second = try await uploader.upload(utteranceID: "u1", wavData: SyntheticWAV.data(frames: 10))
        XCTAssertEqual(second.job.sequence, 1)
        let calls = await transport.recorded
        XCTAssertEqual(calls.count, 2)
        let firstBody = parseMultipart(try XCTUnwrap(calls[0].body), contentTypeHeader: try XCTUnwrap(calls[0].contentType))
        let secondBody = parseMultipart(try XCTUnwrap(calls[1].body), contentTypeHeader: try XCTUnwrap(calls[1].contentType))
        XCTAssertEqual(String(decoding: firstBody[2].body, as: UTF8.self), "0")
        XCTAssertEqual(String(decoding: secondBody[2].body, as: UTF8.self), "1")
    }

    func testUploaderKeepsFailedUploadIdentityForRetry() async throws {
        let configuration = try TestSupport.fastRetryConfiguration()
        let transport = ScriptedTransport(steps: [
            .respond(status: 503, body: Data()),
            .respond(status: 503, body: Data()),
            .respond(status: 503, body: Data()),
            .respond(status: 202, body: body(TestSupport.uploadAcceptedJSON(sequence: 0))),
            .respond(status: 202, body: body(TestSupport.uploadAcceptedJSON(sequence: 1)))
        ])
        let client = BackendHTTPClient(configuration: configuration, transport: transport)
        let uploader = WAVSessionUploader(client: client, sessionID: "s-test")
        do {
            _ = try await uploader.upload(utteranceID: "u0", wavData: SyntheticWAV.data(frames: 10))
            XCTFail("expected exhaustion")
        } catch let error as BackendHTTPError {
            XCTAssertEqual(error, .retryBudgetExhausted("POST audio-jobs/u0"))
        }
        let identity = await uploader.pendingRetryIdentity
        XCTAssertEqual(identity?.utteranceID, "u0")
        XCTAssertEqual(identity?.sequence, 0)
        // Retry keeps the failed identity; a later recording takes the next slot.
        let retried = try await uploader.retryLastUpload()
        XCTAssertEqual(retried.job.utteranceID, "u0")
        let next = try await uploader.upload(utteranceID: "u1", wavData: SyntheticWAV.data(frames: 10))
        XCTAssertEqual(next.job.sequence, 1)
        let calls = await transport.recorded
        XCTAssertEqual(calls.count, 5)
        XCTAssertEqual(calls[0].body, calls[1].body)
        XCTAssertEqual(calls[1].body, calls[2].body)
        XCTAssertEqual(calls[2].body, calls[3].body, "retry must reuse the original multipart bytes")
    }

    // MARK: Redaction

    func testErrorsAndDescriptionsNeverLeakTheToken() async throws {
        let (client, _) = try TestSupport.makeClient([
            .respond(status: 401, body: Data())
        ])
        do {
            _ = try await client.createSession(sessionID: "s-test")
            XCTFail("expected unauthorized")
        } catch let error as BackendHTTPError {
            XCTAssertEqual(error, .unauthorized)
            XCTAssertFalse(errorText(error).contains(TestSupport.testToken))
        }
        let (failingDecode, _) = try TestSupport.makeClient([
            .respond(status: 200, body: body(#"{"detail": "SECRET-HINT-XYZ"}"#))
        ])
        do {
            _ = try await failingDecode.getSession(sessionID: "s-test")
            XCTFail("expected decode failure")
        } catch let error as BackendHTTPError {
            XCTAssertEqual(error, .decodingFailed("GET /v1/sessions"))
            let text = errorText(error)
            XCTAssertFalse(text.contains("SECRET-HINT-XYZ"), "decode errors must not echo bodies")
            XCTAssertFalse(text.contains(TestSupport.testToken))
        }
    }
}
