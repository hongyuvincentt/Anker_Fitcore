import Foundation

/// Runs on macOS with Command Line Tools. This is not an iOS SDK build or UI test.
/// Every store injects private persistence, so running checks cannot change real records.
@main
struct CoreCheck {
  @MainActor
  static func main() async throws {
    try checkConfiguration()
    try await checkContextAndReview()
    try await checkLifecycleAndPersistence()
    try await checkCorrectionsAndDraining()
    try await checkCancellation()
    try await checkAutomaticPlayback()
    try await checkHardwareBoundary()
    try await checkDeviceTelemetryAndHardwareNavigation()
    try await checkConnectionSurvivesNavigation()
    try await checkConnectionDrainingAndFailures()
    try await checkOldConnectionIsolation()
    try await checkEndIntentAndBackpressure()
    try await checkFailedFinalRecoveryAndText()
    checkRecordUpdateFeedbackTiming()
    try await checkRecordUpdateFeedback()
    try await checkLiveCloudQueue()
    try await checkLiveCloudLifecycle()
    try await checkBackendTextAnalysis()
    print(
      "Core checks passed: context, persistence, cancellation, page-independent session ownership, same-ID analysis, final-operation drain, stale cleanup isolation, connection failures, explicit end intent, transcript backpressure, hardware boundary, device telemetry, hardware-driven navigation, committed-record feedback and fade timing, serialized cloud live status and lifecycle"
    )
  }

  private static func checkConfiguration() throws {
    let empty = try AppEnvironment.load(info: [:])
    precondition(empty.apiBaseURL == nil)
    precondition(empty.analysisMode == .mock)
    let backend = try AppEnvironment.load(info: ["FITCORE_ANALYSIS_MODE": "backend"])
    precondition(backend.analysisMode == .backend)
    for badInfo: [String: Any] in [
      ["FITCORE_RECORDER_MODE": "soundcore"],
      ["FITCORE_ANALYSIS_MODE": "anything"],
      ["FITCORE_API_BASE_URL": "http://insecure.example.com"],
      ["FITCORE_API_BASE_URL": "https://user:secret@example.com"],
      ["FITCORE_API_BASE_URL": "https://example.com?key=secret"],
      ["FITCORE_API_BASE_URL": "$(FITCORE_API_BASE_URL)"],
    ] {
      do {
        _ = try AppEnvironment.load(info: badInfo)
        preconditionFailure("Invalid configuration was accepted")
      } catch is AppEnvironment.ConfigurationError {}
    }
    let configured = try AppEnvironment.load(info: [
      "FITCORE_API_BASE_URL": "https://fitcore.example.com/api"
    ])
    precondition(configured.apiBaseURL?.path == "/api")
  }

  private static func checkContextAndReview() async throws {
    let context = DemoFixtures.steps.reduce(TrainingContext()) { $0.applying($1) }
    precondition(context.utterances.count == 11 && context.events.count == 9)
    let bench = context.events.filter { $0.exercise == "杠铃卧推" }
    let fly = context.events.filter { $0.exercise == "哑铃飞鸟" }
    precondition(
      bench.map(\.repetitions) == [10, 9, 8] && bench.map(\.weightKilograms) == [60, 60, 60])
    precondition(bench.map(\.setNumber) == [1, 2, 3] && bench[1].rir == 2)
    precondition(
      fly.map(\.repetitions) == [12, 11, 10, 8] && fly.map(\.setNumber) == [1, 2, 3, 4])
    precondition(fly.allSatisfy { $0.weightKilograms == 5 })
    precondition(context.questions.count == 1 && context.elapsedMinutes == 46)
    precondition(context.events.first?.type == .warmup && context.events.last?.type == .stretch)
    let id = UUID()
    let date = Date(timeIntervalSince1970: 1_700_000_000)
    let review = try await MockTrainingAnalysisService(latency: .zero, reviewLatency: .zero)
      .makeReview(context: context, durationSeconds: 50, sessionID: id, date: date)
    precondition(review.id == id && review.date == date && review.durationMinutes == 46)
    precondition(review.phaseCount == 3 && review.isCompleteChain && review.isSimulated)
    precondition(review.totalRepetitions == 68 && review.estimatedCalories == 288)
    precondition(review.questions.first?.text == "为什么我右肩总是往前跑？")
    let copy = try JSONDecoder().decode(TrainingReview.self, from: JSONEncoder().encode(review))
    precondition(
      copy == review, "Review persistence must preserve IDs, context, questions, and provenance")
    do {
      _ = try await MockTrainingAnalysisService(latency: .zero).analyzeUtterance(
        "arbitrary real text", context: TrainingContext())
      preconditionFailure("A Mock must not present arbitrary text as analyzed audio")
    } catch is TrainingAnalysisError {}
  }

  @MainActor
  private static func checkLifecycleAndPersistence() async throws {
    let persistence = MemoryTrainingPersistence()
    let store = AppStore(info: [:], persistence: persistence, analysis: quickAnalysis)
    store.autoAdvance = false
    store.simulateStart()
    precondition(store.phase == .disconnected)
    store.openRecorder()
    precondition(store.showDeviceSheet && !store.isConversationPresented)
    store.connect()
    store.connect()
    try await wait { store.phase == .ready }
    store.showDeviceSheet = false
    store.openRecorder()
    precondition(store.phase == .recording && store.isConversationPresented)
    try await advance(store, through: 3)
    let before = store.events
    let spoken = store.utterances
    store.dismissConversation()
    precondition(store.phase == .recording && !store.isConversationPresented)
    store.openRecorder()
    precondition(
      store.events == before && store.utterances == spoken && store.conversationStepIndex == 3)
    try await advance(store, through: 11)
    try await wait { store.phase == .completed }
    precondition(store.selectedTab == .insights && !store.isConversationPresented)
    precondition(
      store.history.isEmpty && !store.isReviewSaved, "Generating a review must not save it")
    let first = store.review!
    store.preferences.selectedMuscles = ["chest"]
    store.saveReview()
    precondition(
      store.preferences.selectedMuscles.isEmpty, "A new saved session resets the muscle filter")
    store.preferences.selectedMuscles = ["arms"]
    store.saveReview()
    precondition(
      store.preferences.selectedMuscles == ["arms"],
      "An idempotent save preserves current preferences")
    precondition(store.history.count == 1 && store.isReviewSaved)
    var preferences = store.preferences
    preferences.displayName = "测试用户"
    preferences.goalCalories = 650
    preferences.goalMinutes = 50
    preferences.gender = "female"
    preferences.selectedMuscles = ["chest", "arms"]
    store.updatePreferences(preferences)

    let loaded = AppStore(info: [:], persistence: persistence)
    precondition(loaded.history == [first] && loaded.preferences == preferences)
    precondition(
      loaded.phase == .disconnected && loaded.review == nil,
      "History is persisted; live hardware state is not")
    loaded.preferences.goalMinutes = 65
    let loadedPreferences = try persistence.load().preferences
    precondition(loadedPreferences.goalMinutes == 65, "Direct preference editing must persist")

    store.openRecorder()
    precondition(store.phase == .recording && store.events.isEmpty && store.review == nil)
    try await advance(store, through: 3)
    let liveEvents = store.events
    let liveTranscript = store.utterances
    store.dismissConversation()
    store.selectReview(first)
    precondition(store.review?.id == first.id && store.phase == .recording)
    precondition(store.events == liveEvents && store.utterances == liveTranscript)
    store.openRecorder()
    try await advance(store, through: 4)
    precondition(store.events.last?.setNumber == 2 && store.events.last?.weightKilograms == 60)
    precondition(
      store.review?.id == first.id,
      "Historical browsing must not mutate the active training context")
    store.simulateStop()
    try await wait { store.phase == .completed }
    precondition(store.review?.id != first.id && store.history.count == 1)
    store.saveReview()
    precondition(store.history.count == 2)
    precondition(store.preferences.selectedMuscles.isEmpty)
    let storedState = try persistence.load()
    precondition(storedState.history.count == 2 && storedState.preferences.selectedMuscles.isEmpty)
    store.disconnect()
    precondition(store.phase == .disconnected && !store.canStart)

    // Exercise the actual UserDefaults adapter with an isolated test suite.
    let suiteName = "fitcore.tests.\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suiteName)!
    defer { defaults.removePersistentDomain(forName: suiteName) }
    let disk = UserDefaultsTrainingPersistence(defaults: defaults)
    try disk.save(TrainingLocalState(history: [first], preferences: preferences))
    let diskCopy = try UserDefaultsTrainingPersistence(defaults: defaults).load()
    precondition(diskCopy.history == [first] && diskCopy.preferences == preferences)
  }

