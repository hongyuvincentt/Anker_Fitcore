import Foundation
import XCTest
@testable import WAVHTTPKit

/// Contract tests for facts, pending, events cursor, finish barrier states,
/// review protection, and authorization mapping. All requests are intercepted;
/// fixtures are transcriptions of the sanitized V1.1 samples.
final class BackendHTTPContractTests: XCTestCase {

    // MARK: Facts

    func testFactsDecodeFromSanitizedSample() async throws {
        let (client, transport) = try TestSupport.makeClient([
            .respond(status: 200, body: body(TestSupport.factsJSON))
        ])
        let facts = try await client.facts(sessionID: "s-test")
        XCTAssertEqual(facts.count, 1)
        XCTAssertEqual(facts[0].exercise, "bench_press")
        XCTAssertEqual(facts[0].weightKg, 60.0)
        XCTAssertEqual(facts[0].reps, 8)
        XCTAssertEqual(facts[0].weightProvenance, "EXPLICIT")
        XCTAssertEqual(facts[0].sourceUtteranceID, "u0")
        let call = await transport.recorded.first
        XCTAssertEqual(call?.url, "https://backend.example.test/v1/sessions/s-test/facts")
        XCTAssertEqual(call?.authorization, "Bearer \(TestSupport.testToken)")
    }

    // MARK: Pending

    func testPendingDecodesPermissiveShapeAndFiltersOpenClientSide() async throws {
        let (client, _) = try TestSupport.makeClient([
            .respond(status: 200, body: body(TestSupport.pendingJSON))
        ])
        let pending = try await client.pending(sessionID: "s-test")
        XCTAssertEqual(pending.count, 2)
        XCTAssertEqual(pending.filter(\.isOpen).count, 1)
        XCTAssertEqual(pending[0].pendingID, "7")
        XCTAssertEqual(pending[0].status, "open")
    }

