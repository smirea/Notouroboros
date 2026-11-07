@preconcurrency import AVFAudio
import Foundation
import Observation
import UIKit

@MainActor
@Observable
final class JournalStore {
	private(set) var entries: [JournalEntry]
	private(set) var entryProcessingPhases: [UUID: EntryProcessingPhase] = [:]
	private(set) var namedLocations: [NamedJournalLocation] = []
	private(set) var elevenLabsAPIKey = ""
	private(set) var isLoading = true
	private(set) var storageLoadMessage: String?
	var storageErrorMessage: String?
	private(set) var hasUnsavedNoteChanges = false
	var transcriptionAlertMessage: String?
	var settings = JournalSettings.load()
	let calendarSync: CalendarSync

	let isDemoMode: Bool
	private let fileManager = FileManager.default
	private let rootURL: URL
	private let recordingsURL: URL
	private let cloudServices: CloudServices
	@ObservationIgnored private let configurationRepository: ConfigurationRepository
	@ObservationIgnored private var configurationBootstrapTask: Task<Void, Never>?
	@ObservationIgnored private var configurationWriteTask: Task<Void, Never>?
	@ObservationIgnored private var configurationSnapshot: ConfigurationSnapshot?
	@ObservationIgnored private var configurationIntents: [PendingConfigurationEdit] = []
	@ObservationIgnored private var configurationIntentValue: AppConfiguration
	private let configurationInitialValue: AppConfiguration
	@ObservationIgnored private var hasLoadedConfiguration = false
	@ObservationIgnored private var configurationSaveMessage: String?
	@ObservationIgnored private var cloudSaveFailed = false
	@ObservationIgnored private var cloudRetryTask: Task<Void, Never>?
	@ObservationIgnored private var legacyCloudRetry: CloudRetryState?
	private(set) var cloudStatusMessage: String?
	private(set) var isCloudSyncing = false
	private let mirroringEnabled: Bool
	@ObservationIgnored private var iCloudWorker: Task<Void, Never>?
	@ObservationIgnored private var iCloudPending = false
	@ObservationIgnored private var iCloudRepairPending = false
	@ObservationIgnored private var hasLoadedJournal = false
	@ObservationIgnored private var pendingDeletionIDs = Set<UUID>()
	@ObservationIgnored private var failedNoteSaveIDs = Set<UUID>()
	@ObservationIgnored private var iCloudRevision = 0
	@ObservationIgnored private var pendingICloudDeletionReferences = Set<String>()
	private(set) var processingStates: [UUID: EntryProcessing] = [:]
	private(set) var taskDeliveries: [UUID: MemoTaskDelivery] = [:]
	private(set) var remoteTasks: [UUID: [RemoteMemoTask]] = [:]
	var procrastiMateMessage: String?
	@ObservationIgnored private let procrastiMate: ProcrastiMateClient?
	@ObservationIgnored private var taskDeliveryWorker: Task<Void, Never>?
	@ObservationIgnored private var taskDeliveryPending = false
	@ObservationIgnored private var taskDeliveryRepair = false
	@ObservationIgnored private var taskDeliveryWake: Task<Void, Never>?
	@ObservationIgnored private var taskDeliveryBackground: UIBackgroundTaskIdentifier = .invalid
	@ObservationIgnored private var taskDeliveryStorageFailed = false
	@ObservationIgnored private var processingWorker: Task<Void, Never>?
	@ObservationIgnored private var activeStage: Task<Void, Never>?
	@ObservationIgnored private var activeLease: ProcessingLease?
	@ObservationIgnored private var processingWatchdog: Task<Void, Never>?
	@ObservationIgnored private var retryWakeTask: Task<Void, Never>?
	@ObservationIgnored private var backgroundTask: UIBackgroundTaskIdentifier = .invalid
	@ObservationIgnored private var backgroundRegistration: UUID?
	@ObservationIgnored private let processingBackgroundTasks: ProcessingBackgroundTasks?
	@ObservationIgnored private var backgroundJobs: [UUID: EntryProcessing] = [:]
	@ObservationIgnored private var storageSuspended = false
	@ObservationIgnored private var backgroundSuspended = false
	private var capturePriorityOwners = Set<UUID>()
	@ObservationIgnored private var admissionPolicyRevision: UInt64 = 0
	private static var nextAdmissionPolicyRevision: UInt64 = 0
	@ObservationIgnored private var admittedAt: ContinuousClock.Instant?
	@ObservationIgnored private var remainingStageTime: TimeInterval = 0
	var isCapturePriorityActive: Bool { !capturePriorityOwners.isEmpty }
	private var processingSuspended: Bool { storageSuspended || backgroundSuspended || isCapturePriorityActive }
	@ObservationIgnored private var lastPartialCheckpoint = Date.distantPast
	@ObservationIgnored private var deletedEntryIDs = Set<UUID>()
	@ObservationIgnored private var committedRecords: [UUID: JournalRecord] = [:]
	@ObservationIgnored private var pendingEdits: [PendingJournalEdit] = []
	private let processingServices: ProcessingServices
	private let processingEnabled: Bool
	#if DEBUG
	var processingIdleCheckpoint: (() async -> Void)?
	var journalLoadCheckpoint: (() async -> Void)?
	var weeklyReviewGeneration: (@Sendable () async throws -> WeeklyReview)?
	var processingDeadlineOverride: TimeInterval?
	var deletionIntentCheckpoint: (() async -> Void)?
	var mirrorSnapshotCheckpoint: (() async -> Void)?
	var configurationLoadCheckpoint: (() async -> Void)?
	private var cloudStoppedForContract = false
	#endif
	@ObservationIgnored private var recordingLocationTask: Task<JournalLocation?, Never>?
	@ObservationIgnored private var entryLocationTasks: [UUID: Task<Void, Never>] = [:]
	@ObservationIgnored private let repository: JournalRepository
	@ObservationIgnored private let audioFinalizer = AudioFinalizer()
	@ObservationIgnored private var bootstrapTask: Task<Void, Never>?
	@ObservationIgnored private var persistenceTask: Task<Void, Never>?
	private let usesExternalServices: Bool

