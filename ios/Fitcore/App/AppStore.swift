import Combine
import Foundation

/// The application state machine. Mock fixtures are deliberately kept behind the
/// RecorderGateway and TrainingAnalysisService protocols; this class never labels
/// a fixture as an audio packet or a real AI result.
@MainActor
final class AppStore: ObservableObject {
  enum Tab: Hashable {
    case today, history, insights, profile
    static var training: Self { .today }
    static var review: Self { .insights }
  }

  @Published var selectedTab: Tab = .today
  @Published private(set) var phase: TrainingPhase = .disconnected
  @Published private(set) var device: RecorderDevice?
  @Published private(set) var elapsedSeconds = 0
  @Published private(set) var events: [TrainingEvent] = []
  @Published private(set) var review: TrainingReview?
  @Published private(set) var errorMessage: String?
  @Published private(set) var activeSessionID: UUID?
  @Published private(set) var sessionConnectionState: TrainingSessionConnectionState = .idle
  /// A finish request is not a hardware stop acknowledgement. A real adapter/UI
  /// must obtain recordingStopped and transferDrained before closing the session.
  @Published private(set) var finishRequested = false
  @Published var isConversationPresented = false
  @Published var showDeviceSheet = false
  @Published var autoAdvance = true {
    didSet {
      autoAdvanceTask?.cancel()
      if autoAdvance, phase == .recording, !isProcessing { scheduleAutoAdvance() }
    }
  }
  @Published private(set) var history: [TrainingReview]
  @Published var preferences: UserPreferences { didSet { persist() } }

  let environment: AppEnvironment?
  let configurationError: String?
  /// LHY-04: the cloud WAV training chain view-model. App-scoped so leaving and
  /// returning to the training page never regenerates session or upload
  /// identities. This round it always runs on the offline Mock transport.
  let cloudTraining = CloudTrainingModel.mock()
  private let recorder: any RecorderGateway
  private let mockControls: (any MockRecorderControlling)?
  private var analysis: any TrainingAnalysisService
  private let sessionConnection: any TrainingSessionConnection
  private let persistence: any TrainingPersistence
  private var connectTask: Task<Void, Never>?
  private var conversationAfterDeviceSheet = false
  private var clockTask: Task<Void, Never>?
  private var reviewTask: Task<Void, Never>?
  private var conversationTask: Task<Void, Never>?
  private var autoAdvanceTask: Task<Void, Never>?
  private var sessionBeginTask: Task<Void, Never>?
  private let automaticStepDelay: Duration
  private let questionStepDelay: Duration
  private let firstStepDelay: Duration
  private var sessionRevision = 0
  private var sessionID = UUID()
  private var sessionStartedAt = Date()
  private var context = TrainingContext()
  private var currentStepIndex = 0
  private var hasDrained = false
  private var isApplyingPersistedState = false
  private(set) var receivedAudioPackets = 0

  @Published private(set) var currentUtterance = ""
  @Published private(set) var currentCoachReply = ""
  @Published private(set) var currentQuestion = ""
  @Published private(set) var currentAnswer = ""
  @Published private(set) var conversationStatus = ""
  @Published private(set) var recordUpdateFeedback: TrainingRecordUpdateFeedback?
  @Published private(set) var isProcessing = false
  @Published private(set) var analysisIssue: TrainingInteractionIssue?
  @Published private(set) var pendingInput: PendingTrainingInput?
  @Published private(set) var inputHistory: [TrainingInputEntry] = []
  @Published var previewNextAnalysisFailure = false
  @Published private(set) var cloudSyncStatus = "尚未连接云端"
  @Published private(set) var cloudSyncBusy = false
  @Published private(set) var cloudBaseURL = ""
  @Published private(set) var cloudUserID: String?
  @Published private(set) var cloudLiveStatus = "尚未连接状态同步"
  private var cloudClient: CloudHistoryClient?
  private var cloudResyncNeeded = false
  private let allowsCloudSettings: Bool
  private let livePublisherID = UUID()
  private var livePublisher: CloudLivePublisher?
  private var liveHeartbeatTask: Task<Void, Never>?
  private var livePublishedSessionID: UUID?
  private var liveOpeningSnapshot: CloudLiveSnapshot?
  private var liveTerminalSessionID: UUID?
  private var liveSequence = 0
  private let liveHeartbeatDelay: Duration

