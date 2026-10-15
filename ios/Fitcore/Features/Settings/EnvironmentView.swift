import SwiftUI

struct EnvironmentView: View {
    @EnvironmentObject private var store: AppStore
    @Environment(\.dismiss) private var dismiss
    @State private var status: String?
    @State private var checking = false
    @State private var cloudURL = ""
    @State private var cloudToken = ""

    var body: some View {
        NavigationStack {
            Form {
                Section("本地录音与语料") {
                    NavigationLink("手机 WAV 采集", destination: WAVCaptureView())
                    Text("使用 iPhone 麦克风录制、播放和导出标准 WAV，用于 LHY-01 / D01 的本地采集。")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Section("演示设置") {
                    Toggle("自动播放训练示例", isOn: $store.autoAdvance).disabled(store.usesBackendText)
                    Toggle("下一段演示识别失败", isOn: $store.previewNextAnalysisFailure).disabled(store.usesBackendText)
                    Text(store.usesBackendText ? "当前为真实文字分析，自动示例已停用；录音豆和语音转写尚未接入。" : "关闭后，在训练页点击录音豆，逐条演示原话、结构化记录与教练回答。")
                        .font(.caption).foregroundStyle(.secondary)
                    Text(store.usesBackendText ? "输入真实训练文字，后端调用模型；错误会保留原话并显示原因。" : "开启失败演示后，下一段示例显示补充/重试界面；重试可继续示例。自由文字仍需接入真实 AI。")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Section("构建配置") {
                    LabeledContent("版本", value: "\(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "—") (\(Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "—"))")
                    LabeledContent("环境", value: store.environment?.name ?? "未配置")
                    LabeledContent("录音源", value: "Mock · 未接入真实设备")
                    LabeledContent("AI 分析", value: store.analysisModeDescription)
                    Text(store.environment?.apiBaseURL?.absoluteString ?? "尚未配置后端地址")
                        .font(.caption).textSelection(.enabled)
                }
                Section("后端连接") {
                    Button(checking ? "检查中…" : "检查 /health") {
                        guard let url = store.environment?.apiBaseURL else { return }
                        checking = true
                        Task {
                            defer { checking = false }
                            do {
                                let health = try await BackendClient(baseURL: url).health()
                                status = "\(health.service) · \(health.status) · \(health.environment)"
                            } catch { status = error.localizedDescription }
                        }
                    }
                    .disabled(checking || store.environment?.apiBaseURL == nil)
                    if let status { Text(status).font(.footnote) }
                    Text("健康检查仅验证后端连通。真实文字分析由 FITCORE_ANALYSIS_MODE 启用，并使用下方保存的后端连接；模型 Key 只配置在服务端。")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Section("本机数据") {
                    LabeledContent("已保存训练", value: "\(store.history.count) 次")
                    Text("记录首先保存在本机。配置下方云同步后，手机与电脑可查看同一演示用户的已保存训练；示例记录保留示例标识。")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Section("手机与电脑 · 云端同步") {
                    TextField("https://你的后端域名", text: $cloudURL)
                        .textInputAutocapitalization(.never).autocorrectionDisabled()
                        .keyboardType(.URL).disabled(store.cloudSyncBusy)
                    SecureField("Fitcore 演示访问令牌", text: $cloudToken)
                        .textInputAutocapitalization(.never).autocorrectionDisabled()
                        .disabled(store.cloudSyncBusy)
                    Button(store.cloudSyncBusy ? "正在连接或同步…" : "连接并同步本机历史") {
                        Task {
                            if await store.configureCloudSync(url: cloudURL, token: cloudToken) {
                                cloudToken = ""
                                await store.syncCloudHistory()
                            }
                        }
                    }.disabled(store.cloudSyncBusy || cloudURL.isEmpty || cloudToken.isEmpty)
                    if store.cloudIsConfigured {
                        LabeledContent("演示用户", value: store.cloudUserID ?? "—")
                        Button("立即同步", action: { Task { await store.syncCloudHistory() } })
                            .disabled(store.cloudSyncBusy)
                        Button("停止云同步", action: store.disconnectCloudSync)
                            .disabled(store.cloudSyncBusy)
                    }
                    Text(store.cloudSyncStatus).font(.footnote)
                    Text(store.cloudLiveStatus).font(.footnote).foregroundStyle(.secondary)
                    Text("这里填写自建 Fitcore 后端的访问令牌，不是 ASR 或大模型 API Key。模型密钥只留在服务器。服务器部署完成前不会显示已同步。")
                        .font(.caption).foregroundStyle(.secondary)
                    Text("App 在前台训练时同步录音豆与训练进展；回到前台会刷新已保存历史。状态同步失败不会停止手机记录。AWS 凭据只放在服务器。")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            .navigationTitle("演示与开发设置")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("完成") { dismiss() } } }
            .onAppear { cloudURL = store.cloudBaseURL.isEmpty ? (store.environment?.apiBaseURL?.absoluteString ?? "") : store.cloudBaseURL }
        }
    }
}
