import Foundation

/// Only known error codes reach the UI; supplier response bodies and credentials
/// are never displayed. A retry is always explicit and reuses the input ID.
enum BackendTrainingError: String, Error, LocalizedError, Equatable, Sendable {
  case notConfigured = "llm_not_configured"
  case auth = "llm_auth"
  case rateLimit = "llm_rate_limit"
  case timeout = "llm_timeout"
  case unavailable = "llm_unavailable"
  case invalidOutput = "llm_invalid_output"
  case contextLimit = "llm_context_limit"
  case sessionConflict = "session_conflict"
  case inputConflict = "input_conflict"
  case backendAuth
  case connectionMissing
  case network

  var errorDescription: String? {
    switch self {
    case .notConfigured: return "后端尚未配置模型。请在后端本机配置模型 Key，然后重试；原话已保留。"
    case .auth: return "模型鉴权失败，请检查后端的模型 Key；原话已保留。"
    case .rateLimit: return "模型限流或额度不足，请核对供应商后台后重试；原话已保留。"
    case .timeout: return "模型响应超时，请重试；相同原话不会重复新增训练组。"
    case .unavailable: return "模型服务暂时不可用，请稍后重试；原话已保留。"
    case .invalidOutput: return "模型返回了无法核验的结果，本段未更新记录。请重试。"
    case .contextLimit: return "本次文字上下文已达上限。请结束训练并保存已确认记录；这段未处理原话会一同保留，之后可开始新训练。"
    case .sessionConflict: return "服务端训练状态已变化，本段未覆盖记录。请核对当前会话后重试。"
    case .inputConflict: return "这条原话的标识与服务端内容不一致，已停止写入，请检查会话。"
    case .backendAuth: return "Fitcore 访问令牌无效，请在开发设置中重新连接后端。"
    case .connectionMissing: return "请先在开发设置中连接 Fitcore 后端，填写后端地址和演示访问令牌。"
    case .network: return "无法连接 Fitcore 后端，请检查网络后重试；原话已保留。"
    }
  }
}

struct BackendTrainingAnalysisService: TrainingAnalysisService {
  typealias Transport = @Sendable (URLRequest) async throws -> (Data, HTTPURLResponse)
  let client: CloudHistoryClient?
  let transport: Transport
  var usesBackendText: Bool { true }

  init(client: CloudHistoryClient?, transport: @escaping Transport = { request in
    let (data, response) = try await URLSession.shared.data(for: request)
    guard let http = response as? HTTPURLResponse else { throw BackendTrainingError.invalidOutput }
    return (data, http)
  }) {
    self.client = client
    self.transport = transport
  }

  struct Request: Codable, Sendable {
    let input_id: UUID
    let text: String
    let source: String
    let expected_revision: Int
    let clarifies_input_id: UUID?
  }
  struct Response: Decodable, Sendable {
    struct Event: Decodable, Sendable {
      let id: UUID
      let revision: Int
      let exercise: String
      let weight_kg: Double?
      let repetitions: Int?
      let feeling: String
      let source_text: String
      let source_input_ids: [UUID]
      let set_number: Int
    }
    struct Input: Decodable, Sendable { let id: UUID; let text: String; let source: String }
    let session_id: UUID
    let input_id: UUID
    let revision: Int
    let status: String
    let message: String
    let events: [Event]
    let inputs: [Input]
  }
  private struct ErrorResponse: Decodable {
    struct Detail: Decodable { let code: String }
    let detail: Detail
  }

  /// The ID-less legacy call is intentionally unavailable for network requests.
  func analyzeUtterance(_ utterance: String, context: TrainingContext, sessionID: UUID)
    async throws -> TrainingAnalysisUpdate {
    throw BackendTrainingError.inputConflict
  }