	init(storageRootURL: URL? = nil, processingServices: ProcessingServices? = nil,
		cloudServices: CloudServices? = nil, processingBackgroundTasks: ProcessingBackgroundTasks? = nil,
		procrastiMate: ProcrastiMateClient? = nil) {
		self.cloudServices = cloudServices ?? .live
		mirroringEnabled = storageRootURL == nil || cloudServices != nil
		self.processingServices = processingServices ?? .live
		processingEnabled = storageRootURL == nil || processingServices != nil
		isDemoMode = storageRootURL == nil && ProcessInfo.processInfo.arguments.contains("-demo")
		usesExternalServices = storageRootURL == nil
		self.procrastiMate = procrastiMate ?? (storageRootURL == nil && !isDemoMode ? .live : nil)
		self.processingBackgroundTasks = processingBackgroundTasks ??
			(storageRootURL == nil && !isDemoMode ? ProcessingBackgroundTasks() : nil)
		let initialSettings = storageRootURL == nil ? JournalSettings.load() : JournalSettings()
		settings = initialSettings
		let initialConfiguration = AppConfiguration(settings: initialSettings)
		configurationInitialValue = initialConfiguration
		configurationIntentValue = initialConfiguration
		let applicationSupport = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
		rootURL = storageRootURL ?? applicationSupport.appendingPathComponent("Notouroboros", isDirectory: true)
		recordingsURL = rootURL.appendingPathComponent("Recordings", isDirectory: true)
		repository = JournalRepository(rootURL: rootURL)
		configurationRepository = ConfigurationRepository(rootURL: rootURL)
		calendarSync = CalendarSync(
			isDemoMode: isDemoMode,
			cacheURL: rootURL.appendingPathComponent("calendar-events.json")
		)
		pendingICloudDeletionReferences = Set(
			usesExternalServices ? (UserDefaults.standard.stringArray(forKey: Self.iCloudDeletionKey) ?? []) : []
		)

		if usesExternalServices, let data = UserDefaults.standard.data(forKey: Self.iCloudRetryKey) {
			legacyCloudRetry = try? JSONDecoder().decode(CloudRetryState.self, from: data)
		}
		entries = []
		if isDemoMode {
			entries = JournalEntry.demo
			namedLocations = NamedJournalLocation.demo
			settings.calendarSyncEnabled = true
			isLoading = false
			for entry in entries where !entry.tasks.isEmpty {
				let ids = entry.tasks.indices.map { "demo-task-\($0 + 1)" }
				taskDeliveries[entry.id] = .delivered(zip(entry.tasks, ids).map { MemoTaskReceipt(key: $0.key, id: $1) })
				remoteTasks[entry.id] = zip(entry.tasks, ids).enumerated().map { index, pair in
					RemoteMemoTask(key: pair.0.key, id: pair.1, title: pair.0.title,
						completedAt: index == 2 ? entry.createdAt.addingTimeInterval(86_400) : nil,
						due: index == 1 ? RemoteMemoTask.Due(date: Date.now.addingTimeInterval(86_400)
							.formatted(.iso8601.year().month().day()), time: "09:30") : nil,
						event: pair.0.event)
				}
			}
			#if DEBUG
			if let index = ProcessInfo.processInfo.arguments.firstIndex(of: "-demo-tasks-state"),
				ProcessInfo.processInfo.arguments.indices.contains(index + 1) {
				let state: MemoTaskDelivery? = switch ProcessInfo.processInfo.arguments[index + 1] {
				case "pending": .pending(retry: nil)
				case "retry": .pending(retry: .failed(previous: nil,
					message: "ProcrastiMate couldn’t be reached. These todos will be sent again.", now: .now))
				case "not-installed": .blocked(.notInstalled)
				case "signed-out": .blocked(.signedOut)
				default: nil
				}
				if let state {
					for id in taskDeliveries.keys {
						taskDeliveries[id] = state
						remoteTasks[id] = nil
					}
				}
			}
			hasUnsavedNoteChanges = ProcessInfo.processInfo.arguments.contains("-demo-unsaved-notes")
			if ProcessInfo.processInfo.arguments.contains("-demo-cloud-pending") {
				cloudStatusMessage = "iCloud Drive is unavailable. Recordings and your settings changes remain on this device."
			}
			if ProcessInfo.processInfo.arguments.contains("-demo-configuration-damaged") {
				cloudStatusMessage = "The saved configuration is damaged. Its original file was preserved. Settings changes could not be saved."
			}
			if ProcessInfo.processInfo.arguments.contains("-demo-finalization-failed") {
				for entry in entries { entryProcessingPhases[entry.id] = .finalizationFailed }
			}
			if ProcessInfo.processInfo.arguments.contains("-demo-processing-partial") || ProcessInfo.processInfo.arguments.contains("-demo-processing-failed") {
				for entry in entries {
					var job = EntryProcessing(inputRevision: 0, stage: .transcribe)
					let partial = ProcessInfo.processInfo.arguments.contains("-demo-processing-partial")
					job.status = partial ? .partial : .failed
					job.failure = "The last attempt could not finish. Your audio and previous completed results are preserved."
					if partial {
						job.partialTranscript = TranscriptionProgress(transcript: "I wanted to remember the decision we made this morning, and the next thing to follow up on was", modelName: "Apple Speech · incomplete")
						if let index = entries.firstIndex(where: { $0.id == entry.id }) {
							entries[index].transcript = ""
							entries[index].summary = nil
							entries[index].summaryModel = nil
							entries[index].headline = "Recording saved"
						}
					}
					processingStates[entry.id] = job
					entryProcessingPhases[entry.id] = job.phase
				}
			}
			#endif
		} else {
			bootstrapTask = Task { [weak self] in await self?.loadJournal() }
		}
		self.processingBackgroundTasks?.onLaunch = { [weak self] in self?.resumeBackgroundProcessing() }
		self.processingBackgroundTasks?.onExpiration = { [weak self] in
			guard let self else { return }
			self.backgroundSuspended = true
			let checkpoint = self.preemptProcessing()
			self.updateServiceAdmission()
			await checkpoint?.value
			self.updateBackgroundProcessing()
		}
	}

	var isIsolatedStorage: Bool { !usesExternalServices }

	func waitUntilLoaded() async throws {
		await bootstrapTask?.value
		guard await repository.isLoaded else { throw RepositoryError.notLoaded }
	}

	private func loadJournal() async {
		defer { isLoading = false }
		#if DEBUG
		await journalLoadCheckpoint?()
		#endif
		do {
			let loaded = try await repository.load()
			var records: [UUID: JournalRecord] = [:]
			var processing: [UUID: EntryProcessing] = [:]
			var phases: [UUID: EntryProcessingPhase] = [:]
			var deleted = Set<UUID>()
			for record in loaded.records {
				records[record.id] = record
				processing[record.id] = record.processing
				phases[record.id] = record.processing?.phase
				if record.state == .deleted { deleted.insert(record.id) }
				else {
					taskDeliveries[record.id] = record.taskDelivery
					remoteTasks[record.id] = record.remoteTasks
				}
			}
			committedRecords = records
			processingStates = processing
			updateBackgroundProcessing()
			entryProcessingPhases = phases
			deletedEntryIDs = deleted
			entries = loaded.entries
			let issues = loaded.issues
			storageLoadMessage = issues.isEmpty ? nil : issues.joined(separator: "\n")
			hasLoadedJournal = true
			isLoading = false
			kickProcessing()
			scheduleTaskDelivery(repair: true)
			configurationBootstrapTask = Task { await loadConfiguration() }

		} catch {
			storageLoadMessage = "The journal could not be opened. Original files were preserved. " + error.localizedDescription
		}
	}

	func entries(inWeekContaining date: Date) -> [JournalEntry] {
		let start = date.startOfWeek()
		let end = Calendar.current.date(byAdding: .day, value: 7, to: start) ?? date
		return entries.filter { $0.createdAt >= start && $0.createdAt < end }
	}

	func entry(id: UUID) -> JournalEntry? {
		entries.first { $0.id == id }
	}

	func namedLocation(for location: JournalLocation) -> NamedJournalLocation? {
		NamedLocationResolver.resolve(LocationCoordinate(location), in: namedLocations)
	}

	func displayName(for location: JournalLocation) -> String {
		namedLocation(for: location)?.name ?? location.displayName
	}

	func nearbyNamedLocations(
		to location: JournalLocation,
		excluding excludedID: UUID? = nil
	) -> [NearbyNamedLocation] {
		NamedLocationResolver.nearby(
			to: LocationCoordinate(location),
			locations: namedLocations,
			entries: entries,
			excluding: excludedID
		)
	}

	func saveNamedLocation(
		id: UUID?,
		name: String,
		address: String,
		pin: LocationCoordinate,
		for source: JournalLocation
	) {
		let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
		guard !name.isEmpty else { return }
		let address = address.trimmingCharacters(in: .whitespacesAndNewlines)
		let sourceCoordinate = LocationCoordinate(source)
		let locationID = id ?? UUID()

		removeExactAlias(sourceCoordinate, excluding: locationID)
		if let index = namedLocations.firstIndex(where: { $0.id == locationID }) {
			namedLocations[index].name = name
			namedLocations[index].address = address.isEmpty ? nil : address
			namedLocations[index].pin = pin
			appendAlias(sourceCoordinate, at: index)
		} else {
			namedLocations.append(NamedJournalLocation(
				id: locationID,
				name: name,
				address: address.isEmpty ? nil : address,
				pin: pin,
				aliases: [sourceCoordinate]
			))
		}
		commitConfiguration()
	}

	func assign(_ source: JournalLocation, to locationID: UUID) {
		guard let index = namedLocations.firstIndex(where: { $0.id == locationID }) else { return }
		let coordinate = LocationCoordinate(source)
		removeExactAlias(coordinate, excluding: locationID)
		appendAlias(coordinate, at: index)
		commitConfiguration()
	}

