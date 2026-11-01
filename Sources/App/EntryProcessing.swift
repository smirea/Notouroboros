import Foundation

enum ProcessingStage: String, Codable, Hashable, Sendable {
	case finalizeAudio, transcribe, reflect
	var phase: EntryProcessingPhase {
		switch self {
		case .finalizeAudio: .finalizing
		case .transcribe: .transcribing
		case .reflect: .reflecting
		}
	}

	/// Tasks and reminders were stages after reflect; reminders now come from the live recording instead.
	static let retiredStages: Set<String> = ["tasks", "reminders"]
}

enum ProcessingFailureKind: String, Codable, Sendable { case unavailable, unreadableAudio, execution }

struct EntryProcessing: Codable, Hashable, Sendable {
	enum Status: String, Codable, Sendable { case queued, running, partial, failed, canceled, complete }
	var requestID = UUID()
	var requestedAt = Date.now
	var inputRevision: Int
	var stage: ProcessingStage
	var status: Status = .queued
	var attemptID: UUID?
	var completedStages: Set<ProcessingStage> = []
	var skippedStages: Set<ProcessingStage> = []
	var failureKind: ProcessingFailureKind?
	var partialTranscript: TranscriptionProgress?
	var failure: String?
	var retryAfter: Date?
	var failedAttempts = 0

	init(inputRevision: Int, stage: ProcessingStage) {
		self.inputRevision = inputRevision
		self.stage = stage
	}

	private enum CodingKeys: String, CodingKey {
		case requestID, requestedAt, inputRevision, stage, status, attemptID, completedStages, skippedStages
		case failureKind, partialTranscript, failure, retryAfter, failedAttempts
	}

	init(from decoder: Decoder) throws {
		let values = try decoder.container(keyedBy: CodingKeys.self)
		requestID = try values.decode(UUID.self, forKey: .requestID)
		requestedAt = try values.decode(Date.self, forKey: .requestedAt)
		inputRevision = try values.decode(Int.self, forKey: .inputRevision)
		let rawStage = try values.decode(String.self, forKey: .stage)
		let retired = ProcessingStage.retiredStages.contains(rawStage)
		guard let stage = retired ? .reflect : ProcessingStage(rawValue: rawStage) else {
			throw DecodingError.dataCorruptedError(forKey: .stage, in: values, debugDescription: "Unknown stage \(rawStage)")
		}
		self.stage = stage
		status = retired ? .complete : try values.decode(Status.self, forKey: .status)
		attemptID = retired ? nil : try values.decodeIfPresent(UUID.self, forKey: .attemptID)
		completedStages = Set((try values.decodeIfPresent([String].self, forKey: .completedStages) ?? []).compactMap(ProcessingStage.init))
		skippedStages = Set((try values.decodeIfPresent([String].self, forKey: .skippedStages) ?? []).compactMap(ProcessingStage.init))
		guard !retired else { return }
		failureKind = try values.decodeIfPresent(ProcessingFailureKind.self, forKey: .failureKind)
		partialTranscript = try values.decodeIfPresent(TranscriptionProgress.self, forKey: .partialTranscript)
		failure = try values.decodeIfPresent(String.self, forKey: .failure)
		retryAfter = try values.decodeIfPresent(Date.self, forKey: .retryAfter)
		failedAttempts = max(0, try values.decodeIfPresent(Int.self, forKey: .failedAttempts) ?? 0)
	}

	static func retryDelay(after failures: Int) -> TimeInterval? {
		let delays: [TimeInterval] = [60, 300, 900]
		return (1...delays.count).contains(failures) ? delays[failures - 1] : nil
	}

	var phase: EntryProcessingPhase? {
		switch status {
		case .queued: .queued
		case .running: stage.phase
		case .partial: .partial
		case .failed: stage == .finalizeAudio ? .finalizationFailed : .failed
		case .canceled: .canceled
		case .complete: nil
		}
	}
}

struct ProcessingLease: Hashable, Sendable {
	let entryID: UUID
	let requestID: UUID
	let attemptID: UUID
	let inputRevision: Int
	let stage: ProcessingStage
}

enum ProcessingDeadline {
	static func seconds(stage: ProcessingStage, entry: JournalEntry) -> TimeInterval {
		let duration = entry.duration.isFinite ? max(0, entry.duration) : 0
		let context = Double(entry.transcript.utf8.count)
		switch stage {
		case .finalizeAudio: return max(120, duration * 2 + 60)
		case .transcribe: return max(180, duration * 3 + 120)
		case .reflect: return max(180, context / 20 + 120)
		}
	}
}

actor ProcessingTemporaryFiles {
	static let shared = ProcessingTemporaryFiles()
	static let launchDate = Date.now
	private var cleaned = false

	func cleanOnce() -> [String] {
		guard !cleaned else { return [] }
		cleaned = true
		return Self.clean(in: FileManager.default.temporaryDirectory, before: Self.launchDate)
	}

	static func clean(in directory: URL, before cutoff: Date = .distantFuture) -> [String] {
		let manager = FileManager.default
		do {
			let files = try manager.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.isRegularFileKey, .contentModificationDateKey])
			var issues: [String] = []
			for file in files {
				let stem = file.deletingPathExtension().lastPathComponent
				let patterns = [("speech-input-", "caf"), ("elevenlabs-", "multipart")]
				guard patterns.contains(where: { prefix, ext in
					guard file.pathExtension == ext, stem.hasPrefix(prefix) else { return false }
					let id = String(stem.dropFirst(prefix.count))
					return id.count == 36 && UUID(uuidString: id) != nil
				}) else { continue }
				do {
					let values = try file.resourceValues(forKeys: [.isRegularFileKey, .contentModificationDateKey])
					guard values.isRegularFile == true, let modified = values.contentModificationDate, modified < cutoff else { continue }
					try manager.removeItem(at: file)
				} catch { issues.append("An abandoned processing temporary file could not be removed.") }
			}
			return issues
		} catch { return ["Abandoned processing temporary files could not be checked."] }
	}
}

struct ProcessingWork: Sendable {
	let lease: ProcessingLease
	let record: JournalRecord
}

enum JournalEdit: Sendable {
	case location(JournalLocation)

	func apply(to entry: inout JournalEntry) {
		switch self {
		case let .location(value): entry.location = value
		}
	}
}

struct ProcessingServices: Sendable {
	var transcribe: @Sendable (URL, Bool, String?, @escaping @Sendable (TranscriptionProgress) -> Void) async throws -> TranscriptionResult
	var reflect: @Sendable (String, Bool) async -> ReflectionResult

	static let live = ProcessingServices(
		transcribe: { url, preferred, key, update in
			try await AudioTranscriber.transcribe(url: url, preferElevenLabs: preferred, elevenLabsAPIKey: key, onUpdate: update)
		},
		reflect: { await ReflectionEngine.reflect(on: $0, includeSummary: $1) })
}
