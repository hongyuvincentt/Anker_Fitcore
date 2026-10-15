import SwiftUI

struct WorkoutReviewView: View {
    @EnvironmentObject private var store: AppStore
    @State private var showingTranscript = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                FitcorePageHeader(eyebrow: "FITCORE · AI COACH", title: "训练结果", detail: (store.review?.date ?? Date()).formatted(.dateTime.month().day()))
                if let review = store.review {
                    reviewHero(review)
                    progressSteps(completed: true)
                    HStack {
                        Text(review.isTextRecordSummary ? "训练记录已整理" : "AI 已整理").font(.headline)
                        Spacer()
                        Text(store.isReviewSaved ? "已同步到历史与我的" : "复盘已生成 · 待保存")
                            .font(.system(size: 11)).foregroundStyle(FitcoreTheme.muted)
                    }
                    recordCard(review)
                    analysisCard(review)
                    nextSessionCard(review)
                    questionCard(review)
                    Button(action: store.saveReview) {
                        Label(store.isReviewSaved ? "已保存到训练记录" : "保存训练记录", systemImage: store.isReviewSaved ? "checkmark.circle.fill" : "checkmark")
                    }
                    .buttonStyle(PrimaryButtonStyle())
                    .disabled(store.isReviewSaved || review.events.isEmpty)
                    if store.isReviewSaved {
                        HStack {
                            Button("查看历史") { store.selectedTab = .history }
                            Button("查看我的训练成效") { store.selectedTab = .profile }
                        }.buttonStyle(OutlineButtonStyle())
                    }
                    if let error = store.errorMessage {
                        Label(error, systemImage: "exclamationmark.circle").font(.footnote).foregroundStyle(.red)
                    }
                    Text(review.isSimulated
                         ? "示例复盘 · 运动时长和热量来自演示脚本，未进行真实运动测量。"
                         : review.hasPendingInputs ? "部分原话尚未处理，已保留在原话列表。本页仅汇总已确认记录，请核对后保存。" : "记录依据已提交的原话整理，请核对识别结果；未确认的重量与次数显示待补充。肌群为动作映射，非传感器检测。")
                        .font(.caption).foregroundStyle(FitcoreTheme.muted)
                } else {
                    emptyState
                }
            }
            .padding(20).padding(.bottom, 12)
            .frame(maxWidth: 680).frame(maxWidth: .infinity)
        }
        .background(FitcoreTheme.canvas).foregroundStyle(FitcoreTheme.ink)
        .toolbar(.hidden, for: .navigationBar)
        .sheet(isPresented: $showingTranscript) {
            if let review = store.review { ReviewTranscriptView(review: review) }
        }
    }

    private var emptyState: some View {
        VStack(alignment: .leading, spacing: 22) {
            VStack(alignment: .leading, spacing: 14) {
                Text("还没有训练记录").font(.caption).foregroundStyle(.white.opacity(0.65))
                Text("暂无对应记录\n请开始训练吧～").font(.system(size: 26, weight: .bold)).lineSpacing(4)
                Text("完成训练后，热身、工作组和拉伸会同步到这里")
                    .font(.caption).foregroundStyle(.white.opacity(0.68))
            }
            .frame(maxWidth: .infinity, alignment: .leading).padding(24)
            .foregroundStyle(.white).background(FitcoreTheme.navy, in: RoundedRectangle(cornerRadius: 24))
            progressSteps(completed: false)
            Text(store.phase == .recording ? "训练正在记录中" : "等待训练记录").font(.headline)
            FitcoreCard {
                VStack(alignment: .leading, spacing: 16) {
                    Image(systemName: "sparkles").font(.system(size: 30)).foregroundStyle(FitcoreTheme.accent)
                    Text(store.phase == .recording ? "结束后，AI 会为你整理" : "先记录一段训练").font(.title3.weight(.bold))
                    Text("点击底部录音豆，说说今天的动作、重量、次数和体感。")
                        .font(.subheadline).foregroundStyle(FitcoreTheme.muted).lineSpacing(4)
                    Button(store.phase == .recording ? "返回训练记录" : "开始录音", action: store.openRecorder)
                        .buttonStyle(PrimaryButtonStyle())
                }
            }
            MockBadge()
        }
    }

    private func reviewHero(_ review: TrainingReview) -> some View {
        VStack(alignment: .leading, spacing: 11) {
            Text(review.isSimulated ? "演示训练记录" : "本次记录已整理")
                .font(.caption).foregroundStyle(.white.opacity(0.65))
            Text(review.sessionTitle).font(.system(size: 26, weight: .bold))
            Text(review.phaseLabel.isEmpty ? "尚无结构化训练事件" : review.phaseLabel)
                .font(.caption).foregroundStyle(.white.opacity(0.7))
            HStack(spacing: 14) {
                Label("\(review.durationMinutes) 分钟", systemImage: "clock")
                Label("\(review.workSets.count) 个工作组", systemImage: "dumbbell")
                if review.isSimulated {
                    Text("示例").padding(.horizontal, 7).padding(.vertical, 4).background(.white.opacity(0.12), in: Capsule())
                }
            }.font(.system(size: 11)).foregroundStyle(.white.opacity(0.75))
            Text(review.displayCalories.map { "热量估算 \($0) kcal" } ?? "热量未估算")
                .font(.system(size: 11)).foregroundStyle(.white.opacity(0.65))
        }
        .frame(maxWidth: .infinity, alignment: .leading).padding(23)
        .foregroundStyle(.white)
        .background(LinearGradient(colors: [FitcoreTheme.deep, FitcoreTheme.navy, FitcoreTheme.accent.opacity(0.75)], startPoint: .topLeading, endPoint: .bottomTrailing), in: RoundedRectangle(cornerRadius: 24))
        .shadow(color: FitcoreTheme.navy.opacity(0.12), radius: 14, y: 7)
    }

    private func progressSteps(completed: Bool) -> some View {
        HStack(spacing: 0) {
            ForEach(Array(["内容输入", "记录整理", "AI 分析", "复盘"].enumerated()), id: \.offset) { index, title in
                VStack(spacing: 8) {
                    ZStack {
                        Circle().fill(completed ? FitcoreTheme.accent : FitcoreTheme.line).frame(width: 28, height: 28)
                        if completed { Image(systemName: "checkmark").font(.system(size: 11, weight: .bold)).foregroundStyle(.white) }
                        else { Text("\(index + 1)").font(.caption.weight(.bold)).foregroundStyle(FitcoreTheme.muted) }
                    }
                    Text(title).font(.system(size: 11)).foregroundStyle(completed ? FitcoreTheme.accent : FitcoreTheme.muted)
                }.frame(maxWidth: .infinity)
            }
        }.padding(.vertical, 4).accessibilityElement(children: .combine)
    }

    private func recordCard(_ review: TrainingReview) -> some View {
        FitcoreCard {
            VStack(alignment: .leading, spacing: 14) {
                HStack {
                    Label("本次已记录动作", systemImage: "waveform").font(.subheadline.weight(.bold))
                    Spacer()
                    Text("已结构化").font(.system(size: 10)).foregroundStyle(FitcoreTheme.accent)
                }
                if review.recordedActivities.isEmpty {
                    Text("尚无可确认的动作；可查看原话继续核对。")
                        .font(.subheadline).foregroundStyle(FitcoreTheme.muted)
                }
                ForEach(review.recordedActivities) { activity in
                    reviewRow(activity.name, value: activity.detail)
                }
                HStack(alignment: .top) {
                    Text("\(review.events.count) 条训练事件 · \(review.inputHistory?.count ?? review.utterances.count) 条原话")
                        .font(.system(size: 10)).foregroundStyle(FitcoreTheme.muted)
                    Spacer()
                    Button("查看原话") { showingTranscript = true }.font(.system(size: 11, weight: .semibold))
                }
                Text("原话与理解已分开保留").font(.system(size: 10)).foregroundStyle(FitcoreTheme.muted)
            }
        }
    }

    private func reviewRow(_ title: String, value: String) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Text(title).font(.system(size: 11, weight: .semibold)).frame(width: 56, alignment: .leading)
            Text(value).font(.system(size: 11)).foregroundStyle(FitcoreTheme.muted)
                .frame(maxWidth: .infinity, alignment: .trailing).multilineTextAlignment(.trailing).lineSpacing(3)
        }.padding(11).background(FitcoreTheme.canvas, in: RoundedRectangle(cornerRadius: 10))
    }

    private func analysisCard(_ review: TrainingReview) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Label(review.isTextRecordSummary ? "训练记录汇总" : "AI 训练复盘", systemImage: "sparkles").font(.headline)
                Spacer()
                VStack(spacing: 3) {
                    Text("\(review.phaseCount)").font(.system(size: 28, weight: .bold, design: .rounded))
                    Text("阶段记录").font(.system(size: 9))
                }.foregroundStyle(FitcoreTheme.deep).padding(12)
                    .background(FitcoreTheme.lime, in: RoundedRectangle(cornerRadius: 17))
            }
            Text("按已记录内容整理，缺失信息仍需核对")
                .font(.system(size: 10)).foregroundStyle(.white.opacity(0.65))
            Text(review.observation.isEmpty ? review.summary : review.observation)
                .font(.subheadline).lineSpacing(6).foregroundStyle(.white.opacity(0.88))
        }
        .padding(22).foregroundStyle(.white)
        .background(LinearGradient(colors: [FitcoreTheme.deep, FitcoreTheme.navy], startPoint: .topLeading, endPoint: .bottomTrailing), in: RoundedRectangle(cornerRadius: 24))
    }

    private func nextSessionCard(_ review: TrainingReview) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: "sparkles").font(.title2).foregroundStyle(FitcoreTheme.accent)
            VStack(alignment: .leading, spacing: 7) {
                Text(review.isTextRecordSummary ? "RECORD · CHECK" : "AI · NEXT SESSION").font(.system(size: 9, weight: .bold)).tracking(1.2).foregroundStyle(FitcoreTheme.accent)
                Text(review.isTextRecordSummary ? "核对本次训练" : "下一次训练建议").font(.headline)
                Text(review.nextSession.isEmpty ? "本次暂无建议；先核对动作记录与原话。" : review.nextSession)
                    .font(.subheadline).foregroundStyle(FitcoreTheme.muted).lineSpacing(4)
            }
        }.frame(maxWidth: .infinity, alignment: .leading).padding(20)
            .background(FitcoreTheme.limeSoft, in: RoundedRectangle(cornerRadius: 22))
    }

    private func questionCard(_ review: TrainingReview) -> some View {
        FitcoreCard {
            VStack(alignment: .leading, spacing: 14) {
                Label("训练问题与安全提醒", systemImage: "bubble.left.and.bubble.right").font(.subheadline.weight(.bold))
                if review.questions.isEmpty {
                    Text("本次没有记录训练问题；记录过程中，可以说出你的疑问。")
                        .font(.subheadline).foregroundStyle(FitcoreTheme.muted)
                }
                ForEach(review.questions) { question in
                    VStack(alignment: .leading, spacing: 8) {
                        Text("你问：\(question.text)").font(.subheadline.weight(.semibold))
                        Text(question.answer).font(.subheadline).foregroundStyle(FitcoreTheme.muted).lineSpacing(4)
                    }
                }
                Divider()
                Label("优先保持动作稳定，再考虑增加重量", systemImage: "checkmark.circle")
                Label("出现明确疼痛时停止动作并寻求专业评估", systemImage: "heart.text.square")
            }.font(.caption).foregroundStyle(FitcoreTheme.navy)
        }
    }
}

