import Foundation

enum TrainingPhase: Equatable {
  case disconnected, connecting, ready, recording, finishing, completed

  var title: String {
    switch self {
    case .disconnected: return "未连接"
    case .connecting: return "连接中"
    case .ready: return "准备就绪"
    case .recording: return "训练记录中"
    case .finishing: return "整理复盘中"
    case .completed: return "本次训练已完成"
    }
  }
}

enum RecorderPowerState: Equatable, Sendable {
  case unknown, on, off
}

struct RecorderDevice: Equatable, Sendable {
  let name: String
  let batteryPercent: Int?
  let isSimulated: Bool
  let caseBatteryPercent: Int?
  let powerState: RecorderPowerState

  init(
    name: String, batteryPercent: Int?, isSimulated: Bool,
    caseBatteryPercent: Int? = nil, powerState: RecorderPowerState = .unknown
  ) {
    self.name = name
    self.batteryPercent = batteryPercent.flatMap { (0...100).contains($0) ? $0 : nil }
    self.isSimulated = isSimulated
    self.caseBatteryPercent = caseBatteryPercent.flatMap { (0...100).contains($0) ? $0 : nil }
    self.powerState = powerState
  }
}

enum TrainingEventKind: String, Codable, Sendable { case warmup, set, stretch }

struct TrainingEvent: Identifiable, Equatable, Codable, Sendable {
  let id: UUID
  var exercise: String
  var weightKilograms: Double
  var repetitions: Int
  var feeling: String
  var sourceText: String
  var type: TrainingEventKind
  var phase: String
  var setNumber: Int?
  var rir: Int?
  var detail: String
  var interpretation: String
  var durationMinutes: Double?
  /// Optional for compatibility with previously saved records. A default zero is
  /// not evidence that a user reported zero weight or zero repetitions.
  var weightIsConfirmed: Bool?
  var repetitionsAreConfirmed: Bool?
  var sourceInputIDs: [UUID]?
  var revision: Int?

  init(
    id: UUID = UUID(), exercise: String, weightKilograms: Double = 0,
    repetitions: Int = 0, feeling: String = "", sourceText: String,
    type: TrainingEventKind = .set, phase: String = "training", setNumber: Int? = nil,
    rir: Int? = nil, detail: String = "", interpretation: String = "",
    durationMinutes: Double? = nil, weightIsConfirmed: Bool? = nil,
    repetitionsAreConfirmed: Bool? = nil, sourceInputIDs: [UUID]? = nil, revision: Int? = nil
  ) {
    self.id = id
    self.exercise = exercise
    self.weightKilograms = weightKilograms
    self.repetitions = repetitions
    self.feeling = feeling
    self.sourceText = sourceText
    self.type = type
    self.phase = phase
    self.setNumber = setNumber
    self.rir = rir
    self.detail = detail
    self.interpretation = interpretation
    self.durationMinutes = durationMinutes
    self.weightIsConfirmed = weightIsConfirmed
    self.repetitionsAreConfirmed = repetitionsAreConfirmed
    self.sourceInputIDs = sourceInputIDs
    self.revision = revision
  }

  var label: String { exercise }
  var weightText: String { weightKilograms.formatted(.number.precision(.fractionLength(0...1))) }
  var hasSourceEvidence: Bool { !sourceText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
  var hasRecordedWeight: Bool {
    hasSourceEvidence && weightKilograms.isFinite && weightKilograms >= 0
      && (weightIsConfirmed ?? (weightKilograms > 0))
  }
  var hasRecordedRepetitions: Bool {
    hasSourceEvidence && repetitions >= 0 && (repetitionsAreConfirmed ?? (repetitions > 0))
  }
  var setDescription: String {
    (hasRecordedWeight ? "\(weightText)kg" : "重量待补充") + " × "
      + (hasRecordedRepetitions ? "\(repetitions)次" : "次数待补充")
      + (rir.map { " · RIR\($0)" } ?? "")
  }
  var muscleGroups: [String] {
    RecordedExerciseCatalog.muscles(for: exercise)
  }
  /// Demonstration coefficients only; this is not a measured energy expenditure.
  var estimatedCalories: Int {
    let minutes = type == .set ? 3 : (durationMinutes ?? 0)
    let coefficient = type == .warmup ? 6.0 : (type == .set ? 8.0 : 3.0)
    return Int((minutes * coefficient).rounded())
  }
}

struct TrainingQuestion: Identifiable, Equatable, Codable, Sendable {
  var id: UUID = UUID()
  let text: String
  let answer: String
  let originalText: String
}

struct TrainingReview: Identifiable, Equatable, Codable, Sendable {
  let id: UUID
  let date: Date
  let durationSeconds: Int
  let events: [TrainingEvent]
  let summary: String
  let suggestions: [String]
  let utterances: [String]
  let questions: [TrainingQuestion]
  let phaseCount: Int
  let phaseLabel: String
  let sessionTitle: String
  let isCompleteChain: Bool
  let warmup: String
  let bench: String
  let fly: String
  let stretch: String
  let observation: String
  let nextSession: String
  let estimatedCalories: Int
  let isSimulated: Bool
  /// A real estimate needs an explicit provenance supplied by the integration.
  /// Missing provenance remains unknown, including older non-simulated records.
  let calorieEstimateSource: String?
  /// Preserves failed/retried/supplemented inputs separately from understood text.
  /// Optional so older saved reviews remain readable.
  var inputHistory: [TrainingInputEntry]?

