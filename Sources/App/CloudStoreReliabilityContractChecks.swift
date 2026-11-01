#if DEBUG
import Foundation

@MainActor
enum CloudStoreReliabilityContractChecks {
	static func runFromLaunchArguments() async {
		guard ProcessInfo.processInfo.arguments.contains("-cloud-store-reliability-contract-tests") else { return }
		do {
			try await unavailableChecks()
			try await heldRestoreChecks()
			try await startupAndRepairChecks()
			try await processingConfigurationChecks()
			try await captureChecks()
			try await retryAfterCaptureChecks()
			print("CLOUD STORE RELIABILITY CONTRACT: independent note export, provisional restart, held restore and startup edits, live settings intent, repaired storage retry, and capture cancellation passed")
			fflush(stdout)
		} catch { fatalError("CLOUD STORE RELIABILITY CONTRACT: \(error)") }
	}

	private static func unavailableChecks() async throws {
		let root = try temporaryRoot()
		defer { try? FileManager.default.removeItem(at: root) }
		let entry = try await seed(root)
		let provider = Provider(remote: .unavailable("Fixture iCloud unavailable"))
		let store = makeStore(root, provider)
		try await store.waitUntilLoaded()
		await store.waitForICloudMirrorForContract()
		let calls = await provider.calls
		try expect(calls.contains { $0.jobs.contains { $0.id == entry.id } && $0.configuration == nil },
			"Committed recordings must export independently while configuration restoration is unavailable")
		store.updateSetting(\.hapticsEnabled, false)
		await store.waitForConfigurationWritesForContract()
		await store.waitForICloudMirrorForContract()
		let loads = await provider.loadCount
		try await Task.sleep(for: .milliseconds(30))
		try expect(await provider.loadCount == loads, "A failed restoration must wait for its persisted retry rather than spin")
		try expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent("config.json").path),
			"An unrelated local setting edit must not publish default configuration over an unknown remote file")
		await store.stopCloudForContract()
		let after = makeStore(root, Provider(remote: .unavailable("Fixture still unavailable")))
		try await after.waitUntilLoaded()
		await after.waitForICloudMirrorForContract()
		try expect(!after.settings.hapticsEnabled && after.entry(id: entry.id) != nil && after.cloudStatusMessage != nil,
			"Provisional edits and local notes must survive restart while restore remains unresolved")
		await after.stopCloudForContract()
	}

	private static func heldRestoreChecks() async throws {
		let root = try temporaryRoot()
		defer { try? FileManager.default.removeItem(at: root) }
		_ = try await seed(root)
		var remote = AppConfiguration(settings: JournalSettings())
		remote.settings.showTranscripts = false
		remote.settings.includedCalendarIdentifiers = ["synthetic-calendar"]
		remote.elevenLabsAPIKey = "synthetic-remote-value"
		remote.locations = [NamedJournalLocation(name: "Restored place", pin: LocationCoordinate(latitude: 1, longitude: 2))]
		let provider = Provider(remote: .available(remote), holdRestore: true)
		let store = makeStore(root, provider)
		try await store.waitUntilLoaded()
		try await wait { await provider.loadCount == 1 }
		store.updateSetting(\.hapticsEnabled, false)
		store.setElevenLabsAPIKey("synthetic-provisional-value")
		store.setElevenLabsAPIKey("")
		await store.waitForConfigurationWritesForContract()
		await provider.releaseRestore()
		await store.waitForICloudMirrorForContract()
		try expect(!store.settings.hapticsEnabled && !store.settings.showTranscripts
			&& store.settings.includedCalendarIdentifiers == remote.settings.includedCalendarIdentifiers
			&& store.namedLocations == remote.locations && store.elevenLabsAPIKey.isEmpty,
			"A held remote restore must merge latest local edits and intentional key clear without losing remote fields")
		store.updateSetting(\.showModelNames, false)
		await store.waitForConfigurationWritesForContract()
		await store.waitForICloudMirrorForContract()
		try expect(!store.settings.showModelNames && !store.settings.showTranscripts
			&& store.settings.includedCalendarIdentifiers == remote.settings.includedCalendarIdentifiers,
			"A live Settings binding must mutate only one field of the current restored settings")
		await store.stopCloudForContract()
	}

	private static func startupAndRepairChecks() async throws {
		let root = try temporaryRoot()
		defer { try? FileManager.default.removeItem(at: root) }
		_ = try await seed(root)
		var remote = AppConfiguration(settings: JournalSettings())
		remote.settings.showTranscripts = false
		let gate = Gate()
		let store = makeStore(root, Provider(remote: .available(remote)))
		store.configurationLoadCheckpoint = { await gate.wait() }
		try await store.waitUntilLoaded()
		try await wait { await gate.started }
		store.updateSetting(\.hapticsEnabled, false)
		await gate.release()
		await store.waitForConfigurationWritesForContract()
		await store.waitForICloudMirrorForContract()
		try expect(!store.settings.hapticsEnabled && !store.settings.showTranscripts,
			"An edit before local config load must be compared with the immutable startup baseline")
		await store.stopCloudForContract()

		let damagedRoot = try temporaryRoot()
		defer { try? FileManager.default.removeItem(at: damagedRoot) }
		_ = try await seed(damagedRoot)
		let url = damagedRoot.appendingPathComponent("config.json")
		let damaged = Data("{}".utf8)
		try damaged.write(to: url)
		let damagedStore = makeStore(damagedRoot, Provider(remote: .unavailable("Unexpected restore")))
		try await damagedStore.waitUntilLoaded()
		await damagedStore.waitForICloudMirrorForContract()
		damagedStore.updateSetting(\.hapticsEnabled, false)
		await damagedStore.waitForConfigurationWritesForContract()
		try expect((try Data(contentsOf: url)) == damaged && damagedStore.cloudStatusMessage != nil,
			"Blocked local config must retain bytes and unsaved user intent")
		try remote.jsonData().write(to: url, options: .atomic)
		damagedStore.retryCloudSync()
		try await wait { !damagedStore.settings.showTranscripts && !damagedStore.settings.hapticsEnabled }
		await damagedStore.waitForConfigurationWritesForContract()
		await damagedStore.waitForICloudMirrorForContract()
		let repaired = try JSONDecoder().decode(AppConfiguration.self, from: Data(contentsOf: url))
		try expect(!repaired.settings.showTranscripts && !repaired.settings.hapticsEnabled,
			"Retry after a repaired local file must replay only the unsaved local intent over the repaired value")
		await damagedStore.stopCloudForContract()
	}

	private static func processingConfigurationChecks() async throws {
		let root = try temporaryRoot()
		defer { try? FileManager.default.removeItem(at: root) }
		let entry = try await seed(root)
		let repository = JournalRepository(rootURL: root)
		_ = try await repository.load()
		_ = try await repository.requestProcessing(id: entry.id)
		var saved = AppConfiguration(settings: JournalSettings(), elevenLabsAPIKey: "synthetic-saved-value")
		saved.settings.preferElevenLabsTranscription = false
		try saved.jsonData().write(to: root.appendingPathComponent("config.json"))
		let gate = Gate()
		let transcription = TranscriptionCapture()
		let provider = Provider(remote: .unavailable("Unexpected restore"))
		let services = ProcessingServices(transcribe: { _, preferred, key, _ in
			await transcription.record(preferred, key)
			return TranscriptionResult(transcript: "Completed fixture words", modelName: "Fixture")
		}, reflect: { _, _ in ReflectionResult(headline: "Fixture result", summary: nil, modelName: "Fixture") })
		let store = JournalStore(storageRootURL: root, processingServices: services,
			cloudServices: CloudServices(sync: { jobs, _, configuration, references, revision in
				await provider.sync(jobs, configuration, references, revision)
			}, loadConfiguration: { await provider.load() }))
		store.configurationLoadCheckpoint = { await gate.wait() }
		try await store.waitUntilLoaded()
		try await wait { await gate.started }
		try await Task.sleep(for: .milliseconds(30))
		let record = try JSONDecoder().decode(JournalRecord.self,
			from: Data(contentsOf: root.appendingPathComponent("Records/\(entry.id).json")))
		try expect(await transcription.calls == 0, "Optional processing must not invoke a provider before local configuration is loaded")
		try expect(record.processing?.status == .queued, "Optional processing must not claim its stage using startup defaults")
		await gate.release()
		try await wait { store.processingStates[entry.id]?.status == .complete }
		let captured = await transcription.first
		try expect(captured?.0 == false && captured?.1 == saved.elevenLabsAPIKey,
			"The first admitted transcription must receive the saved provider preference and key")
		await store.waitForICloudMirrorForContract()
		await store.stopCloudForContract()
	}

	private static func captureChecks() async throws {
		let root = try temporaryRoot()
		defer { try? FileManager.default.removeItem(at: root) }
		let entry = try await seed(root)
		try AppConfiguration(settings: JournalSettings()).jsonData().write(to: root.appendingPathComponent("config.json"))
		let provider = Provider(remote: .unavailable("Unexpected restore"), holdFirstSync: true)
		let store = makeStore(root, provider)
		try await store.waitUntilLoaded()
		try await wait { await provider.calls.count == 1 }
		let owner = UUID()
		await store.beginCapturePriority(owner: owner)
		try await wait { await provider.cancelledCalls == 1 }
		await store.waitForICloudMirrorForContract()
		try expect(await provider.active == 0, "Capture preemption must reach and drain the actual provider call")
		await store.endCapturePriority(owner: owner)
		try await wait { await provider.calls.count == 2 }
		await store.waitForICloudMirrorForContract()
		let calls = await provider.calls
		try expect(calls[0].revision == calls[1].revision && calls[1].jobs.contains { $0.id == entry.id },
			"Capture release must retry unacknowledged work at the same content revision")
		try expect(await provider.maximumActive == 1, "Canceled provider work must not overlap its replacement")
		await store.stopCloudForContract()
	}

	private static func retryAfterCaptureChecks() async throws {
		let root = try temporaryRoot()
		defer { try? FileManager.default.removeItem(at: root) }
		_ = try await seed(root)
		try AppConfiguration(settings: JournalSettings()).jsonData().write(to: root.appendingPathComponent("config.json"))
		let provider = Provider(remote: .unavailable("Unexpected restore"), failFirstSync: true)
		let store = makeStore(root, provider)
		try await store.waitUntilLoaded()
		await store.waitForICloudMirrorForContract()
		try expect(await provider.calls.count == 1, "Fixture must stop at its first failed cloud pass")
		let persisted = JournalRepository(rootURL: root)
		_ = try await persisted.load()
		try expect(await persisted.nextCloudRetry() != nil, "Cloud retry must be durable before capture interrupts its timer")
		let owner = UUID()
		await store.beginCapturePriority(owner: owner)
		await store.endCapturePriority(owner: owner)
		try await wait(seconds: 8) { await provider.calls.count == 2 }
		await store.waitForICloudMirrorForContract()
		try expect(await provider.maximumActive == 1, "Resumed retry must still use one provider worker")
		await store.stopCloudForContract()
	}

	private static func makeStore(_ root: URL, _ provider: Provider) -> JournalStore {
		JournalStore(storageRootURL: root, cloudServices: CloudServices(sync: { jobs, _, configuration, references, revision in
			await provider.sync(jobs, configuration, references, revision)
		}, loadConfiguration: { await provider.load() }))
	}
	private struct Call: Sendable {
		var jobs: [CloudNoteJob]
		var configuration: CloudConfigurationJob?
		var revision: Int
	}
	private actor Provider {
		let remote: ConfigurationRead
		var holdRestore: Bool
		let holdFirstSync: Bool
		let failFirstSync: Bool
		private var restore: CheckedContinuation<ConfigurationRead, Never>?
		private(set) var calls: [Call] = []
		private(set) var loadCount = 0
		private(set) var cancelledCalls = 0
		private(set) var active = 0
		private(set) var maximumActive = 0
		init(remote: ConfigurationRead, holdRestore: Bool = false, holdFirstSync: Bool = false, failFirstSync: Bool = false) {
			self.remote = remote
			self.holdRestore = holdRestore
			self.holdFirstSync = holdFirstSync
			self.failFirstSync = failFirstSync
		}
		func sync(_ jobs: [CloudNoteJob], _ configuration: CloudConfigurationJob?, _ references: Set<String>, _ revision: Int) async -> ICloudMirrorResult {
			calls.append(Call(jobs: jobs, configuration: configuration, revision: revision))
			active += 1
			maximumActive = max(maximumActive, active)
			defer { active -= 1 }
			if holdFirstSync && calls.count == 1 {
				do { try await Task.sleep(for: .seconds(30)) }
				catch { cancelledCalls += 1; return ICloudMirrorResult() }
			}
			if failFirstSync && calls.count == 1 { return ICloudMirrorResult(failures: ["Fixture temporary provider failure"]) }
			return ICloudMirrorResult(completedJobs: jobs.map { CloudNoteReceipt(job: $0) }, completedDeletions: references,
				configurationExported: configuration != nil,
				configurationRead: configuration?.mode == .createIfMissing ? configuration.map { .available($0.value) } : nil)
		}
		func load() async -> ConfigurationRead {
			loadCount += 1
			guard holdRestore else { return remote }
			return await withTaskCancellationHandler {
				if Task.isCancelled { return .unavailable("Fixture canceled") }
				return await withCheckedContinuation { restore = $0 }
			} onCancel: { Task { await self.releaseRestore() } }
		}
		func releaseRestore() { holdRestore = false; restore?.resume(returning: remote); restore = nil }
	}
	private actor TranscriptionCapture {
		private(set) var calls = 0
		private(set) var first: (Bool, String?)?
		func record(_ preferred: Bool, _ key: String?) { calls += 1; if first == nil { first = (preferred, key) } }
	}
	private actor Gate {
		private(set) var started = false
		private var continuation: CheckedContinuation<Void, Never>?
		func wait() async { started = true; await withCheckedContinuation { continuation = $0 } }
		func release() { continuation?.resume(); continuation = nil }
	}
	private static func seed(_ root: URL) async throws -> JournalEntry {
		let repository = JournalRepository(rootURL: root)
		_ = try await repository.load()
		let id = UUID()
		let entry = JournalEntry(id: id, duration: 12, transcript: "Completed words", headline: "Saved", audioFilename: "\(id).m4a")
		try await repository.save([entry])
		return entry
	}
	private static func temporaryRoot() throws -> URL {
		let root = FileManager.default.temporaryDirectory.appendingPathComponent("cloud-store-\(UUID())")
		try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
		return root
	}
	private static func wait(seconds: Double = 5, _ condition: () async -> Bool) async throws {
		let deadline = ContinuousClock.now.advanced(by: .seconds(seconds))
		while !(await condition()) {
			guard ContinuousClock.now < deadline else { throw Failure("Timed out at a cloud/configuration ownership boundary") }
			try await Task.sleep(for: .milliseconds(1))
		}
	}
	private static func expect(_ condition: Bool, _ message: String) throws { if !condition { throw Failure(message) } }
	private struct Failure: Error { let message: String; init(_ message: String) { self.message = message } }
}
#endif
