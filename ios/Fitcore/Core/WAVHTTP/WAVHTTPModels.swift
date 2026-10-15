import Foundation

// Field-level DTOs for the frozen V1.1 WAV HTTP contract (2026-10-15).
// Every concrete field is taken from reference/api/WAV_HTTP_API_2026-10-15.md,
// EVENT_FINISH_REPORT_2026-10-15.md, or the sanitized samples in
// STABLE_BASELINE_WAV_HTTP_REPORT_2026-10-15.md. Shapes those documents leave
// open are decoded as JSONValue instead of invented structures.

// MARK: - /health (new shape: status + model_provider; old service/environment is gone)

struct BackendHealth: Decodable, Sendable, Equatable {
    let status: String
    let modelProvider: String?

    enum CodingKeys: String, CodingKey {
        case status
        case modelProvider = "model_provider"
    }
}

// MARK: - Session context

struct SessionContext: Decodable, Sendable, Equatable {
    let sessionID: String
    let version: Int
    let status: String
    let activeExerciseInstanceID: Int?
    let activeExerciseName: String?
    let lastCompletedSetID: Int?
    let lastReportedWeight: Double?
    /// Shape not pinned by the frozen samples (always null there); kept verbatim.
    let nextSetPlan: JSONValue?

    enum CodingKeys: String, CodingKey {
        case sessionID = "session_id"
        case version
        case status
        case activeExerciseInstanceID = "active_exercise_instance_id"
        case activeExerciseName = "active_exercise_name"
        case lastCompletedSetID = "last_completed_set_id"
        case lastReportedWeight = "last_reported_weight"
        case nextSetPlan = "next_set_plan"
    }
}

// MARK: - Audio jobs

enum AudioJobStatus: String, Decodable, Sendable, Equatable {
    case queued
    case asrRunning = "asr_running"
    case finalReady = "final_ready"
    case llmRunning = "llm_running"
    case done
}

enum FactDecision: String, Decodable, Sendable, Equatable {
    case commit = "COMMIT"
    case `defer` = "DEFER"
    case reject = "REJECT"
}

struct AudioMetadataDTO: Decodable, Sendable, Equatable {
    let sampleRate: Int
    let channels: Int
    let bitsPerSample: Int
    let frames: Int
    let durationSeconds: Double
    let rmsDBFS: Double
    let peakDBFS: Double
    let clippedFraction: Double
    let nonSilent: Bool

    enum CodingKeys: String, CodingKey {
        case sampleRate = "sample_rate"
        case channels
        case bitsPerSample = "bits_per_sample"
        case frames
        case durationSeconds = "duration_seconds"
        case rmsDBFS = "rms_dbfs"
        case peakDBFS = "peak_dbfs"
        case clippedFraction = "clipped_fraction"
        case nonSilent = "non_silent"
    }
}

struct CommittedOperation: Decodable, Sendable, Equatable {
    let type: String
    let id: Int?
    let exerciseInstanceID: Int?
    let exercise: String?
    let setNumber: Int?
    let weightKg: Double?
    let reps: Int?
    let weightProvenance: String?
    let note: String?

    enum CodingKeys: String, CodingKey {
        case type
        case id
        case exerciseInstanceID = "exercise_instance_id"
        case exercise
        case setNumber = "set_number"
        case weightKg = "weight_kg"
        case reps
        case weightProvenance = "weight_provenance"
        case note
    }
}

struct AudioJobOutcome: Decodable, Sendable, Equatable {
    let utteranceID: String
    let decision: FactDecision
    let contextVersion: Int
    let committed: [CommittedOperation]?
    let reason: String?
    /// Not pinned by frozen samples; kept verbatim.
    let semanticDiagnostics: JSONValue?
    let reparse: JSONValue?

    enum CodingKeys: String, CodingKey {
        case utteranceID = "utterance_id"
        case decision
        case contextVersion = "context_version"
        case committed
        case reason
        case semanticDiagnostics = "semantic_diagnostics"
        case reparse
    }
}

