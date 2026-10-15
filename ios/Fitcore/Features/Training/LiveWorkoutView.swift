import SwiftUI

struct LiveWorkoutView: View {
    @EnvironmentObject private var store: AppStore
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var showHistory = false
    @State private var typedMessage = ""
    @State private var showCancelConfirmation = false
    @FocusState private var typing: Bool

    var body: some View {
        ZStack(alignment: .bottom) {
            FitcoreTheme.canvas.ignoresSafeArea()
            VStack(spacing: 0) {
                topBar.padding(.horizontal, 20).padding(.top, 10)
                ScrollViewReader { proxy in
                    ScrollView {
                        VStack(spacing: 0) {
                            statusArea
                            liveLog
                            Spacer(minLength: 24)
                        }
                        .padding(.horizontal, 20)
                        .frame(maxWidth: 680)
                        .frame(maxWidth: .infinity)
                        .onChange(of: store.utterances.count) { _, _ in
                            withAnimation { proxy.scrollTo("latest", anchor: .bottom) }
                        }
                    }
                    .scrollDismissesKeyboard(.interactively)
                }.safeAreaInset(edge: .bottom, spacing: 0) { bottomControls }
            }
            if showHistory { historyOverlay }
        }
        .preferredColorScheme(.light)
        .statusBarHidden(false)
        // Presenting/dismissing a page never starts or closes a training session.
        // The app-scoped store owns the recorder and analysis connection.
        .onDisappear { showHistory = false }
        .alert("取消本次训练？", isPresented: $showCancelConfirmation) {
            Button("继续记录", role: .cancel) { }
            Button("取消训练", role: .destructive) { store.cancelSession() }
        } message: { Text("本次尚未保存的原话和训练内容将被清除。") }
    }

    private var topBar: some View {
        HStack(alignment: .center) {
            Button {
                store.dismissConversation()
            } label: {
                Image(systemName: "chevron.left").font(.system(size: 16, weight: .semibold))
                    .frame(width: 42, height: 42).background(.white, in: Circle())
            }.buttonStyle(.plain).accessibilityLabel("返回今日")
            VStack(alignment: .leading, spacing: 4) {
                Text("FITCORE · AI COACH").font(.system(size: 9, weight: .bold)).tracking(1.4).foregroundStyle(FitcoreTheme.muted)
                Text("今日训练记录").font(.system(size: 18, weight: .bold))
            }
            Spacer()
            Button("结束训练") {
                store.simulateStop()
            }
            .font(.system(size: 12, weight: .semibold)).foregroundStyle(FitcoreTheme.navy)
            .disabled(store.phase != .recording)
        }
        .foregroundStyle(FitcoreTheme.ink)
    }

    private var statusArea: some View {
        let feedback = store.recordUpdateFeedback
        let status = store.conversationStatus.isEmpty && store.phase != .recording
            ? "录音豆已连接 · 准备开始" : store.conversationStatus
        return VStack(spacing: 12) {
            TimelineView(.explicit(feedback?.refreshDates(reduceMotion: reduceMotion) ?? [Date()])) { _ in
                let opacity = feedback?.opacity(reduceMotion: reduceMotion) ?? (status.isEmpty ? 0 : 1)
                HStack(spacing: 8) {
                    Circle().fill(store.isProcessing ? FitcoreTheme.accent : FitcoreTheme.lime).frame(width: 7, height: 7)
                    Text(feedback != nil || status.isEmpty ? "已更新训练内容" : status)
                        .font(.caption.weight(.medium)).foregroundStyle(FitcoreTheme.navy)
                }
                // Keep the row in layout after fading so the conversation never jumps.
                .frame(minHeight: 16)
                .opacity(opacity)
                .accessibilityHidden(opacity == 0)
                .allowsHitTesting(false)
            }
            Text(store.usesBackendText ? "真实文字分析 · 录音豆与语音仍为模拟" : store.recorderIsSimulated ? "开发预览 · 当前录音为示例，真实 AI 待接入" : "按实际口述记录 · 不确定的内容请补充确认")
                .font(.system(size: 11)).foregroundStyle(FitcoreTheme.muted)
        }
        .padding(.vertical, 18)
    }

