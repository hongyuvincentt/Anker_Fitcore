import Foundation

/// Reconciles server-owned record snapshots without inventing client facts.
///
/// `/facts` is authoritative: a correction may keep the same fact id while
/// changing reps/weight/source, so the latest server snapshot must replace the
/// previous client value rather than append-only de-duplicating it.
///
/// `/pending` may include already-processed entries. The UI-facing snapshot is
/// therefore rebuilt from the latest response and contains only `status=open`.
/// Unknown fields remain preserved inside `PendingItem`; no A02/A03 candidate
/// fields are interpreted here until they are observed in a deployed response.
enum RecordSnapshotReconciler {
    static func facts(
        current _: [TrainingFactDTO],
        fetched: [TrainingFactDTO]
    ) -> [TrainingFactDTO] {
        // Preserve the server's snapshot order. Same-id corrections therefore
        // replace old values, removed facts disappear, and no duplicate card is
        // created client-side.
        fetched
    }

    static func pending(
        current _: [PendingItem],
        fetched: [PendingItem]
    ) -> [PendingItem] {
        fetched.filter(\.isOpen)
    }
}