  @MainActor
  private static func checkCorrectionsAndDraining() async throws {
    let store = AppStore(
      info: [:], persistence: MemoryTrainingPersistence(), analysis: quickAnalysis)
    store.autoAdvance = false
    store.connect()
    try await wait { store.phase == .ready }
    store.simulateStart()
    try await advance(store, through: 3)
    var corrected = store.events.last!
    corrected.weightKilograms = 55
    corrected.repetitions = 7
    store.correctEvent(corrected)
    precondition(store.events.count == 2 && store.events.last?.id == corrected.id)
    precondition(store.recordUpdateFeedback == nil,
      "A manual correction must not retain an AI-recorded success receipt")
    try await advance(store, through: 4)
    precondition(store.events.last?.weightKilograms == 55 && store.events.last?.repetitions == 9)
    precondition(store.events.last?.setNumber == 2 && store.currentCoachReply.contains("55"))
    store.advanceConversation()
    precondition(store.isProcessing)
    store.simulateStop()  // Drain the already-submitted text operation before summarizing.
    precondition(store.phase == .finishing)
    try await wait { store.phase == .completed }
    precondition(store.review?.utterances.count == 5 && store.review?.questions.count == 1)
    precondition(store.review?.events[1].repetitions == 7)
    precondition(
      store.review?.events.last?.weightKilograms == 60,
      "Explicit new weight overrides inherited correction")
    store.disconnect()
  }

  @MainActor
  private static func checkCancellation() async throws {
    let store = AppStore(
      info: [:], persistence: MemoryTrainingPersistence(), analysis: CancellationIgnoringAnalysis())
    store.autoAdvance = false
    store.connect()
    try await wait { store.phase == .ready }
    store.simulateStart()
    try await wait { store.sessionConnectionState == .active }
    store.advanceConversation()
    // Let the cancellation-ignoring analysis enter its delay before canceling.
    try await Task.sleep(for: .milliseconds(30))
    store.cancelSession()
    try await Task.sleep(for: .milliseconds(400))
    precondition(
      store.phase == .disconnected && store.events.isEmpty && store.review == nil
        && !store.isProcessing)
    precondition(store.history.isEmpty)
    precondition(store.recordUpdateFeedback == nil,
      "A canceled analysis callback must not resurrect success feedback")
    store.connect()
    try await wait { store.phase == .ready }
    store.simulateStart()
    try await advance(store, through: 1)
    store.simulateStop()
    store.disconnect()
    try await Task.sleep(for: .milliseconds(400))
    precondition(
      store.phase == .disconnected && store.review == nil,
      "A canceled review must not resurrect the session")
    precondition(store.recordUpdateFeedback == nil)
    let pending = AppStore(
      info: [:], persistence: MemoryTrainingPersistence(), recorder: CancellationIgnoringRecorder())
    pending.connect()
    pending.disconnect()
    try await Task.sleep(for: .milliseconds(400))
    precondition(pending.device == nil && pending.phase == .disconnected)

    let failedSave = AppStore(
      info: [:], persistence: FailingSavePersistence(), analysis: quickAnalysis)
    failedSave.autoAdvance = false
    failedSave.connect()
    try await wait { failedSave.phase == .ready }
    failedSave.simulateStart()
    try await advance(failedSave, through: 1)
    failedSave.simulateStop()
    try await wait { failedSave.phase == .completed }
    failedSave.saveReview()
    precondition(
      failedSave.history.isEmpty && !failedSave.isReviewSaved && failedSave.errorMessage != nil)
    failedSave.disconnect()

    let failedReview = AppStore(
      info: [:], persistence: MemoryTrainingPersistence(), analysis: ReviewFailureAnalysis())
    failedReview.autoAdvance = false
    failedReview.connect()
    try await wait { failedReview.phase == .ready }
    failedReview.openRecorder()
    failedReview.simulateStop()
    try await wait { failedReview.phase == .ready }
    precondition(!failedReview.isConversationPresented && failedReview.errorMessage != nil)
    precondition(failedReview.review == nil && failedReview.history.isEmpty)
    failedReview.disconnect()
  }

  @MainActor
  private static func checkAutomaticPlayback() async throws {
    let store = AppStore(
      info: [:], persistence: MemoryTrainingPersistence(), analysis: quickAnalysis,
      automaticStepDelay: .milliseconds(50), questionStepDelay: .milliseconds(50),
      firstStepDelay: .milliseconds(50))
    store.connect()
    try await wait { store.phase == .ready }
    store.simulateStart()
    try await wait { store.conversationStepIndex >= 1 && !store.isProcessing }
    store.autoAdvance = false
    let count = store.conversationStepIndex
    try await Task.sleep(for: .milliseconds(300))
    precondition(
      store.conversationStepIndex == count,
      "Disabling auto advancement must cancel its pending timer")
    store.dismissConversation()
    store.autoAdvance = true
    try await wait { store.phase == .completed }
    precondition(store.utterances.count == 11 && store.review?.events.count == 9)
    store.disconnect()
  }

  private static var quickAnalysis: MockTrainingAnalysisService {
    MockTrainingAnalysisService(latency: .milliseconds(20), reviewLatency: .milliseconds(40))
  }

  @MainActor
  private static func checkDeviceTelemetryAndHardwareNavigation() async throws {
    let recorder = HardwareProbe()
    let store = AppStore(info: [:], persistence: MemoryTrainingPersistence(), recorder: recorder)
    store.autoAdvance = false
    store.showDeviceSheet = true
    let powered = RecorderDevice(
      name: "Hardware boundary probe", batteryPercent: 62, isSimulated: false,
      caseBatteryPercent: 84, powerState: .on)
    recorder.onEvent?(.connected(powered))
    precondition(store.phase == .ready && store.device?.powerState == .on)
    precondition(store.device?.batteryPercent == 62 && store.device?.caseBatteryPercent == 84)
    precondition(store.showDeviceSheet && !store.isConversationPresented && store.activeSessionID == nil,
      "Powering on updates the device page without starting a training session")

    recorder.onEvent?(.deviceStateChanged(RecorderDevice(
      name: powered.name, batteryPercent: nil, isSimulated: false,
      caseBatteryPercent: nil, powerState: .off)))
    precondition(store.device?.batteryPercent == nil && store.device?.caseBatteryPercent == nil)
    precondition(store.device?.powerState == .off && !store.canStart,
      "Unknown batteries stay unknown, and a powered-off bean cannot start training")
    store.simulateStart()
    precondition(store.phase == .ready && store.activeSessionID == nil)
    recorder.onEvent?(.recordingStarted)
    precondition(store.device?.powerState == .on,
      "A confirmed physical start supersedes a cached off state")
    precondition(store.phase == .recording && !store.showDeviceSheet && !store.isConversationPresented,
      "Physical recording dismisses the device sheet before presenting the conversation")
    store.deviceSheetDidDismiss()
    precondition(store.isConversationPresented && store.activeSessionID != nil)
    let session = store.activeSessionID
    recorder.onEvent?(.connected(powered))
    recorder.onEvent?(.recordingStarted)
    precondition(store.activeSessionID == session,
      "Duplicate connection/start callbacks must preserve the existing training session")

    store.disconnect()
    recorder.onEvent?(.deviceStateChanged(powered))
    store.deviceSheetDidDismiss()
    precondition(store.phase == .disconnected && store.device == nil && !store.isConversationPresented,
      "Late telemetry and a delayed sheet dismissal must not revive a disconnected device")

    recorder.onEvent?(.connected(RecorderDevice(
      name: powered.name, batteryPercent: -1, isSimulated: false, caseBatteryPercent: 101)))
    precondition(store.device?.batteryPercent == nil && store.device?.caseBatteryPercent == nil,
      "Invalid SDK battery values must be presented as unknown, not as real percentages")
    store.disconnect()

    let delayedRecorder = CancellationIgnoringRecorder()
    let delayedStore = AppStore(info: [:], persistence: MemoryTrainingPersistence(), recorder: delayedRecorder)
    delayedStore.connect()
    delayedRecorder.onEvent?(.connected(powered))
    try await Task.sleep(for: .milliseconds(300))
    precondition(delayedStore.device == powered && delayedStore.phase == .ready,
      "A late connect result must not overwrite the fresher SDK callback snapshot")
    delayedStore.disconnect()
  }

