import Foundation

struct TrainingLocalState: Codable, Equatable {
  var schemaVersion = 1
  var history: [TrainingReview] = []
  var preferences = UserPreferences()
}

@MainActor
protocol TrainingPersistence: AnyObject {
  func load() throws -> TrainingLocalState
  func save(_ state: TrainingLocalState) throws
}

/// Stores JSON locally. Neither the fixture transcript nor preferences leave the phone.
@MainActor
final class UserDefaultsTrainingPersistence: TrainingPersistence {
  private let defaults: UserDefaults
  private let key: String

  init(defaults: UserDefaults = .standard, key: String = "fitcore.local-state.v1") {
    self.defaults = defaults
    self.key = key
  }

  func load() throws -> TrainingLocalState {
    guard let data = defaults.data(forKey: key) else { return TrainingLocalState() }
    return try JSONDecoder().decode(TrainingLocalState.self, from: data)
  }

  func save(_ state: TrainingLocalState) throws {
    defaults.set(try JSONEncoder().encode(state), forKey: key)
  }
}

/// Test dependency: no access to standard UserDefaults or a real user's records.
@MainActor
final class MemoryTrainingPersistence: TrainingPersistence {
  private var data: Data?

  func load() throws -> TrainingLocalState {
    guard let data else { return TrainingLocalState() }
    return try JSONDecoder().decode(TrainingLocalState.self, from: data)
  }

  func save(_ state: TrainingLocalState) throws {
    data = try JSONEncoder().encode(state)
  }
}