    func testResolvePendingSendsConfirmedFieldsAndMaps409() async throws {
        let (client, transport) = try TestSupport.makeClient([
            .respond(status: 200, body: body(#"{"status": "resolved"}"#))
        ])
        let result = try await client.resolvePending(
            sessionID: "s-test",
            pendingID: "7",
            resolution: PendingResolution(resolutionID: "r-001", action: "confirm_set", contextVersion: 2)
        )
        XCTAssertEqual(result.stringValue, nil)
        let call = await transport.recorded.first
        XCTAssertEqual(call?.method, "POST")
        XCTAssertEqual(call?.url, "https://backend.example.test/v1/sessions/s-test/pending/7/resolve")
        XCTAssertEqual(call?.body, body(#"{"action":"confirm_set","context_version":2,"resolution_id":"r-001"}"#))

        let (conflicting, conflictTransport) = try TestSupport.makeClient([
            .respond(status: 409, body: body(#"{"detail": "CONTEXT_VERSION_MISMATCH"}"#))
        ])
        do {
            _ = try await conflicting.resolvePending(
                sessionID: "s-test", pendingID: "7",
                resolution: PendingResolution(resolutionID: "r-002", action: "dismiss", contextVersion: 1)
            )
            XCTFail("expected conflict")
        } catch let error as BackendHTTPError {
            XCTAssertEqual(error, .pendingConflict("CONTEXT_VERSION_MISMATCH"))
        }
        let count = await conflictTransport.recorded.count
        XCTAssertEqual(count, 1, "pending conflicts must not blind-retry")
    }

    // MARK: Events

    func testEventsSendsCursorQueryAndDecodesPage() async throws {
        let (client, transport) = try TestSupport.makeClient([
            .respond(status: 200, body: body(TestSupport.eventsJSON))
        ])
        let page = try await client.events(sessionID: "s-test", after: 0, limit: 100)
        XCTAssertEqual(page.events.count, 2)
        XCTAssertEqual(page.nextCursor, 2)
        XCTAssertFalse(page.hasMore)
        XCTAssertEqual(page.events[0].type, .transcriptFinal)
        XCTAssertEqual(page.events[1].type, .factCommitted)
        XCTAssertEqual(
            page.events[0].payload.objectValue?["text"]?.stringValue,
            "卧推60公斤做了8个。"
        )
        let call = await transport.recorded.first
        XCTAssertEqual(
            call?.url,
            "https://backend.example.test/v1/sessions/s-test/events?after=0&limit=100"
        )
    }

    func testEventsValidatesCursorAndLimitLocally() async throws {
        let (client, transport) = try TestSupport.makeClient([])
        for (after, limit) in [(-1, 100), (0, 0), (0, 101)] {
            do {
                _ = try await client.events(sessionID: "s-test", after: after, limit: limit)
                XCTFail("expected rejection for after=\(after) limit=\(limit)")
            } catch let error as BackendHTTPError {
                XCTAssertEqual(error, .invalidParameters(limit == 100 ? "事件游标 after 不能为负数" : "limit 须在 1–100"))
            }
        }
        let count = await transport.recorded.count
        XCTAssertEqual(count, 0, "invalid cursor/limit must never reach the network")
    }

    func testEventsCursorAheadMapsToConflict() async throws {
        let (client, transport) = try TestSupport.makeClient([
            .respond(status: 409, body: body(#"{"detail": "CURSOR_AHEAD_OF_STREAM"}"#))
        ])
        do {
            _ = try await client.events(sessionID: "s-test", after: 9)
            XCTFail("expected conflict")
        } catch let error as BackendHTTPError {
            XCTAssertEqual(error, .eventCursorConflict("CURSOR_AHEAD_OF_STREAM"))
        }
        let count = await transport.recorded.count
        XCTAssertEqual(count, 1)
    }

    // MARK: Finish

    func testFinishDraining202Decodes() async throws {
        let (client, transport) = try TestSupport.makeClient([
            .respond(status: 202, body: body(TestSupport.finishJSON(
                state: "draining",
                complete: false,
                acceptanceClosed: true,
                unfinished: #"""
                [{"utterance_id": "u0", "sequence": 0,
                "audio_sha256": "cf95fe997c5100ab3ba90e8ec0af94b263e93990efda441fa5b33f86852e6337",
                "status": "queued", "error_type": null}]
                """#
            )))
        ])
        let response = try await client.finishSession(sessionID: "s-test", finishID: "f-test", lastSequence: 0)
        XCTAssertEqual(response.state, "draining")
        XCTAssertFalse(response.complete)
        XCTAssertTrue(response.acceptanceClosed)
        XCTAssertNil(response.review)
        XCTAssertEqual(response.unfinished.count, 1)
        XCTAssertEqual(response.unfinished[0].status, .queued)
        let call = await transport.recorded.first
        XCTAssertEqual(call?.body, body(#"{"finish_id":"f-test","last_sequence":0}"#))
    }

    func testFinishAwaitingAudio409CarriesMissingSequences() async throws {
        let (client, transport) = try TestSupport.makeClient([
            .respond(status: 409, body: body(TestSupport.finishJSON(
                state: "awaiting_audio",
                complete: false,
                acceptanceClosed: false,
                missing: [0, 2]
            )))
        ])
        do {
            _ = try await client.finishSession(sessionID: "s-test", finishID: "f-test", lastSequence: 2)
            XCTFail("expected awaiting audio")
        } catch let error as BackendHTTPError {
            XCTAssertEqual(error, .finishAwaitingAudio([0, 2]))
            XCTAssertTrue(errorText(error).contains("缺 [0, 2]"))
        }
        let count = await transport.recorded.count
        XCTAssertEqual(count, 1, "awaiting_audio is not auto-retried; caller uploads missing audio first")
    }

    func testFinishRangeExcludesAcceptedAudio409() async throws {
        let (client, _) = try TestSupport.makeClient([
            .respond(status: 409, body: body(#"{"detail": "FINISH_RANGE_EXCLUDES_ACCEPTED_AUDIO"}"#))
        ])
        do {
            _ = try await client.finishSession(sessionID: "s-test", finishID: "f-test", lastSequence: 0)
            XCTFail("expected range error")
        } catch let error as BackendHTTPError {
            XCTAssertEqual(error, .finishRangeExcludesAccepted)
        }
    }

    func testFinishFinished200DecodesReviewSnapshot() async throws {
        let (client, _) = try TestSupport.makeClient([
            .respond(status: 200, body: body(TestSupport.finishJSON(
                state: "finished",
                complete: true,
                acceptanceClosed: true,
                review: TestSupport.reviewJSON
            )))
        ])
        let response = try await client.finishSession(sessionID: "s-test", finishID: "f-test", lastSequence: 0)
        XCTAssertTrue(response.complete)
        XCTAssertEqual(response.review?.totalSets, 1)
        XCTAssertEqual(response.review?.volumeKgReps, 480.0)
    }

    func testFinish503RetriesSameFinishBody() async throws {
        let configuration = try TestSupport.fastRetryConfiguration()
        let transport = ScriptedTransport(steps: [
            .respond(status: 503, body: body(#"{"detail": "FINISH_DATABASE_ERROR_RETRY_SAME_ID"}"#)),
            .respond(status: 200, body: body(TestSupport.finishJSON(
                state: "finished", complete: true, acceptanceClosed: true,
                review: TestSupport.reviewJSON
            )))
        ])
        let client = BackendHTTPClient(configuration: configuration, transport: transport)
        let response = try await client.finishSession(sessionID: "s-test", finishID: "f-test", lastSequence: 0)
        XCTAssertTrue(response.complete)
        let calls = await transport.recorded
        XCTAssertEqual(calls.count, 2)
        XCTAssertEqual(calls[0].body, calls[1].body, "503 must retry the same finish_id and range")
    }

    func testFinishStatus404MapsToNotFound() async throws {
        let (client, _) = try TestSupport.makeClient([
            .respond(status: 404, body: body(#"{"detail": "FINISH_NOT_REQUESTED"}"#))
        ])
        do {
            _ = try await client.finishStatus(sessionID: "s-test")
            XCTFail("expected notFound")
        } catch let error as BackendHTTPError {
            XCTAssertEqual(error, .notFound)
        }
    }

    func testDrainToCompletionPollsUntilFinished() async throws {
        let configuration = try TestSupport.fastRetryConfiguration()
        let transport = ScriptedTransport(steps: [
            .respond(status: 202, body: body(TestSupport.finishJSON(
                state: "draining", complete: false, acceptanceClosed: true
            ))),
            .respond(status: 200, body: body(TestSupport.finishJSON(
                state: "draining", complete: false, acceptanceClosed: true
            ))),
            .respond(status: 200, body: body(TestSupport.finishJSON(
                state: "finished", complete: true, acceptanceClosed: true,
                review: TestSupport.reviewJSON
            )))
        ])
        let client = BackendHTTPClient(configuration: configuration, transport: transport)
        let final = try await client.drainToCompletion(
            sessionID: "s-test", finishID: "f-test", lastSequence: 0,
            pollInterval: .milliseconds(1), timeout: .seconds(2)
        )
        XCTAssertTrue(final.complete)
        XCTAssertEqual(final.review?.totalSets, 1)
        let calls = await transport.recorded
        XCTAssertEqual(calls.map(\.method), ["POST", "GET", "GET"])
    }

    func testDrainToCompletionRepostsWhenReadyToFinalize() async throws {
        let configuration = try TestSupport.fastRetryConfiguration()
        let transport = ScriptedTransport(steps: [
            .respond(status: 202, body: body(TestSupport.finishJSON(
                state: "draining", complete: false, acceptanceClosed: true
            ))),
            .respond(status: 200, body: body("""
            {"session_id": "s-test", "finish_id": "f-test", "last_sequence": 0,
            "state": "draining", "complete": false, "acceptance_closed": true,
            "missing_sequences": [], "missing_count": 0, "unfinished": [],
            "accepted_count": 1, "ready_to_finalize": true, "review": null}
            """)),
            .respond(status: 200, body: body(TestSupport.finishJSON(
                state: "finished", complete: true, acceptanceClosed: true,
                review: TestSupport.reviewJSON
            )))
        ])
        let client = BackendHTTPClient(configuration: configuration, transport: transport)
        let final = try await client.drainToCompletion(
            sessionID: "s-test", finishID: "f-test", lastSequence: 0,
            pollInterval: .milliseconds(1), timeout: .seconds(2)
        )
        XCTAssertTrue(final.complete)
        let calls = await transport.recorded
        XCTAssertEqual(calls.map(\.method), ["POST", "GET", "POST"], "ready_to_finalize requires re-POSTing the same finish")
        XCTAssertEqual(calls[0].body, calls[2].body)
    }

    // MARK: Review

    func testReview409MapsToNotFinished() async throws {
        let (client, transport) = try TestSupport.makeClient([
            .respond(status: 409, body: body(#"{"detail": "FINISH_NOT_COMPLETE"}"#))
        ])
        do {
            _ = try await client.review(sessionID: "s-test")
            XCTFail("expected not finished")
        } catch let error as BackendHTTPError {
            XCTAssertEqual(error, .reviewNotFinished("FINISH_NOT_COMPLETE"))
        }
        let count = await transport.recorded.count
        XCTAssertEqual(count, 1)
    }

    func testReviewDecodesFromSanitizedSample() async throws {
        let (client, _) = try TestSupport.makeClient([
            .respond(status: 200, body: body(TestSupport.reviewJSON))
        ])
        let review = try await client.review(sessionID: "s-test")
        XCTAssertEqual(review.sessionID, "s-test")
        XCTAssertEqual(review.contextVersion, 2)
        XCTAssertEqual(review.totalSets, 1)
        XCTAssertEqual(review.totalReps, 8)
        XCTAssertEqual(review.volumeKgReps, 480.0)
        XCTAssertEqual(review.pendingCount, 0)
        XCTAssertEqual(review.facts.first?.sourceUtteranceID, "u0")
    }

    // MARK: Authorization and generic errors

    func testUnauthorized401And403AreMappedAndNotRetried() async throws {
        for status in [401, 403] {
            let (client, transport) = try TestSupport.makeClient([
                .respond(status: status, body: Data())
            ])
            do {
                _ = try await client.facts(sessionID: "s-test")
                XCTFail("expected unauthorized")
            } catch let error as BackendHTTPError {
                XCTAssertEqual(error, .unauthorized)
                XCTAssertTrue(errorText(error).contains("401/403"))
            }
            let count = await transport.recorded.count
            XCTAssertEqual(count, 1)
        }
    }

    func testUnexpectedStatusIsSurfaced() async throws {
        let (client, _) = try TestSupport.makeClient([
            .respond(status: 418, body: Data())
        ])
        do {
            _ = try await client.facts(sessionID: "s-test")
            XCTFail("expected unexpected status")
        } catch let error as BackendHTTPError {
            XCTAssertEqual(error, .unexpectedStatus(418, "GET facts"))
        }
    }

    func testDoneOutcomeDefersAndRejectsAreDistinctFromCommit() throws {
        // done ≠ committed: the three outcome decisions decode distinctly.
        for (decision, expected) in [("COMMIT", FactDecision.commit), ("DEFER", FactDecision.defer), ("REJECT", FactDecision.reject)] {
            let json = TestSupport.jobStatusJSON(status: "done", decision: decision)
            let decoded = try JSONDecoder().decode(AudioJobStatusResponse.self, from: body(json))
            XCTAssertEqual(decoded.job.status, .done)
            XCTAssertEqual(decoded.job.outcome?.decision, expected)
        }
    }
}