  @MainActor
  private static func checkConnectionSurvivesNavigation() async throws {
    let probe = SessionLifecycleProbe()
    let store = AppStore(
      info: [:], persistence: MemoryTrainingPersistence(), analysis: probe,
      sessionConnection: probe, automaticStepDelay: .milliseconds(60),
      questionStepDelay: .milliseconds(60), firstStepDelay: .milliseconds(10))
    store.connect()
    try await wait { store.phase == .ready }
    store.openRecorder()
    try await wait { store.conversationStepIndex == 1 && !store.isProcessing }
    let id = store.activeSessionID!
    store.dismissConversation()
    for tab in [AppStore.Tab.today, .history, .insights, .profile] {
      let count = store.utterances.count
      store.selectedTab = tab
      try await wait { store.utterances.count > count && !store.isProcessing }
      precondition(store.activeSessionID == id && store.sessionConnectionState == .active)
      precondition(store.phase == .recording && !store.isConversationPresented)
      let connection = await probe.snapshot()
      precondition(
        connection.beginIDs == [id] && connection.finishIDs.isEmpty && connection.cancelIDs.isEmpty)
      precondition(
        connection.activeIDs == [id], "Page navigation must preserve the same analysis session")
    }
    precondition(
      store.events.count >= 4, "Data must continue arriving off-screen, not only the UI timer")
    store.openRecorder()
    precondition(store.activeSessionID == id && store.conversationStepIndex >= 5)
    try await wait { store.phase == .completed }
    let completed = await probe.snapshot()
    precondition(
      completed.beginIDs == [id] && completed.finishIDs == [id] && completed.cancelIDs.isEmpty)
    precondition(completed.analysisIDs.count == 11 && completed.analysisIDs.allSatisfy { $0 == id })
    precondition(completed.lastAnalysisFinishedBeforeFinish)
    precondition(store.review?.utterances.count == 11 && store.review?.events.count == 9)
    precondition(store.activeSessionID == nil && store.sessionConnectionState == .closed)
    store.disconnect()
  }

  @MainActor
  private static func checkConnectionDrainingAndFailures() async throws {
    let recorder = DrainControlledRecorder()
    let probe = SessionLifecycleProbe(analysisDelay: .milliseconds(180))
    let store = AppStore(
      info: [:], persistence: MemoryTrainingPersistence(), recorder: recorder,
      analysis: probe, sessionConnection: probe)
    store.autoAdvance = false
    store.connect()
    try await wait { store.phase == .ready }
    store.simulateStart()
    try await wait { store.sessionConnectionState == .active }
    let id = store.activeSessionID!
    store.advanceConversation()
    store.simulateStop()
    try await Task.sleep(for: .milliseconds(25))
    var snapshot = await probe.snapshot()
    precondition(snapshot.finishIDs.isEmpty, "A hardware stop alone must not finish the session")
    recorder.drain()
    recorder.drain()
    snapshot = await probe.snapshot()
    precondition(
      store.isProcessing && snapshot.finishIDs.isEmpty,
      "Drain must also wait for the final submitted analysis")
    try await wait { store.phase == .completed }
    snapshot = await probe.snapshot()
    precondition(snapshot.beginIDs == [id] && snapshot.finishIDs == [id])
    precondition(snapshot.lastAnalysisFinishedBeforeFinish && store.review?.utterances.count == 1)
    store.disconnect()

    let flushRecorder = DrainControlledRecorder()
    let flushProbe = SessionLifecycleProbe(analysisDelay: .milliseconds(80))
    let flush = AppStore(
      info: [:], persistence: MemoryTrainingPersistence(), recorder: flushRecorder,
      analysis: flushProbe, sessionConnection: flushProbe)
    flush.autoAdvance = false
    flush.connect()
    try await wait { flush.phase == .ready }
    flush.simulateStart()
    try await wait { flush.sessionConnectionState == .active }
    flush.simulateStop()
    precondition(
      flush.acceptTranscribedUtterance(DemoFixtures.steps[0].utterance),
      "A final sentence arriving after physical stop must be accepted before drain")
    flushRecorder.drain()
    precondition(!flush.acceptTranscribedUtterance("late after drain"))
    try await wait { flush.phase == .completed }
    precondition(flush.review?.utterances == [DemoFixtures.steps[0].utterance])
    let flushed = await flushProbe.snapshot()
    precondition(flushed.lastAnalysisFinishedBeforeFinish && flushed.finishIDs.count == 1)
    flush.disconnect()

    for failBegin in [true, false] {
      let failingProbe = SessionLifecycleProbe(failBegin: failBegin, failFinish: !failBegin)
      let failed = AppStore(
        info: [:], persistence: MemoryTrainingPersistence(),
        analysis: failingProbe, sessionConnection: failingProbe)
      failed.autoAdvance = false
      failed.connect()
      try await wait { failed.phase == .ready }
      failed.openRecorder()
      try await wait { failed.sessionConnectionState == (failBegin ? .failed : .active) }
      if failBegin {
        failed.dismissConversation()
        precondition(
          failed.phase == .recording, "A connection error must not fabricate hardware completion")
      }
      failed.simulateStop()
      try await wait { failed.phase == .ready }
      precondition(failed.activeSessionID == nil && failed.sessionConnectionState == .failed)
      precondition(failed.review == nil && failed.history.isEmpty && failed.errorMessage != nil)
      precondition(!failed.isConversationPresented)
      failed.disconnect()
    }
  }

  @MainActor
  private static func checkOldConnectionIsolation() async throws {
    for duringBegin in [true, false] {
      let probe = SessionLifecycleProbe(
        firstBeginDelay: duringBegin ? .milliseconds(180) : .zero,
        finishDelay: duringBegin ? .zero : .milliseconds(180),
        cancelDelay: .milliseconds(120))
      let recorder = DrainControlledRecorder()
      let store = AppStore(
        info: [:], persistence: MemoryTrainingPersistence(), recorder: recorder,
        analysis: probe, sessionConnection: probe)
      store.autoAdvance = false
      store.connect()
      try await wait { store.phase == .ready }
      store.simulateStart()
      let oldID = store.activeSessionID!
      try await waitAsync { (await probe.snapshot()).beginIDs.contains(oldID) }
      if !duringBegin {
        try await wait { store.sessionConnectionState == .active }
        store.simulateStop()
        recorder.drain()
        try await waitAsync { (await probe.snapshot()).finishIDs.contains(oldID) }
      }
      store.cancelSession()
      store.connect()
      try await wait { store.phase == .ready }
      store.simulateStart()
      let newID = store.activeSessionID!
      precondition(newID != oldID)
      try await wait { store.sessionConnectionState == .active }
      try await Task.sleep(for: .milliseconds(320))
      let snapshot = await probe.snapshot()
      precondition(store.activeSessionID == newID && store.phase == .recording)
      precondition(snapshot.activeIDs == [newID] && snapshot.cancelIDs.contains(oldID))
      precondition(
        !snapshot.cancelIDs.contains(newID),
        "Delayed cleanup for an old ID must not close the new session")
      store.cancelSession()
    }
    // The production Mock also retains tombstones when cancel precedes begin.
    let connection = MockTrainingSessionConnection()
    let oldID = UUID()
    let newID = UUID()
    await connection.cancel(sessionID: oldID)
    do {
      try await connection.begin(sessionID: oldID)
      preconditionFailure("Canceled session was resurrected")
    } catch is CancellationError {}
    try await connection.begin(sessionID: newID)
    await connection.cancel(sessionID: oldID)
    try await connection.finish(sessionID: newID)
    try await connection.finish(sessionID: newID)
  }

