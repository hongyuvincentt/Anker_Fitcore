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
