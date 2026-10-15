import Foundation
import XCTest
@testable import WAVHTTPKit

final class RecordSnapshotReconcilerTests: XCTestCase {
    private func decodeFacts(_ json: String) throws -> [TrainingFactDTO] {
        try JSONDecoder().decode([TrainingFactDTO].self, from: Data(json.utf8))
    }

    private func decodePending(_ json: String) throws -> [PendingItem] {
        try JSONDecoder().decode([PendingItem].self, from: Data(json.utf8))
    }

    func testFactsSnapshotReplacesCorrectedFactWithSameID() throws {
        let current = try decodeFacts("""
        [{"id":12,"exercise_instance_id":1,"exercise":"卧推","set_number":1,"weight_kg":60,"reps":10,"weight_provenance":"explicit","weight_source_fact_id":null,"source_utterance_id":"u1"}]
        """)
        let fetched = try decodeFacts("""
        [{"id":12,"exercise_instance_id":1,"exercise":"卧推","set_number":1,"weight_kg":60,"reps":8,"weight_provenance":"explicit","weight_source_fact_id":null,"source_utterance_id":"u2"}]
        """)

        let result = RecordSnapshotReconciler.facts(current: current, fetched: fetched)

        XCTAssertEqual(result.count, 1)
        XCTAssertEqual(result[0].id, 12)
        XCTAssertEqual(result[0].reps, 8, "同 fact_id 的服务端纠错快照必须覆盖旧值，不能保留 10 次")
        XCTAssertEqual(result[0].sourceUtteranceID, "u2")
    }

    func testPendingSnapshotKeepsOnlyCurrentlyOpenItemsAndRemovesResolvedOnes() throws {
        let current = try decodePending("""
        [{"id":1,"status":"open"},{"id":2,"status":"open"}]
        """)
        let fetched = try decodePending("""
        [{"id":1,"status":"resolved"},{"id":2,"status":"open"},{"id":3,"status":"closed"}]
        """)

        let result = RecordSnapshotReconciler.pending(current: current, fetched: fetched)

        XCTAssertEqual(result.count, 1)
        XCTAssertEqual(result.first?.pendingID, "2")
        XCTAssertTrue(result.allSatisfy(\.isOpen))
    }

    func testUnknownEventTypePreservesPageInsteadOfFailingDecode() throws {
        let json = """
        {
          "events": [
            {
              "event_seq": 9,
              "event_id": "session-e000009",
              "type": "PENDING_AUTO_RECOVERED",
              "utterance_id": "u9",
              "payload": {"recovery_kind": "auto_slot_merge", "matched_pending_id": 3},
              "created_at": "2026-10-16T05:00:00Z"
            }
          ],
          "next_cursor": 9,
          "has_more": false
        }
        """

        let page = try JSONDecoder().decode(EventsPage.self, from: Data(json.utf8))

        XCTAssertEqual(page.events.count, 1)
        XCTAssertEqual(page.events[0].type.rawValue, "PENDING_AUTO_RECOVERED")
        XCTAssertEqual(page.events[0].eventSeq, 9)
        XCTAssertEqual(page.events[0].utteranceID, "u9")
        XCTAssertEqual(page.nextCursor, 9)
    }
}