	func audioURL(for entry: JournalEntry) -> URL? {
		entry.audioFilename.map { recordingsURL.appendingPathComponent($0) }
	}

	func processingPhase(for entryID: UUID) -> EntryProcessingPhase? {
		entryProcessingPhases[entryID]
	}

	func canReprocessEntry(id entryID: UUID) -> Bool {
		guard let entry = entry(id: entryID),
			let url = audioURL(for: entry)
		else { return false }
		return fileManager.fileExists(atPath: url.path)
	}

	@discardableResult
	func beginRecordingLocationCapture() -> Task<JournalLocation?, Never> {
		guard usesExternalServices else { return Task { nil } }
		recordingLocationTask?.cancel()
		let task = Task {
			await EntryLocationCapture.capture()
		}
		recordingLocationTask = task
		return task
	}

	func destinationForNewRecording(calendarEvent: JournalCalendarEvent?) async throws -> URL {
		try await waitUntilLoaded()
		try Task.checkCancellation()
		let entry = try await repository.beginRecording(calendarEvent: calendarEvent)
		return recordingsURL.appendingPathComponent(entry.audioFilename!)
	}

	func checkpointRecording(at url: URL, duration: TimeInterval) {
		guard let id = UUID(uuidString: url.deletingPathExtension().lastPathComponent) else { return }
		Task {
			do { try await repository.checkpoint(id: id, duration: duration) }
			catch { storageErrorMessage = error.localizedDescription }
		}
	}

	func cancelRecordingLocationCapture() {
		recordingLocationTask?.cancel()
		recordingLocationTask = nil
	}

	func cancelRecording(at url: URL) async throws {
		await persistenceTask?.value
		guard let id = UUID(uuidString: url.deletingPathExtension().lastPathComponent) else {
			throw RepositoryError.unavailableRecord
		}
		_ = try await repository.delete(id: id)
		await cleanupDeletedAudio(id: id)
	}

	private func cleanupDeletedAudio(id: UUID) async {
		do { try await repository.cleanupDeletedAudio(id: id) }
		catch {
			storageErrorMessage = "Deletion was saved. Audio cleanup is pending and will retry when the app opens. " + error.localizedDescription
		}
	}

	func waitForPendingWrites() async { await persistenceTask?.value }

	@discardableResult
	func finishRecording(at url: URL, calendarEvent: JournalCalendarEvent?) async throws -> UUID {
		try await waitUntilLoaded()
		await persistenceTask?.value
		guard let entryID = UUID(uuidString: url.deletingPathExtension().lastPathComponent) else {
			throw RepositoryError.unavailableRecord
		}
		_ = try await repository.finishRecording(id: entryID)
		if let record = await repository.record(id: entryID) { publish(record) }
		startUserInitiatedProcessing()
		scheduleICloudDriveMirror()
		kickProcessing()
		if usesExternalServices { attachRecordedLocation(to: entryID) }
		return entryID
	}

	func resumeStaleProcessing(now: Date = .now) {
		backgroundSuspended = false
		updateBackgroundProcessing()
		updateServiceAdmission()
		scheduleICloudDriveMirror(changed: false, repair: true)
		scheduleTaskDelivery(repair: true)
	}

	func beginCapturePriority(owner: UUID) async {
		capturePriorityOwners.insert(owner)
		if iCloudWorker != nil { iCloudPending = true; iCloudWorker?.cancel() }
		cloudRetryTask?.cancel()
		preemptProcessing()
		let revision = newAdmissionRevision()
		await synchronizeServiceAdmission(revision: revision)
	}

	func endCapturePriority(owner: UUID) async {
		guard capturePriorityOwners.remove(owner) != nil else { return }
		let revision = newAdmissionRevision()
		await synchronizeServiceAdmission(revision: revision)
	}

	private func newAdmissionRevision() -> UInt64 {
		Self.nextAdmissionPolicyRevision += 1
		admissionPolicyRevision = Self.nextAdmissionPolicyRevision
		return admissionPolicyRevision
	}

	private func updateServiceAdmission() {
		let revision = newAdmissionRevision()
		Task { await synchronizeServiceAdmission(revision: revision) }
	}

	private func synchronizeServiceAdmission(revision: UInt64) async {
		guard revision == admissionPolicyRevision else { return }
		let suspended = backgroundSuspended || isCapturePriorityActive
		await ServiceAdmission.model.setSuspended(suspended, revision: revision)
		await ServiceAdmission.speech.setSuspended(suspended, revision: revision)
		guard revision == admissionPolicyRevision else { return }
		startICloudMirrorWorker()
		if iCloudWorker == nil { scheduleCloudRetry() }
		if !processingSuspended { kickProcessing() }
	}

	@discardableResult
	private func preemptProcessing() -> Task<Void, Never>? {
		retryWakeTask?.cancel()
		retryWakeTask = nil
		processingWatchdog?.cancel()
		admittedAt = nil
		activeStage?.cancel()
		endBackgroundProcessing()
		guard let lease = activeLease else { return nil }
		return Task {
			do { publish(try await repository.pauseProcessing(lease)) }
			catch RepositoryError.staleProcessing {}
			catch { reportProcessingStorageError(error, entryID: lease.entryID) }
		}
	}

	private func kickProcessing() {
		guard processingEnabled, hasLoadedConfiguration, !isDemoMode, !isLoading, !processingSuspended, processingWorker == nil else { return }
		retryWakeTask?.cancel()
		processingWorker = Task { [weak self] in await self?.drainProcessing() }
	}

	private func drainProcessing() async {
		defer {
			processingWorker = nil
			activeStage = nil
			activeLease = nil
			updateBackgroundProcessing()
			processingBackgroundTasks?.finish(success: !processingSuspended && backgroundJobs.values.allSatisfy { $0.status == .complete })
			backgroundJobs.removeAll()
			endBackgroundProcessing()
			Task { await scheduleProcessingRetry() }
		}
		let temporaryIssues = await ProcessingTemporaryFiles.shared.cleanOnce()
		if !temporaryIssues.isEmpty {
			storageLoadMessage = ([storageLoadMessage].compactMap { $0 } + temporaryIssues).joined(separator: "\n")
		}
		while !Task.isCancelled, !processingSuspended {
			let work: ProcessingWork
			do {
				guard let next = try await repository.claimProcessing(excluding: pendingDeletionIDs) else {
					#if DEBUG
					await processingIdleCheckpoint?()
					#endif
					if !processingSuspended, processingStates.contains(where: { id, job in
						!pendingDeletionIDs.contains(id) && (job.status == .queued ||
							((job.status == .failed || job.status == .partial) && job.retryAfter.map { $0 <= .now } == true))
					}) { continue }
					break
				}
				if Task.isCancelled || processingSuspended || pendingDeletionIDs.contains(next.lease.entryID) {
					if let record = try? await repository.pauseProcessing(next.lease) { publish(record) }
					if Task.isCancelled || processingSuspended { break }
					continue
				}
				work = next
			} catch {
				storageSuspended = true
				storageErrorMessage = "Processing could not save its progress. Your audio is preserved. " + error.localizedDescription
				break
			}
			publish(work.record)
			activeLease = work.lease
			lastPartialCheckpoint = .distantPast
			beginBackgroundProcessing()
			remainingStageTime = work.record.entry.map { ProcessingDeadline.seconds(stage: work.lease.stage, entry: $0) } ?? 300
			#if DEBUG
			if let processingDeadlineOverride { remainingStageTime = processingDeadlineOverride }
			#endif
			let task = Task { [weak self] in
				_ = await ServiceAdmission.$activity.withValue({ [weak self] active in
					await self?.serviceActivityChanged(active, lease: work.lease)
				}) {
					await self?.process(work)
				}
			}
			activeStage = task
			if work.lease.stage == .finalizeAudio { serviceActivityChanged(true, lease: work.lease) }
			await task.value
			processingWatchdog?.cancel()
			processingWatchdog = nil
			admittedAt = nil
			activeStage = nil
			activeLease = nil
		}
	}