  init(
    info: [String: Any] = Bundle.main.infoDictionary ?? [:],
    persistence: (any TrainingPersistence)? = nil,
    recorder: (any RecorderGateway)? = nil,
    analysis: (any TrainingAnalysisService)? = nil,
    sessionConnection: (any TrainingSessionConnection)? = nil,
    livePublisher: CloudLivePublisher? = nil, liveHeartbeatDelay: Duration = .seconds(5),
    automaticStepDelay: Duration = .seconds(5), questionStepDelay: Duration = .seconds(10),
    firstStepDelay: Duration = .milliseconds(1200)
  ) {
    do {
      environment = try AppEnvironment.load(info: info)
      configurationError = nil
    } catch {
      environment = nil
      configurationError = error.localizedDescription
    }
    let mock = (recorder as? MockRecorderGateway) ?? MockRecorderGateway()
    self.recorder = recorder ?? mock
    self.mockControls = self.recorder as? any MockRecorderControlling
    self.analysis = analysis ?? (environment?.analysisMode == .backend
      ? BackendTrainingAnalysisService(client: nil) : MockTrainingAnalysisService())
    self.sessionConnection = sessionConnection ?? MockTrainingSessionConnection()
    self.automaticStepDelay = automaticStepDelay
    self.questionStepDelay = questionStepDelay
    self.firstStepDelay = firstStepDelay
    self.livePublisher = livePublisher
    self.liveHeartbeatDelay = liveHeartbeatDelay
    let localPersistence = persistence ?? UserDefaultsTrainingPersistence()
    self.persistence = localPersistence
    self.allowsCloudSettings = persistence == nil
    let saved: TrainingLocalState
    let persistenceError: String?
    do {
      saved = try localPersistence.load()
      persistenceError = nil
    } catch {
      saved = TrainingLocalState()
      persistenceError = "本地记录读取失败：\(error.localizedDescription)"
    }
    self.history = saved.history.sorted { $0.date > $1.date }
    self.preferences = saved.preferences
    self.errorMessage = persistenceError
    self.recorder.onEvent = { [weak self] event in self?.handle(event) }
    if allowsCloudSettings {
      cloudBaseURL = UserDefaults.standard.string(forKey: "fitcore.cloud.url") ?? ""
      cloudUserID = UserDefaults.standard.string(forKey: "fitcore.cloud.user")
      if let token = CloudCredentials.read(), let user = cloudUserID, !user.isEmpty,
        let client = try? CloudHistoryClient(url: cloudBaseURL, accessToken: token) {
        cloudClient = client
        if self.analysis.usesBackendText { self.analysis = BackendTrainingAnalysisService(client: client) }
        cloudSyncStatus = "已配置 · 等待同步"
        installLivePublisher(client)
      }
    }
  }

  var usesBackendText: Bool { analysis.usesBackendText }
  var analysisModeDescription: String { usesBackendText ? "真实文字模型 · 录音硬件仍为模拟" : "预设示例" }
  var canSupplementPending: Bool {
    guard usesBackendText else { return true }
    if case .backendClarification = analysisIssue { return true }
    return false
  }

  var canStart: Bool {
    device != nil && device?.powerState != .off && (phase == .ready || phase == .completed)
  }
  var recorderIsSimulated: Bool { device?.isSimulated ?? (mockControls != nil) }
  var isBusy: Bool { phase == .connecting || phase == .recording || phase == .finishing }
  var timerText: String { String(format: "%02d:%02d", elapsedSeconds / 60, elapsedSeconds % 60) }
  var utterances: [String] { context.utterances }
  var conversationStepIndex: Int { currentStepIndex }
  var conversationStepCount: Int { DemoFixtures.steps.count }
  var sessionConnectionIsSimulated: Bool { sessionConnection.isSimulated }
  var cloudIsConfigured: Bool { cloudClient != nil }
  var canSubmitText: Bool {
    !isProcessing && sessionConnectionState == .active
      && (phase == .recording || (phase == .finishing && pendingInput != nil))
  }
  var isReviewSaved: Bool {
    review.map { displayed in history.contains { $0.id == displayed.id } } ?? false
  }

  func updatePreferences(_ preferences: UserPreferences) { self.preferences = preferences }

  func updatePreferences(_ update: (inout UserPreferences) -> Void) {
    var next = preferences
    update(&next)
    preferences = next
  }

  func connect() {
    guard phase == .disconnected, configurationError == nil else { return }
    phase = .connecting
    errorMessage = nil
    connectTask?.cancel()
    connectTask = Task { [weak self] in
      guard let self else { return }
      do {
        let result = try await recorder.connect()
        try Task.checkCancellation()
        // An SDK connection callback may arrive before connect() returns.
        if device == nil {
          device = result
          phase = .ready
        }
      } catch is CancellationError { return } catch {
        guard device == nil else { return }
        phase = .disconnected
        errorMessage = error.localizedDescription
      }
    }
  }

  /// Opens the recorder interaction without losing an active conversation.
  func openRecorder() {
    switch phase {
    case .disconnected: showDeviceSheet = true
    case .ready, .completed:
      guard device != nil, device?.powerState != .off else {
        showDeviceSheet = true
        return
      }
      isConversationPresented = true
      if mockControls != nil { simulateStart() } else { conversationStatus = "请按录音豆实体按键开始录音" }
    case .recording, .finishing: isConversationPresented = true
    case .connecting: showDeviceSheet = true
    }
  }

  /// Navigation has no effect on recorder/analysis ownership or their tasks.
  func dismissConversation() { isConversationPresented = false }

  func deviceSheetDidDismiss() {
    guard conversationAfterDeviceSheet else { return }
    conversationAfterDeviceSheet = false
    if phase == .recording || phase == .finishing { isConversationPresented = true }
  }

