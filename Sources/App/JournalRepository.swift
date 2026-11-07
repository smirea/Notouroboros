import AVFAudio
import Foundation

struct JournalRecord: Codable, Sendable {
	enum State: String, Codable { case recording, saved, deleted }
	private enum CodingKeys: String, CodingKey {
		case schemaVersion, id, entry, state, ownedAudioFilenames, inputRevision, revision, processing
		case contentRevision, exportedRevision, cloudRetry, cloudAudioReceipt, cloudDeletionReferences, cloudMetadataReceipt
		case taskDelivery, remoteTasks
	}
	private enum RetiredDelivery: String, CodingKey { case draft }
	var schemaVersion = 1
	let id: UUID
	var entry: JournalEntry?
	var state: State
	var ownedAudioFilenames: Set<String>
	var inputRevision: Int = 0
	var revision: Int = 0
	var processing: EntryProcessing?
	var contentRevision = 0
	var exportedRevision = 0
	var cloudRetry: CloudRetryState?
	var cloudAudioReceipt: CloudAudioReceipt?
	var cloudMetadataReceipt: CloudMetadataReceipt?
	var cloudDeletionReferences: Set<String> = []
	var taskDelivery = MemoTaskDelivery.notExtracted
	var remoteTasks: [RemoteMemoTask]?

	init(entry: JournalEntry, state: State = .saved, ownedAudioFilenames: Set<String> = []) {
		id = entry.id
		self.entry = entry
		self.state = state
		self.ownedAudioFilenames = ownedAudioFilenames.union(entry.audioFilename.map { [$0] } ?? [])
	}

	init(from decoder: Decoder) throws {
		let values = try decoder.container(keyedBy: CodingKeys.self)
		schemaVersion = try values.decode(Int.self, forKey: .schemaVersion)
		id = try values.decode(UUID.self, forKey: .id)
		entry = try values.decodeIfPresent(JournalEntry.self, forKey: .entry)
		state = try values.decode(State.self, forKey: .state)
		ownedAudioFilenames = try values.decode(Set<String>.self, forKey: .ownedAudioFilenames)
		inputRevision = try values.decodeIfPresent(Int.self, forKey: .inputRevision) ?? 0
		revision = try values.decodeIfPresent(Int.self, forKey: .revision) ?? 0
		processing = try values.decodeIfPresent(EntryProcessing.self, forKey: .processing)
		contentRevision = try values.decodeIfPresent(Int.self, forKey: .contentRevision) ?? 1
		exportedRevision = try values.decodeIfPresent(Int.self, forKey: .exportedRevision) ?? 0
		cloudRetry = try values.decodeIfPresent(CloudRetryState.self, forKey: .cloudRetry)
		cloudAudioReceipt = try values.decodeIfPresent(CloudAudioReceipt.self, forKey: .cloudAudioReceipt)
		cloudMetadataReceipt = try values.decodeIfPresent(CloudMetadataReceipt.self, forKey: .cloudMetadataReceipt)
		cloudDeletionReferences = try values.decodeIfPresent(Set<String>.self, forKey: .cloudDeletionReferences)
			?? (state == .deleted ? ownedAudioFilenames.union([id.uuidString]) : [])
		// Reminder drafts were unconfirmed live extraction output, retired with it; such a note keeps no tasks.
		if (try? values.nestedContainer(keyedBy: RetiredDelivery.self, forKey: .taskDelivery))?.contains(.draft) == true {
			taskDelivery = .notExtracted
			entry?.tasks = []
			entry?.taskModel = nil
		} else {
			taskDelivery = try values.decodeIfPresent(MemoTaskDelivery.self, forKey: .taskDelivery) ?? .notExtracted
		}
		remoteTasks = try values.decodeIfPresent([RemoteMemoTask].self, forKey: .remoteTasks)
	}
}

struct TaskDeliveryJob: Equatable, Sendable {
	let id: UUID
	let recordedAt: Date
	let tasks: [MemoTask]
}

struct JournalLoad: Sendable {
	var entries: [JournalEntry]
	var records: [JournalRecord]
	var issues: [String]
	var deletionReferences: Set<String>
}

