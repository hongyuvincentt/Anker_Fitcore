import Foundation

/// Status shared with the desktop, separate from saved reviews. This describes
/// the evidence available to the phone; a connected device alone is not recording.
struct CloudLiveSnapshot: Codable, Equatable, Sendable {
  enum Phase: String, Codable, Sendable {
    case recording, finishing, completed, cancelled, disconnected
    var isTerminal: Bool { self == .completed || self == .cancelled || self == .disconnected }
  }
  enum Stage: String, Codable, Sendable { case idle, active, complete, attention, unknown }
  struct Device: Codable, Equatable, Sendable {
    let name: String
    let connected: Bool?
    let recording: Bool?
    let simulated: Bool
  }
  struct Stages: Codable, Equatable, Sendable {
    let recording: Stage
    let transcription: Stage
    let analysis: Stage
    let review: Stage
  }
  let publisher_id: UUID
  let sequence: Int
  let phase: Phase
  let elapsed_seconds: Int
  let device: Device
  let stages: Stages
  let analysis_issue: String?
  let latest_utterance: String
  let coach_reply: String
  let record_count: Int
  let is_simulated: Bool
  let review_id: UUID?
}

/// A committed analysis result, owned by the session rather than a screen.
/// Monotonic time prevents navigation or clock changes from replaying old success.
struct TrainingRecordUpdateFeedback: Equatable, Sendable {
  let id = UUID()
  let sessionID: UUID
  let inputID: UUID
  let startedAt: ContinuousClock.Instant

  init(sessionID: UUID, inputID: UUID, startedAt: ContinuousClock.Instant = .now) {
    self.sessionID = sessionID
    self.inputID = inputID
    self.startedAt = startedAt
  }

  private static let holdSeconds = 3.0
  private static let fadeSeconds = 0.65

  func opacity(at now: ContinuousClock.Instant = .now, reduceMotion: Bool = false) -> Double {
    let elapsed = elapsedSeconds(at: now)
    if elapsed < Self.holdSeconds { return 1 }
    if reduceMotion { return 0 }
    if elapsed >= Self.holdSeconds + Self.fadeSeconds { return 0 }
    let remaining = max(0, 1 - (elapsed - Self.holdSeconds) / Self.fadeSeconds)
    return remaining * remaining * remaining
  }

  /// Schedule only the hold boundary and fade frames, with no perpetual UI timer.
  /// Rebuilding the view resumes the remaining interval; it never restarts it.
  func refreshDates(from date: Date = Date(), at now: ContinuousClock.Instant = .now,
    reduceMotion: Bool = false) -> [Date] {
    let elapsed = elapsedSeconds(at: now)
    var offsets = [0.0]
    if elapsed < Self.holdSeconds { offsets.append(Self.holdSeconds - elapsed) }
    if !reduceMotion {
      for frame in 1...40 {
        let offset = Self.holdSeconds + Self.fadeSeconds * Double(frame) / 40 - elapsed
        if offset > 0 { offsets.append(offset) }
      }
    }
    return offsets.map { date.addingTimeInterval($0) }
  }

  private func elapsedSeconds(at now: ContinuousClock.Instant) -> Double {
    let components = startedAt.duration(to: now).components
    return max(0, Double(components.seconds) + Double(components.attoseconds) / 1e18)
  }
}

enum TrainingInputSource: String, Codable, Sendable {
  case speech, text, demo
  var label: String {
    switch self {
    case .speech: return "语音转写"
    case .text: return "文字输入"
    case .demo: return "演示原话"
    }
  }
}

struct TrainingInputEntry: Identifiable, Equatable, Codable, Sendable {
  enum State: String, Codable, Sendable {
    case processing = "处理中"
    case understood = "已整理"
    case needsAttention = "待处理"
    case supplemented = "已补充说明"
  }
  let id: UUID
  let text: String
  let source: TrainingInputSource
  var state: State
}

struct PendingTrainingInput: Sendable {
  let id: UUID
  let text: String
  let source: TrainingInputSource
  let isDemoStep: Bool
  var analysisText: String? = nil
  var clarifiesInputID: UUID? = nil
}

enum TrainingInteractionIssue: Equatable, Sendable {
  case clarification
  case service
  case notConfigured
  case backend(BackendTrainingError)
  case backendClarification(String)

  var title: String {
    switch self {
    case .clarification, .backendClarification: return "这句话还需要你补充一下"
    case .service: return "暂时没能完成分析"
    case .notConfigured: return "真实 AI 尚未接入"
    case .backend: return "文字分析未完成"
    }
  }

  var message: String {
    switch self {
    case .backend(let error): return error.localizedDescription
    case .backendClarification(let message): return message
    case .clarification:
      return "不好意思，这句话我还没理解。可以再说一遍，或在下方打字补充动作、重量和次数。"
    case .service:
      return "分析服务暂时不可用，原话已保留在本次会话中。请重试，无需重复描述。"
    case .notConfigured:
      return "文字已保留在本次会话中。接入真实 AI 后才能分析自由输入；当前不会生成虚构的训练记录。"
    }
  }
}