	private func serviceActivityChanged(_ active: Bool, lease: ProcessingLease) {
		guard activeLease == lease, !processingSuspended, activeStage?.isCancelled == false else { return }
		var perResponse = lease.stage == .reflect
		#if DEBUG
		if processingDeadlineOverride != nil { perResponse = false }
		#endif
		if perResponse {
			remainingStageTime = 90
		} else if let admittedAt {
			let elapsed = admittedAt.duration(to: .now).components
			remainingStageTime -= Double(elapsed.seconds) + Double(elapsed.attoseconds) / 1e18
		}
		admittedAt = active ? .now : nil
		processingWatchdog?.cancel()
		processingWatchdog = nil
		guard active, let task = activeStage else { return }
		let remaining = max(0, remainingStageTime)
		processingWatchdog = Task { [weak self] in
			do { try await Task.sleep(for: .seconds(remaining)) } catch { return }
			guard let self, self.activeLease == lease, !self.processingSuspended else { return }
			do {
				self.publish(try await self.repository.failProcessing(lease,
					message: "Processing took too long. Your saved results are preserved."))
			} catch is CancellationError { return
			} catch RepositoryError.staleProcessing {
			} catch { self.reportProcessingStorageError(error, entryID: lease.entryID) }
			task.cancel()
		}
	}

	private func process(_ work: ProcessingWork) async {
		let lease = work.lease
		guard let entry = work.record.entry else { return }
		do {
			try Task.checkCancellation()
			let record: JournalRecord
			switch lease.stage {
			case .finalizeAudio:
				let request = try await repository.prepareAudioFinalization(id: entry.id)
				defer { try? fileManager.removeItem(at: request.stagingURL) }
				let prepared = try await audioFinalizer.prepare(request)
				_ = try await repository.commitFinalizedAudio(prepared, lease: lease)
				guard let saved = await repository.record(id: entry.id) else { return }
				record = saved
			case .transcribe:
				guard let url = audioURL(for: entry) else { throw RepositoryError.invalidAudio }
				let result = try await processingServices.transcribe(url, settings.preferElevenLabsTranscription, elevenLabsAPIKey) { [weak self] progress in
					Task { @MainActor [weak self] in await self?.receivePartial(progress, lease: lease) }
				}
				try Task.checkCancellation()
				record = try await repository.commitTranscription(result, lease: lease)
				transcriptionAlertMessage = result.warning
			case .reflect:
				let result: ReflectionResult
				if entry.transcript.isEmpty {
					result = ReflectionResult(headline: "No speech detected", summary: nil, modelName: "Completed transcription", outcome: .skipped)
				} else { result = await processingServices.reflect(entry.transcript, entry.duration > 20) }
				try Task.checkCancellation()
				guard result.outcome.isComplete else {
					try await failModelStage(result.outcome, lease: lease, fallback: result)
					return
				}
				record = try await repository.commitReflection(result, lease: lease)
			}
			publish(record)
			scheduleICloudDriveMirror()
		} catch is CancellationError {
			if let record = try? await repository.pauseProcessing(lease, canceled: !Task.isCancelled) { publish(record) }
		} catch RepositoryError.staleProcessing {
		} catch {
			do {
				let failure = error as? TranscriptionFailure
				let record = try await repository.failProcessing(lease, message: error.localizedDescription,
					partial: failure?.partial,
					kind: failure?.category == .unavailable ? .unavailable : (failure?.category == .unreadableAudio ? .unreadableAudio : .execution))
				publish(record)
			} catch RepositoryError.staleProcessing {
			} catch { reportProcessingStorageError(error, entryID: lease.entryID) }
		}
	}

	private func failModelStage(_ outcome: ModelProcessingOutcome, lease: ProcessingLease, fallback: ReflectionResult? = nil) async throws {
		let message: String
		switch outcome {
		case .cancelled: throw CancellationError()
		case .unavailable:
			message = "On-device analysis is unavailable. Your recording and completed text are preserved."
		case let .failed(reason):
			message = reason
		case .complete, .skipped: return
		}
		publish(try await repository.failProcessing(lease, message: message, fallback: fallback, kind: outcome == .unavailable ? .unavailable : .execution))
	}

	private func receivePartial(_ progress: TranscriptionProgress, lease: ProcessingLease) async {
		guard activeLease == lease, let state = processingStates[lease.entryID],
			state.attemptID == lease.attemptID, state.status == .running else { return }
		processingStates[lease.entryID]?.partialTranscript = progress
		guard Date.now.timeIntervalSince(lastPartialCheckpoint) >= 1 else { return }
		lastPartialCheckpoint = .now
		do { publish(try await repository.savePartial(progress, lease: lease)) }
		catch RepositoryError.staleProcessing {}
		catch { storageErrorMessage = "Partial transcript progress could not be saved. " + error.localizedDescription }
	}

	private func reportProcessingStorageError(_ error: Error, entryID: UUID) {
		storageSuspended = true
		entryProcessingPhases[entryID] = .failed
		storageErrorMessage = "Processing progress could not be saved. Your audio and previous results are preserved. Retry after storage is available. " + error.localizedDescription
	}

	private func scheduleProcessingRetry() async {
		guard processingEnabled, !processingSuspended, processingWorker == nil,
			let next = await repository.nextProcessingRetry(excluding: pendingDeletionIDs), processingWorker == nil, !processingSuspended else { return }
		retryWakeTask?.cancel()
		retryWakeTask = Task { [weak self] in
			try? await Task.sleep(for: .seconds(max(0, next.timeIntervalSinceNow)))
			guard !Task.isCancelled else { return }
			self?.kickProcessing()
		}
	}

	private func beginBackgroundProcessing() {
		guard usesExternalServices, backgroundTask == .invalid, processingBackgroundTasks?.hasRuntime != true else { return }
		let registration = UUID()
		backgroundRegistration = registration
		backgroundTask = UIApplication.shared.beginBackgroundTask(withName: "Process voice memo") { [weak self] in
			Task { @MainActor [weak self] in
				guard let self, self.backgroundRegistration == registration else { return }
				self.expireBackgroundTime()
			}
		}
	}

	func expireBackgroundProcessing(lease: ProcessingLease, registration: UUID? = nil) {
		guard activeLease == lease, backgroundRegistration == registration else { return }
		expireBackgroundTime()
	}

	private func expireBackgroundTime() {
		if processingBackgroundTasks?.hasRuntime == true { endBackgroundProcessing(); return }
		backgroundSuspended = true
		preemptProcessing()
		updateServiceAdmission()
	}

	private func startUserInitiatedProcessing() {
		backgroundSuspended = false
		processingBackgroundTasks?.startUserInitiatedWork()
		updateServiceAdmission()
	}

	private func resumeBackgroundProcessing() {
		backgroundSuspended = false
		endBackgroundProcessing()
		Task {
			await bootstrapTask?.value
			await configurationBootstrapTask?.value
			guard processingBackgroundTasks?.hasRuntime == true else { return }
			updateBackgroundProcessing()
			let revision = newAdmissionRevision()
			await synchronizeServiceAdmission(revision: revision)
			if processingWorker == nil { processingBackgroundTasks?.finish(success: false) }
		}
	}

	private func updateBackgroundProcessing() {
		guard let processingBackgroundTasks else { return }
		let pending = processingStates.filter { _, job in
			job.status == .queued || job.status == .running ||
				((job.status == .failed || job.status == .partial) && job.retryAfter != nil)
		}
		let next = pending.values.map { $0.retryAfter ?? .distantPast }.min()
		processingBackgroundTasks.scheduleRecovery(at: next, needsNetwork: settings.preferElevenLabsTranscription)
		for (id, job) in processingStates where backgroundJobs[id] != nil || job.status == .running || job.status == .queued {
			backgroundJobs[id] = job
		}
		backgroundJobs = backgroundJobs.filter { processingStates[$0.key] != nil }
		processingBackgroundTasks.update(jobs: Array(backgroundJobs.values))
	}

