import Foundation

/// Session state is independent of whichever historical review is being browsed.
struct TrainingContext: Equatable, Sendable {
  var phase = "ready"
  var exercise: String?
  var weightKilograms: Double?
  var setNumber = 0
  var events: [TrainingEvent] = []
  var utterances: [String] = []
  var questions: [TrainingQuestion] = []
  var elapsedMinutes = 0
  var analysisRevision = 0

  init() {}

  init(
    events: [TrainingEvent], utterances: [String] = [], questions: [TrainingQuestion] = [],
    elapsedMinutes: Int = 0
  ) {
    self.events = events
    self.utterances = utterances
    self.questions = questions
    self.elapsedMinutes = elapsedMinutes
    self.phase = events.last?.phase ?? "ready"
    self.exercise = events.last(where: { $0.type == .set })?.exercise
    if let latest = events.last(where: { $0.type == .set }), latest.hasRecordedWeight {
      self.weightKilograms = latest.weightKilograms
    }
    self.setNumber = events.last(where: { $0.type == .set })?.setNumber ?? 0
  }

  func applying(_ step: TrainingConversationStep) -> TrainingContext {
    var next = self
    next.utterances.append(step.utterance)
    next.elapsedMinutes = max(elapsedMinutes, step.endMinute)
    if let phase = step.phase { next.phase = phase }
    if let exercise = step.exercise, exercise != next.exercise {
      next.exercise = exercise
      next.setNumber = 0
    }
    if let weight = step.weightKilograms { next.weightKilograms = weight }
    if let question = step.question { next.questions.append(question) }
    guard let kind = step.eventKind else { return next }
    if kind == .set {
      let number = step.setNumber ?? next.setNumber + 1
      let event = TrainingEvent(
        exercise: next.exercise ?? "未识别动作",
        weightKilograms: next.weightKilograms ?? 0,
        repetitions: step.repetitions ?? 0,
        feeling: step.feeling, sourceText: step.utterance,
        type: .set, setNumber: number, rir: step.rir,
        interpretation: step.interpretation)
      next.phase = "training"
      next.setNumber = number
      next.events.append(event)
    } else {
      next.events.append(
        TrainingEvent(
          exercise: step.label ?? "训练活动",
          sourceText: step.utterance, type: kind,
          phase: next.phase, detail: step.detail,
          interpretation: step.interpretation,
          durationMinutes: step.durationMinutes))
    }
    return next
  }

  /// Corrections replace a stable event instead of appending a duplicate set.
  mutating func correct(_ event: TrainingEvent) {
    guard let index = events.firstIndex(where: { $0.id == event.id }) else { return }
    events[index] = event
    if let latest = events.last(where: { $0.type == .set }), latest.exercise == exercise {
      weightKilograms = latest.hasRecordedWeight ? latest.weightKilograms : nil
      setNumber = latest.setNumber ?? setNumber
    }
  }
}

struct TrainingConversationStep: Sendable {
  let utterance: String
  let status: String
  let interpretation: String
  var eventKind: TrainingEventKind? = nil
  var phase: String? = nil
  var exercise: String? = nil
  var weightKilograms: Double? = nil
  var setNumber: Int? = nil
  var repetitions: Int? = nil
  var rir: Int? = nil
  var feeling: String = ""
  var label: String? = nil
  var detail: String = ""
  var durationMinutes: Double? = nil
  var question: TrainingQuestion? = nil
  var endSession = false
  var endMinute = 0
}

struct TrainingAnalysisUpdate: Sendable {
  let context: TrainingContext
  let status: String
  let coachReply: String
  let question: TrainingQuestion?
  let endIntent: TrainingEndIntent
  let isSimulated: Bool
  /// Real adapters set this only on a committed transcript and confirmed intent.
  let isFinal: Bool
  let requiresClarification: Bool

  var requestsSessionEnd: Bool { endIntent == .complete }

  init(
    context: TrainingContext, status: String, coachReply: String, question: TrainingQuestion?,
    requestsSessionEnd: Bool, isSimulated: Bool, endIntent: TrainingEndIntent? = nil,
    isFinal: Bool = true, requiresClarification: Bool = false
  ) {
    self.context = context
    self.status = status
    self.coachReply = coachReply
    self.question = question
    self.endIntent = endIntent ?? (requestsSessionEnd ? .complete : .continueTraining)
    self.isSimulated = isSimulated
    self.isFinal = isFinal
    self.requiresClarification = requiresClarification
  }
}