  func simulateStart() {
    guard canStart, configurationError == nil else { return }
    mockControls?.simulateHardwareStart()
  }
  func simulateStop() {
    guard phase == .recording else { return }
    requestSessionFinish()
  }
  func appendSampleEvent() {
    guard phase == .recording else { return }
    advanceConversation()
  }

  /// Advances one of the eleven mobile_final.html text fixture steps. The fixture
  /// is explicit Mock data and is never presented as a microphone transcript.
  func advanceConversation() {
    guard !usesBackendText, pendingInput == nil, mockControls != nil, device?.isSimulated == true,
      phase == .recording, !isProcessing, currentStepIndex < DemoFixtures.steps.count
    else { return }
    let step = DemoFixtures.steps[currentStepIndex]
    processUtterance(step.utterance, status: step.status, isDemoStep: true, source: .demo)
  }

  /// Integration point for final ASR sentences with explicit backpressure. False
  /// means the caller MUST retain the sentence and retry after the current work
  /// completes; it has not been accepted. No final sentence is silently dropped.
  /// After hardware stop, the adapter may still submit its last final sentences;
  /// it must signal transferDrained only after those have all been accepted.
  /// The default Mock service rejects arbitrary non-fixture text.
  func acceptTranscribedUtterance(_ utterance: String) -> Bool {
    guard !usesBackendText, pendingInput == nil, !utterance.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
      phase == .recording || (phase == .finishing && !hasDrained), !isProcessing,
      activeSessionID != nil,
      sessionConnectionState == .opening || sessionConnectionState == .active
    else { return false }
    processUtterance(utterance, status: "正在整理训练记录", isDemoStep: false, source: .speech)
    return true
  }

  /// Text is passed to the same analysis boundary as ASR. It is never fabricated
  /// into an exercise locally; the current Mock deliberately rejects free text.
  @discardableResult
  func submitTrainingText(_ text: String) -> Bool {
    let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
    guard canSubmitText, !trimmed.isEmpty, trimmed.count <= 2000 else { return false }
    if let pendingInput {
      guard canSupplementPending else {
        errorMessage = "请先重试上方原话，确认服务端处理结果后再补充，避免重复或遗漏训练组。"
        return false
      }
      updateInputState(pendingInput.id, .supplemented)
      return processUtterance(trimmed, status: "正在理解文字补充", isDemoStep: false,
        source: .text, resolvingPending: true,
        clarifiesInputID: usesBackendText ? pendingInput.id : nil,
        analysisText: "待确认原话：\(pendingInput.analysisText ?? pendingInput.text)\n用户补充：\(trimmed)\n请将以上视为同一段记录的澄清，不新增重复训练组。")
    }
    return processUtterance(trimmed, status: "正在理解文字输入", isDemoStep: false, source: .text)
  }

  func retryPendingAnalysis() {
    guard let pendingInput, canSubmitText else { return }
    processUtterance(pendingInput.text, status: "正在重新分析", isDemoStep: pendingInput.isDemoStep,
      source: pendingInput.source, resolvingPending: true, inputID: pendingInput.id,
      clarifiesInputID: pendingInput.clarifiesInputID, analysisText: pendingInput.analysisText)
  }

