import Foundation
import Security

enum CloudHistoryError: LocalizedError {
  case invalidURL, missingToken, unauthorized, conflict, response(Int), invalidData, differentOwner
  case credentialStorage
  case liveConflict(String)
  var errorDescription: String? {
    switch self {
    case .invalidURL: return "请填写不含密码或查询参数的 HTTPS 后端地址。"
    case .missingToken: return "请填写 Fitcore 演示访问令牌（不是模型 API Key）。"
    case .unauthorized: return "访问令牌无效，请检查服务器与手机配置。"
    case .conflict: return "同一训练存在不同内容，已停止同步以免覆盖。请保留本机记录并核对。"
    case .response(let code): return "同步服务返回 HTTP \(code)，本机记录仍保留。"
    case .invalidData: return "云端记录格式不正确，本机记录未被替换。"
    case .differentOwner: return "本机历史已绑定其他服务器或演示用户，请使用原配置，避免混合不同用户的记录。"
    case .credentialStorage: return "访问令牌无法安全保存，请重试。"
    case .liveConflict: return "训练状态已变化，正在核对当前会话。"
    }
  }
}

struct CloudHistoryClient: Sendable {
  struct Identity: Decodable, Sendable { let user_id: String }
  struct Record: Decodable, Sendable {
    let id: UUID
    let updated_at: String
    let review: TrainingReview
  }
  struct List: Decodable, Sendable { let records: [Record] }
  struct Upload: Encodable { let review: TrainingReview }

  let baseURL: URL
  let accessToken: String

  init(url: String, accessToken: String) throws {
    guard let url = URL(string: url.trimmingCharacters(in: .whitespacesAndNewlines)),
      url.scheme == "https", url.host != nil, url.user == nil, url.password == nil,
      url.query == nil, url.fragment == nil else { throw CloudHistoryError.invalidURL }
    let token = accessToken.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !token.isEmpty, !token.contains("\n"), !token.contains("\r") else { throw CloudHistoryError.missingToken }
    self.baseURL = url
    self.accessToken = token
  }

  static func encoder() -> JSONEncoder {
    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .iso8601
    encoder.outputFormatting = [.sortedKeys]
    return encoder
  }

  static func decoder() -> JSONDecoder {
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .custom { container in
      let value = try container.singleValueContainer().decode(String.self)
      let format = ISO8601DateFormatter()
      format.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
      if let date = format.date(from: value) { return date }
      format.formatOptions = [.withInternetDateTime]
      guard let date = format.date(from: value) else { throw CloudHistoryError.invalidData }
      return date
    }
    return decoder
  }

  func identity() async throws -> String {
    try Self.decoder().decode(Identity.self, from: await request("v1/me")).user_id
  }

  func list() async throws -> [TrainingReview] {
    let result = try Self.decoder().decode(List.self, from: await request("v1/records"))
    guard result.records.allSatisfy({ $0.id == $0.review.id }),
      Set(result.records.map(\.id)).count == result.records.count else { throw CloudHistoryError.invalidData }
    return result.records.map(\.review)
  }

  func upload(_ review: TrainingReview) async throws {
    _ = try await request("v1/records/\(review.id.uuidString.lowercased())", method: "PUT",
      body: Self.encoder().encode(Upload(review: review)))
  }

  func publishLive(sessionID: UUID, snapshot: CloudLiveSnapshot) async throws {
    _ = try await request("v1/live/sessions/\(sessionID.uuidString.lowercased())", method: "PUT",
      body: Self.encoder().encode(snapshot), live: true)
  }

  private func request(_ path: String, method: String = "GET", body: Data? = nil,
    live: Bool = false) async throws -> Data {
    var request = URLRequest(url: baseURL.appendingPathComponent(path))
    request.httpMethod = method
    request.timeoutInterval = 20
    request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
    request.setValue("application/json", forHTTPHeaderField: "Accept")
    if let body {
      request.httpBody = body
      request.setValue("application/json", forHTTPHeaderField: "Content-Type")
    }
    let (data, response) = try await URLSession.shared.data(for: request)
    guard let response = response as? HTTPURLResponse else { throw CloudHistoryError.invalidData }
    switch response.statusCode {
    case 200..<300: return data
    case 401, 403: throw CloudHistoryError.unauthorized
    case 409:
      if live {
        let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        let detail = object?["detail"] as? [String: Any]
        throw CloudHistoryError.liveConflict(detail?["code"] as? String ?? "unknown")
      }
      throw CloudHistoryError.conflict
    default: throw CloudHistoryError.response(response.statusCode)
    }
  }
}

