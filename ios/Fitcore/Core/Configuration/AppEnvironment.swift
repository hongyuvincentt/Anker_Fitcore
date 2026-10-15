import Foundation

struct AppEnvironment: Sendable {
    enum ConfigurationError: LocalizedError {
        case invalid(String)

        var errorDescription: String? {
            switch self {
            case .invalid(let message): return message
            }
        }
    }

    enum AnalysisMode: String, Sendable { case mock, backend }

    let analysisMode: AnalysisMode
    let name: String
    let apiBaseURL: URL?

    static func load(info: [String: Any] = Bundle.main.infoDictionary ?? [:]) throws -> Self {
        let mode = (info["FITCORE_RECORDER_MODE"] as? String ?? "mock")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard mode == "mock" else {
            throw ConfigurationError.invalid("当前工程仅实现 Mock 录音。真实 SDK 适配完成后才能启用硬件模式。")
        }
        let rawAnalysisMode = (info["FITCORE_ANALYSIS_MODE"] as? String ?? "mock")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard let analysisMode = AnalysisMode(rawValue: rawAnalysisMode) else {
            throw ConfigurationError.invalid("FITCORE_ANALYSIS_MODE 只能是 mock 或 backend。")
        }
        let rawURL = (info["FITCORE_API_BASE_URL"] as? String ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        var apiURL: URL?
        if !rawURL.isEmpty {
            guard let url = URL(string: rawURL),
                  url.scheme == "https", let host = url.host, !host.isEmpty,
                  url.user == nil, url.password == nil,
                  url.query == nil, url.fragment == nil,
                  !rawURL.contains("$(") else {
                throw ConfigurationError.invalid("API 地址需要使用不含密钥、查询参数的 HTTPS 地址，请检查 Local.xcconfig。")
            }
            apiURL = url
        }
        return Self(analysisMode: analysisMode, name: info["FITCORE_ENVIRONMENT"] as? String ?? "development", apiBaseURL: apiURL)
    }
}