  @MainActor
  private static func checkEndIntentAndBackpressure() async throws {
    let nonFinishing = ["休息一下", "先退出页面，训练继续", "练不动了", "不要结束训练", "结束训练吗？"]
    for text in nonFinishing {
      precondition(DemoTrainingEndIntentPolicy.classify(text) != .complete)
    }
    let store = AppStore(
      info: [:], persistence: MemoryTrainingPersistence(),
      analysis: IntentAnalysisProbe(intent: .complete, isSimulated: true))
    store.autoAdvance = false
    store.connect()
    try await wait { store.phase == .ready }
    store.openRecorder()
    let id = store.activeSessionID!
    // An erroneous Mock completion flag cannot turn rest/navigation into session end.
    for text in nonFinishing {
      precondition(store.acceptTranscribedUtterance(text))
      try await wait { !store.isProcessing }
      precondition(
        store.phase == .recording && store.activeSessionID == id && !store.finishRequested)
    }
    precondition(store.acceptTranscribedUtterance("休息一下，再做下一组"))
    let acceptedSecond = store.acceptTranscribedUtterance("去看历史页面，继续训练")
    precondition(
      !acceptedSecond,
      "A busy session must explicitly reject, never silently consume, a final sentence")
    try await wait { !store.isProcessing }
    precondition(store.acceptTranscribedUtterance("去看历史页面，继续训练"))
    try await wait { !store.isProcessing }
    precondition(Array(store.utterances.suffix(2)) == ["休息一下，再做下一组", "去看历史页面，继续训练"])
    precondition(store.acceptTranscribedUtterance(DemoFixtures.steps.last!.utterance))
    try await wait { store.phase == .completed }
    precondition(
      store.finishRequested && store.review?.utterances.last == DemoFixtures.steps.last!.utterance)
    store.disconnect()

    // Confirmed final intent from a real adapter is not restricted by demo phrases.
    let confirmed = AppStore(
      info: [:], persistence: MemoryTrainingPersistence(),
      analysis: IntentAnalysisProbe(intent: .complete, isSimulated: false))
    confirmed.autoAdvance = false
    confirmed.connect()
    try await wait { confirmed.phase == .ready }
    confirmed.simulateStart()
    precondition(confirmed.acceptTranscribedUtterance("That's all for my workout."))
    try await wait { confirmed.phase == .completed }
    confirmed.disconnect()

    let hardware = HardwareProbe()
    let partial = AppStore(
      info: [:], persistence: MemoryTrainingPersistence(), recorder: hardware,
      analysis: IntentAnalysisProbe(intent: .complete, isSimulated: false, isFinal: false,
        updatesRecord: true))
    partial.connect()
    try await wait { partial.phase == .ready }
    hardware.onEvent?(.recordingStarted)
    precondition(partial.acceptTranscribedUtterance("训练结束…"))
    try await wait { !partial.isProcessing }
    precondition(
      !partial.finishRequested && partial.phase == .recording && partial.utterances.isEmpty
        && partial.events.isEmpty)
    precondition(partial.recordUpdateFeedback == nil,
      "An unfinished analysis cannot acknowledge a successful record update")
    partial.disconnect()

    let actualStop = AppStore(
      info: [:], persistence: MemoryTrainingPersistence(), recorder: hardware,
      analysis: IntentAnalysisProbe(intent: .complete, isSimulated: false, updatesRecord: true))
    actualStop.connect()
    try await wait { actualStop.phase == .ready }
    hardware.onEvent?(.recordingStarted)
    precondition(actualStop.acceptTranscribedUtterance("Finished for today."))
    try await wait { !actualStop.isProcessing }
    precondition(actualStop.finishRequested && actualStop.phase == .recording)
    precondition(!actualStop.events.isEmpty && actualStop.recordUpdateFeedback == nil,
      "Confirmed completion takes priority over record feedback while hardware stop is pending")
    precondition(
      actualStop.sessionConnectionState == .active,
      "AI intent must not fake a physical hardware stop")
    hardware.onEvent?(.recordingStopped)
    hardware.onEvent?(.transferDrained)
    try await wait { actualStop.phase == .ready }
    precondition(actualStop.activeSessionID == nil && actualStop.review == nil)
    actualStop.disconnect()
  }

  @MainActor
  private static func checkFailedFinalRecoveryAndText() async throws {
    let store = AppStore(info: [:], persistence: MemoryTrainingPersistence(),
      analysis: FailOnceAnalysis())
    store.autoAdvance = false
    store.connect()
    try await wait { store.phase == .ready }
    store.simulateStart()
    try await wait { store.sessionConnectionState == .active }
    store.advanceConversation()
    store.simulateStop()
    try await wait { store.pendingInput != nil }
    precondition(store.phase == .finishing && store.review == nil && store.events.isEmpty)
    precondition(store.analysisIssue == .service && store.inputHistory.count == 1)
    precondition(store.recordUpdateFeedback == nil,
      "A failed analysis keeps the original input without claiming record success")
    let firstID = store.inputHistory[0].id
    store.dismissConversation()
    precondition(store.pendingInput?.id == firstID && store.sessionConnectionState == .active)
    store.retryPendingAnalysis()
    try await wait { store.phase == .completed }
    precondition(store.review?.events.count == 1 && store.pendingInput == nil)
    precondition(store.inputHistory.count == 1 && store.inputHistory[0].state == .understood)
    precondition(store.review?.utterances == [DemoFixtures.steps[0].utterance])
    precondition(store.recordUpdateFeedback == nil,
      "Finishing an interrupted final operation must not leave live-recording feedback")
    store.disconnect()

    let text = AppStore(info: [:], persistence: MemoryTrainingPersistence(),
      analysis: IntentAnalysisProbe(intent: .continueTraining, isSimulated: false))
    text.autoAdvance = false
    text.connect()
    try await wait { text.phase == .ready }
    text.simulateStart()
    try await wait { text.canSubmitText }
    precondition(!text.submitTrainingText(" \n "))
    precondition(text.submitTrainingText("今天做了深蹲，重量暂时不记得"))
    precondition(!text.submitTrainingText("不能抢占上一条"))
    try await wait { !text.isProcessing }
    precondition(text.utterances == ["今天做了深蹲，重量暂时不记得"])
    precondition(text.inputHistory[0].source == .text && text.events.isEmpty)
    precondition(text.recordUpdateFeedback == nil,
      "A successful AI response without changed training events is not a record update")
    text.cancelSession()

    let preview = AppStore(info: [:], persistence: MemoryTrainingPersistence(),
      analysis: MockTrainingAnalysisService(latency: .zero, reviewLatency: .zero))
    preview.autoAdvance = false
    preview.previewNextAnalysisFailure = true
    preview.connect()
    try await wait { preview.phase == .ready }
    preview.simulateStart()
    preview.advanceConversation()
    try await wait { preview.analysisIssue == .clarification }
    precondition(preview.phase == .recording && preview.utterances.isEmpty)
    precondition(preview.recordUpdateFeedback == nil)
    precondition(!preview.acceptTranscribedUtterance("另一个终稿由调用方保留"))
    preview.retryPendingAnalysis()
    try await wait { !preview.isProcessing }
    precondition(preview.events.count == 1 && preview.inputHistory.count == 1)
    precondition(preview.recordUpdateFeedback?.inputID == preview.inputHistory[0].id,
      "A successful retry acknowledges the original input instead of creating a duplicate")
    preview.cancelSession()
    precondition(preview.recordUpdateFeedback == nil)

    let encoded = try CloudHistoryClient.encoder().encode(
      TrainingReview(date: Date(timeIntervalSince1970: 1700000000), durationSeconds: 60,
        events: [], summary: "真实输入未形成动作", suggestions: [], isSimulated: false))
    let restored = try CloudHistoryClient.decoder().decode(TrainingReview.self, from: encoded)
    precondition(restored.date == Date(timeIntervalSince1970: 1700000000))
  }

  private static func checkRecordUpdateFeedbackTiming() {
    let started = ContinuousClock.now
    let receipt = TrainingRecordUpdateFeedback(
      sessionID: UUID(), inputID: UUID(), startedAt: started)
    func opacity(_ milliseconds: Int, reduced: Bool = false) -> Double {
      receipt.opacity(at: started.advanced(by: .milliseconds(milliseconds)), reduceMotion: reduced)
    }
    precondition(opacity(0) == 1 && opacity(2999) == 1 && opacity(3000) == 1,
      "A successful record update remains fully visible for all three seconds")
    let early = opacity(3100)
    let middle = opacity(3325)
    let late = opacity(3600)
    precondition(early < 1 && early > middle && middle > late && late > 0,
      "The next 650 milliseconds progressively lower opacity without flashing")
    precondition(middle < 0.5, "The fade eases out instead of disappearing abruptly at the end")
    precondition(opacity(3650) == 0 && opacity(10000) == 0,
      "Expired feedback remains hidden even when the page is rendered again")
    precondition(opacity(2999, reduced: true) == 1 && opacity(3000, reduced: true) == 0,
      "Reduce Motion preserves the three-second hold and skips the fade")

    let wallTime = Date(timeIntervalSince1970: 1_700_000_000)
    let refreshes = receipt.refreshDates(from: wallTime, at: started)
    precondition(!refreshes.isEmpty && refreshes == refreshes.sorted())
    precondition(refreshes.allSatisfy {
      $0 >= wallTime && $0 <= wallTime.addingTimeInterval(3.651)
    }, "The animation must have a bounded refresh schedule ending at its expiry")
    let resumed = receipt.refreshDates(
      from: wallTime, at: started.advanced(by: .milliseconds(3400)))
    precondition(resumed.allSatisfy { $0 <= wallTime.addingTimeInterval(0.251) },
      "Returning during the fade schedules only the remaining time, never another full hold")
    let expired = receipt.refreshDates(
      from: wallTime, at: started.advanced(by: .seconds(10)))
    precondition(expired.allSatisfy { $0 <= wallTime },
      "Expired feedback must not schedule an ongoing animation")
  }

