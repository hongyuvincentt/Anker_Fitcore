import SwiftUI
import UniformTypeIdentifiers

struct TodayView: View {
    @EnvironmentObject private var store: AppStore
    @State private var showingImporter = false
    @State private var importMessage: String?

    private var active: Bool { store.phase == .recording || store.phase == .finishing }
    private var weekSessions: [TrainingReview] {
        guard let week = Calendar.current.dateInterval(of: .weekOfYear, for: Date()) else { return [] }
        return store.history.filter { week.contains($0.date) }
    }

    var body: some View {
        GeometryReader { viewport in
          ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                header
                hero(minimumHeight: min(192, max(164, (min(viewport.size.width, 640) - 40) * 0.48)))
                HStack(alignment: .firstTextBaseline) {
                    Text("记录今天的训练").font(.system(size: 17, weight: .bold))
                    Spacer()
                    Text(Date(), format: .dateTime.month().day().weekday(.abbreviated))
                        .font(.system(size: 11)).foregroundStyle(FitcoreTheme.muted)
                }
                captureCard
                NavigationLink {
                    CloudTrainingView()
                } label: {
                    HStack(spacing: 12) {
                        Image(systemName: "cloud.fill").font(.title3)
                            .frame(width: 42, height: 42).background(FitcoreTheme.limeSoft, in: RoundedRectangle(cornerRadius: 14))
                        VStack(alignment: .leading, spacing: 5) {
                            Text("云端训练链 · 口述到复盘").font(.subheadline.weight(.bold))
                            Text("离线 Mock 集成 · 不访问真实后端").font(.caption).foregroundStyle(FitcoreTheme.muted)
                        }
                        Spacer(minLength: 0)
                        Image(systemName: "chevron.right").font(.caption.weight(.bold))
                    }
                    .foregroundStyle(FitcoreTheme.navy).padding(16)
                    .background(.white, in: RoundedRectangle(cornerRadius: 22))
                }.buttonStyle(.plain)
                if store.review != nil {
                    Button { store.selectedTab = .insights } label: {
                        HStack(spacing: 12) {
                            Image(systemName: "sparkles").font(.title3)
                                .frame(width: 42, height: 42).background(FitcoreTheme.limeSoft, in: RoundedRectangle(cornerRadius: 14))
                            VStack(alignment: .leading, spacing: 5) {
                                Text("查看 AI 训练结果").font(.subheadline.weight(.bold))
                                Text("训练记录与专属复盘已准备好").font(.caption).foregroundStyle(FitcoreTheme.muted)
                            }
                            Spacer(minLength: 0)
                            Image(systemName: "chevron.right").font(.caption.weight(.bold))
                        }
                        .foregroundStyle(FitcoreTheme.navy).padding(16)
                        .background(.white, in: RoundedRectangle(cornerRadius: 22))
                    }.buttonStyle(.plain)
                }
                if let error = store.errorMessage {
                    Label(error, systemImage: "exclamationmark.circle")
                        .font(.footnote).foregroundStyle(.red)
                }
                Label(store.usesBackendText ? "真实文字分析 · 录音豆与语音仍为模拟" : "演示模式 · 训练语音与 AI 回答均为示例", systemImage: "testtube.2")
                    .font(.system(size: 11)).foregroundStyle(FitcoreTheme.muted)
                    .frame(maxWidth: .infinity)
            }
            .padding(.horizontal, 20).padding(.top, 14).padding(.bottom, 24)
            .frame(maxWidth: 640)
            .frame(maxWidth: .infinity)
          }
        }
        .background(FitcoreTheme.canvas).foregroundStyle(FitcoreTheme.ink)
        .fileImporter(isPresented: $showingImporter, allowedContentTypes: [.audio]) { result in
            switch result {
            case .success(let url):
                // Only show the chosen name. No audio is copied, decoded or sent in Mock mode.
                importMessage = "已选择「\(url.lastPathComponent)」。当前演示版尚未接入音频转写，文件未上传。可以先播放训练示例。"
            case .failure(let error): importMessage = error.localizedDescription
            }
        }
        .alert("音频文件", isPresented: Binding(get: { importMessage != nil }, set: { if !$0 { importMessage = nil } })) {
            Button("知道了", role: .cancel) { importMessage = nil }
        } message: { Text(importMessage ?? "") }
    }

    private var header: some View {
        HStack {
            VStack(alignment: .leading, spacing: 5) {
                Text("\(greeting)，\(store.preferences.displayName)")
                    .font(.system(size: 12)).foregroundStyle(FitcoreTheme.muted)
                Text("今天也动起来").font(.system(size: 28, weight: .bold))
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer()
            Button { store.selectedTab = .profile } label: {
                Text(String(store.preferences.displayName.prefix(1))).font(.headline)
                    .foregroundStyle(.white).frame(width: 42, height: 42)
                    .background(FitcoreTheme.navy, in: Circle())
                    .overlay(Circle().stroke(.white, lineWidth: 3))
                    .shadow(color: FitcoreTheme.navy.opacity(0.15), radius: 8, y: 4)
            }.buttonStyle(.plain).accessibilityLabel("打开我的训练成效")
        }
    }

    private func hero(minimumHeight: CGFloat) -> some View {
        HStack(alignment: .center, spacing: 16) {
            VStack(alignment: .leading, spacing: 13) {
                HStack(spacing: 6) {
                    Circle().fill(FitcoreTheme.lime).frame(width: 5, height: 5)
                    Text("FITCORE · AI COACH").font(.system(size: 8, weight: .bold)).tracking(1.5)
                }.foregroundStyle(.white.opacity(0.75))
                Text("Let's Do It").font(.system(size: 25, weight: .heavy, design: .rounded))
                    .tracking(-1).minimumScaleFactor(0.7).lineLimit(1)
                Text("一起见证\n你的潜能").font(.system(size: 17, weight: .semibold)).lineSpacing(3)
            }.frame(maxWidth: .infinity, alignment: .leading)
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Text("本周节奏").font(.system(size: 10)).foregroundStyle(.white.opacity(0.65))
                    Spacer(minLength: 4)
                    Text("\(weekSessions.count) / 5").font(.system(size: 14, weight: .bold)).foregroundStyle(FitcoreTheme.lime)
                }
                HStack(alignment: .bottom, spacing: 8) {
                    ForEach(0..<7) { index in
                        VStack(spacing: 6) {
                            Capsule().fill(dayHasWorkout(index) ? FitcoreTheme.lime : .white.opacity(0.18))
                                .frame(width: 6, height: dayHasWorkout(index) ? 30 : 13)
                                .frame(height: 32, alignment: .bottom)
                            Text(["一", "二", "三", "四", "五", "六", "日"][index])
                                .font(.system(size: 9)).foregroundStyle(.white.opacity(0.6))
                        }.frame(maxWidth: .infinity)
                    }
                }
                Text(weekSessions.count >= 5 ? "本周目标已达成，继续保持" : "再完成 \(5 - weekSessions.count) 次，达成本周目标")
                    .font(.system(size: 9)).foregroundStyle(.white.opacity(0.64)).fixedSize(horizontal: false, vertical: true)
            }.frame(maxWidth: .infinity)
        }
        .foregroundStyle(.white).padding(22)
        .frame(maxWidth: .infinity, minHeight: minimumHeight)
        .background(LinearGradient(colors: [FitcoreTheme.deep, FitcoreTheme.navy, FitcoreTheme.accent.opacity(0.65)], startPoint: .leading, endPoint: .bottomTrailing))
        .overlay(alignment: .trailing) {
            ZStack {
                Circle().stroke(.white.opacity(0.1), lineWidth: 1).frame(width: 210, height: 210).offset(x: 95, y: -45)
                Circle().stroke(.white.opacity(0.06), lineWidth: 24).frame(width: 250, height: 250).offset(x: 95, y: -35)
            }
            .allowsHitTesting(false)
            .accessibilityHidden(true)
        }
        // Clip at the card's own bounds, not at the decorative circles' size.
        .clipShape(RoundedRectangle(cornerRadius: 28))
        .shadow(color: FitcoreTheme.navy.opacity(0.12), radius: 10, y: 5)
    }

    private var captureCard: some View {
        FitcoreCard {
            VStack(alignment: .leading, spacing: 16) {
                HStack(alignment: .top) {
                    VStack(alignment: .leading, spacing: 8) {
                        Text(active ? "正在记录这一次进步" : "开始一段训练记录").font(.system(size: 16, weight: .bold))
                        Button { store.showDeviceSheet = true } label: {
                            HStack(spacing: 5) {
                                Circle().fill(store.device == nil ? FitcoreTheme.muted : .green).frame(width: 5, height: 5)
                                Text(store.device == nil ? "录音豆 · 点击连接" : "录音豆 · 已连接")
                                Image(systemName: "chevron.right").font(.system(size: 8))
                            }.font(.system(size: 10)).foregroundStyle(FitcoreTheme.muted)
                        }.buttonStyle(.plain).padding(.vertical, 3)
                    }
                    Spacer(minLength: 4)
                    Text(active ? (store.phase == .finishing ? "生成复盘" : "记录中") : "等待录音")
                        .font(.system(size: 10, weight: .medium)).padding(.horizontal, 10).padding(.vertical, 7)
                        .background(active ? FitcoreTheme.limeSoft : FitcoreTheme.canvas, in: Capsule())
                }
                HStack(spacing: 10) {
                    Button(action: store.openRecorder) {
                        RecorderArtwork(isOutOfCase: active, active: store.phase == .recording, size: 110)
                    }.buttonStyle(.plain).accessibilityLabel(active ? "返回实时训练记录" : "连接录音豆并开始示例训练")
                    VStack(alignment: .leading, spacing: 11) {
                        Text(active ? "每一句，都被认真记下" : "尝试点击左侧录音豆")
                            .font(.system(size: 15, weight: .bold)).fixedSize(horizontal: false, vertical: true)
                        Text(store.usesBackendText ? "输入实际训练文字，AI 会\n提取动作与组次" : "请畅所欲言，AI 会自动\n提取对话信息")
                            .font(.system(size: 12)).foregroundStyle(FitcoreTheme.muted).lineSpacing(4)
                        HStack(spacing: 4) {
                            Circle().fill(store.device == nil ? FitcoreTheme.muted : .green).frame(width: 4, height: 4)
                            Text(store.device == nil ? "未连接" : "已连接")
                            Spacer(minLength: 0)
                            if let battery = store.device?.batteryPercent { Text("\(battery)% 电量") }
                        }.font(.system(size: 10)).foregroundStyle(FitcoreTheme.muted)
                        Label(active ? store.timerText : "准备开始训练", systemImage: active ? "record.circle" : "circle.fill")
                            .font(.system(size: 11, weight: .semibold)).foregroundStyle(FitcoreTheme.navy)
                    }.frame(maxWidth: .infinity, alignment: .leading)
                }
                TrainingWaveform(active: store.phase == .recording)
                if active {
                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            Label("AI 持续记录", systemImage: "sparkles")
                                .font(.caption.weight(.semibold))
                            Spacer()
                            Text("\(store.utterances.count) 条原话").font(.caption)
                        }
                        Text(store.phase == .finishing ? "正在整理完整训练复盘…" : store.isProcessing ? "正在理解新的训练口述…" : store.currentCoachReply.isEmpty ? "训练仍在记录，返回对话可查看详情。" : store.currentCoachReply)
                            .font(.caption).lineSpacing(3).fixedSize(horizontal: false, vertical: true)
                    }
                    .foregroundStyle(FitcoreTheme.navy)
                    .padding(13).background(FitcoreTheme.limeSoft, in: RoundedRectangle(cornerRadius: 14))
                }
                HStack(spacing: 10) {
                    Button { showingImporter = true } label: { Label("上传音频", systemImage: "square.and.arrow.up") }
                        .disabled(active)
                    Button(action: store.openRecorder) { Label(active ? "返回记录" : store.usesBackendText ? "开始记录" : "播放示例", systemImage: "waveform") }
                }.buttonStyle(OutlineButtonStyle())
            }
        }
    }

    private var greeting: String {
        let hour = Calendar.current.component(.hour, from: Date())
        return hour < 12 ? "早上好" : hour < 18 ? "下午好" : "晚上好"
    }

    private func dayHasWorkout(_ index: Int) -> Bool {
        let weekday = index == 6 ? 1 : index + 2
        return weekSessions.contains { Calendar.current.component(.weekday, from: $0.date) == weekday }
    }
}