/// One writer serializes live updates. It retains the initial recording receipt
/// (required to create a session) and coalesces later heartbeats into the newest
/// state. Navigation never owns or cancels this queue.
@MainActor
final class CloudLivePublisher {
  typealias Transport = @Sendable (UUID, CloudLiveSnapshot) async throws -> Void
  private struct Pending: Sendable {
    let sessionID: UUID
    let snapshot: CloudLiveSnapshot
    let opening: Bool
  }
  private let transport: Transport
  private let retryDelay: Duration
  private let onStatus: @MainActor (String) -> Void
  private var pending: [Pending] = []
  private var task: Task<Void, Never>?
  private var invalidated = false
  private var seenSessions: Set<UUID> = []
  private var closedSessions: Set<UUID> = []

  init(retryDelay: Duration = .seconds(3), onStatus: @escaping @MainActor (String) -> Void = { _ in },
    transport: @escaping Transport) {
    self.transport = transport
    self.retryDelay = retryDelay
    self.onStatus = onStatus
  }

  func enqueue(sessionID: UUID, snapshot: CloudLiveSnapshot) {
    guard !invalidated, !closedSessions.contains(sessionID) else { return }
    let opening = !seenSessions.contains(sessionID)
    guard !opening || snapshot.phase == .recording else { return }
    seenSessions.insert(sessionID)
    if opening {
      // An in-flight old upload may finish, but no old queued snapshot can be
      // sent after the new session begins. Its next upload supersedes the old.
      pending.removeAll { $0.sessionID != sessionID }
    }
    // Never replace the opening receipt with finishing/completed before the
    // server has had a chance to create the session.
    pending.removeAll { $0.sessionID == sessionID && !$0.opening }
    pending.append(Pending(sessionID: sessionID, snapshot: snapshot, opening: opening))
    startIfNeeded()
  }

  func invalidate() {
    invalidated = true
    task?.cancel()
    task = nil
    pending.removeAll()
  }

  private func startIfNeeded() {
    guard task == nil, !pending.isEmpty, !invalidated else { return }
    task = Task { [weak self] in
      guard let self else { return }
      defer { task = nil }
      while !Task.isCancelled, !invalidated, !pending.isEmpty {
        let item = pending.removeFirst()
        do {
          try await transport(item.sessionID, item.snapshot)
          try Task.checkCancellation()
          guard !invalidated else { return }
          onStatus("手机状态已同步")
        } catch is CancellationError {
          return
        } catch {
          guard !invalidated, !Task.isCancelled else { return }
          if case CloudHistoryError.liveConflict(let code) = error, code != "active_session" {
            // A lost successful response or a newer publisher may cause 409.
            // Do not replay stale state; a newer queued sequence may proceed.
            onStatus("状态已更新，等待下一次同步")
            if ["stale_session", "publisher_conflict", "session_closed", "stale_sequence",
              "phase_regression", "missing_session_start"].contains(code) {
              closedSessions.insert(item.sessionID)
              pending.removeAll { $0.sessionID == item.sessionID }
            }
            continue
          }
          onStatus("状态同步暂不可用 · 本机记录继续")
          // A newer session supersedes an unreachable old session. Otherwise
          // retain its opening receipt, or retry only its newest queued state.
          let newerSession = pending.contains { $0.sessionID != item.sessionID }
          if !newerSession {
            if item.opening || !pending.contains(where: { $0.sessionID == item.sessionID }) {
              pending.insert(item, at: 0)
            }
          } else {
            pending.removeAll { $0.sessionID == item.sessionID }
          }
          do { try await Task.sleep(for: retryDelay) } catch { return }
        }
      }
    }
  }

  deinit { task?.cancel() }
}

/// Stores only the Fitcore demo access token. Supplier API keys never enter iOS.
@MainActor
enum CloudCredentials {
  private static let service = "fitcore.cloud-demo"
  private static let account = "access-token"
  static func read() -> String? {
    let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
      kSecAttrService as String: service, kSecAttrAccount as String: account,
      kSecReturnData as String: true, kSecMatchLimit as String: kSecMatchLimitOne]
    var result: CFTypeRef?
    guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
      let data = result as? Data else { return nil }
    return String(data: data, encoding: .utf8)
  }

  static func save(_ value: String) throws {
    let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
      kSecAttrService as String: service, kSecAttrAccount as String: account]
    let attributes: [String: Any] = [kSecValueData as String: Data(value.utf8),
      kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly]
    let status = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
    if status == errSecItemNotFound {
      var item = query
      attributes.forEach { item[$0.key] = $0.value }
      guard SecItemAdd(item as CFDictionary, nil) == errSecSuccess else { throw CloudHistoryError.credentialStorage }
    } else if status != errSecSuccess { throw CloudHistoryError.credentialStorage }
  }

  static func remove() {
    let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
      kSecAttrService as String: service, kSecAttrAccount as String: account]
    SecItemDelete(query as CFDictionary)
  }
}