  @MainActor
  private static func checkRecordUpdateFeedback() async throws {
    let store = AppStore(info: [:], persistence: MemoryTrainingPersistence(),
      analysis: IntentAnalysisProbe(intent: .continueTraining, isSimulated: false,
        updatesRecord: true))
    store.autoAdvance = false
    store.connect()
    try await wait { store.phase == .ready }
    store.simulateStart()
    try await wait { store.canSubmitText }
    precondition(store.recordUpdateFeedback == nil)
    precondition(store.submitTrainingText("第一组深蹲做了十次"))
    precondition(store.recordUpdateFeedback == nil,
      "Submitting an input cannot announce success before analysis completes")
    try await wait { !store.isProcessing }
    guard let first = store.recordUpdateFeedback else {
      preconditionFailure("A final, committed event update must emit success feedback")
    }
    precondition(first.sessionID == store.activeSessionID && first.inputID == store.inputHistory.last?.id)
    let eventID = store.events[0].id
    let originalRepetitions = store.events[0].repetitions
    store.dismissConversation()
    for tab in [AppStore.Tab.today, .history, .insights, .profile] { store.selectedTab = tab }
    store.openRecorder()
    precondition(store.recordUpdateFeedback?.id == first.id
      && store.recordUpdateFeedback?.startedAt == first.startedAt,
      "Page navigation must preserve the receipt and its original three-second deadline")

    precondition(store.submitTrainingText("更正，刚才实际做了十一次"))
    precondition(store.recordUpdateFeedback == nil,
      "A new analysis must not display the preceding input's success status")
    try await wait { !store.isProcessing }
    precondition(store.events.count == 1 && store.events[0].id == eventID
      && store.events[0].repetitions != originalRepetitions)
    guard let corrected = store.recordUpdateFeedback else {
      preconditionFailure("Changing a committed event with the same ID is also a record update")
    }
    precondition(corrected.id != first.id && corrected.startedAt > first.startedAt
      && corrected.inputID == store.inputHistory.last?.id,
      "Each distinct successful input owns a fresh feedback interval")
    store.simulateStop()
    precondition(store.recordUpdateFeedback == nil,
      "Ending training clears live-recording feedback immediately")
    try await wait { store.phase == .completed }
    store.simulateStart()
    precondition(store.recordUpdateFeedback == nil && store.activeSessionID != first.sessionID,
      "A new session must not inherit a previous session's receipt")
    try await wait { store.canSubmitText }
    precondition(store.submitTrainingText("新训练的第一组"))
    try await wait { !store.isProcessing }
    precondition(store.recordUpdateFeedback != nil)
    store.disconnect()
    precondition(store.recordUpdateFeedback == nil,
      "Disconnecting clears feedback together with live-session ownership")

    // The second fixture changes exercise context and transcript but adds no event.
    let unchanged = AppStore(info: [:], persistence: MemoryTrainingPersistence(), analysis: quickAnalysis)
    unchanged.autoAdvance = false
    unchanged.connect()
    try await wait { unchanged.phase == .ready }
    unchanged.simulateStart()
    try await advance(unchanged, through: 1)
    precondition(unchanged.recordUpdateFeedback != nil)
    let recordedEvents = unchanged.events
    try await advance(unchanged, through: 2)
    precondition(unchanged.events == recordedEvents && unchanged.recordUpdateFeedback == nil,
      "Changed context or a new utterance alone must not retrigger record-success feedback")
    unchanged.cancelSession()
  }

  @MainActor
  private static func checkLiveCloudQueue() async throws {
    let probe = LiveUploadProbe(failures: 1, latency: .milliseconds(50))
    let publisher = CloudLivePublisher(retryDelay: .milliseconds(10)) { id, snapshot in
      try await probe.upload(id, snapshot)
    }
    let id = UUID()
    let publisherID = UUID()
    func snapshot(_ sequence: Int, _ phase: CloudLiveSnapshot.Phase) -> CloudLiveSnapshot {
      CloudLiveSnapshot(publisher_id: publisherID, sequence: sequence, phase: phase, elapsed_seconds: 4,
        device: .init(name: "Test bean", connected: true, recording: phase == .recording, simulated: true),
        stages: .init(recording: phase == .recording ? .active : .complete,
          transcription: .idle, analysis: .complete, review: phase == .completed ? .complete : .idle),
        analysis_issue: nil, latest_utterance: "", coach_reply: "", record_count: 1,
        is_simulated: true, review_id: phase == .completed ? id : nil)
    }
    publisher.enqueue(sessionID: id, snapshot: snapshot(1, .recording))
    try await waitAsync { await probe.attempts.count == 1 }
    publisher.enqueue(sessionID: id, snapshot: snapshot(2, .recording))
    publisher.enqueue(sessionID: id, snapshot: snapshot(3, .finishing))
    publisher.enqueue(sessionID: id, snapshot: snapshot(4, .completed))
    try await waitAsync { await probe.successes.count == 2 }
    let sent = await probe.successes
    precondition(sent.map { $0.1.sequence } == [1, 4],
      "Opening recording is retried before the newest coalesced terminal state")
    let maximum = await probe.maximumConcurrent
    precondition(maximum == 1, "Live uploads must be serialized")
    let encoded = try CloudHistoryClient.encoder().encode(sent[1].1)
    let decoded = try CloudHistoryClient.decoder().decode(CloudLiveSnapshot.self, from: encoded)
    precondition(decoded == sent[1].1)
    publisher.invalidate()

    // A cancellation-ignoring transport cannot mutate a replacement owner's UI.
    let lateProbe = LiveUploadProbe(failures: 0, latency: .milliseconds(60))
    var statusUpdates = 0
    let retired = CloudLivePublisher(onStatus: { _ in statusUpdates += 1 }) { id, snapshot in
      try await lateProbe.upload(id, snapshot)
    }
    retired.enqueue(sessionID: id, snapshot: snapshot(1, .recording))
    try await waitAsync { await lateProbe.attempts.count == 1 }
    retired.invalidate()
    try await Task.sleep(for: .milliseconds(90))
    precondition(statusUpdates == 0, "Retired client callbacks must not affect current UI state")
  }

