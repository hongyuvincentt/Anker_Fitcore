import Foundation

@main
struct DynamicRecordsCheck {
  static func main() throws {
    let unknown = TrainingEvent(exercise: "一个没有确认名称的动作", sourceText: "做了一个新动作")
    precondition(unknown.setDescription == "重量待补充 × 次数待补充")
    precondition(unknown.muscleGroups.isEmpty)
    let unnamedWarmup = TrainingEvent(exercise: "热身", sourceText: "先热身", type: .warmup)
    precondition(unnamedWarmup.muscleGroups.isEmpty, "A phase alone cannot establish trained muscles")

    let bodyweight = TrainingEvent(
      exercise: "自重深蹲", repetitions: 12, sourceText: "自重深蹲，没有额外负重，十二次",
      weightIsConfirmed: true, repetitionsAreConfirmed: true)
    precondition(bodyweight.setDescription == "0kg × 12次")
    precondition(bodyweight.muscleGroups == ["legs", "core"])
    let uncertain = TrainingEvent(
      exercise: "深蹲", weightKilograms: 100, repetitions: 10,
      sourceText: "深蹲，重量没记住", weightIsConfirmed: false, repetitionsAreConfirmed: false)
    precondition(uncertain.setDescription == "重量待补充 × 次数待补充")
    let noSource = TrainingEvent(exercise: "硬拉", weightKilograms: 100, repetitions: 8,
      sourceText: "", weightIsConfirmed: true, repetitionsAreConfirmed: true)
    precondition(!noSource.hasRecordedWeight && !noSource.hasRecordedRepetitions)
    let invalid = TrainingEvent(exercise: "硬拉", weightKilograms: -1, repetitions: -3, sourceText: "原话")
    precondition(invalid.setDescription == "重量待补充 × 次数待补充")

    let first = TrainingEvent(exercise: "杠铃平板卧推", weightKilograms: 40, repetitions: 8, sourceText: "  杠铃平板卧推，40公斤，8次。\n")
    let second = TrainingEvent(exercise: "杠铃卧推", weightKilograms: 40, repetitions: 7, sourceText: "第二组还是这个重量，七次")
    let groups = RecordedActivity.build(from: [bodyweight, first, second, unknown])
    precondition(groups.map(\.name) == ["徒手深蹲", "杠铃卧推", "一个没有确认名称的动作"])
    precondition(groups[1].events.count == 2)
    precondition(groups[1].events[0].sourceText == first.sourceText, "Normalization must preserve the original utterance verbatim")
    precondition(groups[2].muscleDescription == "肌群待确认")
    precondition(RecordedExerciseCatalog.normalizedName("卧推") == "卧推", "Do not invent equipment")
    precondition(RecordedActivity.build(from: [bodyweight]).count == 1, "Do not add fixed demo exercises")

    let resumedBench = TrainingEvent(exercise: "杠铃卧推", weightKilograms: 35, repetitions: 10,
      sourceText: "回到卧推，35公斤十次")
    let timeline = RecordedActivity.build(from: [first, second, bodyweight, resumedBench])
    precondition(timeline.map(\.name) == ["杠铃卧推", "徒手深蹲", "杠铃卧推"],
      "Returning to an exercise must remain at its later position in the timeline")
    precondition(timeline.map { $0.events.count } == [2, 1, 1])
    precondition(Set(timeline.map(\.id)).count == 3, "Separate timeline entries need distinct selection IDs")
    precondition(timeline[0].muscles == ["chest", "shoulders", "arms"])
    precondition(timeline[1].muscles == ["legs", "core"], "Selecting another entry must use its own muscle mapping")
    precondition(groups[1].summary == "40 kg · 2 组")
    precondition(RecordedActivity.build(from: [uncertain])[0].summary == "1 组 · 重量待补充")
    precondition(RecordedActivity.build(from: [first, resumedBench])[0].summary == "2 组 · 多档重量")

    let real = TrainingReview(durationSeconds: 30, events: [bodyweight], summary: "", suggestions: [], isSimulated: false)
    precondition(real.displayCalories == nil && real.estimatedCalories == 0)
    let unsourced = TrainingReview(durationSeconds: 30, events: [], summary: "", suggestions: [], estimatedCalories: 288, isSimulated: false)
    precondition(unsourced.displayCalories == nil, "A number without provenance is not a reliable real estimate")
    let sourced = TrainingReview(durationSeconds: 30, events: [], summary: "", suggestions: [], estimatedCalories: 80, isSimulated: false, calorieEstimateSource: "已核对的外部估算")
    precondition(sourced.displayCalories == 80)
    let missingEstimate = TrainingReview(durationSeconds: 30, events: [], summary: "", suggestions: [], isSimulated: false, calorieEstimateSource: "缺少数值")
    precondition(missingEstimate.displayCalories == nil)
    let mock = TrainingReview(durationSeconds: 30, events: [first], summary: "", suggestions: [])
    precondition(mock.displayCalories == first.estimatedCalories, "Keep explicit demo behavior")

    // Round-trip the legacy JSON shape without any newly introduced keys.
    let encoded = try JSONEncoder().encode(mock)
    var json = try JSONSerialization.jsonObject(with: encoded) as! [String: Any]
    json.removeValue(forKey: "calorieEstimateSource")
    json.removeValue(forKey: "inputHistory")
    var events = json["events"] as! [[String: Any]]
    for index in events.indices {
      events[index].removeValue(forKey: "weightIsConfirmed")
      events[index].removeValue(forKey: "repetitionsAreConfirmed")
    }
    json["events"] = events
    let legacy = try JSONDecoder().decode(TrainingReview.self, from: JSONSerialization.data(withJSONObject: json))
    precondition(legacy.events.first?.setDescription == "40kg × 8次")
    precondition(legacy.displayCalories == mock.displayCalories)
    precondition(legacy.inputHistory == nil)
    var audited = real
    audited.inputHistory = [
      TrainingInputEntry(id: UUID(), text: "我做了深蹲", source: .speech, state: .supplemented),
      TrainingInputEntry(id: UUID(), text: "60公斤10次", source: .text, state: .understood),
    ]
    let auditRoundTrip = try JSONDecoder().decode(TrainingReview.self, from: JSONEncoder().encode(audited))
    precondition(auditRoundTrip.inputHistory == audited.inputHistory,
      "Save original and supplemental inputs independently, including state and source")
    print("Dynamic record checks passed: source preservation, grouping, missing values, safe muscle mapping, calories, and legacy JSON.")
  }
}
