import SwiftUI

struct RootView: View {
    @EnvironmentObject private var store: AppStore
    @State private var startAfterDeviceSheet = false

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                Group {
                    switch store.selectedTab {
                    case .today: TodayView()
                    case .history: HistoryView()
                    case .insights: WorkoutReviewView()
                    case .profile: ProfileView()
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                // Each page owns the space above the footer. Scrolling content,
                // backgrounds and shadows must not paint through the navigation.
                .clipped()
                VStack(spacing: 0) {
                    if store.phase == .recording || store.phase == .finishing {
                        Button(action: store.openRecorder) {
                            HStack(spacing: 10) {
                                Image(systemName: "waveform").symbolEffect(.variableColor, isActive: store.phase == .recording)
                                Text(store.pendingInput != nil ? "有一段内容待处理 · 返回补充" : store.phase == .finishing ? "正在整理本次训练…" : "持续记录中 · \(store.timerText)")
                                Spacer()
                                Text("返回记录").font(.caption.weight(.semibold))
                                Image(systemName: "chevron.right").font(.caption)
                            }
                            .font(.footnote.weight(.medium))
                            .padding(.horizontal, 20).padding(.vertical, 12)
                            .foregroundStyle(.white).background(FitcoreTheme.navy)
                        }
                        .buttonStyle(.plain)
                    }
                    bottomNavigation
                }
                .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(FitcoreTheme.canvas)
            .toolbar(.hidden, for: .navigationBar)
        }
        .fullScreenCover(isPresented: $store.isConversationPresented) {
            LiveWorkoutView().environmentObject(store).interactiveDismissDisabled()
        }
        .sheet(isPresented: $store.showDeviceSheet, onDismiss: {
            store.deviceSheetDidDismiss()
            if startAfterDeviceSheet {
                startAfterDeviceSheet = false
                store.openRecorder()
            }
        }) {
            RecorderDeviceView {
                startAfterDeviceSheet = true
                store.showDeviceSheet = false
            }.environmentObject(store)
        }
    }

    private var bottomNavigation: some View {
        HStack(alignment: .center, spacing: 0) {
            tab("今日", icon: "square.grid.2x2", value: .today)
            tab("历史", icon: "clock.arrow.circlepath", value: .history)
            Button(action: store.openRecorder) {
                Image("RecorderBean")
                    .resizable().scaledToFit().frame(width: 38, height: 44)
                    .frame(width: 58, height: 58)
                    .background(FitcoreTheme.navy, in: Circle())
                    .overlay(Circle().stroke(.white, lineWidth: 4))
                    .shadow(color: FitcoreTheme.navy.opacity(0.12), radius: 4, y: 2)
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(store.phase == .recording ? "返回训练记录" : "录音豆，开始训练")
            tab("AI 分析", icon: "sparkles", value: .insights)
            tab("我的", icon: "person", value: .profile)
        }
        .padding(.horizontal, 12)
        // The bean has real layout space instead of an offset outside the bar.
        .frame(height: 80)
        .background { Color.white.ignoresSafeArea(edges: .bottom) }
        .overlay(alignment: .top) { Rectangle().fill(FitcoreTheme.line).frame(height: 0.5) }
    }

    private func tab(_ title: String, icon: String, value: AppStore.Tab) -> some View {
        Button { store.selectedTab = value } label: {
            VStack(spacing: 5) {
                Image(systemName: icon).font(.system(size: 19, weight: store.selectedTab == value ? .semibold : .regular))
                Text(title).font(.system(size: 11, weight: store.selectedTab == value ? .semibold : .regular))
                Circle().fill(store.selectedTab == value ? FitcoreTheme.accent : .clear).frame(width: 4, height: 4)
            }
            .foregroundStyle(store.selectedTab == value ? FitcoreTheme.navy : FitcoreTheme.muted)
            .frame(maxWidth: .infinity, minHeight: 50)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(store.selectedTab == value ? .isSelected : [])
    }
}