  @MainActor
  private static func checkLiveCloudLifecycle() async throws {
    let probe = LiveUploadProbe(failures: 0, latency: .milliseconds(1))
    let publisher = CloudLivePublisher(retryDelay: .milliseconds(10)) { id, snapshot in
      try await probe.upload(id, snapshot)
    }
    let store = AppStore(info: [:], persistence: MemoryTrainingPersistence(), analysis: quickAnalysis,
      livePublisher: publisher, liveHeartbeatDelay: .milliseconds(35))
    store.autoAdvance = false
    store.connect()
    try await wait { store.phase == .ready }
    let before = await probe.attempts
    precondition(before.isEmpty, "Connected is not evidence of recording")
    store.simulateStart()
    try await wait { store.canSubmitText }
    try await waitAsync { !(await probe.successes.isEmpty) }
    let first = await probe.successes[0]
    precondition(first.1.phase == .recording && first.1.device.connected == true
      && first.1.device.recording == true && first.1.stages.transcription == .idle && first.1.is_simulated)
    store.dismissConversation()
    store.selectedTab = .profile
    let count = await probe.successes.count
    try await waitAsync { await probe.successes.count > count }
    precondition(store.phase == .recording, "Navigation preserves recording and the live heartbeat")
    try await advance(store, through: 1)
    try await waitAsync { await probe.successes.last?.1.record_count == 1 }
    store.previewNextAnalysisFailure = true
    store.advanceConversation()
    try await wait { store.pendingInput != nil }
    try await waitAsync { await probe.successes.last?.1.stages.analysis == .attention }
    store.retryPendingAnalysis()
    try await wait { store.pendingInput == nil && !store.isProcessing }
    store.simulateStop()
    try await wait { store.phase == .completed }
    try await waitAsync { await probe.successes.last?.1.phase == .completed }
    let completed = await probe.successes.last!
    precondition(completed.0 == first.0 && completed.1.review_id == store.review?.id
      && completed.1.device.connected == true && completed.1.device.recording == false)
    let afterCompletion = await probe.successes.count
    try await Task.sleep(for: .milliseconds(90))
    let afterWaiting = await probe.successes.count
    precondition(afterWaiting == afterCompletion,
      "A completed session must not be revived by heartbeat")
    store.saveReview()
    precondition(store.history.count == 1)
    store.simulateStart()
    try await waitAsync { await probe.successes.last?.0 != first.0 }
    store.cancelSession()
    try await waitAsync { await probe.successes.last?.1.phase == .cancelled }
    let all = await probe.successes
    precondition(all.filter { $0.0 == first.0 }.map { $0.1.sequence }
      == all.filter { $0.0 == first.0 }.map { $0.1.sequence }.sorted())
    precondition(all.last?.1.device.recording == nil && all.last?.1.device.connected == false,
      "Cancellation without hardware stop acknowledgement cannot claim the bean stopped recording")
    publisher.invalidate()

    let failing = LiveUploadProbe(failures: 100, latency: .milliseconds(1))
    let unavailable = CloudLivePublisher(retryDelay: .milliseconds(20)) { id, snapshot in
      try await failing.upload(id, snapshot)
    }
    let offline = AppStore(info: [:], persistence: MemoryTrainingPersistence(), analysis: quickAnalysis,
      livePublisher: unavailable, liveHeartbeatDelay: .milliseconds(35))
    offline.autoAdvance = false
    offline.connect()
    try await wait { offline.phase == .ready }
    offline.simulateStart()
    try await advance(offline, through: 1)
    offline.simulateStop()
    try await wait { offline.phase == .completed }
    offline.saveReview()
    precondition(offline.history.count == 1 && offline.errorMessage == nil,
      "Status upload failures must not stop recording, review generation or local save")
    unavailable.invalidate()

    let hardwareUploads = LiveUploadProbe(failures: 0, latency: .milliseconds(1))
    let hardwarePublisher = CloudLivePublisher { id, snapshot in
      try await hardwareUploads.upload(id, snapshot)
    }
    let hardware = HardwareProbe()
    let hardwareStore = AppStore(info: [:], persistence: MemoryTrainingPersistence(), recorder: hardware,
      livePublisher: hardwarePublisher)
    hardwareStore.autoAdvance = false
    hardwareStore.connect()
    try await wait { hardwareStore.phase == .ready }
    hardware.onEvent?(.recordingStarted)
    try await wait { hardwareStore.canSubmitText }
    hardware.onEvent?(.disconnected)
    try await waitAsync { await hardwareUploads.successes.last?.1.phase == .disconnected }
    let lostHardware = await hardwareUploads.successes.last!.1
    precondition(lostHardware.device.connected == false && lostHardware.device.recording == nil
      && lostHardware.stages.recording == .unknown,
      "Disconnecting Bluetooth cannot assert that physical recording stopped")

    hardwareStore.connect()
    try await wait { hardwareStore.phase == .ready }
    hardware.onEvent?(.recordingStarted)
    try await wait { hardwareStore.canSubmitText }
    let failedSessionID = hardwareStore.activeSessionID
    hardware.onEvent?(.recordingStopped)
    hardware.onEvent?(.transferDrained)
    try await wait { hardwareStore.phase == .ready }
    try await waitAsync {
      let last = await hardwareUploads.successes.last
      return last?.0 == failedSessionID && last?.1.phase == .cancelled
    }
    let failedAnalysis = await hardwareUploads.successes.last!.1
    precondition(failedAnalysis.device.connected == true && failedAnalysis.device.recording == false,
      "Analysis failure does not disconnect the bean; prior hardware stop remains confirmed")
    hardwarePublisher.invalidate()
  }

