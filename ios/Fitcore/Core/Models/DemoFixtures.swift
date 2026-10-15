import Foundation

/// These are the eleven prerecorded text steps from mobile_final.html.
/// No microphone, Soundcore hardware, speech recognizer, or LLM produces this data.
enum DemoFixtures {
  static let steps: [TrainingConversationStep] = [
    .init(
      utterance: "跑步机爬坡速度6，坡度4，15分钟。", status: "训练语音记录中",
      interpretation: "识别为训练前热身，保留用户口述的速度与坡度数值。",
      eventKind: .warmup, phase: "warmup", label: "跑步机爬坡",
      detail: "速度 6 · 坡度 4 · 15 分钟", durationMinutes: 15, endMinute: 15),
    .init(
      utterance: "接下来做那个杠铃放在胸上，躺下来往上推。", status: "正在识别动作",
      interpretation: "动作识别：杠铃卧推", phase: "training", exercise: "杠铃卧推", endMinute: 15),
    .init(
      utterance: "第一组60公斤，10个。", status: "正在补全训练事件",
      interpretation: "结合当前动作，记录杠铃卧推第 1 组。",
      eventKind: .set, weightKilograms: 60, repetitions: 10, endMinute: 18),
    .init(
      utterance: "9个，还剩两个。", status: "正在结合上一组判断",
      interpretation: "继承杠铃卧推和 60kg，自动递增为第 2 组，并提取 RIR2。",
      eventKind: .set, repetitions: 9, rir: 2, endMinute: 21),
    .init(
      utterance: "这组卧推60公斤做了8个，为什么我右肩总是往前跑？", status: "正在记录并理解问题",
      interpretation: "记录杠铃卧推第 3 组，同时识别到一个训练知识问题。",
      eventKind: .set, weightKilograms: 60, repetitions: 8,
      question: .init(
        text: "为什么我右肩总是往前跑？",
        answer: "先降低重量，保持肩胛后缩下沉，肘部不要过度外展。如果出现明确疼痛，应停止动作并寻求专业评估。",
        originalText: "这组卧推60公斤做了8个，为什么我右肩总是往前跑？"), endMinute: 24),
    .init(
      utterance: "换飞鸟，5公斤，第一组12个。", status: "正在切换训练动作",
      interpretation: "动作切换为哑铃飞鸟，重量 5kg，从第 1 组开始记录。",
      eventKind: .set, exercise: "哑铃飞鸟", weightKilograms: 5, repetitions: 12, endMinute: 27),
    .init(
      utterance: "还是这个重量，11个。", status: "正在结合上一组判断",
      interpretation: "继承哑铃飞鸟和 5kg，记录第 2 组。",
      eventKind: .set, repetitions: 11, endMinute: 30),
    .init(
      utterance: "第三组10个。", status: "正在补全重量信息",
      interpretation: "继承 5kg，记录哑铃飞鸟第 3 组。",
      eventKind: .set, setNumber: 3, repetitions: 10, endMinute: 33),
    .init(
      utterance: "8个。", status: "正在结合当前训练理解",
      interpretation: "继承哑铃飞鸟和 5kg，自动递增为第 4 组。次数连续下降，后程疲劳正在累积。",
      eventKind: .set, repetitions: 8, endMinute: 36),
    .init(
      utterance: "最后拉伸了十分钟，主要是胸和肩。", status: "正在整理训练后放松",
      interpretation: "识别为训练后放松：胸部、肩部拉伸 10 分钟。",
      eventKind: .stretch, phase: "stretch", label: "胸肩拉伸", detail: "10 分钟",
      durationMinutes: 10, endMinute: 46),
    .init(
      utterance: "今天就到此为止吧，练不动了。", status: "已识别训练结束",
      interpretation: "用户提到训练结束，正在梳理，即将跳转 AI 分析页面。",
      endSession: true, endMinute: 46),
  ]

  static var events: [TrainingEvent] {
    steps.reduce(TrainingContext()) { $0.applying($1) }.events
  }
}
