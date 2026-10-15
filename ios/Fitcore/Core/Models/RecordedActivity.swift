import Foundation

/// Presentation groups are built exclusively from recorded events. Normalization
/// only applies known synonyms; it never adds equipment, a set, or a measurement.
struct RecordedActivity: Identifiable, Equatable, Sendable {
  let id: String
  let name: String
  let events: [TrainingEvent]

  var muscles: [String] { RecordedExerciseCatalog.muscles(for: name) }
  var symbol: String {
    switch events.first?.type {
    case .warmup: return "figure.walk"
    case .stretch: return "figure.flexibility"
    default: return "dumbbell.fill"
    }
  }
  var detail: String {
    events.map { event in
      if event.type == .set { return event.setDescription }
      if let duration = event.durationMinutes, duration.isFinite, duration > 0,
        event.hasSourceEvidence {
        return "\(duration.formatted(.number.precision(.fractionLength(0...1)))) 分钟"
      }
      return "时长待补充"
    }.joined(separator: " / ")
  }
  var muscleDescription: String {
    muscles.isEmpty ? "肌群待确认" : muscles.compactMap { RecordedExerciseCatalog.muscleLabels[$0] }.joined(separator: " · ")
  }
  var summary: String {
    guard let first = events.first else { return "等待记录" }
    guard first.type == .set else {
      return "\(first.type == .warmup ? "热身" : "恢复") · \(detail)"
    }
    guard events.allSatisfy(\.hasRecordedWeight) else { return "\(events.count) 组 · 重量待补充" }
    if Set(events.map(\.weightKilograms)).count == 1 {
      return "\(first.weightText) kg · \(events.count) 组"
    }
    return "\(events.count) 组 · 多档重量"
  }

  static func build(from events: [TrainingEvent]) -> [Self] {
    var groups: [[TrainingEvent]] = []
    for event in events {
      let name = RecordedExerciseCatalog.normalizedName(event.exercise)
      if let previous = groups.last?.last, previous.type == event.type,
        RecordedExerciseCatalog.normalizedName(previous.exercise) == name {
        groups[groups.count - 1].append(event)
      } else {
        groups.append([event])
      }
    }
    return groups.compactMap { records in
      guard let first = records.first else { return nil }
      return Self(id: first.id.uuidString,
        name: RecordedExerciseCatalog.normalizedName(first.exercise), events: records)
    }
  }
}

enum RecordedExerciseCatalog {
  static let muscleLabels = ["chest": "胸部", "shoulders": "肩部", "arms": "手臂", "back": "背部", "core": "核心", "legs": "腿部"]
  private static let aliases = [
    "杠铃平板卧推": "杠铃卧推", "平板杠铃卧推": "杠铃卧推",
    "哑铃平板卧推": "哑铃卧推", "平板哑铃卧推": "哑铃卧推",
    "自重深蹲": "徒手深蹲", "引体": "引体向上", "卷腹训练": "卷腹",
    "俯卧撑训练": "俯卧撑",
  ]
  private static let mapping: [String: [String]] = [
    "卧推": ["chest", "shoulders", "arms"],
    "杠铃卧推": ["chest", "shoulders", "arms"],
    "哑铃卧推": ["chest", "shoulders", "arms"],
    "上斜哑铃卧推": ["chest", "shoulders", "arms"],
    "俯卧撑": ["chest", "shoulders", "arms"],
    "哑铃飞鸟": ["chest", "shoulders"], "绳索夹胸": ["chest"],
    "深蹲": ["legs", "core"], "杠铃深蹲": ["legs", "core"],
    "徒手深蹲": ["legs", "core"], "高脚杯深蹲": ["legs", "core"],
    "硬拉": ["legs", "back", "core"], "杠铃硬拉": ["legs", "back", "core"],
    "罗马尼亚硬拉": ["legs", "back", "core"], "腿举": ["legs"],
    "哑铃划船": ["back", "arms"], "杠铃划船": ["back", "arms"],
    "坐姿划船": ["back", "arms"], "引体向上": ["back", "arms"],
    "高位下拉": ["back", "arms"], "哑铃推举": ["shoulders", "arms"],
    "杠铃推举": ["shoulders", "arms"], "哑铃侧平举": ["shoulders"],
    "哑铃弯举": ["arms"], "杠铃弯举": ["arms"], "绳索下压": ["arms"],
    "平板支撑": ["core"], "卷腹": ["core"],
    "跑步": ["legs"], "跑步机爬坡": ["legs"], "骑行": ["legs"],
    "胸肩拉伸": ["chest", "shoulders"],
  ]

  static func normalizedName(_ raw: String) -> String {
    let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return "动作待确认" }
    return aliases[trimmed] ?? trimmed
  }

  static func muscles(for exercise: String) -> [String] {
    mapping[normalizedName(exercise)] ?? []
  }
}