	private func endBackgroundProcessing() {
		backgroundRegistration = nil
		guard backgroundTask != .invalid else { return }
		UIApplication.shared.endBackgroundTask(backgroundTask)
		backgroundTask = .invalid
	}

	func reprocessEntry(id entryID: UUID) {
		if activeLease?.entryID == entryID { activeStage?.cancel() }
		Task {
			do {
				let record = try await repository.requestProcessing(id: entryID)
				publish(record)
				startUserInitiatedProcessing()
				cancelObsoleteStage()
				storageSuspended = false
				kickProcessing()
			} catch { reportProcessingStorageError(error, entryID: entryID) }
		}
	}

	func retryProcessingEntry(id entryID: UUID) {
		Task {
			do {
				publish(try await repository.retryProcessing(id: entryID))
				startUserInitiatedProcessing()
				cancelObsoleteStage()
				storageSuspended = false
				kickProcessing()
			} catch { reportProcessingStorageError(error, entryID: entryID) }
		}
	}

	func partialTranscript(for entryID: UUID) -> TranscriptionProgress? { processingStates[entryID]?.partialTranscript }
	func processingFailure(for entryID: UUID) -> String? {
		guard let job = processingStates[entryID], let failure = job.failure else { return nil }
		if let retry = job.retryAfter {
			return failure + " Automatic retry at " + retry.formatted(date: .omitted, time: .shortened) + "."
		}
		return failure
	}

	func publish(_ record: JournalRecord) {
		let previous = committedRecords[record.id]
		if record.state == .deleted, previous?.state != .deleted {
			deletedEntryIDs.insert(record.id)
			entries.removeAll { $0.id == record.id }
		}
		if record.state != .deleted, deletedEntryIDs.contains(record.id) { return }
		guard record.revision >= (committedRecords[record.id]?.revision ?? -1) else { return }
		committedRecords[record.id] = record
		defer { updateBackgroundProcessing() }
		if processingStates[record.id] != record.processing { processingStates[record.id] = record.processing }
		if record.state == .saved {
			if taskDeliveries[record.id] != record.taskDelivery { taskDeliveries[record.id] = record.taskDelivery }
			if remoteTasks[record.id] != record.remoteTasks { remoteTasks[record.id] = record.remoteTasks }
		}
		if entryProcessingPhases[record.id] != record.processing?.phase { entryProcessingPhases[record.id] = record.processing?.phase }
		if previous?.entry == record.entry, previous?.state == record.state { return }
		guard record.state == .saved, var entry = record.entry else { return }
		for pending in pendingEdits where pending.entryID == record.id { pending.edit.apply(to: &entry) }
		if let index = entries.firstIndex(where: { $0.id == entry.id }) { entries[index] = entry }
		else { entries.append(entry); entries.sort { $0.createdAt > $1.createdAt } }
	}

	private func cancelObsoleteStage() {
		guard let lease = activeLease, let current = committedRecords[lease.entryID] else { return }
		if current.processing?.requestID != lease.requestID || current.processing?.attemptID != lease.attemptID
			|| current.inputRevision != lease.inputRevision { activeStage?.cancel() }
	}

	private func attachRecordedLocation(to entryID: UUID) {
		let locationTask = recordingLocationTask ?? Task { await EntryLocationCapture.capture() }
		recordingLocationTask = nil
		entryLocationTasks[entryID]?.cancel()
		entryLocationTasks[entryID] = Task { [weak self] in
			let location = await locationTask.value
			guard !Task.isCancelled, let self else { return }
			defer { self.entryLocationTasks.removeValue(forKey: entryID) }
			guard let location, self.entries.contains(where: { $0.id == entryID }) else { return }
			self.persist(.location(location), entryID: entryID)
		}
	}

	/// Deleting the memo proceeds whether or not ProcrastiMate deletes its tasks; a failed task deletion is reported.
	@discardableResult
	func deleteEntry(id entryID: UUID, deletingTasks: Bool = false) async -> Bool {
		if deletingTasks, let procrastiMate {
			let status = procrastiMate.status()
			Task {
				do {
					guard case let .linked(credentials) = status else { throw ProcrastiMateError.unauthorized }
					try await procrastiMate.delete(credentials, entryID)
				} catch {
					procrastiMateMessage = "The note was deleted, but its tasks are still in ProcrastiMate. Delete them there. "
						+ error.localizedDescription
				}
			}
		}
		return await deleteEntries(ids: [entryID])
	}

	func asksAboutTasksOnDeletion(_ entryID: UUID) -> Bool {
		MemoDeletionPrompt.asksAboutTasks(delivery: taskDeliveries[entryID], remote: remoteTasks[entryID])
	}

	func scheduleTaskDelivery(repair: Bool = false) {
		if repair { taskDeliveryStorageFailed = false }
		taskDeliveryPending = true
		taskDeliveryRepair = taskDeliveryRepair || repair
		startTaskDelivery()
	}

	private func startTaskDelivery() {
		guard let procrastiMate, hasLoadedJournal, !isDemoMode, taskDeliveryPending, taskDeliveryWorker == nil else { return }
		taskDeliveryWake?.cancel()
		if usesExternalServices {
			taskDeliveryBackground = UIApplication.shared.beginBackgroundTask(withName: "Send tasks to ProcrastiMate") { [weak self] in
				Task { @MainActor [weak self] in
					self?.taskDeliveryWorker?.cancel()
					self?.endTaskDeliveryBackground()
				}
			}
		}
		taskDeliveryWorker = Task {
			defer {
				taskDeliveryWorker = nil
				endTaskDeliveryBackground()
				if taskDeliveryPending, !Task.isCancelled { startTaskDelivery() } else { scheduleTaskDeliveryRetry() }
			}
			while taskDeliveryPending, !Task.isCancelled {
				taskDeliveryPending = false
				let repair = taskDeliveryRepair
				taskDeliveryRepair = false
				let jobs = await repository.taskDeliveryJobs(repair: repair)
				guard !jobs.isEmpty else { continue }
				var status = procrastiMate.status()
				for job in jobs {
					guard !Task.isCancelled else { return }
					do {
						switch status {
						case let .unavailable(problem):
							if let record = try await repository.blockTasks(job, problem) { publish(record) }
						case let .linked(credentials):
							do {
								let remote = try await procrastiMate.put(credentials,
									MemoTasksRequest(memoID: job.id, recordedAt: job.recordedAt, tasks: job.tasks))
								if let record = try await repository.acknowledgeTasks(job, remote: remote) { publish(record) }
							} catch ProcrastiMateError.unauthorized {
								status = .unavailable(.signedOut)
								if let record = try await repository.blockTasks(job, .signedOut) { publish(record) }
							} catch {
								if let record = try await repository.failTasks(job,
									message: "ProcrastiMate couldn’t be reached. These todos will be sent again.") { publish(record) }
							}
						}
					} catch {
						// Without a saved outcome the timer would resend at once; wait for a foreground visit instead.
						taskDeliveryStorageFailed = true
						storageErrorMessage = "Task delivery progress couldn’t be saved. " + error.localizedDescription
						return
					}
				}
			}
		}
	}

	private func endTaskDeliveryBackground() {
		guard taskDeliveryBackground != .invalid else { return }
		UIApplication.shared.endBackgroundTask(taskDeliveryBackground)
		taskDeliveryBackground = .invalid
	}

	private func scheduleTaskDeliveryRetry() {
		taskDeliveryWake?.cancel()
		guard procrastiMate != nil, !taskDeliveryStorageFailed else { return }
		taskDeliveryWake = Task {
			guard let next = await repository.nextTaskDeliveryRetry() else { return }
			do { try await Task.sleep(for: .seconds(max(0.05, next.timeIntervalSinceNow))) } catch { return }
			scheduleTaskDelivery()
		}
	}

	func refreshRemoteTasks(for entryID: UUID) async {
		guard let procrastiMate, !isDemoMode, taskDeliveries[entryID]?.receipts.isEmpty == false,
			case let .linked(credentials) = procrastiMate.status(),
			let remote = try? await procrastiMate.list(credentials, entryID),
			let record = try? await repository.cacheRemoteTasks(remote, for: entryID) else { return }
		publish(record)
	}