    private var liveLog: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text("TRAINING · LIVE LOG").font(.system(size: 10, weight: .bold)).tracking(1.2).foregroundStyle(FitcoreTheme.muted)
                Spacer()
                Text("训练记录中").font(.caption.weight(.medium)).foregroundStyle(FitcoreTheme.accent)
            }
            HStack(alignment: .center) {
                Text("训练对话").font(.title3.weight(.bold))
                Spacer()
                Button { showHistory = true } label: {
                    Label("原话 · \(store.inputHistory.count)", systemImage: "list.bullet.rectangle")
                        .font(.caption.weight(.semibold)).foregroundStyle(FitcoreTheme.navy)
                }.buttonStyle(.plain)
            }
            if store.inputHistory.isEmpty && !store.isProcessing {
                FitcoreCard {
                    VStack(spacing: 14) {
                        Image(systemName: "waveform.and.mic").font(.system(size: 32)).foregroundStyle(FitcoreTheme.accent)
                        Text(store.usesBackendText ? "输入今天实际完成的训练" : "录音豆即将开始模拟训练语音").font(.subheadline.weight(.semibold))
                        Text(store.usesBackendText ? "例如：卧推60公斤10次；未知信息会保持待补充" : "可以等待自动播放，也可以点击下方录音豆立即开始")
                            .font(.caption).foregroundStyle(FitcoreTheme.muted).multilineTextAlignment(.center)
                    }.frame(maxWidth: .infinity).padding(.vertical, 20)
                }
            }
            if store.utterances.count > 1 {
                VStack(spacing: 4) {
                    ForEach(0..<min(2, store.utterances.count - 1), id: \.self) { index in
                        RoundedRectangle(cornerRadius: 8).fill(FitcoreTheme.navy.opacity(index == 0 ? 0.04 : 0.07))
                            .frame(height: 9).padding(.horizontal, index == 0 ? 28 : 14)
                    }
                }.padding(.leading, 50).accessibilityHidden(true)
            }
            if let pending = store.pendingInput {
                conversationRow(index: -1, utterance: pending.text)
            } else if store.isProcessing && !store.currentUtterance.isEmpty {
                conversationRow(index: store.utterances.count, utterance: store.currentUtterance)
            } else if let latest = store.utterances.last {
                conversationRow(index: store.utterances.count - 1, utterance: latest)
            }
            if let issue = store.analysisIssue { recoveryCard(issue) }
            if store.analysisIssue == nil && (store.isProcessing || store.phase == .finishing) {
                processingCard
            }
            if !store.currentQuestion.isEmpty {
                questionCard
            }
            Color.clear.frame(height: 1).id("latest")
        }
    }

    private func recoveryCard(_ issue: TrainingInteractionIssue) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Label(issue.title, systemImage: issue == .clarification ? "bubble.left.and.text.bubble.right" : "exclamationmark.arrow.triangle.2.circlepath")
                .font(.subheadline.weight(.semibold)).foregroundStyle(FitcoreTheme.navy)
            Text(issue.message).font(.subheadline).lineSpacing(4)
            HStack(spacing: 12) {
                Button("重试分析", action: store.retryPendingAnalysis)
                    .buttonStyle(.borderedProminent).tint(FitcoreTheme.accent)
                    .disabled(!store.canSubmitText)
                Button("文字补充") { typing = true }
                    .buttonStyle(.bordered).disabled(!store.canSubmitText || !store.canSupplementPending)
            }
            if store.phase == .finishing {
                Text("录音已结束，这段内容处理成功后再生成完整复盘。")
                    .font(.caption).foregroundStyle(FitcoreTheme.muted)
            } else {
                Text(store.usesBackendText ? (store.canSupplementPending ? "文字会话保持中 · 可补充动作、重量和次数" : "原话已保留 · 请先重试这条原话") : store.recorderIsSimulated ? "模拟训练保持中 · 自动示例等待本段处理" : "录音会话保持中 · 原话不会因页面退出而清除")
                    .font(.caption).foregroundStyle(FitcoreTheme.muted)
            }
            Button("取消本次训练") { showCancelConfirmation = true }
                .font(.caption).foregroundStyle(FitcoreTheme.muted)
        }
        .frame(maxWidth: .infinity, alignment: .leading).padding(17)
        .background(Color(red: 1, green: 0.96, blue: 0.86), in: RoundedRectangle(cornerRadius: 20))
        .accessibilityElement(children: .contain)
    }

    private var processingCard: some View {
        HStack(spacing: 14) {
            Circle().fill(FitcoreTheme.accent.opacity(0.1)).frame(width: 42, height: 42)
                .overlay(ProgressView().tint(FitcoreTheme.accent))
            VStack(alignment: .leading, spacing: 5) {
                Text(store.conversationStatus.isEmpty ? "正在聆听你的训练记录" : store.conversationStatus).font(.subheadline.weight(.semibold))
                Text(store.usesBackendText ? "后端模型正在分析这一段文字…" : "录音豆正在整理这一段口述…").font(.caption).foregroundStyle(FitcoreTheme.muted)
            }
            Spacer()
        }.padding(16).background(.white, in: RoundedRectangle(cornerRadius: 18))
    }

    private func conversationRow(index: Int, utterance: String) -> some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack(alignment: .top, spacing: 10) {
                Spacer(minLength: 36)
                VStack(alignment: .trailing, spacing: 7) {
                    Text(utterance).font(.system(size: 17, weight: .medium)).foregroundStyle(FitcoreTheme.ink).lineSpacing(5)
                        .padding(20).background(.white, in: RoundedRectangle(cornerRadius: 22))
                        .overlay(RoundedRectangle(cornerRadius: 22).stroke(FitcoreTheme.line))
                }
            }
            if index == store.utterances.count - 1 && !store.currentCoachReply.isEmpty {
                HStack(alignment: .top, spacing: 10) {
                    Circle().fill(FitcoreTheme.accent).frame(width: 26, height: 26)
                        .overlay(Image(systemName: "sparkles").font(.caption2).foregroundStyle(.white))
                    VStack(alignment: .leading, spacing: 5) {
                        Text("AI 教练 · 已理解").font(.caption.weight(.semibold)).foregroundStyle(FitcoreTheme.accent)
                        Text(store.currentCoachReply).font(.subheadline).foregroundStyle(FitcoreTheme.ink).lineSpacing(5)
                            .padding(18).background(FitcoreTheme.limeSoft, in: RoundedRectangle(cornerRadius: 20))
                    }
                    Spacer(minLength: 12)
                }
            }
        }
        .padding(.vertical, 4)
    }

    private var questionCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("AI COACH · QUICK ANSWER", systemImage: "bubble.left.and.bubble.right.fill")
                .font(.caption.weight(.bold)).foregroundStyle(FitcoreTheme.lime)
            Text(store.currentQuestion).font(.subheadline.weight(.semibold))
            if !store.currentAnswer.isEmpty {
                Text(store.currentAnswer).font(.subheadline).foregroundStyle(FitcoreTheme.ink)
                    .padding(13).background(FitcoreTheme.limeSoft, in: RoundedRectangle(cornerRadius: 14))
            } else { ProgressView().tint(FitcoreTheme.accent) }
        }
        .padding(17).background(FitcoreTheme.navy, in: RoundedRectangle(cornerRadius: 20))
        .foregroundStyle(.white)
    }

    private var bottomControls: some View {
        VStack(spacing: 9) {
            HStack(alignment: .bottom, spacing: 10) {
                TextField("也可以打字记录动作、重量和次数…", text: $typedMessage, axis: .vertical)
                    .lineLimit(1...3).font(.system(size: 16))
                    .padding(12).background(.white, in: RoundedRectangle(cornerRadius: 16))
                    .focused($typing).disabled(!store.canSubmitText)
                    .accessibilityLabel("文字训练记录")
                Button {
                    if store.submitTrainingText(typedMessage) { typedMessage = ""; typing = false }
                } label: {
                    Image(systemName: "arrow.up").font(.system(size: 17, weight: .bold))
                        .frame(width: 44, height: 44).foregroundStyle(.white)
                        .background(FitcoreTheme.accent, in: Circle())
                }
                .buttonStyle(.plain).accessibilityLabel("发送文字")
                .disabled(!store.canSubmitText || typedMessage.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || typedMessage.count > 2000)
            }.padding(.horizontal, 20)
            if typedMessage.count > 2000 {
                Text("请将每条文字控制在 2000 字以内。").font(.caption).foregroundStyle(.red)
            }
            HStack(spacing: 12) {
                Label(store.timerText, systemImage: "record.circle").monospacedDigit()
                Spacer()
                Text(store.usesBackendText ? "文字输入" : "示例 \(store.conversationStepIndex) / \(store.conversationStepCount)")
                Button { store.autoAdvance.toggle() } label: {
                    Label(store.usesBackendText ? "手动" : store.autoAdvance ? "自动" : "手动", systemImage: store.usesBackendText ? "keyboard" : store.autoAdvance ? "pause.circle" : "play.circle")
                }.buttonStyle(.plain).disabled(store.usesBackendText).accessibilityLabel(store.autoAdvance ? "关闭自动推进" : "开启自动推进")
            }.font(.caption).foregroundStyle(FitcoreTheme.muted).padding(.horizontal, 28)
            if !typing { Button(action: store.advanceConversation) {
                ZStack {
                    Circle().fill(FitcoreTheme.accent.opacity(0.05)).frame(width: 104, height: 104)
                    RecorderArtwork(showCase: false, active: store.phase == .recording, size: 102)
                    if store.phase == .finishing { ProgressView().tint(FitcoreTheme.accent) }
                }
                .shadow(color: FitcoreTheme.navy.opacity(0.22), radius: 15, y: 7)
            }
            .buttonStyle(.plain).disabled(store.usesBackendText || store.isProcessing || store.phase == .finishing || store.pendingInput != nil)
            .opacity(store.isProcessing || store.phase == .finishing || store.pendingInput != nil ? 0.45 : 1)
            .accessibilityLabel("立即播放下一段模拟语音")
            }
            Text(store.pendingInput != nil ? "先处理上方待确认内容" : store.phase == .finishing ? "正在生成训练复盘…" : store.isProcessing ? "请稍候，AI 正在理解这一段" : store.usesBackendText ? "请在上方输入文字 · 录音豆硬件尚未接入" : "轻点录音豆，立即播放下一段示例")
                .font(.system(size: 10)).foregroundStyle(FitcoreTheme.muted)
        }
        .frame(maxWidth: .infinity).padding(.top, 14).padding(.bottom, 16)
        .background(.ultraThinMaterial)
    }

    private var historyOverlay: some View {
        VStack(spacing: 0) {
            HStack {
                Text("训练原话 · \(store.inputHistory.count)").font(.headline)
                Spacer()
                Button { showHistory = false } label: { Image(systemName: "xmark").font(.caption.weight(.bold)).padding(10) }.buttonStyle(.plain)
            }.padding(.horizontal, 20).padding(.vertical, 15).background(.white)
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    ForEach(Array(store.inputHistory.enumerated()), id: \.element.id) { index, entry in
                        HStack(alignment: .top, spacing: 12) {
                            Text(String(format: "%02d", index + 1)).font(.caption.monospacedDigit().weight(.bold)).foregroundStyle(FitcoreTheme.accent).frame(width: 22)
                            VStack(alignment: .leading, spacing: 6) {
                                Text(entry.text).font(.subheadline).foregroundStyle(FitcoreTheme.ink)
                                Text("\(entry.source.label) · \(entry.state.rawValue)")
                                    .font(.caption).foregroundStyle(FitcoreTheme.muted)
                            }
                            Spacer()
                        }.padding(14).background(.white, in: RoundedRectangle(cornerRadius: 14))
                    }
                }.padding(20)
            }
            Spacer(minLength: 0)
        }
        .background(FitcoreTheme.canvas)
        .clipShape(RoundedRectangle(cornerRadius: 24))
        .padding(.top, 90)
        .transition(.move(edge: .bottom))
    }
}