actor JournalRepository {
	private let rootURL: URL
	private let recordsURL: URL
	private let recordingsURL: URL
	private let fileManager = FileManager.default
	private var records: [UUID: JournalRecord] = [:]
	private var reservedIDs = Set<UUID>()
	private var didLoad = false
	private var loadIssues: [String] = []
	#if DEBUG
	var audioPublicationCheckpoint: (@Sendable () -> Void)?
	func setAudioPublicationCheckpoint(_ checkpoint: @escaping @Sendable () -> Void) {
		audioPublicationCheckpoint = checkpoint
	}
	#endif

	init(rootURL: URL) {
		self.rootURL = rootURL
		recordsURL = rootURL.appendingPathComponent("Records", isDirectory: true)
		recordingsURL = rootURL.appendingPathComponent("Recordings", isDirectory: true)
	}

	var isLoaded: Bool { didLoad }

	func load() throws -> JournalLoad {
		guard !didLoad else { return snapshot(issues: loadIssues) }
		records.removeAll()
		reservedIDs.removeAll()
		var issues = try prepareDirectories()
		let urls = try fileManager.contentsOfDirectory(at: recordsURL, includingPropertiesForKeys: nil)
		for url in urls where url.pathExtension == "json" {
			guard let id = UUID(uuidString: url.deletingPathExtension().lastPathComponent) else {
				issues.append("An unrecognized note record was preserved.")
				continue
			}
			reservedIDs.insert(id)
			do {
				let record = try JSONDecoder().decode(JournalRecord.self, from: Data(contentsOf: url))
				guard record.id == id, record.schemaVersion == 1,
					(record.state == .deleted ? record.entry == nil : record.entry?.id == id),
					record.ownedAudioFilenames.allSatisfy(Self.isFilename),
					record.cloudDeletionReferences.allSatisfy(Self.isFilename), record.contentRevision >= 1,
					record.exportedRevision >= 0, record.exportedRevision <= record.contentRevision,
					record.entry?.audioFilename.map(Self.isFilename) ?? true
				else { throw RepositoryError.invalidRecord }
				records[id] = record
			} catch {
				issues.append("Note \(id.uuidString.prefix(8)) could not be read. Its original files were preserved.")
			}
		}
		try migrateLegacyEntries(issues: &issues)
		migratePendingRecording(issues: &issues)
		try recoverRecordings(issues: &issues)
		migrateProcessing(issues: &issues)
		didLoad = true
		loadIssues = issues
		return snapshot(issues: issues)
	}

	func beginRecording(calendarEvent: JournalCalendarEvent?) throws -> JournalEntry {
		try requireLoaded()
		let id = UUID()
		let entry = JournalEntry(id: id, duration: 0, transcript: "", headline: "Processing recording",
			audioFilename: "\(id.uuidString).\(RecordingAudioFormat.fileExtension)", calendarEvent: calendarEvent)
		try write(JournalRecord(entry: entry, state: .recording,
			ownedAudioFilenames: ["\(id.uuidString).m4a", "\(id.uuidString).caf", "\(id.uuidString).aac"]))
		return entry
	}

	func checkpoint(id: UUID, duration: TimeInterval) throws {
		guard var record = records[id], record.state == .recording else { return }
		let elapsed = max(record.entry?.duration ?? 0, duration)
		record.entry?.duration = elapsed
		try write(record)
	}

	func finishRecording(id: UUID) throws -> JournalEntry {
		try requireLoaded()
		guard var record = records[id], record.state != .deleted, var entry = record.entry else {
			throw RepositoryError.unavailableRecord
		}
		guard let filename = entry.audioFilename else { throw RepositoryError.invalidAudio }
		entry.duration = try Self.audioDuration(at: recordingsURL.appendingPathComponent(filename))
		record.entry = entry
		record.state = .saved
		if record.processing == nil { record.processing = newProcessing(for: record) }
		try write(record)
		return entry
	}

	func save(_ entries: [JournalEntry]) throws {
		try requireLoaded()
		for var entry in entries {
			if records[entry.id]?.state == .deleted { continue }
			if reservedIDs.contains(entry.id), records[entry.id] == nil { throw RepositoryError.invalidRecord }
			if let committed = records[entry.id]?.entry {
				// Media publication owns these fields; an older UI snapshot must not undo it.
				entry.audioFilename = committed.audioFilename
				entry.duration = committed.duration
			}
			if records[entry.id]?.entry == entry { continue }
			var record = records[entry.id] ?? JournalRecord(entry: entry)
			record.entry = entry
			if let filename = entry.audioFilename { record.ownedAudioFilenames.insert(filename) }
			try write(record)
		}
	}

	func delete(id: UUID) throws -> Set<String> {
		try requireLoaded()
		guard var record = records[id] else { throw RepositoryError.unavailableRecord }
		record.state = .deleted
		record.entry = nil
		record.processing = nil
		record.taskDelivery = .notExtracted
		record.remoteTasks = nil
		try write(record)
		return records[id]!.cloudDeletionReferences
	}

	func cleanupDeletedAudio(id: UUID) throws {
		guard let record = records[id], record.state == .deleted else { return }
		for filename in record.ownedAudioFilenames {
			do { try fileManager.removeItem(at: recordingsURL.appendingPathComponent(filename)) }
			catch where Self.isMissing(error) {}
		}
	}

	func record(id: UUID) -> JournalRecord? { records[id] }

	func prepareAudioFinalization(id: UUID) throws -> AudioFinalizationRequest {
		try requireLoaded()
		guard var record = records[id], record.state == .saved,
			let filename = record.entry?.audioFilename, RecordingAudioFormat.needsFinalization(filename)
		else { throw RepositoryError.unavailableRecord }
		let sourceURL = recordingsURL.appendingPathComponent(filename)
		let destinationURL = sourceURL.deletingPathExtension().appendingPathExtension("m4a")
		let stagingURL = recordingsURL.appendingPathComponent(".\(id.uuidString)-\(UUID().uuidString).finalizing.m4a")
		record.ownedAudioFilenames.formUnion([destinationURL.lastPathComponent, stagingURL.lastPathComponent])
		try write(record)
		return AudioFinalizationRequest(entryID: id, sourceURL: sourceURL,
			destinationURL: destinationURL, stagingURL: stagingURL)
	}

	func commitFinalizedAudio(_ audio: FinalizedAudio, lease: ProcessingLease? = nil) throws -> JournalEntry {
		try Task.checkCancellation()
		let request = audio.request
		if let lease {
			guard lease.entryID == request.entryID, lease.stage == .finalizeAudio else { throw RepositoryError.staleProcessing }
			_ = try currentRecord(for: lease)
		}
		guard var record = records[request.entryID], record.state == .saved,
			var entry = record.entry, entry.audioFilename == request.sourceURL.lastPathComponent,
			record.ownedAudioFilenames.contains(request.stagingURL.lastPathComponent),
			audio.preparedURL == request.stagingURL || audio.preparedURL == request.destinationURL
		else { throw RepositoryError.unavailableRecord }
		if audio.preparedURL != request.destinationURL {
			if fileManager.fileExists(atPath: request.destinationURL.path) {
				_ = try fileManager.replaceItemAt(request.destinationURL, withItemAt: audio.preparedURL)
			} else {
				try fileManager.moveItem(at: audio.preparedURL, to: request.destinationURL)
			}
		}
		#if DEBUG
		audioPublicationCheckpoint?()
		#endif
		entry.audioFilename = request.destinationURL.lastPathComponent
		entry.duration = audio.duration
		record.entry = entry
		if record.processing?.stage == .finalizeAudio { advance(&record, after: .finalizeAudio) }
		try write(record)
		try? cleanupFinalizedAudio(id: entry.id)
		return entry
	}

	func cleanupFinalizedAudio(id: UUID) throws {
		guard let record = records[id], record.state == .saved,
			let filename = record.entry?.audioFilename, filename.hasSuffix(".m4a")
		else { return }
		guard record.ownedAudioFilenames.contains(where: { $0 != filename }) else { return }
		_ = try Self.audioDuration(at: recordingsURL.appendingPathComponent(filename))
		for owned in record.ownedAudioFilenames where owned != filename {
			do { try fileManager.removeItem(at: recordingsURL.appendingPathComponent(owned)) }
			catch where Self.isMissing(error) {}
		}
	}

	func committedEntries() -> [JournalEntry] {
		records.values.filter { $0.state == .saved }.compactMap(\.entry).sorted { $0.createdAt > $1.createdAt }
	}

	func cloudJobs(repair: Bool = false, now: Date = .now) -> [CloudNoteJob] {
		records.values.filter { record in
			guard record.state == .deleted || (record.state == .saved && record.entry?.audioFilename?.hasSuffix(".m4a") == true) else { return false }
			return repair || (record.contentRevision > record.exportedRevision && (record.cloudRetry?.isDue(at: now) ?? true))
		}.map { CloudNoteJob(id: $0.id, contentRevision: $0.contentRevision, entry: $0.entry,
			deletionReferences: $0.cloudDeletionReferences, audioReceipt: $0.cloudAudioReceipt, metadataReceipt: $0.cloudMetadataReceipt) }
		.sorted { $0.id.uuidString < $1.id.uuidString }
	}

	func acknowledgeCloud(job: CloudNoteJob, audioReceipt: CloudAudioReceipt? = nil, metadataReceipt: CloudMetadataReceipt? = nil) throws -> JournalRecord? {
		guard var record = currentCloudRecord(job) else { return nil }
		guard record.exportedRevision != job.contentRevision || record.cloudRetry != nil
			|| (audioReceipt != nil && record.cloudAudioReceipt != audioReceipt)
			|| (metadataReceipt != nil && record.cloudMetadataReceipt != metadataReceipt) else { return record }
		record.exportedRevision = job.contentRevision
		record.cloudRetry = nil
		if let audioReceipt { record.cloudAudioReceipt = audioReceipt }
		if let metadataReceipt { record.cloudMetadataReceipt = metadataReceipt }
		try write(record)
		return records[record.id]
	}

	func failCloud(job: CloudNoteJob, message: String, now: Date = .now) throws -> JournalRecord? {
		guard var record = currentCloudRecord(job) else { return nil }
		record.exportedRevision = min(record.exportedRevision, max(0, record.contentRevision - 1))
		record.cloudRetry = .failed(previous: record.cloudRetry, message: message, now: now)
		try write(record)
		return records[record.id]
	}

	func nextCloudRetry() -> Date? {
		records.values.compactMap { record -> Date? in
			guard record.contentRevision > record.exportedRevision,
				record.state == .deleted || (record.state == .saved && record.entry?.audioFilename?.hasSuffix(".m4a") == true)
			else { return nil }
			if let retry = record.cloudRetry { return retry.retryAfter }
			return .distantPast
		}.min()
	}

	private func currentCloudRecord(_ job: CloudNoteJob) -> JournalRecord? {
		guard let record = records[job.id], record.contentRevision == job.contentRevision,
			record.entry == job.entry, record.state == (job.entry == nil ? .deleted : .saved),
			job.entry != nil || record.cloudDeletionReferences == job.deletionReferences else { return nil }
		return record
	}

	#if DEBUG
	/// A memo with a finished transcript and no audio, queued at `stage`.
	func seed(_ entry: JournalEntry, at stage: ProcessingStage) throws -> JournalRecord {
		try requireLoaded()
		var record = JournalRecord(entry: entry)
		var job = EntryProcessing(inputRevision: 0, stage: stage)
		job.completedStages = [.transcribe]
		record.processing = job
		try write(record)
		return records[entry.id]!
	}
	#endif

	func requestProcessing(id: UUID, startAt stage: ProcessingStage? = nil) throws -> JournalRecord {
		guard var record = records[id], record.state == .saved else { throw RepositoryError.unavailableRecord }
		var job = newProcessing(for: record)
		job.completedStages = record.processing?.completedStages ?? []
		if let stage, record.entry?.audioFilename.map(RecordingAudioFormat.needsFinalization) != true { job.stage = stage }
		record.processing = job
		try write(record)
		return records[id]!
	}

	func retryProcessing(id: UUID) throws -> JournalRecord {
		guard var record = records[id], record.state == .saved, var job = record.processing else {
			throw RepositoryError.unavailableRecord
		}
		job.status = .queued
		job.attemptID = nil
		job.failure = nil
		job.failureKind = nil
		job.retryAfter = nil
		job.failedAttempts = 0
		job.inputRevision = record.inputRevision
		record.processing = job
		try write(record)
		return records[id]!
	}

	func claimProcessing(now: Date = .now, excluding excludedIDs: Set<UUID> = []) throws -> ProcessingWork? {
		let candidates = records.values.filter { record in
			guard record.state == .saved, !excludedIDs.contains(record.id), let job = record.processing else { return false }
			return job.status == .queued || ((job.status == .failed || job.status == .partial) && job.retryAfter.map { $0 <= now } == true)
		}.sorted { ($0.processing!.requestedAt, $0.id.uuidString) < ($1.processing!.requestedAt, $1.id.uuidString) }
		guard var record = candidates.first, var job = record.processing else { return nil }
		job.status = .running
		job.attemptID = UUID()
		job.retryAfter = nil
		job.failure = nil
		job.failureKind = nil
		job.inputRevision = record.inputRevision
		record.processing = job
		try write(record)
		let lease = ProcessingLease(entryID: record.id, requestID: job.requestID, attemptID: job.attemptID!,
			inputRevision: job.inputRevision, stage: job.stage)
		return ProcessingWork(lease: lease, record: records[record.id]!)
	}

	func nextProcessingRetry(excluding excludedIDs: Set<UUID> = []) -> Date? {
		records.values.compactMap { record -> Date? in
			guard record.state == .saved, !excludedIDs.contains(record.id), let job = record.processing else { return nil }
			if job.status == .queued { return .distantPast }
			return job.status == .failed || job.status == .partial ? job.retryAfter : nil
		}.min()
	}

	func commitTranscription(_ result: TranscriptionResult, lease: ProcessingLease) throws -> JournalRecord {
		var record = try currentRecord(for: lease)
		guard lease.stage == .transcribe else { throw RepositoryError.staleProcessing }
		record.entry?.transcript = result.transcript.trimmingCharacters(in: .whitespacesAndNewlines)
		record.entry?.transcriptModel = result.modelName
		record.entry?.analysis = nil
		record.processing?.partialTranscript = nil
		record.inputRevision += 1
		advance(&record, after: .transcribe)
		try write(record)
		return records[record.id]!
	}

	func commitReflection(_ result: ReflectionResult, lease: ProcessingLease) throws -> JournalRecord {
		var record = try currentRecord(for: lease)
		guard lease.stage == .reflect, result.outcome.isComplete else { throw RepositoryError.staleProcessing }
		record.entry?.headline = result.headline
		record.entry?.summary = result.summary
		record.entry?.summaryModel = result.modelName
		let analysis = result.analysisContext.map { MemoAnalysis(transcript: record.entry?.transcript ?? "", notes: $0) }
		record.entry?.analysis = analysis
		advance(&record, after: .reflect)
		if result.outcome == .skipped { record.processing?.skippedStages.insert(.reflect) }
		try write(record)
		return records[record.id]!
	}

	func taskDeliveryJobs(repair: Bool = false, now: Date = .now) -> [TaskDeliveryJob] {
		records.values.compactMap { record -> TaskDeliveryJob? in
			guard record.state == .saved, let entry = record.entry, !entry.tasks.isEmpty else { return nil }
			switch record.taskDelivery {
			case let .pending(retry):
				guard repair || retry.map({ $0.isDue(at: now) }) ?? true else { return nil }
			case .blocked:
				guard repair else { return nil }
			case .notExtracted, .delivered:
				return nil
			}
			return TaskDeliveryJob(id: record.id, recordedAt: entry.createdAt, tasks: entry.tasks)
		}.sorted { ($0.recordedAt, $0.id.uuidString) < ($1.recordedAt, $1.id.uuidString) }
	}

	/// ProcrastiMate now holds what the job sent, so those tasks become the memo's.
	func acknowledgeTasks(_ job: TaskDeliveryJob, remote: [RemoteMemoTask]) throws -> JournalRecord? {
		guard var record = records[job.id], record.state == .saved, record.taskDelivery.awaitsDelivery else { return nil }
		let ids = Dictionary(remote.map { ($0.key, $0.id) }, uniquingKeysWith: { first, _ in first })
		record.entry?.tasks = job.tasks
		record.taskDelivery = .delivered(job.tasks.map { MemoTaskReceipt(key: $0.key, id: ids[$0.key]) })
		record.remoteTasks = remote
		try write(record)
		return records[job.id]
	}

	func failTasks(_ job: TaskDeliveryJob, message: String, now: Date = .now) throws -> JournalRecord? {
		guard var record = currentTaskRecord(job) else { return nil }
		let previous: CloudRetryState? = if case let .pending(retry) = record.taskDelivery { retry } else { nil }
		record.taskDelivery = .pending(retry: .failed(previous: previous, message: message, now: now))
		try write(record)
		return records[job.id]
	}

	func blockTasks(_ job: TaskDeliveryJob, _ problem: MemoTaskLinkProblem) throws -> JournalRecord? {
		guard var record = currentTaskRecord(job), record.taskDelivery != .blocked(problem) else { return nil }
		record.taskDelivery = .blocked(problem)
		try write(record)
		return records[job.id]
	}

	func nextTaskDeliveryRetry() -> Date? {
		records.values.compactMap { record -> Date? in
			guard record.state == .saved, record.entry?.tasks.isEmpty == false,
				case let .pending(retry) = record.taskDelivery else { return nil }
			guard let retry else { return .distantPast }
			return retry.retryAfter
		}.min()
	}

	func cacheRemoteTasks(_ remote: [RemoteMemoTask], for id: UUID) throws -> JournalRecord? {
		guard var record = records[id], record.state == .saved, record.remoteTasks != remote else { return nil }
		record.remoteTasks = remote
		try write(record)
		return records[id]
	}

	private func currentTaskRecord(_ job: TaskDeliveryJob) -> JournalRecord? {
		guard let record = records[job.id], record.state == .saved, record.entry?.tasks == job.tasks,
			record.taskDelivery.awaitsDelivery else { return nil }
		return record
	}

	func savePartial(_ progress: TranscriptionProgress, lease: ProcessingLease) throws -> JournalRecord {
		var record = try currentRecord(for: lease)
		guard lease.stage == .transcribe else { throw RepositoryError.staleProcessing }
		record.processing?.partialTranscript = progress
		try write(record)
		return records[record.id]!
	}

	func failProcessing(_ lease: ProcessingLease, message: String, partial: TranscriptionProgress? = nil,
		retryAfter: Date? = nil, fallback: ReflectionResult? = nil, kind: ProcessingFailureKind = .execution,
		now: Date = .now) throws -> JournalRecord {
		var record = try currentRecord(for: lease)
		if let partial { record.processing?.partialTranscript = partial }
		let hasPartial = record.processing?.partialTranscript != nil
		record.processing?.status = hasPartial ? .partial : .failed
		record.processing?.failure = message
		record.processing?.failureKind = kind
		record.processing?.attemptID = nil
		let failures = (record.processing?.failedAttempts ?? 0) + 1
		record.processing?.failedAttempts = failures
		let delay = kind == .execution ? EntryProcessing.retryDelay(after: failures) : nil
		record.processing?.retryAfter = delay.map { retryAfter ?? now.addingTimeInterval($0) }
		if let fallback, record.processing?.completedStages.contains(.reflect) != true {
			record.entry?.headline = fallback.headline
			record.entry?.summary = fallback.summary
			record.entry?.summaryModel = fallback.modelName
		}
		try write(record)
		return records[record.id]!
	}

	func pauseProcessing(_ lease: ProcessingLease, canceled: Bool = false) throws -> JournalRecord {
		var record = try currentRecord(for: lease, checkCancellation: false)
		record.processing?.status = canceled ? .canceled : .queued
		record.processing?.attemptID = nil
		record.processing?.retryAfter = nil
		try write(record)
		return records[record.id]!
	}

	func apply(_ edit: JournalEdit, to id: UUID) throws -> JournalRecord {
		guard var record = records[id], record.state == .saved, var entry = record.entry else {
			throw RepositoryError.unavailableRecord
		}
		edit.apply(to: &entry)
		guard entry != record.entry else { return record }
		record.entry = entry
		try write(record)
		return records[id]!
	}

	private func currentRecord(for lease: ProcessingLease, checkCancellation: Bool = true) throws -> JournalRecord {
		if checkCancellation { try Task.checkCancellation() }
		guard let record = records[lease.entryID], record.state == .saved,
			let job = record.processing, job.status == .running,
			job.requestID == lease.requestID, job.attemptID == lease.attemptID,
			job.stage == lease.stage, record.inputRevision == lease.inputRevision,
			job.inputRevision == lease.inputRevision else { throw RepositoryError.staleProcessing }
		return record
	}

	private func advance(_ record: inout JournalRecord, after stage: ProcessingStage) {
		guard var job = record.processing else { return }
		job.inputRevision = record.inputRevision
		job.completedStages.insert(stage)
		job.skippedStages.remove(stage)
		job.attemptID = nil
		job.failure = nil
		job.failureKind = nil
		job.retryAfter = nil
		job.failedAttempts = 0
		job.status = .queued
		switch stage {
		case .finalizeAudio: job.stage = .transcribe
		case .transcribe: job.stage = .reflect
		case .reflect: job.status = .complete
		}
		record.processing = job
	}

	private func newProcessing(for record: JournalRecord) -> EntryProcessing {
		EntryProcessing(inputRevision: record.inputRevision,
			stage: record.entry?.audioFilename.map(RecordingAudioFormat.needsFinalization) == true ? .finalizeAudio : .transcribe)
	}

	private func migrateProcessing(issues: inout [String]) {
		for var record in Array(records.values) where record.state == .saved {
			do {
				if record.processing == nil, let entry = record.entry {
					var job = newProcessing(for: record)
					if !["Processing recording", "Recovered recording"].contains(entry.headline), entry.transcript != "No transcript available." {
						job.completedStages = [.transcribe, .reflect]
					}
					if entry.audioFilename == nil {
						job.status = .complete
					} else if entry.transcript == "No transcript available." {
						job.status = .failed
						job.failure = "This older recording has no completed transcript. Retry to transcribe it."
					} else if !RecordingAudioFormat.needsFinalization(entry.audioFilename!),
						!["Processing recording", "Recovered recording"].contains(entry.headline) {
						job.status = .complete
						job.completedStages = [.transcribe, .reflect]
					}
					record.processing = job
					try write(record)
				} else if record.processing?.status == .running {
					record.processing?.status = .queued
					record.processing?.attemptID = nil
					try write(record)
				}
			} catch {
				issues.append("Processing state for note \(record.id.uuidString.prefix(8)) could not be saved. Its original note remains available.")
			}
		}
	}

	private func snapshot(issues: [String]) -> JournalLoad {
		JournalLoad(
			entries: committedEntries(),
			records: Array(records.values),
			issues: issues,
			deletionReferences: records.values.filter { $0.state == .deleted }.reduce(into: []) {
				$0.formUnion($1.cloudDeletionReferences)
				$0.insert($1.id.uuidString)
			})
	}

	private func migrateLegacyEntries(issues: inout [String]) throws {
		let marker = rootURL.appendingPathComponent("records-migration-v1.complete")
		if let data = try readIfPresent(marker) {
			guard data == Data("1".utf8) else { throw RepositoryError.invalidRecord }
			return
		}
		let legacy = rootURL.appendingPathComponent("entries.json")
		let data: Data?
		do { data = try readIfPresent(legacy) }
		catch {
			issues.append("The previous journal could not be read. Its original files were preserved.")
			return
		}
		guard let data else {
			try Data("1".utf8).write(to: marker, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
			return
		}
		let objects: [Any]
		do {
			guard let array = try JSONSerialization.jsonObject(with: data) as? [Any] else {
				throw RepositoryError.invalidRecord
			}
			objects = array
		} catch {
			issues.append("The previous journal is damaged. Its original files were preserved; automatic audio recovery is paused.")
			return
		}
		var complete = true
		for (index, object) in objects.enumerated() {
			do {
				let entry = try JSONDecoder().decode(JournalEntry.self, from: JSONSerialization.data(withJSONObject: object, options: .fragmentsAllowed))
				guard entry.audioFilename.map(Self.isFilename) ?? true else { throw RepositoryError.invalidRecord }
				if !reservedIDs.contains(entry.id) { try write(JournalRecord(entry: entry)) }
				else if records[entry.id] == nil { complete = false }
			} catch {
				complete = false
				if let raw = object as? [String: Any], let value = raw["id"] as? String, let id = UUID(uuidString: value) {
					reservedIDs.insert(id)
				}
				issues.append("Previous note \(index + 1) could not be migrated. Its original data was preserved.")
			}
		}
		if complete {
			try Data("1".utf8).write(to: marker, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
		}
	}

	private func migratePendingRecording(issues: inout [String]) {
		do {
			guard let data = try readIfPresent(rootURL.appendingPathComponent("pending-recording.json")) else { return }
			let pending = try JSONDecoder().decode(LegacyPendingRecording.self, from: data)
			guard Self.isFilename(pending.filename) else { throw RepositoryError.invalidRecord }
			guard !records.values.contains(where: { $0.ownedAudioFilenames.contains(pending.filename) }) else { return }
			let id = UUID(uuidString: URL(fileURLWithPath: pending.filename).deletingPathExtension().lastPathComponent) ?? UUID()
			guard !reservedIDs.contains(id), issues.isEmpty else { return }
			let entry = JournalEntry(id: id, createdAt: pending.startedAt, duration: pending.duration,
				transcript: "", headline: "Recovered recording", audioFilename: pending.filename, calendarEvent: pending.calendarEvent)
			try write(JournalRecord(entry: entry, state: .recording))
		} catch {
			issues.append("Interrupted recording metadata could not be read. Its original files were preserved.")
		}
	}

	private func recoverRecordings(issues: inout [String]) throws {
		for record in Array(records.values) where record.state == .recording {
			guard record.entry != nil else { continue }
			var readable: (String, TimeInterval)?
			var hasUnreadableAudio = false
			let filenames = record.ownedAudioFilenames.sorted {
				$0.hasSuffix(".m4a") && !$1.hasSuffix(".m4a")
			}
			for filename in filenames {
				do {
					readable = (filename, try Self.audioDuration(at: recordingsURL.appendingPathComponent(filename)))
					break
				} catch { if !Self.isMissing(error) { hasUnreadableAudio = true } }
			}
			guard let (filename, duration) = readable else {
				if hasUnreadableAudio { issues.append("A recording could not be recovered. Its audio and metadata were preserved.") }
				else { _ = try deleteLoaded(id: record.id) }
				continue
			}
			var recovered = record
			recovered.entry?.audioFilename = filename
			recovered.entry?.duration = duration
			recovered.entry?.headline = "Recovered recording"
			recovered.state = .saved
			if recovered.processing == nil { recovered.processing = newProcessing(for: recovered) }
			try write(recovered)
		}
		for record in records.values where record.state == .deleted {
			do { try cleanupDeletedAudio(id: record.id) }
			catch { issues.append("Deleted audio cleanup is pending and will be retried.") }
		}
		for record in records.values where record.state == .saved {
			do {
				if record.entry?.audioFilename?.hasSuffix(".m4a") == true {
					try cleanupFinalizedAudio(id: record.id)
				} else {
					for filename in record.ownedAudioFilenames where filename.hasPrefix(".") {
						do { try fileManager.removeItem(at: recordingsURL.appendingPathComponent(filename)) }
						catch where Self.isMissing(error) {}
					}
				}
			} catch { issues.append("Recording cleanup is pending. Original files were preserved.") }
		}
		guard issues.isEmpty else { return }
		let urls = try fileManager.contentsOfDirectory(at: recordingsURL,
			includingPropertiesForKeys: [.creationDateKey], options: [.skipsHiddenFiles])
		let owned = records.values.reduce(into: Set<String>()) { $0.formUnion($1.ownedAudioFilenames) }
		let groups = Dictionary(grouping: urls.filter {
			["m4a", "caf", "aac"].contains($0.pathExtension.lowercased()) && !owned.contains($0.lastPathComponent)
		}, by: { $0.deletingPathExtension().lastPathComponent })
		for (stem, group) in groups {
			let id = UUID(uuidString: stem) ?? UUID()
			guard !reservedIDs.contains(id) else { continue }
			let candidates = group.sorted { $0.pathExtension == "m4a" && $1.pathExtension != "m4a" }
			guard let candidate = candidates.compactMap({ url -> (URL, TimeInterval)? in
				guard let duration = try? Self.audioDuration(at: url) else { return nil }
				return (url, duration)
			}).first else {
				issues.append("Unrecognized audio could not be recovered. The original file was preserved.")
				continue
			}
			let createdAt = try candidate.0.resourceValues(forKeys: [.creationDateKey]).creationDate ?? .now
			let entry = JournalEntry(id: id, createdAt: createdAt, duration: candidate.1, transcript: "",
				headline: "Recovered recording", audioFilename: candidate.0.lastPathComponent)
			try write(JournalRecord(entry: entry, ownedAudioFilenames: Set(group.map(\.lastPathComponent))))
		}
	}

	private func deleteLoaded(id: UUID) throws -> Set<String> {
		guard var record = records[id] else { throw RepositoryError.unavailableRecord }
		record.entry = nil
		record.state = .deleted
		record.processing = nil
		try write(record)
		return record.ownedAudioFilenames
	}

	private func write(_ value: JournalRecord) throws {
		var record = value
		let previous = records[record.id]
		record.revision = (previous?.revision ?? record.revision) + 1
		let contentChanged = previous == nil || previous?.entry != record.entry || previous?.state != record.state
		record.contentRevision = (previous?.contentRevision ?? 0) + (contentChanged ? 1 : 0)
		if contentChanged {
			record.cloudRetry = nil
			if previous?.entry?.audioFilename != record.entry?.audioFilename { record.cloudAudioReceipt = nil }
		}
		if record.state == .deleted {
			record.cloudDeletionReferences.formUnion(record.ownedAudioFilenames)
			record.cloudDeletionReferences.insert(record.id.uuidString)
		}
		guard record.ownedAudioFilenames.allSatisfy(Self.isFilename),
			record.entry?.audioFilename.map(Self.isFilename) ?? true else { throw RepositoryError.invalidRecord }
		let data = try JSONEncoder().encode(record)
		try data.write(to: recordsURL.appendingPathComponent("\(record.id.uuidString).json"),
			options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
		records[record.id] = record
		reservedIDs.insert(record.id)
	}

	private func prepareDirectories() throws -> [String] {
		var issues: [String] = []
		for directory in [rootURL, recordsURL, recordingsURL] {
			let existed = fileManager.fileExists(atPath: directory.path)
			try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
			do {
				try fileManager.setAttributes([.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication], ofItemAtPath: directory.path)
				var url = directory
				var values = URLResourceValues()
				values.isExcludedFromBackup = false
				try url.setResourceValues(values)
			} catch {
				guard existed else { throw error }
				issues.append("Storage protection or backup settings could not be refreshed. Readable notes remain available.")
			}
		}
		return issues
	}

	private func requireLoaded() throws {
		guard didLoad else { throw RepositoryError.notLoaded }
	}

	private func readIfPresent(_ url: URL) throws -> Data? {
		do { return try Data(contentsOf: url) }
		catch where Self.isMissing(error) { return nil }
	}

	private static func audioDuration(at url: URL) throws -> TimeInterval {
		_ = try url.resourceValues(forKeys: [.fileSizeKey])
		let file = try AVAudioFile(forReading: url)
		guard file.length > 0, file.processingFormat.sampleRate > 0 else { throw RepositoryError.invalidAudio }
		guard let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: 1) else { throw RepositoryError.invalidAudio }
		try file.read(into: buffer, frameCount: 1)
		guard buffer.frameLength == 1 else { throw RepositoryError.invalidAudio }
		return Double(file.length) / file.processingFormat.sampleRate
	}

	private static func isFilename(_ value: String) -> Bool {
		!value.isEmpty && value != "." && value != ".." && URL(fileURLWithPath: value).lastPathComponent == value
	}

	private static func isMissing(_ error: Error) -> Bool {
		let error = error as NSError
		return error.domain == NSCocoaErrorDomain && [NSFileNoSuchFileError, NSFileReadNoSuchFileError].contains(error.code)
	}
}

private struct LegacyPendingRecording: Decodable {
	var filename: String
	var startedAt: Date
	var duration: TimeInterval
	var calendarEvent: JournalCalendarEvent?
}

enum RepositoryError: LocalizedError {
	case invalidRecord, invalidAudio, unavailableRecord, notLoaded, staleProcessing, unsavedChanges
	var errorDescription: String? {
		switch self {
		case .staleProcessing: "This processing attempt is no longer current."
		case .unsavedChanges: "Your changes could not be saved. Use Try Again to save them."
		case .invalidRecord: "The note metadata could not be read safely. Original files were preserved."
		case .invalidAudio: "The recording could not be read. Its original audio was preserved."
		case .unavailableRecord: "This recording is no longer available."
		case .notLoaded: "The journal could not be opened. Original files were preserved."
		}
	}
}