private struct ReviewTranscriptView: View {
    @Environment(\.dismiss) private var dismiss
    let review: TrainingReview
    var body: some View {
        NavigationStack {
            List {
                Section {
                    Text(review.isSimulated
                         ? "以下为训练示例原话。结构化记录与原话分别保留，便于核对。"
                         : "以下为本次提交的原话。补充前后的输入分别保留，请对照原话核对结构化结果。")
                        .font(.footnote).foregroundStyle(.secondary)
                }
                if let inputs = review.inputHistory {
                    ForEach(Array(inputs.enumerated()), id: \.element.id) { index, input in
                        transcriptRow(index: index, inputID: input.id, utterance: input.text,
                            note: "\(input.source.label) · \(input.state.rawValue)")
                    }
                } else {
                    ForEach(Array(review.utterances.enumerated()), id: \.offset) { index, utterance in
                        transcriptRow(index: index, inputID: nil, utterance: utterance, note: nil)
                    }
                }
            }
            .navigationTitle("原话与理解")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("完成") { dismiss() } } }
        }
    }

    private func transcriptRow(index: Int, inputID: UUID?, utterance: String, note: String?) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("原话 \(index + 1)").font(.caption.weight(.bold)).foregroundStyle(FitcoreTheme.accent)
            Text(utterance).font(.subheadline).textSelection(.enabled)
            if let note { Text(note).font(.caption).foregroundStyle(.secondary) }
            ForEach(review.events.filter { event in
                if let inputID, let sourceIDs = event.sourceInputIDs {
                    return sourceIDs.contains(inputID)
                }
                return event.sourceText == utterance
            }) { event in
                Label(event.interpretation.isEmpty ? event.exercise : event.interpretation, systemImage: "sparkles")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }.padding(.vertical, 5)
    }
}
