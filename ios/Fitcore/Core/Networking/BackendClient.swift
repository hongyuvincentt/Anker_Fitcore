import Foundation

struct BackendClient: Sendable {
    struct Health: Decodable, Sendable {
        let status: String
        let service: String
        let environment: String
    }

    enum ClientError: LocalizedError {
        case httpStatus(Int)
        case invalidResponse

        var errorDescription: String? {
            switch self {
            case .httpStatus(let code): return "后端返回 HTTP \(code)"
            case .invalidResponse: return "后端响应格式不正确"
            }
        }
    }

    let baseURL: URL

    /// Explicitly invoked from diagnostics only; Mock training does not call a backend.
    func health() async throws -> Health {
        var request = URLRequest(url: baseURL.appendingPathComponent("health"))
        request.timeoutInterval = 10
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw ClientError.invalidResponse }
        guard (200..<300).contains(http.statusCode) else { throw ClientError.httpStatus(http.statusCode) }
        return try JSONDecoder().decode(Health.self, from: data)
    }
}