struct AudioJob: Decodable, Sendable, Equatable {
    let sessionID: String
    let utteranceID: String
    let sequence: Int
    let audioSHA256: String
    let audioSource: String
    let sourceType: String
    let speakerStatus: String
    let status: AudioJobStatus
    let finalText: String?
    let asrAttempts: Int
    let llmAttempts: Int
    let errorType: String?
    let audioMetadata: AudioMetadataDTO
    let outcome: AudioJobOutcome?
    /// Not pinned by frozen samples; kept verbatim.
    let asrDiagnostics: JSONValue?

    enum CodingKeys: String, CodingKey {
        case sessionID = "session_id"
        case utteranceID = "utterance_id"
        case sequence
        case audioSHA256 = "audio_sha256"
        case audioSource = "audio_source"
        case sourceType = "source_type"
        case speakerStatus = "speaker_status"
        case status
        case finalText = "final_text"
        case asrAttempts = "asr_attempts"
        case llmAttempts = "llm_attempts"
        case errorType = "error_type"
        case audioMetadata = "audio_metadata"
        case outcome
        case asrDiagnostics = "asr_diagnostics"
    }
}

/// Response of POST /v1/sessions/{sid}/audio-jobs (202). `acceptance: persisted`
/// only means the WAV and metadata were committed; it never implies ASR or facts.
struct UploadAccepted: Decodable, Sendable, Equatable {
    let acceptance: String
    let speakerVerification: String
    let sourceAssurance: String?
    let job: AudioJob

    enum CodingKeys: String, CodingKey {
        case acceptance
        case speakerVerification = "speaker_verification"
        case sourceAssurance = "source_assurance"
        case job
    }
}

/// Response of GET /v1/sessions/{sid}/audio-jobs/{utterance_id}. When
/// `automaticRetryExhausted` is true the client must stop automatic retries.
struct AudioJobStatusResponse: Decodable, Sendable, Equatable {
    let speakerVerification: String
    let automaticRetryExhausted: Bool
    let job: AudioJob

    enum CodingKeys: String, CodingKey {
        case speakerVerification = "speaker_verification"
        case automaticRetryExhausted = "automatic_retry_exhausted"
        case job
    }
}

// MARK: - Facts, events, pending

struct TrainingFactDTO: Decodable, Sendable, Equatable {
    let id: Int
    let exerciseInstanceID: Int
    let exercise: String
    let setNumber: Int
    let weightKg: Double
    let reps: Int
    let weightProvenance: String
    let weightSourceFactID: Int?
    let sourceUtteranceID: String

    enum CodingKeys: String, CodingKey {
        case id
        case exerciseInstanceID = "exercise_instance_id"
        case exercise
        case setNumber = "set_number"
        case weightKg = "weight_kg"
        case reps
        case weightProvenance = "weight_provenance"
        case weightSourceFactID = "weight_source_fact_id"
        case sourceUtteranceID = "source_utterance_id"
    }
}

enum PersistentEventType: String, Decodable, Sendable, Equatable {
    case transcriptFinal = "TRANSCRIPT_FINAL"
    case factCommitted = "FACT_COMMITTED"
    case operationDeferred = "OPERATION_DEFERRED"
    case inputRejected = "INPUT_REJECTED"
    case processingError = "PROCESSING_ERROR"
}

struct PersistentEvent: Decodable, Sendable, Equatable {
    let eventSeq: Int
    let eventID: String
    let type: PersistentEventType
    let utteranceID: String?
    /// Free-form per event type; kept verbatim instead of guessing per-type schemas.
    let payload: JSONValue
    let createdAt: String

    enum CodingKeys: String, CodingKey {
        case eventSeq = "event_seq"
        case eventID = "event_id"
        case type
        case utteranceID = "utterance_id"
        case payload
        case createdAt = "created_at"
    }
}

struct EventsPage: Decodable, Sendable, Equatable {
    let events: [PersistentEvent]
    let nextCursor: Int
    let hasMore: Bool

    enum CodingKeys: String, CodingKey {
        case events
        case nextCursor = "next_cursor"
        case hasMore = "has_more"
    }
}

/// Pending items have no frozen field-level sample (pending_count was 0 in the
/// baseline). Everything is preserved verbatim; `status` and common identifier
/// keys are surfaced as convenience accessors. Field-level gap: GAP-PENDING-SHAPE.
struct PendingItem: Decodable, Sendable, Equatable {
    let fields: [String: JSONValue]