	#if DEBUG
	func seedMemoForTesting(_ entry: JournalEntry, at stage: ProcessingStage) async throws {
		publish(try await repository.seed(entry, at: stage))
		startUserInitiatedProcessing()
		kickProcessing()
	}

	func waitForTaskDeliveryForContract() async {
		while let worker = taskDeliveryWorker { await worker.value }
	}
	#endif

	@discardableResult
	func clearJournal() async -> Bool {
		await deleteEntries(ids: entries.map(\.id))
	}

	private func deleteEntries(ids: [UUID]) async -> Bool {
		pendingDeletionIDs.formUnion(ids)
		if let lease = activeLease, pendingDeletionIDs.contains(lease.entryID) { activeStage?.cancel() }
		defer {
			pendingDeletionIDs.subtract(ids)
			kickProcessing()
		}
		#if DEBUG
		await deletionIntentCheckpoint?()
		#endif
		await persistenceTask?.value
		var failedCount = 0
		for entryID in ids {
			guard entries.contains(where: { $0.id == entryID }) else { continue }
			do {
				_ = try await repository.delete(id: entryID)
				if activeLease?.entryID == entryID { activeStage?.cancel() }
				pendingEdits.removeAll { $0.entryID == entryID }
				deletedEntryIDs.insert(entryID)
				processingStates.removeValue(forKey: entryID)
				taskDeliveries.removeValue(forKey: entryID)
				remoteTasks.removeValue(forKey: entryID)
				failedNoteSaveIDs.remove(entryID)
				updateUnsavedNoteStatus()
				entryProcessingPhases.removeValue(forKey: entryID)
				entryLocationTasks.removeValue(forKey: entryID)?.cancel()
				entries.removeAll { $0.id == entryID }
				if let record = await repository.record(id: entryID) { publish(record) }
				scheduleICloudDriveMirror()
				await cleanupDeletedAudio(id: entryID)
			} catch { failedCount += 1 }
		}
		if failedCount > 0 {
			storageErrorMessage = "Couldn’t delete \(failedCount == 1 ? "one note" : "\(failedCount) notes"). Their audio is still on this device. Try deleting them again."
		}
		updateUnsavedNoteStatus()
		return failedCount == 0
	}

	func weeklyReview(for date: Date) async -> WeeklyReview {
		if isDemoMode {
			var review = WeeklyReview.demo
			#if DEBUG
			if ProcessInfo.processInfo.arguments.contains("-demo-review-empty") {
				review = await ReflectionEngine.weeklyReview(entries: [], weekStart: date.startOfWeek())
			}
			if ProcessInfo.processInfo.arguments.contains("-demo-review-unavailable") { review.outcome = .unavailable }
			if ProcessInfo.processInfo.arguments.contains("-demo-review-data-unavailable") {
				review = WeeklyReview(weekStart: date.startOfWeek(), title: "", body: "",
					outcome: .failed("Your saved recordings could not be loaded. Try again."))
			}
			#endif
			return review
		}
		let start = date.startOfWeek()
		do {
			try Task.checkCancellation()
			if !isLoading, !hasLoadedJournal {
				isLoading = true
				bootstrapTask = Task { await loadJournal() }
			}
			try await waitUntilLoaded()
			try Task.checkCancellation()
		} catch {
			return WeeklyReview(weekStart: start, title: "", body: "", outcome: Task.isCancelled || error is CancellationError
				? .cancelled : .failed("Your saved recordings could not be loaded. Try again."))
		}
		let weekEntries = entries(inWeekContaining: date)
		#if DEBUG
		if let generation = weeklyReviewGeneration {
			return await ReflectionEngine.weeklyReview(entries: weekEntries, weekStart: start, generation: generation)
		}
		#endif
		return await ReflectionEngine.weeklyReview(entries: weekEntries, weekStart: start)
	}

	func updateSetting<Value>(_ keyPath: WritableKeyPath<JournalSettings, Value>, _ value: Value) {
		var current = settings
		current[keyPath: keyPath] = value
		updateSettings(current)
	}

	func updateSettings(_ settings: JournalSettings) {
		let calendarScopeChanged = applySettings(settings)
		commitConfiguration()
		if usesExternalServices, calendarScopeChanged { Task { await refreshCalendar(force: true) } }
	}

	@discardableResult
	private func applySettings(_ settings: JournalSettings) -> Bool {
		let calendarScopeChanged = self.settings.calendarSyncEnabled != settings.calendarSyncEnabled
			|| self.settings.includedCalendarIdentifiers != settings.includedCalendarIdentifiers
		self.settings = settings
		return calendarScopeChanged
	}

	func setShowModelNames(_ showModelNames: Bool) {
		settings.showModelNames = showModelNames
		commitConfiguration()
	}

	func setElevenLabsAPIKey(_ apiKey: String) {
		elevenLabsAPIKey = apiKey
		commitConfiguration(keyEdited: true)
	}

	func clearTranscriptionAlert() {
		transcriptionAlertMessage = nil
	}

	func requestCalendarAccess() async -> Bool {
		await calendarSync.requestAccess()
	}

	func refreshCalendar(force: Bool = false) async {
		await bootstrapTask?.value
		await configurationBootstrapTask?.value
		guard settings.calendarSyncEnabled else {
			calendarSync.clear()
			return
		}
		await calendarSync.refresh(
			includedCalendarIdentifiers: settings.includedCalendarIdentifiers,
			force: force
		)
	}

	private var currentConfiguration: AppConfiguration {
		AppConfiguration(settings: settings, locations: namedLocations, elevenLabsAPIKey: elevenLabsAPIKey)
	}

	private func loadConfiguration() async {
		#if DEBUG
		await configurationLoadCheckpoint?()
		#endif
		do {
			let snapshot = try await configurationRepository.load(baseline: configurationInitialValue)
			publishConfiguration(snapshot)
		} catch {
			configurationSaveMessage = "Settings could not be opened. Original files were preserved."
			updateCloudStatus()
		}
		hasLoadedConfiguration = true
		kickProcessing()
		startConfigurationWriter()
		scheduleICloudDriveMirror(repair: true)
	}

	func applyRestoredConfiguration(_ configuration: AppConfiguration) {
		let scopeChanged = applySettings(configuration.settings)
		namedLocations = configuration.locations
		elevenLabsAPIKey = configuration.elevenLabsAPIKey
		configurationIntentValue = configuration
		if usesExternalServices, scopeChanged { Task { await refreshCalendar(force: true) } }
	}

	private func publishConfiguration(_ snapshot: ConfigurationSnapshot) {
		guard snapshot.revision >= (configurationSnapshot?.revision ?? -1) else { return }
		configurationSnapshot = snapshot
		var value = snapshot.value
		for intent in configurationIntents {
			value = value.applying(value: intent.value, baseline: intent.baseline, keyEdited: intent.keyEdited)
		}
		applyRestoredConfiguration(value)
		if usesExternalServices, configurationIntents.isEmpty { value.settings.save() }
		updateCloudStatus()
	}

	private func commitConfiguration(keyEdited: Bool = false) {
		let value = currentConfiguration
		let baseline = configurationIntentValue
		configurationIntentValue = value
		guard !isDemoMode else { return }
		configurationIntents.append(PendingConfigurationEdit(baseline: baseline, value: value, keyEdited: keyEdited))
		startConfigurationWriter()
	}

	private func startConfigurationWriter() {
		guard configurationWriteTask == nil, !configurationIntents.isEmpty else { return }
		configurationWriteTask = Task {
			await configurationBootstrapTask?.value
			defer { configurationWriteTask = nil; updateCloudStatus() }
			while let intent = configurationIntents.first {
				do {
					let snapshot = try await configurationRepository.saveLocal(intent.value, baseline: intent.baseline, keyEdited: intent.keyEdited)
					configurationIntents.removeAll { $0.id == intent.id }
					configurationSaveMessage = nil
					publishConfiguration(snapshot)
					scheduleICloudDriveMirror()
				} catch {
					configurationSaveMessage = "Settings changes haven’t been saved. Original files were preserved. Try again."
					break
				}
			}
		}
	}