  init(
    id: UUID = UUID(), date: Date = Date(), durationSeconds: Int,
    events: [TrainingEvent], summary: String, suggestions: [String],
    utterances: [String] = [], questions: [TrainingQuestion] = [],
    phaseCount: Int = 0, phaseLabel: String = "", sessionTitle: String = "训练记录",
    isCompleteChain: Bool = false, warmup: String = "本次未记录热身",
    bench: String = "尚未记录卧推工作组", fly: String = "尚未记录飞鸟工作组",
    stretch: String = "本次未记录训练后放松", observation: String = "",
    nextSession: String = "", estimatedCalories: Int? = nil, isSimulated: Bool = true,
    calorieEstimateSource: String? = nil, inputHistory: [TrainingInputEntry]? = nil
  ) {
    self.id = id
    self.date = date
    self.durationSeconds = max(0, durationSeconds)
    self.events = events
    self.summary = summary
    self.suggestions = suggestions
    self.utterances = utterances
    self.questions = questions
    self.phaseCount = phaseCount
    self.phaseLabel = phaseLabel
    self.sessionTitle = sessionTitle
    self.isCompleteChain = isCompleteChain
    self.warmup = warmup
    self.bench = bench
    self.fly = fly
    self.stretch = stretch
    self.observation = observation
    self.nextSession = nextSession
    self.estimatedCalories = max(0, estimatedCalories ?? (isSimulated ? events.reduce(0) { $0 + $1.estimatedCalories } : 0))
    self.isSimulated = isSimulated
    self.calorieEstimateSource = estimatedCalories != nil ? calorieEstimateSource : nil
    self.inputHistory = inputHistory
  }

  var isTextRecordSummary: Bool { !isSimulated && events.contains { $0.sourceInputIDs != nil } }
  var hasPendingInputs: Bool { inputHistory?.contains { $0.state == .needsAttention } ?? false }
  var title: String { sessionTitle }
  var durationMinutes: Int { durationSeconds / 60 }
  var totalRepetitions: Int { events.reduce(0) { $0 + ($1.hasRecordedRepetitions ? $1.repetitions : 0) } }
  var recordedActivities: [RecordedActivity] { RecordedActivity.build(from: events) }
  var displayCalories: Int? {
    if isSimulated { return estimatedCalories }
    guard estimatedCalories >= 0, let source = calorieEstimateSource,
      !source.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
    return estimatedCalories
  }
  var workSets: [TrainingEvent] { events.filter { $0.type == .set } }
  var category: String {
    if !workSets.isEmpty { return "力量训练" }
    return events.contains { $0.type == .warmup } ? "热身" : "训练"
  }
  var muscleGroups: [String] { Array(Set(events.flatMap(\.muscleGroups))).sorted() }
}

struct UserPreferences: Equatable, Codable, Sendable {
  var displayName: String = "Fitcore 体验者"
  var goalCalories: Int = 500
  var goalMinutes: Int = 45
  var gender: String = "male"
  var selectedMuscles: [String] = []
}

/// A future Soundcore adapter emits decrypted Opus packets, not PCM or WAV.
/// The Mock shell does not synthesize or transmit audio bytes.
struct AudioPacket: Sendable {
  let fileID: Int
  let sequenceNumber: Int
  let payload: Data
  let isMarked: Bool
  let isAppendPreAudio: Bool
}