  func analyzeInput(_ input: PendingTrainingInput, context: TrainingContext, sessionID: UUID)
    async throws -> TrainingAnalysisUpdate {
    guard let client else { throw BackendTrainingError.connectionMissing }
    guard input.source == .text else { throw TrainingAnalysisError.unsupportedInput }
    var request = URLRequest(url: client.baseURL.appendingPathComponent(
      "v1/training/sessions/\(sessionID.uuidString.lowercased())/inputs"))
    request.httpMethod = "POST"
    // The backend owns the model timeout (at most 65 seconds). Do not trigger
    // an unnecessary user retry while that original request is still running.
    request.timeoutInterval = 75
    request.setValue("Bearer \(client.accessToken)", forHTTPHeaderField: "Authorization")
    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
    request.setValue("application/json", forHTTPHeaderField: "Accept")
    request.httpBody = try JSONEncoder().encode(Request(input_id: input.id, text: input.text,
      source: "text", expected_revision: context.analysisRevision, clarifies_input_id: input.clarifiesInputID))
    let data: Data
    let response: HTTPURLResponse
    do { (data, response) = try await transport(request) }
    catch is CancellationError { throw CancellationError() }
    catch let error as URLError {
      if error.code == .cancelled { throw CancellationError() }
      throw error.code == .timedOut ? BackendTrainingError.timeout : BackendTrainingError.network
    } catch let error as BackendTrainingError { throw error }
    catch { throw BackendTrainingError.network }
    guard (200..<300).contains(response.statusCode) else {
      if response.statusCode == 401 || response.statusCode == 403 { throw BackendTrainingError.backendAuth }
      let code = (try? JSONDecoder().decode(ErrorResponse.self, from: data))?.detail.code
      throw code.flatMap(BackendTrainingError.init(rawValue:)) ?? .unavailable
    }
    let result: Response
    do { result = try JSONDecoder().decode(Response.self, from: data) }
    catch { throw BackendTrainingError.invalidOutput }
    let inputIDs = Set(result.inputs.map(\.id))
    guard result.session_id == sessionID, result.input_id == input.id,
      result.revision >= context.analysisRevision,
      ["recorded", "needs_clarification"].contains(result.status),
      inputIDs.count == result.inputs.count,
      result.inputs.contains(where: { $0.id == input.id && $0.text == input.text && $0.source == "text" }),
      result.inputs.allSatisfy({ $0.source == "text" }),
      Set(result.events.map(\.id)).count == result.events.count,
      result.events.allSatisfy({ event in
        event.revision > 0 && event.set_number > 0 && !event.exercise.isEmpty
          && !event.source_text.isEmpty && !event.source_input_ids.isEmpty
          && Set(event.source_input_ids).isSubset(of: inputIDs)
          && (event.weight_kg.map { $0.isFinite && $0 >= 0 } ?? true)
          && (event.repetitions.map { $0 >= 0 } ?? true)
      }) else { throw BackendTrainingError.invalidOutput }
    let events = result.events.map { event in
      TrainingEvent(id: event.id, exercise: event.exercise, weightKilograms: event.weight_kg ?? 0,
        repetitions: event.repetitions ?? 0, feeling: event.feeling, sourceText: event.source_text,
        setNumber: event.set_number, weightIsConfirmed: event.weight_kg != nil,
        repetitionsAreConfirmed: event.repetitions != nil, sourceInputIDs: event.source_input_ids,
        revision: event.revision)
    }
    var next = TrainingContext(events: events, utterances: result.inputs.map(\.text),
      questions: context.questions, elapsedMinutes: context.elapsedMinutes)
    next.analysisRevision = result.revision
    return TrainingAnalysisUpdate(context: next, status: result.status, coachReply: result.message,
      question: nil, requestsSessionEnd: false, isSimulated: false,
      requiresClarification: result.status == "needs_clarification")
  }

  /// A factual local record summary. Coaching, energy estimates and unsupported
  /// exercise details are deliberately absent; no second paid request is made.
  func makeReview(context: TrainingContext, durationSeconds: Int, sessionID: UUID, date: Date)
    async throws -> TrainingReview {
    let sets = context.events.filter { $0.type == .set }
    let exercises = sets.reduce(into: [String]()) { names, event in
      if !names.contains(event.exercise) { names.append(event.exercise) }
    }
    let summary = sets.isEmpty ? "本次没有已确认的训练动作。"
      : sets.map { "\($0.exercise)第 \($0.setNumber ?? 1) 组：\($0.setDescription)" }.joined(separator: "；") + "。"
    return TrainingReview(id: sessionID, date: date, durationSeconds: durationSeconds,
      events: context.events, summary: summary, suggestions: [], utterances: context.utterances,
      questions: context.questions, phaseCount: sets.isEmpty ? 0 : 1,
      phaseLabel: sets.isEmpty ? "" : "已记录动作", sessionTitle: exercises.isEmpty ? "训练记录" : exercises.joined(separator: " · "),
      bench: "", fly: "", observation: "依据实际文字记录整理，未生成训练建议或消耗估计。",
      nextSession: "", isSimulated: false)
  }
}

/// A real implementation must obtain this output from its ASR/context/LLM pipeline.
/// The presentation layer never treats fixture text as a hardware audio transcript.
protocol TrainingAnalysisService: Sendable {
  var usesBackendText: Bool { get }
  func analyzeInput(_ input: PendingTrainingInput, context: TrainingContext, sessionID: UUID)
    async throws -> TrainingAnalysisUpdate
  func analyzeUtterance(_ utterance: String, context: TrainingContext, sessionID: UUID) async throws
    -> TrainingAnalysisUpdate
  func makeReview(context: TrainingContext, durationSeconds: Int, sessionID: UUID, date: Date)
    async throws -> TrainingReview
}

extension TrainingAnalysisService {
  var usesBackendText: Bool { false }

  func analyzeInput(_ input: PendingTrainingInput, context: TrainingContext, sessionID: UUID)
    async throws -> TrainingAnalysisUpdate {
    try await analyzeUtterance(input.analysisText ?? input.text, context: context, sessionID: sessionID)
  }

  /// Convenience for isolated analysis tests. The app always supplies its active ID.
  func analyzeUtterance(_ utterance: String, context: TrainingContext) async throws
    -> TrainingAnalysisUpdate
  {
    try await analyzeUtterance(utterance, context: context, sessionID: UUID())
  }