	func retryCloudSync() {
		guard !isDemoMode else { return }
		cloudSaveFailed = false
		Task {
			if configurationSnapshot == nil || configurationSnapshot?.status == .blocked || !hasLoadedConfiguration {
				do {
					let snapshot = try await configurationRepository.load(baseline: configurationInitialValue)
					configurationSaveMessage = nil
					hasLoadedConfiguration = true
					publishConfiguration(snapshot)
				} catch { configurationSaveMessage = "Settings could not be opened. Original files were preserved." }
			}
			startConfigurationWriter()
			await configurationWriteTask?.value
			scheduleICloudDriveMirror(changed: false, repair: true)
		}
	}

	private func updateCloudStatus() {
		if let configurationSaveMessage { cloudStatusMessage = configurationSaveMessage; return }
		if cloudSaveFailed { cloudStatusMessage = "iCloud export progress could not be saved locally. Your recordings are preserved. Try again."; return }
		if let issue = configurationSnapshot?.issue { cloudStatusMessage = issue; return }
		if let failure = committedRecords.values.compactMap({ $0.cloudRetry?.message }).first {
			cloudStatusMessage = failure
			return
		}
		if let message = legacyCloudRetry?.message { cloudStatusMessage = message; return }
		if configurationSnapshot?.status == .provisional {
			cloudStatusMessage = "Settings changes are saved on this device while iCloud configuration is checked."
			return
		}
		let hasPendingNotes = committedRecords.values.contains {
			$0.contentRevision > $0.exportedRevision && ($0.state == .deleted || $0.entry?.audioFilename?.hasSuffix(".m4a") == true)
		}
		cloudStatusMessage = hasPendingNotes || configurationSnapshot?.export != nil
			? "iCloud Drive exports are pending. Your recordings remain saved on this device." : nil
	}

	private func removeExactAlias(_ coordinate: LocationCoordinate, excluding locationID: UUID) {
		for index in namedLocations.indices where namedLocations[index].id != locationID {
			namedLocations[index].aliases.removeAll {
				$0.location.distance(from: coordinate.location) < 5
			}
		}
	}

	private func appendAlias(_ coordinate: LocationCoordinate, at index: Int) {
		guard !namedLocations[index].matchingCoordinates.contains(where: {
			$0.location.distance(from: coordinate.location) < 5
		}) else { return }
		namedLocations[index].aliases.append(coordinate)
	}

	func retrySavingChanges() async {
		queuePendingWrites()
		await persistenceTask?.value
	}

	func hasUnsavedChanges(for entryID: UUID) -> Bool {
		(isDemoMode && hasUnsavedNoteChanges) || pendingEdits.contains { $0.entryID == entryID }
	}

	private func updateUnsavedNoteStatus() {
		hasUnsavedNoteChanges = !failedNoteSaveIDs.isEmpty
	}

	func committedEntryForExport(id: UUID) async throws -> JournalEntry {
		guard !pendingDeletionIDs.contains(id), !deletedEntryIDs.contains(id) else { throw RepositoryError.unavailableRecord }
		if isDemoMode, let entry = entry(id: id) { return entry }
		await persistenceTask?.value
		while true {
			guard !pendingDeletionIDs.contains(id), !deletedEntryIDs.contains(id) else { throw RepositoryError.unavailableRecord }
			guard !hasUnsavedChanges(for: id) else { throw RepositoryError.unsavedChanges }
			guard let record = await repository.record(id: id), record.state == .saved,
				let entry = record.entry else { throw RepositoryError.unavailableRecord }
			guard !pendingDeletionIDs.contains(id), !deletedEntryIDs.contains(id) else { throw RepositoryError.unavailableRecord }
			guard !hasUnsavedChanges(for: id) else { throw RepositoryError.unsavedChanges }
			if record.revision < (committedRecords[id]?.revision ?? 0) { continue }
			return entry
		}
	}

	func committedEntriesForExport() async -> [JournalEntry] {
		if isDemoMode { return entries }
		await persistenceTask?.value
		return await repository.committedEntries()
	}

	func persist(_ edit: JournalEdit, entryID: UUID) {
		guard let index = entries.firstIndex(where: { $0.id == entryID }) else { return }
		edit.apply(to: &entries[index])
		guard !isDemoMode else { return }
		pendingEdits.append(PendingJournalEdit(entryID: entryID, edit: edit))
		queuePendingWrites()
	}

	private func queuePendingWrites() {
		let previous = persistenceTask
		persistenceTask = Task {
			await previous?.value
			var attempted = Set<UUID>()
			var failedEntries = Set<UUID>()
			while let pending = pendingEdits.first(where: { !attempted.contains($0.id) && !failedEntries.contains($0.entryID) }) {
				attempted.insert(pending.id)
				do {
					let record = try await repository.apply(pending.edit, to: pending.entryID)
					pendingEdits.removeAll { $0.id == pending.id }
					failedNoteSaveIDs.remove(pending.entryID)
					publish(record)
					cancelObsoleteStage()
					scheduleICloudDriveMirror()
				} catch RepositoryError.unavailableRecord {
					pendingEdits.removeAll { $0.id == pending.id }
					failedNoteSaveIDs.remove(pending.entryID)
				} catch {
					failedEntries.insert(pending.entryID)
					failedNoteSaveIDs.insert(pending.entryID)
					updateUnsavedNoteStatus()
					storageErrorMessage = "Note changes haven’t been saved. Try saving again. " + error.localizedDescription
				}
			}
			updateUnsavedNoteStatus()
			kickProcessing()
		}
	}

	private var canMirror: Bool {
		#if DEBUG
		if cloudStoppedForContract { return false }
		#endif
		return hasLoadedJournal && hasLoadedConfiguration && !isLoading && !isCapturePriorityActive
	}

	private func scheduleICloudDriveMirror(changed: Bool = true, repair: Bool = false) {
		guard !isDemoMode, mirroringEnabled else { return }
		if changed { iCloudRevision += 1 }
		if repair { cloudSaveFailed = false }
		iCloudPending = true
		iCloudRepairPending = iCloudRepairPending || repair
		cloudRetryTask?.cancel()
		startICloudMirrorWorker()
	}

	private func startICloudMirrorWorker() {
		guard iCloudPending, canMirror, iCloudWorker == nil else { return }
		iCloudWorker = Task {
			var activeRepair = false
			isCloudSyncing = true
			defer {
				if Task.isCancelled {
					iCloudPending = true
					iCloudRepairPending = iCloudRepairPending || activeRepair
				}
				iCloudWorker = nil
				isCloudSyncing = false
				updateCloudStatus()
				if iCloudPending, canMirror { startICloudMirrorWorker() }
				else { scheduleCloudRetry() }
			}
			while iCloudPending, canMirror, !Task.isCancelled {
				iCloudPending = false
				let repair = iCloudRepairPending
				activeRepair = repair
				iCloudRepairPending = false
				let revision = iCloudRevision
				let jobs = await repository.cloudJobs(repair: repair)
				let configuration = await configurationRepository.snapshot(repair: repair)
				#if DEBUG
				await mirrorSnapshotCheckpoint?()
				#endif
				guard revision == iCloudRevision, canMirror, !Task.isCancelled else {
					iCloudPending = true
					iCloudRepairPending = iCloudRepairPending || repair
					continue
				}
				publishConfiguration(configuration)
				let references = repair || (legacyCloudRetry?.isDue(at: .now) ?? true) ? pendingICloudDeletionReferences : []
				if !jobs.isEmpty || configuration.export != nil || !references.isEmpty {
					let result = await cloudServices.sync(jobs, recordingsURL, configuration.export, references, revision)
					await acceptCloudResult(result, jobs: jobs, configuration: configuration, references: references)
				}
				guard canMirror, !Task.isCancelled else { return }
				if configuration.needsRestore {
					let result = await cloudServices.loadConfiguration()
					guard !Task.isCancelled else { return }
					await applyRemoteConfiguration(result, revision: configuration.revision)
				}
			}
		}
	}