private actor SnapshotRefreshTransport: HTTPTransport {
    enum Snapshot {
        case initial
        case corrected
    }

    private var snapshot: Snapshot = .initial

    func use(_ snapshot: Snapshot) {
        self.snapshot = snapshot
    }

    nonisolated func send(_ request: URLRequest) async throws -> (data: Data, response: HTTPURLResponse) {
        let (status, body) = await response(for: request)
        let response = HTTPURLResponse(
            url: request.url!,
            statusCode: status,
            httpVersion: "HTTP/1.1",
            headerFields: ["Content-Type": "application/json"]
        )!
        return (Data(body.utf8), response)
    }

    private func response(for request: URLRequest) -> (Int, String) {
        let path = request.url?.path ?? ""
        let method = request.httpMethod ?? "GET"

        if method == "POST", path == "/v1/sessions" {
            let sid = ((try? JSONSerialization.jsonObject(with: request.httpBody ?? Data())) as? [String: Any])?["session_id"] as? String ?? "s1"
            return (201, sessionJSON(sid))
        }
        if method == "GET", path.hasSuffix("/facts") {
            switch snapshot {
            case .initial:
                return (200, "[{\"id\":12,\"exercise_instance_id\":1,\"exercise\":\"卧推\",\"set_number\":1,\"weight_kg\":60,\"reps\":10,\"weight_provenance\":\"explicit\",\"weight_source_fact_id\":null,\"source_utterance_id\":\"u1\"}]")
            case .corrected:
                return (200, "[{\"id\":12,\"exercise_instance_id\":1,\"exercise\":\"卧推\",\"set_number\":1,\"weight_kg\":60,\"reps\":8,\"weight_provenance\":\"explicit\",\"weight_source_fact_id\":null,\"source_utterance_id\":\"u2\"}]")
            }
        }
        if method == "GET", path.hasSuffix("/pending") {
            switch snapshot {
            case .initial: return (200, "[{\"id\":1,\"status\":\"open\"}]")
            case .corrected: return (200, "[{\"id\":1,\"status\":\"resolved\"}]")
            }
        }
        if method == "GET", path.hasSuffix("/events") {
            return (200, "{\"events\":[],\"next_cursor\":0,\"has_more\":false}")
        }
        return (404, "{\"detail\":\"NOT_FOUND\"}")
    }

    private func sessionJSON(_ sid: String) -> String {
        "{\"session_id\":\"\(sid)\",\"version\":0,\"status\":\"active\",\"active_exercise_instance_id\":null,\"active_exercise_name\":null,\"last_completed_set_id\":null,\"last_reported_weight\":null,\"next_set_plan\":null}"
    }
}

@MainActor
final class CloudTrainingSnapshotRefreshTests: XCTestCase {
    private func waitUntil(
        timeout: Duration = .seconds(2),
        _ condition: @MainActor () -> Bool
    ) async -> Bool {
        let deadline = ContinuousClock.now + timeout
        while ContinuousClock.now < deadline {
            if condition() { return true }
            try? await Task.sleep(for: .milliseconds(20))
        }
        return condition()
    }

    func testRefreshReplacesCorrectedFactAndRemovesResolvedPending() async throws {
        let transport = SnapshotRefreshTransport()
        let configuration = try BackendHTTPConfiguration(
            baseURL: URL(string: "https://snapshot.fitcore.test")!,
            accessToken: "offline-test-token"
        )
        let model = CloudTrainingModel(
            client: BackendHTTPClient(configuration: configuration, transport: transport),
            jobPollInterval: .milliseconds(20),
            jobPollTimeout: .seconds(1),
            drainTimeout: .seconds(1)
        )

        model.createSession()
        XCTAssertTrue(await waitUntil { model.phase == .ready })

        model.refreshRecords()
        XCTAssertTrue(await waitUntil { !model.isRefreshingRecords && model.facts.count == 1 })
        XCTAssertEqual(model.facts[0].reps, 10)
        XCTAssertEqual(model.pendingItems.count, 1)

        await transport.use(.corrected)
        model.refreshRecords()
        XCTAssertTrue(await waitUntil {
            !model.isRefreshingRecords && model.facts.first?.reps == 8 && model.pendingItems.isEmpty
        })
        XCTAssertEqual(model.facts.count, 1, "纠错不得新增第二张训练组卡片")
        XCTAssertEqual(model.facts[0].id, 12)
        XCTAssertEqual(model.facts[0].sourceUtteranceID, "u2")
        XCTAssertTrue(model.pendingItems.isEmpty, "服务端已处理 Pending 后，UI 不得残留旧待确认卡片")
    }
}