    init(from decoder: Decoder) throws {
        fields = try [String: JSONValue](from: decoder)
    }

    var status: String? { fields["status"]?.stringValue }
    var isOpen: Bool { status == "open" }
    /// Tries the documented naming variants without inventing new ones.
    var pendingID: String? {
        for key in ["id", "pending_id", "pendingID"] {
            if let value = fields[key] {
                if let text = value.stringValue { return text }
                if case .number(let number) = value {
                    if number.rounded() == number, let integer = Int(exactly: number) {
                        return String(integer)
                    }
                    return String(number)
                }
            }
        }
        return nil
    }
}

/// Reconciles server-owned records without inventing client facts.
/// `/facts` is an authoritative current snapshot, so same-id corrections replace
/// old values. `/pending` may contain processed rows; only currently-open items
/// belong in the user-facing Pending list. Unknown fields remain untouched.
enum RecordSnapshotReconciler {
    static func facts(
        current _: [TrainingFactDTO],
        fetched: [TrainingFactDTO]
    ) -> [TrainingFactDTO] {
        fetched
    }

    static func pending(
        current _: [PendingItem],
        fetched: [PendingItem]
    ) -> [PendingItem] {
        fetched.filter(\.isOpen)
    }
}

/// Confirmed resolve fields only (resolution_id, action, context_version).
/// The exact confirm_set payload fields are NOT pinned by the provided contract
/// and are therefore not invented here. Field-level gap: GAP-PENDING-RESOLVE-BODY.
struct PendingResolution: Encodable, Sendable, Equatable {
    let resolutionID: String
    let action: String
    let contextVersion: Int

    enum CodingKeys: String, CodingKey {
        case resolutionID = "resolution_id"
        case action
        case contextVersion = "context_version"
    }
}

// MARK: - Finish and review

struct UnfinishedJob: Decodable, Sendable, Equatable {
    let utteranceID: String
    let sequence: Int
    let audioSHA256: String
    let status: AudioJobStatus
    let errorType: String?

    enum CodingKeys: String, CodingKey {
        case utteranceID = "utterance_id"
        case sequence
        case audioSHA256 = "audio_sha256"
        case status
        case errorType = "error_type"
    }
}

struct SessionReviewDTO: Decodable, Sendable, Equatable {
    let sessionID: String
    let contextVersion: Int
    let totalSets: Int
    let totalReps: Int
    let volumeKgReps: Double
    let pendingCount: Int
    let facts: [TrainingFactDTO]

    enum CodingKeys: String, CodingKey {
        case sessionID = "session_id"
        case contextVersion = "context_version"
        case totalSets = "total_sets"
        case totalReps = "total_reps"
        case volumeKgReps = "volume_kg_reps"
        case pendingCount = "pending_count"
        case facts
    }
}

/// Shared envelope for POST/GET finish. The 409 awaiting_audio body carries the
/// same fields with complete=false, acceptance_closed=false and missing sequences.
struct FinishResponse: Decodable, Sendable, Equatable {
    let sessionID: String
    let finishID: String
    let lastSequence: Int
    let state: String
    let complete: Bool
    let acceptanceClosed: Bool
    let missingSequences: [Int]
    let missingCount: Int
    let unfinished: [UnfinishedJob]
    let acceptedCount: Int
    let readyToFinalize: Bool
    let review: SessionReviewDTO?

    enum CodingKeys: String, CodingKey {
        case sessionID = "session_id"
        case finishID = "finish_id"
        case lastSequence = "last_sequence"
        case state
        case complete
        case acceptanceClosed = "acceptance_closed"
        case missingSequences = "missing_sequences"
        case missingCount = "missing_count"
        case unfinished
        case acceptedCount = "accepted_count"
        case readyToFinalize = "ready_to_finalize"
        case review
    }
}

struct FinishRequestBody: Encodable, Sendable, Equatable {
    let finishID: String
    let lastSequence: Int

    enum CodingKeys: String, CodingKey {
        case finishID = "finish_id"
        case lastSequence = "last_sequence"
    }
}

struct CreateSessionRequestBody: Encodable, Sendable, Equatable {
    let sessionID: String

    enum CodingKeys: String, CodingKey {
        case sessionID = "session_id"
    }
}