  /// Retains the original event-only entry point for callers without conversation context.
  func makeReview(events: [TrainingEvent], durationSeconds: Int) async throws -> TrainingReview {
    try await makeReview(
      context: TrainingContext(events: events), durationSeconds: durationSeconds,
      sessionID: UUID(), date: Date())
  }
}

enum TrainingAnalysisError: LocalizedError {
  case unsupportedInput
  case needsClarification
  case serviceUnavailable

  var errorDescription: String? {
    switch self {
    case .unsupportedInput: return "当前为预设文本演示；真实音频转写和大模型分析尚未接入。"
    case .needsClarification: return "这句话需要补充动作、重量或次数。"
    case .serviceUnavailable: return "分析服务暂时不可用，请重试。"
    }
  }
}

struct MockTrainingAnalysisService: TrainingAnalysisService {
  let latency: Duration
  let reviewLatency: Duration

  init(latency: Duration = .milliseconds(850), reviewLatency: Duration = .milliseconds(450)) {
    self.latency = latency
    self.reviewLatency = reviewLatency
  }

  func analyzeUtterance(_ utterance: String, context: TrainingContext, sessionID: UUID) async throws
    -> TrainingAnalysisUpdate
  {
    try await Task.sleep(for: latency)
    guard context.utterances.count < DemoFixtures.steps.count else {
      throw TrainingAnalysisError.unsupportedInput
    }
    let step = DemoFixtures.steps[context.utterances.count]
    guard utterance == step.utterance else { throw TrainingAnalysisError.unsupportedInput }
    let next = context.applying(step)
    var reply = step.interpretation
    // A manually corrected preceding set must also update inherited-weight copy.
    if step.eventKind == .set, step.weightKilograms == nil, let latest = next.events.last,
      latest.weightKilograms != (latest.exercise == "杠铃卧推" ? 60 : 5)
    {
      reply = "结合已更正的上下文，记录\(latest.exercise)第 \(latest.setNumber ?? 1) 组：\(latest.setDescription)。"
    }
    return TrainingAnalysisUpdate(
      context: next, status: step.status, coachReply: reply,
      question: step.question, requestsSessionEnd: step.endSession, isSimulated: true,
      endIntent: DemoTrainingEndIntentPolicy.classify(utterance))
  }

  func makeReview(context: TrainingContext, durationSeconds: Int, sessionID: UUID, date: Date)
    async throws -> TrainingReview
  {
    try await Task.sleep(for: reviewLatency)
    let events = context.events
    let warmup = events.first { $0.type == .warmup }
    let stretch = events.first { $0.type == .stretch }
    let bench = events.filter { $0.type == .set && $0.exercise == "杠铃卧推" }
    let fly = events.filter { $0.type == .set && $0.exercise == "哑铃飞鸟" }
    let hasSets = events.contains { $0.type == .set }
    let labels = [
      warmup == nil ? nil : "热身", hasSets ? "工作组" : nil,
      stretch == nil ? nil : "拉伸恢复",
    ].compactMap { $0 }
    var observations: [String] = []
    if bench.count >= 2 {
      let stable = Set(bench.map(\.weightKilograms)).count == 1
      observations.append(stable ? "卧推工作重量稳定，后组次数自然回落。" : "卧推工作重量有所调整，请结合体感核对各组记录。")
    }
    if fly.count >= 3, let first = fly.first, let last = fly.last,
      last.repetitions < first.repetitions
    {
      observations.append("飞鸟次数逐组下降，后程疲劳正在累积。")
    }
    if warmup != nil && stretch != nil { observations.append("热身与训练后放松均有记录，训练链路完整。") }
    if observations.isEmpty { observations.append("当前记录较短，完成更多训练后可获得趋势建议。") }
    let nextSession =
      bench.last.map {
        "卧推保持 \($0.weightText)kg，以肩胛稳定和动作质量为先；飞鸟先稳定各组次数，不急于加重。"
      } ?? "下次训练先从稳定动作和完整记录开始。"
    return TrainingReview(
      id: sessionID, date: date,
      durationSeconds: max(durationSeconds, context.elapsedMinutes * 60),
      events: events, summary: observations.joined(separator: " "),
      suggestions: [nextSession, "这是基于预设文本的示例复盘，不代表真实 AI 分析或运动评估。"],
      utterances: context.utterances, questions: context.questions,
      phaseCount: labels.count, phaseLabel: labels.joined(separator: " · "),
      sessionTitle: hasSets ? "胸部力量训练" : (warmup == nil ? "训练记录" : "热身记录"),
      isCompleteChain: warmup != nil && hasSets && stretch != nil,
      warmup: warmup.map { "\($0.exercise) · \($0.detail)" } ?? "本次未记录热身",
      bench: bench.isEmpty ? "尚未记录卧推工作组" : bench.map(\.setDescription).joined(separator: " / "),
      fly: fly.isEmpty ? "尚未记录飞鸟工作组" : fly.map(\.setDescription).joined(separator: " / "),
      stretch: stretch.map { "\($0.exercise) · \($0.detail)" } ?? "本次未记录训练后放松",
      observation: observations.joined(separator: " "), nextSession: nextSession, isSimulated: true)
  }
}