  /// A subsequent ASR final may replace a clarification, explicitly and only after
  /// the UI has asked the user to repeat. The original input remains in history.
  @discardableResult
  func submitRepeatedUtterance(_ text: String) -> Bool {
    guard !usesBackendText, let pendingInput, canSubmitText, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return false }
    updateInputState(pendingInput.id, .supplemented)
    return processUtterance(text, status: "正在理解补充口述", isDemoStep: false,
      source: .speech, resolvingPending: true,
      analysisText: "待确认原话：\(pendingInput.analysisText ?? pendingInput.text)\n用户补充：\(text)\n请将以上视为同一段记录的澄清，不新增重复训练组。")
  }

  private func updateInputState(_ id: UUID, _ state: TrainingInputEntry.State) {
    if let index = inputHistory.firstIndex(where: { $0.id == id }) { inputHistory[index].state = state }
  }

  @discardableResult
  private func processUtterance(_ utterance: String, status: String, isDemoStep: Bool,
    source: TrainingInputSource, resolvingPending: Bool = false, inputID: UUID? = nil,
    clarifiesInputID: UUID? = nil, analysisText: String? = nil) -> Bool {
    guard phase == .recording || (phase == .finishing && (!hasDrained || resolvingPending)), !isProcessing,
      pendingInput == nil || resolvingPending,
      let id = activeSessionID,
      sessionConnectionState == .opening || sessionConnectionState == .active
    else { return false }
    let input = PendingTrainingInput(id: inputID ?? UUID(), text: utterance,
      source: source, isDemoStep: isDemoStep, analysisText: usesBackendText ? nil : analysisText,
      clarifiesInputID: clarifiesInputID)
    recordUpdateFeedback = nil
    pendingInput = nil
    analysisIssue = nil
    errorMessage = nil
    if inputHistory.contains(where: { $0.id == input.id }) {
      updateInputState(input.id, .processing)
    } else {
      inputHistory.append(TrainingInputEntry(id: input.id, text: utterance, source: source, state: .processing))
    }
    currentCoachReply = ""
    currentQuestion = ""
    currentAnswer = ""
    currentUtterance = utterance
    conversationStatus = status
    isProcessing = true
    publishLiveStatus()
    let revision = sessionRevision
    autoAdvanceTask?.cancel()
    conversationTask?.cancel()
    let snapshot = context
    let beginTask = sessionBeginTask
    let demonstrateFailure = previewNextAnalysisFailure && isDemoStep && recorderIsSimulated
    if demonstrateFailure { previewNextAnalysisFailure = false }
    conversationTask = Task { [weak self] in
      guard let self else { return }
      do {
        await beginTask?.value
        try Task.checkCancellation()
        guard activeSessionID == id, revision == sessionRevision else { return }
        guard sessionConnectionState == .active else {
          isProcessing = false
          retainFailedInput(input, issue: .service)
          if phase == .finishing { finishReviewIfReady() }
          return
        }
        if demonstrateFailure { throw TrainingAnalysisError.needsClarification }
        if !isDemoStep, analysis is MockTrainingAnalysisService {
          throw TrainingAnalysisError.unsupportedInput
        }
        let update = try await analysis.analyzeInput(input, context: snapshot, sessionID: id)
        try Task.checkCancellation()
        guard revision == sessionRevision, activeSessionID == id,
          phase == .recording || phase == .finishing
        else {
          return
        }
        let recordChanged = context.events != update.context.events
        if update.isFinal {
          context = update.context
          events = context.events
          if update.requiresClarification {
            isProcessing = false
            retainFailedInput(input, issue: .backendClarification(update.coachReply))
            return
          }
          if isDemoStep { currentStepIndex += 1 }
          updateInputState(input.id, .understood)
        } else {
          // This entry point consumes final ASR sentences. An unfinished model
          // response cannot acknowledge that sentence as successfully recorded.
          isProcessing = false
          retainFailedInput(input, issue: .clarification)
          return
        }
        currentCoachReply = update.coachReply
        currentQuestion = update.question?.text ?? ""
        currentAnswer = update.question?.answer ?? ""
        let confirmedEnd =
          update.isFinal && update.endIntent == .complete
          && (!update.isSimulated
            || DemoTrainingEndIntentPolicy.shouldFinish(
              utterance: utterance, analysisIntent: update.endIntent))
        conversationStatus = confirmedEnd || phase == .finishing ? "正在整理训练复盘…" : ""
        isProcessing = false
        if recordChanged, !confirmedEnd, phase == .recording {
          recordUpdateFeedback = TrainingRecordUpdateFeedback(sessionID: id, inputID: input.id)
        }
        publishLiveStatus()
        if phase == .finishing {
          finishReviewIfReady()
        } else if confirmedEnd {
          requestSessionFinish()
        } else if autoAdvance {
          scheduleAutoAdvance()
        }
      } catch is CancellationError {
        guard revision == sessionRevision, activeSessionID == id else { return }
        isProcessing = false
        retainFailedInput(input, issue: .service)
        if phase == .finishing { finishReviewIfReady() }
      } catch {
        guard revision == sessionRevision, activeSessionID == id else { return }
        isProcessing = false
        let issue: TrainingInteractionIssue
        switch error {
        case TrainingAnalysisError.needsClarification: issue = .clarification
        case TrainingAnalysisError.unsupportedInput: issue = .notConfigured
        case let backendError as BackendTrainingError: issue = .backend(backendError)
        default: issue = .service
        }
        retainFailedInput(input, issue: issue)
        // Stop/drain can arrive while this request is still in flight. Recheck
        // once its failure is retained; the finish policy decides whether the
        // pending input requires retry or may remain as an unprocessed original.
        if phase == .finishing { finishReviewIfReady() }
      }
    }
    return true
  }

  private func retainFailedInput(_ input: PendingTrainingInput, issue: TrainingInteractionIssue) {
    recordUpdateFeedback = nil
    pendingInput = input
    analysisIssue = issue
    currentCoachReply = ""
    updateInputState(input.id, .needsAttention)
    conversationStatus = phase == .finishing ? "有一段原话待处理，暂未完成复盘" : "原话已保留 · 等待补充或重试"
    errorMessage = issue.message
    autoAdvanceTask?.cancel()
    publishLiveStatus()
  }

  private func scheduleAutoAdvance() {
    guard !usesBackendText, pendingInput == nil, autoAdvance, mockControls != nil, device?.isSimulated == true,
      sessionConnectionState == .active
    else { return }
    autoAdvanceTask?.cancel()
    let revision = sessionRevision
    let delay =
      currentStepIndex == 0
      ? firstStepDelay : (currentQuestion.isEmpty ? automaticStepDelay : questionStepDelay)
    autoAdvanceTask = Task { [weak self] in
      do { try await Task.sleep(for: delay) } catch { return }
      guard let self, autoAdvance, !Task.isCancelled, revision == sessionRevision,
        phase == .recording, !isProcessing
      else { return }
      advanceConversation()
    }
  }

  private func requestSessionFinish() {
    recordUpdateFeedback = nil
    finishRequested = true
    if let mockControls {
      mockControls.simulateHardwareStop()
    } else {
      // SDK documents do not provide a verified remote stop command. Keep the
      // real stream/session alive until the adapter observes the physical stop.
      conversationStatus = "已确认训练完成，请按录音豆按键结束录音"
    }
  }

  func correctEvent(_ event: TrainingEvent) {
    guard !usesBackendText else {
      errorMessage = "请在训练对话中输入更正，例如“上一组其实是八次”，由服务端更新原组。"
      return
    }
    guard phase == .recording, !isProcessing, context.events.contains(where: { $0.id == event.id }) else { return }
    recordUpdateFeedback = nil
    sessionRevision += 1
    conversationTask?.cancel()
    autoAdvanceTask?.cancel()
    isProcessing = false
    context.correct(event)
    events = context.events
    conversationStatus = "已更正训练记录"
    currentCoachReply = "已更新\(event.exercise)第 \(event.setNumber ?? 1) 组：\(event.setDescription)。"
    publishLiveStatus()
    if autoAdvance { scheduleAutoAdvance() }
  }

  /// Cancellation discards the partial session and invalidates pending AI work.
  func cancelSession() {
    publishLiveStatus(terminal: .cancelled, recorderDisconnected: true)
    recordUpdateFeedback = nil
    sessionRevision += 1
    connectTask?.cancel()
    clockTask?.cancel()
    reviewTask?.cancel()
    conversationTask?.cancel()
    autoAdvanceTask?.cancel()
    cancelActiveSessionConnection()
    recorder.disconnect()
    context = TrainingContext()
    currentStepIndex = 0
    events = []
    review = nil
    currentUtterance = ""
    currentCoachReply = ""
    currentQuestion = ""
    currentAnswer = ""
    pendingInput = nil
    analysisIssue = nil
    inputHistory = []
    conversationStatus = ""
    isProcessing = false
    elapsedSeconds = 0
    isConversationPresented = false
    conversationAfterDeviceSheet = false
    finishRequested = false
    phase = .disconnected
  }

  func disconnect() {
    connectTask?.cancel()
    recorder.disconnect()
  }

  /// History browsing changes only the displayed review, never the active context.
  func selectReview(_ selected: TrainingReview) {
    review = selected
    selectedTab = .insights
  }

  /// Explicit save is the only operation that adds a generated review to history.
  func saveReview() {
    guard let review, !review.events.isEmpty else { return }
    guard !history.contains(where: { $0.id == review.id }) else { return }
    let nextHistory = (history + [review]).sorted { $0.date > $1.date }
    var nextPreferences = preferences
    nextPreferences.selectedMuscles = []
    do {
      try persistence.save(TrainingLocalState(history: nextHistory, preferences: nextPreferences))
      history = nextHistory
      isApplyingPersistedState = true
      preferences = nextPreferences
      isApplyingPersistedState = false
      if cloudClient != nil {
        cloudSyncStatus = "已保存在本机 · 等待同步"
        if cloudSyncBusy { cloudResyncNeeded = true }
        else { Task { await syncCloudHistory() } }
      }
    } catch { errorMessage = error.localizedDescription }
  }

  @discardableResult
  func configureCloudSync(url: String, token: String) async -> Bool {
    guard allowsCloudSettings, !cloudSyncBusy else { return false }
    cloudSyncBusy = true
    defer { cloudSyncBusy = false }
    do {
      let client = try CloudHistoryClient(url: url, accessToken: token)
      let user = try await client.identity()
      let owner = client.baseURL.absoluteString.trimmingCharacters(in: CharacterSet(charactersIn: "/")) + "|" + user
      if let previous = UserDefaults.standard.string(forKey: "fitcore.cloud.owner"), previous != owner {
        throw CloudHistoryError.differentOwner
      }
      try CloudCredentials.save(token)
      UserDefaults.standard.set(client.baseURL.absoluteString, forKey: "fitcore.cloud.url")
      UserDefaults.standard.set(user, forKey: "fitcore.cloud.user")
      UserDefaults.standard.set(owner, forKey: "fitcore.cloud.owner")
      cloudBaseURL = client.baseURL.absoluteString
      cloudUserID = user
      cloudClient = client
      if analysis.usesBackendText { analysis = BackendTrainingAnalysisService(client: client) }
      installLivePublisher(client)
      cloudSyncStatus = "已连接 · \(user)"
      if phase == .recording || phase == .finishing { startLiveHeartbeat() }
      return true
    } catch {
      cloudSyncStatus = error.localizedDescription
      return false
    }
  }

  func syncCloudHistory() async {
    guard let client = cloudClient, let user = cloudUserID, !cloudSyncBusy else { return }
    cloudSyncBusy = true
    cloudSyncStatus = "正在同步训练记录…"
    defer {
      cloudSyncBusy = false
      if cloudResyncNeeded {
        cloudResyncNeeded = false
        Task { await syncCloudHistory() }
      }
    }
    do {
      guard try await client.identity() == user else { throw CloudHistoryError.differentOwner }
      let remote = try await client.list()
      let remoteByID = Dictionary(uniqueKeysWithValues: remote.map { ($0.id, $0) })
      let local = history
      for record in local {
        if let existing = remoteByID[record.id] {
          guard try CloudHistoryClient.encoder().encode(record) == CloudHistoryClient.encoder().encode(existing)
          else { throw CloudHistoryError.conflict }
        } else {
          try await client.upload(record)
        }
      }
      // Merge against current local state: a save made during the network request
      // must not be lost. Its upload is scheduled by cloudResyncNeeded.
      var merged = Dictionary(uniqueKeysWithValues: history.map { ($0.id, $0) })
      for record in remote where merged[record.id] == nil { merged[record.id] = record }
      let result = merged.values.sorted { $0.date > $1.date }
      try persistence.save(TrainingLocalState(history: result, preferences: preferences))
      history = result
      cloudSyncStatus = "已同步 \(result.count) 条 · \(Date().formatted(date: .omitted, time: .shortened))"
    } catch {
      cloudSyncStatus = "同步未完成：\(error.localizedDescription)"
    }
  }

  func disconnectCloudSync() {
    guard allowsCloudSettings, !cloudSyncBusy else { return }
    CloudCredentials.remove()
    cloudClient = nil
    if analysis.usesBackendText { analysis = BackendTrainingAnalysisService(client: nil) }
    livePublisher?.invalidate()
    livePublisher = nil
    liveHeartbeatTask?.cancel()
    liveHeartbeatTask = nil
    cloudLiveStatus = "已停止状态同步"
    cloudSyncStatus = "已停止云同步 · 本机记录保留"
  }

  /// Refresh saved history when the phone becomes active again, independently
  /// of the five-second live status heartbeat. No screen owns the session.
  func sceneDidBecomeActive() async {
    if phase == .recording || phase == .finishing {
      if liveHeartbeatTask == nil { startLiveHeartbeat() }
      else { publishLiveStatus() }
    }
    await syncCloudHistory()
  }

  private func installLivePublisher(_ client: CloudHistoryClient) {
    livePublisher?.invalidate()
    livePublisher = CloudLivePublisher(onStatus: { [weak self] status in
      self?.cloudLiveStatus = status
    }) { id, snapshot in
      try await client.publishLive(sessionID: id, snapshot: snapshot)
    }
    cloudLiveStatus = "已配置 · 等待训练状态"
    if (phase == .recording || phase == .finishing), livePublishedSessionID == sessionID,
      let opening = liveOpeningSnapshot {
      // The owner check in configureCloudSync forbids switching datasets. When
      // rotating its token, replay the same opening receipt (idempotent/stale),
      // then continue with a newer sequence so finishing is never lost.
      livePublisher?.enqueue(sessionID: sessionID, snapshot: opening)
      publishLiveStatus()
    }
  }

  private func startLiveHeartbeat() {
    liveHeartbeatTask?.cancel()
    guard livePublisher != nil else { liveHeartbeatTask = nil; return }
    publishLiveStatus()
    let id = sessionID
    let delay = liveHeartbeatDelay
    liveHeartbeatTask = Task { [weak self] in
      while !Task.isCancelled {
        do { try await Task.sleep(for: delay) } catch { return }
        guard let self, sessionID == id, phase == .recording || phase == .finishing else { return }
        publishLiveStatus()
      }
    }
  }

  private func publishLiveStatus(terminal: CloudLiveSnapshot.Phase? = nil,
    recorderDisconnected: Bool = false) {
    guard let livePublisher, liveTerminalSessionID != sessionID else { return }
    let livePhase: CloudLiveSnapshot.Phase
    if let terminal { livePhase = terminal }
    else if phase == .recording { livePhase = .recording }
    else if phase == .finishing { livePhase = .finishing }
    else { return }
    if livePublishedSessionID != sessionID {
      // Configuring cloud after a workout cannot invent an opening recording
      // event. Saved reviews still synchronize through their separate endpoint.
      guard livePhase == .recording else { return }
      livePublishedSessionID = sessionID
      liveSequence = 0
      liveOpeningSnapshot = nil
    }
    liveSequence += 1
    let completed = livePhase == .completed
    let stoppedUnexpectedly = livePhase == .cancelled || livePhase == .disconnected
    // Losing Bluetooth or cancelling a session is not a physical stop receipt.
    // Only the hardware-stopped/finishing state establishes recording=false.
    let recording: Bool? = livePhase == .recording ? true
      : (phase == .finishing || phase == .completed || completed) ? false : nil
    let issue = analysisIssue?.title ?? (sessionConnectionState == .failed ? "训练会话连接不可用" : nil)
    let analysisStage: CloudLiveSnapshot.Stage = stoppedUnexpectedly ? .unknown
      : issue != nil ? .attention : isProcessing ? .active
      : (!currentCoachReply.isEmpty || !events.isEmpty || completed) ? .complete : .idle
    // The current adapter receives final sentences; it exposes no trustworthy
    // in-flight ASR signal. Mock fixture text must never highlight real ASR.
    let transcription: CloudLiveSnapshot.Stage = inputHistory.contains { $0.source == .speech } ? .complete
      : (receivedAudioPackets > 0 && !recorderIsSimulated ? .unknown : .idle)
    let reviewStage: CloudLiveSnapshot.Stage = completed ? .complete
      : stoppedUnexpectedly ? .idle : issue != nil && livePhase == .finishing ? .attention
      : livePhase == .finishing && hasDrained && !isProcessing ? .active : .idle
    let snapshot = CloudLiveSnapshot(publisher_id: livePublisherID, sequence: liveSequence,
      phase: livePhase, elapsed_seconds: max(0, elapsedSeconds),
      device: .init(name: device?.name ?? "录音豆", connected: recorderDisconnected ? false : device != nil,
        recording: recording, simulated: recorderIsSimulated),
      stages: .init(recording: recording == true ? .active : recording == false ? .complete : .unknown,
        transcription: transcription, analysis: analysisStage, review: reviewStage),
      analysis_issue: issue, latest_utterance: currentUtterance, coach_reply: currentCoachReply,
      record_count: events.count,
      is_simulated: recorderIsSimulated || sessionConnection.isSimulated || analysis is MockTrainingAnalysisService,
      review_id: completed && review?.id == sessionID ? review?.id : nil)
    if liveOpeningSnapshot == nil { liveOpeningSnapshot = snapshot }
    livePublisher.enqueue(sessionID: sessionID, snapshot: snapshot)
    if livePhase.isTerminal {
      liveTerminalSessionID = sessionID
      liveHeartbeatTask?.cancel()
      liveHeartbeatTask = nil
    }
  }

  private func handle(_ event: RecorderEvent) {
    switch event {
    case .connected(let connectedDevice):
      guard device == nil, phase == .disconnected || phase == .connecting else { return }
      device = connectedDevice
      phase = .ready
      errorMessage = nil
    case .deviceStateChanged(let updatedDevice):
      guard let current = device, current.name == updatedDevice.name else { return }
      device = updatedDevice
      publishLiveStatus()
    case .recordingStarted:
      // A confirmed physical recording is newer evidence than a cached power state.
      guard device != nil, phase == .ready || phase == .completed else { return }
      recordUpdateFeedback = nil
      sessionRevision += 1
      reviewTask?.cancel()
      conversationTask?.cancel()
      autoAdvanceTask?.cancel()
      sessionID = UUID()
      sessionStartedAt = Date()
      context = TrainingContext()
      currentStepIndex = 0
      events = []
      review = nil
      elapsedSeconds = 0
      receivedAudioPackets = 0
      errorMessage = nil
      hasDrained = false
      finishRequested = false
      currentUtterance = ""
      currentCoachReply = ""
      currentQuestion = ""
      currentAnswer = ""
      pendingInput = nil
      analysisIssue = nil
      inputHistory = []
      conversationStatus = ""
      isProcessing = false
      phase = .recording
      selectedTab = .today
      if let current = device {
        device = RecorderDevice(
          name: current.name, batteryPercent: current.batteryPercent,
          isSimulated: current.isSimulated, caseBatteryPercent: current.caseBatteryPercent,
          powerState: .on)
      }
      if showDeviceSheet {
        conversationAfterDeviceSheet = true
        showDeviceSheet = false
      } else {
        isConversationPresented = true
      }
      startClock()
      beginSessionConnection()
      startLiveHeartbeat()
    case .recordingStopped:
      guard phase == .recording else { return }
      recordUpdateFeedback = nil
      clockTask?.cancel()
      autoAdvanceTask?.cancel()
      phase = .finishing
      finishRequested = true
      conversationStatus = "正在整理训练复盘…"
      publishLiveStatus()
    case .transferDrained:
      guard phase == .finishing else { return }
      hasDrained = true
      finishReviewIfReady()
    case .disconnected:
      publishLiveStatus(terminal: .disconnected, recorderDisconnected: true)
      recordUpdateFeedback = nil
      sessionRevision += 1
      connectTask?.cancel()
      clockTask?.cancel()
      reviewTask?.cancel()
      conversationTask?.cancel()
      autoAdvanceTask?.cancel()
      cancelActiveSessionConnection()
      device = nil
      conversationAfterDeviceSheet = false
      isProcessing = false
      phase = .disconnected
      isConversationPresented = false
    case .audioPacket:
      // Future audio transport must provide ASR utterances before analysis.
      // Receiving bytes alone must never manufacture a transcript or review.
      receivedAudioPackets += 1
    }
  }

  private func startClock() {
    clockTask?.cancel()
    let started = Date()
    clockTask = Task { [weak self] in
      do {
        while !Task.isCancelled {
          try await Task.sleep(for: .seconds(1))
          guard let self, phase == .recording else { return }
          elapsedSeconds = Int(Date().timeIntervalSince(started))
        }
      } catch {}
    }
  }

  private func finishReview() {
    let revision = sessionRevision
    let snapshot = context
    let duration = elapsedSeconds
    let id = sessionID
    let date = sessionStartedAt
    sessionConnectionState = .finishing
    reviewTask?.cancel()
    reviewTask = Task { [weak self] in
      guard let self else { return }
      do {
        try await sessionConnection.finish(sessionID: id)
        try Task.checkCancellation()
        guard activeSessionID == id, sessionRevision == revision, phase == .finishing else {
          return
        }
        sessionConnectionState = .closed
        activeSessionID = nil
        // Closing a real transport is distinct from having a completed ASR/AI implementation.
        guard device?.isSimulated == true else { throw TrainingAnalysisError.unsupportedInput }
        var result = try await analysis.makeReview(
          context: snapshot, durationSeconds: duration, sessionID: id, date: date)
        try Task.checkCancellation()
        guard sessionRevision == revision, phase == .finishing else { return }
        result.inputHistory = inputHistory
        review = result
        recordUpdateFeedback = nil
        phase = .completed
        isConversationPresented = false
        selectedTab = .insights
        conversationStatus = usesBackendText ? "训练记录汇总已生成" : "复盘已生成"
        publishLiveStatus(terminal: .completed)
      } catch is CancellationError {
        // An explicit cancellation already changes the active ID. A spontaneous
        // transport cancellation is a failure, not a successful review.
        guard sessionRevision == revision, phase == .finishing else { return }
        if activeSessionID == id { await sessionConnection.cancel(sessionID: id) }
        guard sessionRevision == revision, phase == .finishing else { return }
        failStoppedSession("训练会话已中断，未生成复盘。")
      } catch {
        guard sessionRevision == revision else { return }
        if activeSessionID == id { await sessionConnection.cancel(sessionID: id) }
        guard sessionRevision == revision else { return }
        failStoppedSession(error.localizedDescription)
      }
    }
  }

  private func finishReviewIfReady() {
    guard phase == .finishing, hasDrained, !isProcessing else { return }
    if sessionConnectionState == .failed {
      failStoppedSession(errorMessage ?? "训练会话未就绪，未生成复盘。")
      return
    }
    // A bounded context cannot be fixed by retrying. Explicit hardware/user stop
    // may summarize confirmed events while preserving the unprocessed original
    // in review.inputHistory; it must never fabricate a successful result.
    guard pendingInput == nil || analysisIssue == .backend(.contextLimit) else { return }
    guard sessionConnectionState == .active else { return }
    finishReview()
  }

  private func beginSessionConnection() {
    let id = sessionID
    activeSessionID = id
    sessionConnectionState = .opening
    sessionBeginTask = Task { [weak self] in
      guard let self else { return }
      do {
        try await sessionConnection.begin(sessionID: id)
        try Task.checkCancellation()
        guard activeSessionID == id else {
          await sessionConnection.cancel(sessionID: id)
          return
        }
        sessionConnectionState = .active
        publishLiveStatus()
        if phase == .finishing {
          finishReviewIfReady()
        } else if autoAdvance, !isProcessing {
          scheduleAutoAdvance()
        }
      } catch {
        await sessionConnection.cancel(sessionID: id)
        guard activeSessionID == id else { return }
        sessionConnectionState = .failed
        errorMessage = "训练会话建立失败：\(error.localizedDescription)"
        publishLiveStatus()
        if phase == .finishing { finishReviewIfReady() }
      }
    }
  }

  private func cancelActiveSessionConnection() {
    sessionBeginTask?.cancel()
    guard let id = activeSessionID else { return }
    activeSessionID = nil
    sessionConnectionState = .closed
    let connection = sessionConnection
    // Capture the old ID, not mutable store state. Delayed cleanup cannot affect
    // a newly started training session using the same connection adapter.
    Task { await connection.cancel(sessionID: id) }
  }

  private func failStoppedSession(_ message: String) {
    // The recorder is still connected here; the analysis/session failed after
    // transfer drained. Mark the run cancelled so desktop does not claim a
    // Bluetooth disconnect.
    publishLiveStatus(terminal: .cancelled)
    recordUpdateFeedback = nil
    activeSessionID = nil
    sessionConnectionState = .failed
    errorMessage = message
    phase = device == nil ? .disconnected : .ready
    isConversationPresented = false
  }

  private func persist() {
    guard !isApplyingPersistedState else { return }
    do {
      try persistence.save(TrainingLocalState(history: history, preferences: preferences))
    } catch { errorMessage = error.localizedDescription }
  }

  deinit {
    connectTask?.cancel()
    clockTask?.cancel()
    reviewTask?.cancel()
    conversationTask?.cancel()
    autoAdvanceTask?.cancel()
    sessionBeginTask?.cancel()
    liveHeartbeatTask?.cancel()
  }
}
