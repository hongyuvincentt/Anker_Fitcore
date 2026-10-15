import Foundation

enum TrainingEndIntent: Equatable, Sendable {
  case continueTraining
  case rest
  case navigateAway
  case complete
}

/// This small text policy belongs only to the offline demo. Real adapters provide
/// a confirmed typed intent on a final transcript; no local vocabulary restricts it.
enum DemoTrainingEndIntentPolicy {
  static func classify(_ utterance: String) -> TrainingEndIntent {
    let ignored = CharacterSet.whitespacesAndNewlines.union(CharacterSet(charactersIn: "，。！,!"))
    let text = utterance.components(separatedBy: ignored).joined()
    let completed = ["今天就到此为止吧练不动了", "结束今天的训练", "结束本次训练", "结束训练", "今天练完了"]
    if completed.contains(text) {
      return .complete
    }
    if ["返回首页", "回到首页", "退出页面", "离开页面", "切换页面", "看看历史", "去看历史", "返回训练页", "先退出", "关掉页面"].contains(
      where: { text.contains($0) })
    {
      return .navigateAway
    }
    if ["休息", "歇一会", "暂停", "喝口水", "稍等", "先等等"].contains(where: { text.contains($0) }) {
      return .rest
    }
    return .continueTraining
  }

  static func shouldFinish(utterance: String, analysisIntent: TrainingEndIntent) -> Bool {
    analysisIntent == .complete && classify(utterance) == .complete
  }
}
