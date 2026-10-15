import Foundation

enum TrainingSessionConnectionState: Equatable, Sendable {
  case idle, opening, active, finishing, closed, failed
}

/// Owns the lifetime of a training conversation, not the lifetime of a SwiftUI view.
/// A future vendor adapter may own an HTTP session or socket behind this boundary.
/// Operations are scoped to an immutable ID: canceling an older ID must never close
/// another session. Implementations must make finish/cancel idempotent and retain
/// cancellation even when a slow begin operation completes afterward.
protocol TrainingSessionConnection: Sendable {
  var isSimulated: Bool { get }
  func begin(sessionID: UUID) async throws
  /// Called only after hardware transfer and submitted transcript work have drained.
  func finish(sessionID: UUID) async throws
  func cancel(sessionID: UUID) async
}

enum TrainingSessionConnectionError: LocalizedError {
  case missingSession
  case alreadyClosed

  var errorDescription: String? {
    switch self {
    case .missingSession: return "训练会话尚未建立"
    case .alreadyClosed: return "训练会话已关闭"
    }
  }
}

/// An in-memory lifecycle implementation. It does not open an HTTP/WSS connection
/// or transmit audio. It gives tests and the demo the same ownership boundary that
/// a future real backend adapter must implement.
actor MockTrainingSessionConnection: TrainingSessionConnection {
  nonisolated let isSimulated = true
  private enum State { case active, finished, cancelled }
  private var sessions: [UUID: State] = [:]

  func begin(sessionID: UUID) async throws {
    try Task.checkCancellation()
    switch sessions[sessionID] {
    case .active: return
    case .finished: throw TrainingSessionConnectionError.alreadyClosed
    case .cancelled: throw CancellationError()
    case nil: sessions[sessionID] = .active
    }
  }

  func finish(sessionID: UUID) async throws {
    try Task.checkCancellation()
    switch sessions[sessionID] {
    case .active: sessions[sessionID] = .finished
    case .finished: return
    case .cancelled: throw CancellationError()
    case nil: throw TrainingSessionConnectionError.missingSession
    }
  }

  func cancel(sessionID: UUID) async {
    guard sessions[sessionID] != .finished else { return }
    sessions[sessionID] = .cancelled
  }
}