  @MainActor
  private static func checkBackendTextAnalysis() async throws {
    let client = try CloudHistoryClient(url: "https://fitcore.example.invalid", accessToken: "test-only-fitcore-token")
    let probe = TextBackendProbe()
    let adapter = BackendTrainingAnalysisService(client: client) { request in try await probe.respond(request) }
    let store = AppStore(info: ["FITCORE_ANALYSIS_MODE": "backend"], persistence: MemoryTrainingPersistence(),
      analysis: adapter, automaticStepDelay: .milliseconds(1), firstStepDelay: .milliseconds(1))
    store.connect()
    try await wait { store.phase == .ready }
    store.openRecorder()
    try await wait { store.canSubmitText }
    store.advanceConversation()
    try await Task.sleep(for: .milliseconds(30))
    precondition(store.utterances.isEmpty && store.inputHistory.isEmpty, "Real text mode cannot autoplay fixtures")
    precondition(!store.acceptTranscribedUtterance("假转录"), "Text-only adapter must not mislabel speech as typed input")
    precondition(store.submitTrainingText("卧推60公斤10次"))
    try await wait { store.analysisIssue == .backend(.timeout) }
    let firstID = store.pendingInput!.id
    precondition(store.events.isEmpty && !store.canSupplementPending)
    precondition(!store.submitTrainingText("补充内容"), "An uncertain failed delivery must be retried before supplementing")
    store.dismissConversation()
    precondition(store.phase == .recording, "Navigation must keep text session alive")
    store.retryPendingAnalysis()
    try await wait { !store.isProcessing && store.events.count == 1 }
    let first = store.events[0]
    precondition(first.exercise == "卧推" && first.weightKilograms == 60 && first.repetitions == 10)
    precondition(first.sourceInputIDs == [firstID] && first.revision == 1)
    precondition(store.inputHistory.count == 1 && store.pendingInput == nil)
    var edited = first
    edited.repetitions = 99
    store.correctEvent(edited)
    precondition(store.events[0].repetitions == 10, "Backend-authoritative records cannot diverge via local edits")
    precondition(store.submitTrainingText("上一组其实是八次"))
    try await wait { !store.isProcessing && store.events.first?.repetitions == 8 }
    let corrected = store.events[0]
    precondition(store.events.count == 1 && corrected.id == first.id && corrected.weightKilograms == 60)
    precondition(corrected.sourceInputIDs?.count == 2 && corrected.revision == 2)
    precondition(store.submitTrainingText("又做了一组"))
    try await wait { store.canSupplementPending && store.pendingInput != nil }
    let ambiguousID = store.pendingInput!.id
    precondition(store.events.count == 1 && store.utterances.last == "又做了一组")
    precondition(store.submitTrainingText("深蹲12次"))
    try await wait { !store.isProcessing && store.events.count == 2 }
    let incomplete = store.events[1]
    precondition(incomplete.exercise == "深蹲" && !incomplete.hasRecordedWeight && incomplete.hasRecordedRepetitions)
    precondition(incomplete.setDescription.contains("重量待补充"))
    let requests = await probe.requests
    precondition(requests.count == 5 && requests[0].input_id == requests[1].input_id)
    precondition(requests[2].expected_revision == 1 && requests[4].expected_revision == 3)
    precondition(requests[4].text == "深蹲12次" && requests[4].clarifies_input_id == ambiguousID,
      "Clarification must send a raw source sentence plus its source link")
    precondition(store.submitTrainingText("超出上下文"))
    try await waitAsync { await probe.contextLimitIsWaiting }
    store.simulateStop()
    precondition(store.phase == .finishing && store.isProcessing,
      "Hardware stop and drain must complete while the analysis response is still pending")
    await probe.releaseContextLimit()
    try await wait { store.phase == .completed }
    let review = store.review!
    precondition(review.isTextRecordSummary && review.displayCalories == nil && review.suggestions.isEmpty)
    precondition(!review.sessionTitle.contains("胸部") && review.bench.isEmpty && review.fly.isEmpty)
    precondition(review.events == store.events && review.inputHistory?.count == 5 && review.hasPendingInputs)
    precondition(review.inputHistory?.last?.text == "超出上下文",
      "A bounded-context stop preserves the unprocessed original without adding a fake event")
    let saved = try JSONDecoder().decode(TrainingReview.self, from: JSONEncoder().encode(review))
    precondition(saved == review && saved.events[0].sourceInputIDs == corrected.sourceInputIDs)

    let input = PendingTrainingInput(id: UUID(), text: "卧推60公斤10次", source: .text, isDemoStep: false)
    for (code, expected) in [("llm_auth", BackendTrainingError.auth), ("llm_rate_limit", .rateLimit),
      ("llm_not_configured", .notConfigured), ("llm_invalid_output", .invalidOutput),
      ("llm_context_limit", .contextLimit),
      ("session_conflict", .sessionConflict), ("unknown-code", .unavailable)] {
      let failing = BackendTrainingAnalysisService(client: client) { request in
        let data = try JSONSerialization.data(withJSONObject: ["detail": ["code": code, "message": "secret-provider-body"]])
        return (data, HTTPURLResponse(url: request.url!, statusCode: 503, httpVersion: nil, headerFields: nil)!)
      }
      do {
        _ = try await failing.analyzeInput(input, context: TrainingContext(), sessionID: UUID())
        preconditionFailure("Provider error must not produce a record")
      } catch let error as BackendTrainingError {
        precondition(error == expected && !error.localizedDescription.contains("secret-provider-body"))
      }
    }
    let malformed = BackendTrainingAnalysisService(client: client) { request in
      (Data("{}".utf8), HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
    }
    do {
      _ = try await malformed.analyzeInput(input, context: TrainingContext(), sessionID: UUID())
      preconditionFailure("Malformed response must not be accepted")
    } catch BackendTrainingError.invalidOutput {}
  }

  @MainActor
  private static func checkHardwareBoundary() async throws {
    let recorder = HardwareProbe()
    let store = AppStore(info: [:], persistence: MemoryTrainingPersistence(), recorder: recorder)
    store.connect()
    try await wait { store.phase == .ready }
    store.openRecorder()
    store.simulateStart()
    precondition(store.phase == .ready, "A real gateway must require a hardware start event")
    recorder.onEvent?(.recordingStarted)
    store.advanceConversation()
    precondition(
      store.utterances.isEmpty && !store.isProcessing,
      "Real hardware cannot silently replay Mock text")
    recorder.onEvent?(
      .audioPacket(
        AudioPacket(
          fileID: 1, sequenceNumber: 1, payload: Data([1]), isMarked: false, isAppendPreAudio: false
        )))
    recorder.onEvent?(.recordingStopped)
    recorder.onEvent?(.transferDrained)
    try await wait { store.phase == .ready }
    precondition(store.review == nil && store.errorMessage != nil && store.phase == .ready)
    store.disconnect()
  }

  @MainActor
  private static func advance(_ store: AppStore, through count: Int) async throws {
    while store.conversationStepIndex < count {
      let next = store.conversationStepIndex + 1
      store.advanceConversation()
      try await wait { store.conversationStepIndex >= next && !store.isProcessing }
    }
  }

  @MainActor
  private static func wait(_ condition: () -> Bool) async throws {
    let deadline = ContinuousClock.now.advanced(by: .seconds(5))
    while !condition() {
      precondition(ContinuousClock.now < deadline, "Timed out waiting for core state transition")
      try await Task.sleep(for: .milliseconds(10))
    }
  }

  @MainActor
  private static func waitAsync(_ condition: () async -> Bool) async throws {
    let deadline = ContinuousClock.now.advanced(by: .seconds(5))
    while !(await condition()) {
      precondition(ContinuousClock.now < deadline, "Timed out waiting for session probe")
      try await Task.sleep(for: .milliseconds(10))
    }
  }
}

/// A stateful fake server that commits an input then loses its first response.
/// This checks the native retry and correction contract without calling a model.
private actor TextBackendProbe {
  private(set) var requests: [BackendTrainingAnalysisService.Request] = []
  private var accepted: [BackendTrainingAnalysisService.Request] = []
  private let eventID = UUID()
  private let secondEventID = UUID()
  private var contextLimitContinuation: CheckedContinuation<Void, Never>?
  var contextLimitIsWaiting: Bool { contextLimitContinuation != nil }
  func releaseContextLimit() {
    contextLimitContinuation?.resume()
    contextLimitContinuation = nil
  }
  func respond(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
    precondition(request.httpMethod == "POST")
    precondition(request.value(forHTTPHeaderField: "Authorization") == "Bearer test-only-fitcore-token")
    let input = try JSONDecoder().decode(BackendTrainingAnalysisService.Request.self, from: request.httpBody!)
    precondition(input.source == "text")
    requests.append(input)
    if input.text == "超出上下文" {
      await withCheckedContinuation { contextLimitContinuation = $0 }
      let data = try JSONSerialization.data(withJSONObject: ["detail": ["code": "llm_context_limit"]])
      return (data, HTTPURLResponse(url: request.url!, statusCode: 422, httpVersion: nil, headerFields: nil)!)
    }
    if !accepted.contains(where: { $0.input_id == input.input_id }) { accepted.append(input) }
    let sessionID = request.url!.deletingLastPathComponent().lastPathComponent
    let corrected = accepted.contains { $0.text == "上一组其实是八次" }
    let firstSources = accepted.filter { $0.text == "卧推60公斤10次" || $0.text == "上一组其实是八次" }
    var events: [[String: Any]] = [["id": eventID.uuidString, "revision": corrected ? 2 : 1,
      "exercise": "卧推", "weight_kg": 60, "repetitions": corrected ? 8 : 10, "feeling": "",
      "source_text": firstSources.map(\.text).joined(separator: "\n"),
      "source_input_ids": firstSources.map { $0.input_id.uuidString }, "set_number": 1]]
    if let supplement = accepted.first(where: { $0.text == "深蹲12次" }) {
      events.append(["id": secondEventID.uuidString, "revision": 1, "exercise": "深蹲",
        "weight_kg": NSNull(), "repetitions": 12, "feeling": "", "source_text": "又做了一组\n深蹲12次",
        "source_input_ids": [supplement.clarifies_input_id!.uuidString, supplement.input_id.uuidString], "set_number": 1])
    }
    if requests.count == 1 { throw URLError(.timedOut) }
    let needsClarification = input.text == "又做了一组"
    let object: [String: Any] = ["session_id": sessionID, "input_id": input.input_id.uuidString,
      "revision": accepted.count, "status": needsClarification ? "needs_clarification" : "recorded",
      "message": needsClarification ? "请补充这一组的动作和次数。" : "已按原话整理训练记录。", "events": events,
      "inputs": accepted.map { ["id": $0.input_id.uuidString, "text": $0.text, "source": "text"] }]
    return (try JSONSerialization.data(withJSONObject: object),
      HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
  }
}

private actor LiveUploadProbe {
  enum Failure: Error { case offline }
  private var failures: Int
  private let latency: Duration
  private(set) var attempts: [(UUID, CloudLiveSnapshot)] = []
  private(set) var successes: [(UUID, CloudLiveSnapshot)] = []
  private var concurrent = 0
  private(set) var maximumConcurrent = 0
  init(failures: Int, latency: Duration) { self.failures = failures; self.latency = latency }
  func upload(_ id: UUID, _ snapshot: CloudLiveSnapshot) async throws {
    attempts.append((id, snapshot))
    concurrent += 1
    maximumConcurrent = max(maximumConcurrent, concurrent)
    defer { concurrent -= 1 }
    try? await Task.sleep(for: latency)
    if failures > 0 { failures -= 1; throw Failure.offline }
    successes.append((id, snapshot))
  }
}

private actor FailOnceAnalysis: TrainingAnalysisService {
  private var attempts = 0
  func analyzeUtterance(_ utterance: String, context: TrainingContext, sessionID: UUID) async throws -> TrainingAnalysisUpdate {
    attempts += 1
    try await Task.sleep(for: .milliseconds(30))
    if attempts == 1 { throw TrainingAnalysisError.serviceUnavailable }
    return try await MockTrainingAnalysisService(latency: .zero, reviewLatency: .zero)
      .analyzeUtterance(utterance, context: context, sessionID: sessionID)
  }
  func makeReview(context: TrainingContext, durationSeconds: Int, sessionID: UUID, date: Date) async throws -> TrainingReview {
    try await MockTrainingAnalysisService(latency: .zero, reviewLatency: .zero)
      .makeReview(context: context, durationSeconds: durationSeconds, sessionID: sessionID, date: date)
  }
}

/// These fakes intentionally ignore cancellation to prove revision guards work.
private struct CancellationIgnoringAnalysis: TrainingAnalysisService {
  func analyzeUtterance(_ utterance: String, context: TrainingContext, sessionID: UUID) async throws
    -> TrainingAnalysisUpdate
  {
    try? await Task.sleep(for: .milliseconds(220))
    let step = DemoFixtures.steps[context.utterances.count]
    return TrainingAnalysisUpdate(
      context: context.applying(step), status: step.status,
      coachReply: step.interpretation, question: step.question,
      requestsSessionEnd: step.endSession, isSimulated: true)
  }
  func makeReview(context: TrainingContext, durationSeconds: Int, sessionID: UUID, date: Date)
    async throws -> TrainingReview
  {
    try? await Task.sleep(for: .milliseconds(220))
    return TrainingReview(
      id: sessionID, date: date, durationSeconds: durationSeconds,
      events: context.events, summary: "Cancellation probe", suggestions: [])
  }
}

@MainActor
private final class CancellationIgnoringRecorder: RecorderGateway {
  var onEvent: ((RecorderEvent) -> Void)?
  func connect() async throws -> RecorderDevice {
    try? await Task.sleep(for: .milliseconds(220))
    return RecorderDevice(name: "Cancellation probe", batteryPercent: 80, isSimulated: true)
  }
  func disconnect() { onEvent?(.disconnected) }
}

@MainActor
private final class HardwareProbe: RecorderGateway {
  var onEvent: ((RecorderEvent) -> Void)?
  func connect() async throws -> RecorderDevice {
    RecorderDevice(name: "Hardware boundary probe", batteryPercent: 80, isSimulated: false)
  }
  func disconnect() { onEvent?(.disconnected) }
}

@MainActor
private final class FailingSavePersistence: TrainingPersistence {
  enum Failure: Error { case failed }
  func load() throws -> TrainingLocalState { TrainingLocalState() }
  func save(_ state: TrainingLocalState) throws { throw Failure.failed }
}

private struct ReviewFailureAnalysis: TrainingAnalysisService {
  enum Failure: Error { case failed }
  func analyzeUtterance(_ utterance: String, context: TrainingContext, sessionID: UUID) async throws
    -> TrainingAnalysisUpdate
  {
    throw Failure.failed
  }
  func makeReview(context: TrainingContext, durationSeconds: Int, sessionID: UUID, date: Date)
    async throws -> TrainingReview
  {
    throw Failure.failed
  }
}

@MainActor
private final class DrainControlledRecorder: RecorderGateway, MockRecorderControlling {
  var onEvent: ((RecorderEvent) -> Void)?
  private var recording = false
  func connect() async throws -> RecorderDevice {
    RecorderDevice(name: "Drain-controlled test recorder", batteryPercent: 80, isSimulated: true)
  }
  func disconnect() {
    recording = false
    onEvent?(.disconnected)
  }
  func simulateHardwareStart() {
    guard !recording else { return }
    recording = true
    onEvent?(.recordingStarted)
  }
  func simulateHardwareStop() {
    guard recording else { return }
    recording = false
    onEvent?(.recordingStopped)
  }
  func drain() { onEvent?(.transferDrained) }
}

private actor SessionLifecycleProbe: TrainingSessionConnection, TrainingAnalysisService {
  nonisolated let isSimulated = true
  enum Entry: Equatable, Sendable {
    case begin(UUID)
    case ready(UUID)
    case analyzed(UUID)
    case finish(UUID)
    case finished(UUID)
    case cancel(UUID)
  }
  struct Snapshot: Sendable {
    let entries: [Entry]
    let activeIDs: Set<UUID>
    var beginIDs: [UUID] {
      entries.compactMap {
        if case .begin(let id) = $0 { return id }
        return nil
      }
    }
    var analysisIDs: [UUID] {
      entries.compactMap {
        if case .analyzed(let id) = $0 { return id }
        return nil
      }
    }
    var finishIDs: [UUID] {
      entries.compactMap {
        if case .finish(let id) = $0 { return id }
        return nil
      }
    }
    var cancelIDs: [UUID] {
      entries.compactMap {
        if case .cancel(let id) = $0 { return id }
        return nil
      }
    }
    var lastAnalysisFinishedBeforeFinish: Bool {
      guard
        let last = entries.lastIndex(where: {
          if case .analyzed = $0 { return true }
          return false
        }),
        let finish = entries.firstIndex(where: {
          if case .finish = $0 { return true }
          return false
        })
      else { return false }
      return last < finish
    }
  }
  enum Failure: Error { case begin, finish }
  private var entries: [Entry] = []
  private var activeIDs: Set<UUID> = []
  private var canceledIDs: Set<UUID> = []
  private var finishedIDs: Set<UUID> = []
  private let firstBeginDelay: Duration
  private let finishDelay: Duration
  private let cancelDelay: Duration
  private let analysisDelay: Duration
  private let failBegin: Bool
  private let failFinish: Bool

  init(
    firstBeginDelay: Duration = .zero, finishDelay: Duration = .zero, cancelDelay: Duration = .zero,
    analysisDelay: Duration = .milliseconds(20), failBegin: Bool = false, failFinish: Bool = false
  ) {
    self.firstBeginDelay = firstBeginDelay
    self.finishDelay = finishDelay
    self.cancelDelay = cancelDelay
    self.analysisDelay = analysisDelay
    self.failBegin = failBegin
    self.failFinish = failFinish
  }

  func snapshot() -> Snapshot { Snapshot(entries: entries, activeIDs: activeIDs) }
  func begin(sessionID: UUID) async throws {
    let first = entries.isEmpty
    entries.append(.begin(sessionID))
    if first { await Self.uncancellableDelay(firstBeginDelay) }
    if canceledIDs.contains(sessionID) { throw CancellationError() }
    if failBegin { throw Failure.begin }
    activeIDs.insert(sessionID)
    entries.append(.ready(sessionID))
  }
  func finish(sessionID: UUID) async throws {
    entries.append(.finish(sessionID))
    await Self.uncancellableDelay(finishDelay)
    if canceledIDs.contains(sessionID) { throw CancellationError() }
    if failFinish { throw Failure.finish }
    guard activeIDs.contains(sessionID) || finishedIDs.contains(sessionID) else {
      throw TrainingSessionConnectionError.missingSession
    }
    activeIDs.remove(sessionID)
    finishedIDs.insert(sessionID)
    entries.append(.finished(sessionID))
  }
  func cancel(sessionID: UUID) async {
    canceledIDs.insert(sessionID)
    entries.append(.cancel(sessionID))
    await Self.uncancellableDelay(cancelDelay)
    activeIDs.remove(sessionID)
  }
  func analyzeUtterance(_ utterance: String, context: TrainingContext, sessionID: UUID) async throws
    -> TrainingAnalysisUpdate
  {
    guard activeIDs.contains(sessionID) else { throw TrainingSessionConnectionError.missingSession }
    let update = try await MockTrainingAnalysisService(latency: analysisDelay).analyzeUtterance(
      utterance, context: context, sessionID: sessionID)
    entries.append(.analyzed(sessionID))
    return update
  }
  func makeReview(context: TrainingContext, durationSeconds: Int, sessionID: UUID, date: Date)
    async throws -> TrainingReview
  {
    precondition(
      finishedIDs.contains(sessionID), "Review must be generated after connection finish")
    return try await MockTrainingAnalysisService(reviewLatency: .zero).makeReview(
      context: context, durationSeconds: durationSeconds, sessionID: sessionID, date: date)
  }
  private static func uncancellableDelay(_ duration: Duration) async {
    // Child test delay intentionally outlives cancellation of the calling task.
    await Task.detached { try? await Task.sleep(for: duration) }.value
  }
}

private struct IntentAnalysisProbe: TrainingAnalysisService {
  let intent: TrainingEndIntent
  let isSimulated: Bool
  var isFinal = true
  var updatesRecord = false
  func analyzeUtterance(_ utterance: String, context: TrainingContext, sessionID: UUID) async throws
    -> TrainingAnalysisUpdate
  {
    try await Task.sleep(for: .milliseconds(25))
    var next = context
    next.utterances.append(utterance)
    if updatesRecord {
      if next.events.isEmpty {
        next.events.append(TrainingEvent(exercise: "深蹲", repetitions: 10, sourceText: utterance))
      } else {
        next.events[0].repetitions += 1
      }
    }
    return TrainingAnalysisUpdate(
      context: next, status: "Test response", coachReply: "Test response", question: nil,
      requestsSessionEnd: intent == .complete, isSimulated: isSimulated, endIntent: intent,
      isFinal: isFinal)
  }
  func makeReview(context: TrainingContext, durationSeconds: Int, sessionID: UUID, date: Date)
    async throws -> TrainingReview
  {
    TrainingReview(
      id: sessionID, date: date, durationSeconds: durationSeconds, events: context.events,
      summary: "Test response", suggestions: [], utterances: context.utterances,
      isSimulated: isSimulated)
  }
}
