import SwiftUI

struct RecorderDeviceView: View {
    @EnvironmentObject private var store: AppStore
    @Environment(\.dismiss) private var dismiss
    var onStart: () -> Void

    private var connected: Bool { store.device != nil }
    private var powerState: RecorderPowerState { store.device?.powerState ?? .unknown }
    private var isOutOfCase: Bool { connected && powerState == .on }

    private var title: String {
        guard connected else { return "连接你的录音豆" }
        switch powerState {
        case .on: return "录音豆已开启"
        case .off: return "录音豆已关闭"
        case .unknown: return "录音豆已连接"
        }
    }

    private var deviceGuidance: String {
        guard connected else { return "请开启录音豆并靠近手机，连接后自动同步设备状态。" }
        switch powerState {
        case .on: return "佩戴录音豆，准备记录下一次进步。"
        case .off: return "请开启录音豆，开启后此页面将自动更新。"
        case .unknown: return "设备已连接，正在等待开关状态同步。"
        }
    }

    var body: some View {
        NavigationStack {
            GeometryReader { viewport in
                ScrollView {
                    VStack(spacing: 20) {
                        VStack(spacing: 8) {
                            Text(title).font(.system(size: 28, weight: .bold))
                                .multilineTextAlignment(.center)
                            Text(store.device?.name ?? "Soundcore Work · D3200")
                                .font(.subheadline).foregroundStyle(FitcoreTheme.muted)
                        }
                        RecorderArtwork(
                            isOutOfCase: isOutOfCase, active: powerState == .on,
                            size: min(216, max(170, viewport.size.width * 0.5)))
                            .frame(maxWidth: .infinity).padding(.vertical, 12)
                            .background(
                                RadialGradient(colors: [.white, FitcoreTheme.canvas], center: .center,
                                               startRadius: 40, endRadius: 180),
                                in: RoundedRectangle(cornerRadius: 32))
                        Text(deviceGuidance)
                            .font(.system(size: 13)).foregroundStyle(FitcoreTheme.muted)
                            .lineSpacing(4).multilineTextAlignment(.center)
                            .fixedSize(horizontal: false, vertical: true)
                        deviceStatusCard
                        if let error = store.errorMessage {
                            Label(error, systemImage: "exclamationmark.circle")
                                .font(.footnote).foregroundStyle(.red)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                    .padding(.horizontal, 24).padding(.top, 22).padding(.bottom, 16)
                    .frame(maxWidth: 520).frame(maxWidth: .infinity)
                }
            }
            .background(FitcoreTheme.canvas)
            .safeAreaInset(edge: .bottom, spacing: 0) { actions }
            .navigationTitle("录音豆与录音盒")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                if store.recorderIsSimulated {
                    ToolbarItem(placement: .topBarLeading) {
                        Text("MOCK").font(.system(size: 10, weight: .semibold))
                            .tracking(1).foregroundStyle(FitcoreTheme.muted)
                    }
                }
                ToolbarItem(placement: .confirmationAction) { Button("完成") { dismiss() } }
            }
        }
        .foregroundStyle(FitcoreTheme.navy)
        .presentationDetents([.large])
        .presentationDragIndicator(.visible)
    }

    private var deviceStatusCard: some View {
        FitcoreCard {
            VStack(spacing: 14) {
                HStack(spacing: 10) {
                    Image(systemName: connected ? "checkmark.circle.fill" : "antenna.radiowaves.left.and.right")
                        .foregroundStyle(connected ? FitcoreTheme.accent : FitcoreTheme.muted)
                    Text(connected ? "录音豆已连接" : store.phase == .connecting ? "正在连接录音豆" : "等待连接")
                        .font(.system(size: 16, weight: .semibold))
                    Spacer(minLength: 4)
                    Circle().fill(connected ? Color.green : FitcoreTheme.muted.opacity(0.35))
                        .frame(width: 7, height: 7).accessibilityHidden(true)
                }
                Divider()
                statusRow("录音盒电量", icon: "shippingbox", value: batteryText(store.device?.caseBatteryPercent), known: store.device?.caseBatteryPercent != nil)
                statusRow("录音豆电量", icon: "battery.75percent", value: batteryText(store.device?.batteryPercent), known: store.device?.batteryPercent != nil)
                statusRow("录音豆开关状态", icon: "power", value: powerText, known: powerState != .unknown)
            }
        }
    }

    private func statusRow(_ title: String, icon: String, value: String, known: Bool) -> some View {
        HStack(spacing: 12) {
            Image(systemName: icon).font(.system(size: 16))
                .foregroundStyle(FitcoreTheme.muted).frame(width: 22)
            Text(title).font(.system(size: 14))
            Spacer(minLength: 8)
            Text(value).font(.system(size: 13, weight: .semibold)).monospacedDigit()
                .foregroundStyle(known ? FitcoreTheme.navy : FitcoreTheme.muted)
                .padding(.horizontal, 11).padding(.vertical, 6)
                .background(known ? FitcoreTheme.limeSoft : FitcoreTheme.canvas, in: Capsule())
        }
        .accessibilityElement(children: .combine)
    }

    private var actions: some View {
        VStack(spacing: 12) {
            if !connected {
                Button(action: store.connect) {
                    HStack(spacing: 8) {
                        if store.phase == .connecting { ProgressView().tint(.white) }
                        Text(store.phase == .connecting ? "正在连接录音豆…" : "连接录音豆")
                    }
                }
                .buttonStyle(PrimaryButtonStyle()).disabled(store.phase == .connecting)
                Text("请保持手机蓝牙开启，并允许 Fitcore 访问蓝牙。")
                    .font(.system(size: 12)).foregroundStyle(FitcoreTheme.muted)
                    .multilineTextAlignment(.center)
            } else {
                Button(store.phase == .recording ? "返回本次训练" : "开始训练", action: onStart)
                    .buttonStyle(PrimaryButtonStyle())
                    .disabled(store.phase == .finishing || (store.phase != .recording && !store.canStart))
                HStack(spacing: 8) {
                    Image(systemName: "info.circle")
                    Text("按下录音豆实体按键，即可开始记录训练。")
                }
                .font(.system(size: 12)).foregroundStyle(FitcoreTheme.muted)
                .multilineTextAlignment(.center)
                Button("断开设备") { store.disconnect() }
                    .font(.system(size: 13)).foregroundStyle(FitcoreTheme.muted)
                    .padding(.vertical, 3).disabled(store.isBusy)
            }
            if store.recorderIsSimulated {
                Text("开发预览 · 当前设备数据为示例")
                    .font(.system(size: 10)).foregroundStyle(FitcoreTheme.muted.opacity(0.8))
            }
        }
        .padding(.horizontal, 24).padding(.top, 14).padding(.bottom, 12)
        .frame(maxWidth: 520).frame(maxWidth: .infinity)
        .background(FitcoreTheme.canvas)
    }

    private func batteryText(_ percent: Int?) -> String {
        percent.map { "\($0)%" } ?? "待同步"
    }

    private var powerText: String {
        switch powerState {
        case .on: return "已开启"
        case .off: return "已关闭"
        case .unknown: return "待同步"
        }
    }
}