	private func acceptCloudResult(_ result: ICloudMirrorResult, jobs: [CloudNoteJob],
		configuration: ConfigurationSnapshot, references: Set<String>) async {
		let submitted = Dictionary(uniqueKeysWithValues: jobs.map { ($0.id, $0) })
		var completed = Set<UUID>()
		for receipt in result.completedJobs {
			guard let job = submitted[receipt.job.id], job.contentRevision == receipt.job.contentRevision,
				job.entry == receipt.job.entry, job.deletionReferences == receipt.job.deletionReferences else { continue }
			completed.insert(job.id)
			do {
				if let record = try await repository.acknowledgeCloud(job: job, audioReceipt: receipt.audioReceipt,
					metadataReceipt: receipt.metadataReceipt) { publish(record) }
			} catch is CancellationError {} catch { cloudSaveFailed = true }
		}
		let acknowledged = result.completedDeletions.intersection(references)
		pendingICloudDeletionReferences.subtract(acknowledged)
		if pendingICloudDeletionReferences.isEmpty { legacyCloudRetry = nil }
		guard !Task.isCancelled else { savePendingICloudDeletions(); return }
		if !references.subtracting(acknowledged).isEmpty {
			legacyCloudRetry = .failed(previous: legacyCloudRetry,
				message: "Some iCloud Drive deletions remain pending. Local deletion is preserved.", now: .now)
		}
		savePendingICloudDeletions()
		for job in jobs where !completed.contains(job.id) {
			do {
				if let record = try await repository.failCloud(job: job,
					message: "Some iCloud Drive exports remain pending. Your recordings are saved on this device.") { publish(record) }
			} catch is CancellationError {} catch { cloudSaveFailed = true }
		}
		guard let export = configuration.export, !Task.isCancelled else { return }
		if export.mode == .createIfMissing, let read = result.configurationRead {
			await applyRemoteConfiguration(read, revision: configuration.revision)
		}
		do {
			if result.configurationExported {
				publishConfiguration(try await configurationRepository.acknowledgeCloud(fingerprint: export.fingerprint))
			} else if export.mode == .replace || result.configurationRead == nil {
				publishConfiguration(try await configurationRepository.failCloud(fingerprint: export.fingerprint,
					revision: configuration.revision, message: cloudConfigurationMessage(result.configurationRead)))
			}
		} catch is CancellationError {} catch { cloudSaveFailed = true }
	}

	private func applyRemoteConfiguration(_ read: ConfigurationRead, revision: Int) async {
		do {
			let snapshot = try await configurationRepository.applyRemote(read, expectedRevision: revision)
			publishConfiguration(snapshot)
			switch read {
			case .available, .missing:
				if snapshot.export != nil { scheduleICloudDriveMirror() }
			default: break
			}
		} catch is CancellationError {} catch { cloudSaveFailed = true }
	}

	private func cloudConfigurationMessage(_ read: ConfigurationRead?) -> String {
		switch read {
		case .unavailable(let message), .damaged(let message): message
		case .unsupported: "The iCloud configuration needs a newer app. Its original file was preserved."
		case .conflict: "iCloud has conflicting configuration versions. They were preserved for resolution."
		default: "Configuration export remains pending. Your saved settings are preserved on this device."
		}
	}

	private func scheduleCloudRetry() {
		cloudRetryTask?.cancel()
		guard mirroringEnabled, !isDemoMode, canMirror, !cloudSaveFailed else { return }
		cloudRetryTask = Task {
			let notes = await repository.nextCloudRetry()
			let configuration = await configurationRepository.snapshot()
			guard !Task.isCancelled else { return }
			let retry = [notes, configuration.nextRetry, pendingICloudDeletionReferences.isEmpty ? nil : legacyCloudRetry?.retryAfter]
				.compactMap { $0 }.min()
			guard let retry else { return }
			do { try await Task.sleep(for: .seconds(max(0.05, retry.timeIntervalSinceNow))) }
			catch { return }
			guard !Task.isCancelled else { return }
			scheduleICloudDriveMirror(changed: false)
		}
	}

	#if DEBUG
	func stopCloudForContract() async {
		cloudStoppedForContract = true
		cloudRetryTask?.cancel()
		iCloudWorker?.cancel()
		await cloudRetryTask?.value
		await iCloudWorker?.value
		await configurationBootstrapTask?.value
		await configurationWriteTask?.value
		iCloudPending = false
		iCloudRepairPending = false
	}
	func waitForICloudMirrorForContract() async {
		await configurationBootstrapTask?.value
		await configurationWriteTask?.value
		await iCloudWorker?.value
	}

	func waitForConfigurationWritesForContract() async {
		await configurationBootstrapTask?.value
		await configurationWriteTask?.value
	}
	#endif

	private func savePendingICloudDeletions() {
		guard usesExternalServices else { return }
		if let legacyCloudRetry, let data = try? JSONEncoder().encode(legacyCloudRetry) {
			UserDefaults.standard.set(data, forKey: Self.iCloudRetryKey)
		} else { UserDefaults.standard.removeObject(forKey: Self.iCloudRetryKey) }
		if pendingICloudDeletionReferences.isEmpty {
			UserDefaults.standard.removeObject(forKey: Self.iCloudDeletionKey)
		} else {
			UserDefaults.standard.set(
				pendingICloudDeletionReferences.sorted(),
				forKey: Self.iCloudDeletionKey
			)
		}
	}


	private static let iCloudDeletionKey = "pending-icloud-drive-deletions"
	private static let iCloudRetryKey = "pending-icloud-drive-deletion-retry"
}

private struct PendingConfigurationEdit {
	let id = UUID()
	var baseline: AppConfiguration
	var value: AppConfiguration
	var keyEdited: Bool
}

private struct PendingJournalEdit {
	let id = UUID()
	let entryID: UUID
	let edit: JournalEdit
}

struct JournalSettings: Codable, Equatable, Sendable {
	var keepScreenAwakeWhileRecording = true
	var hapticsEnabled = true
	var showTranscripts = true
	var showModelNames = true
	var preferElevenLabsTranscription = true
	var calendarSyncEnabled = false
	var includedCalendarIdentifiers: Set<String>?
	var preferredCalendarApp = PreferredCalendarApp.google

	private static let key = "journal-settings"

	init() {}

	init(from decoder: Decoder) throws {
		let container = try decoder.container(keyedBy: CodingKeys.self)
		keepScreenAwakeWhileRecording = try container.decodeIfPresent(
			Bool.self,
			forKey: .keepScreenAwakeWhileRecording
		) ?? true
		hapticsEnabled = try container.decodeIfPresent(Bool.self, forKey: .hapticsEnabled) ?? true
		showTranscripts = try container.decodeIfPresent(Bool.self, forKey: .showTranscripts) ?? true
		showModelNames = try container.decodeIfPresent(Bool.self, forKey: .showModelNames) ?? true
		preferElevenLabsTranscription = try container.decodeIfPresent(
			Bool.self,
			forKey: .preferElevenLabsTranscription
		) ?? true
		calendarSyncEnabled = try container.decodeIfPresent(Bool.self, forKey: .calendarSyncEnabled) ?? false
		includedCalendarIdentifiers = try container.decodeIfPresent(
			Set<String>.self,
			forKey: .includedCalendarIdentifiers
		)
		preferredCalendarApp = try container.decodeIfPresent(
			PreferredCalendarApp.self,
			forKey: .preferredCalendarApp
		) ?? .google
	}

	static func load() -> JournalSettings {
		guard let data = UserDefaults.standard.data(forKey: key) else { return JournalSettings() }
		return (try? JSONDecoder().decode(JournalSettings.self, from: data)) ?? JournalSettings()
	}

	func save() {
		guard let data = try? JSONEncoder().encode(self) else { return }
		UserDefaults.standard.set(data, forKey: Self.key)
	}
}
