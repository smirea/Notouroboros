#if DEBUG
import AVFoundation
import Foundation

@MainActor
enum ProcessingWorkerContractChecks {
	static func runFromLaunchArguments() async {
		guard ProcessInfo.processInfo.arguments.contains("-processing-worker-contract-tests") else { return }
		do {
			try await failedEditAndReceiptChecks()
			try await stageWriteFailureChecks()
			try await drainBoundaryChecks()
			print("PROCESSING WORKER CONTRACT: narrow edit retry, stale/deleted receipts, stage write failure, preserved results, one active pipeline, and drain-boundary enqueue passed")
			fflush(stdout)
		} catch { fatalError("PROCESSING WORKER CONTRACT: \(error)") }
	}

	private static func failedEditAndReceiptChecks() async throws {
		let root = try temporaryRoot()
		let entry = try seed(root: root)
		let probe = Probe()
		let store = JournalStore(storageRootURL: root, processingServices: services(probe))
		defer { try? FileManager.default.removeItem(at: root) }
		do {
			try await store.waitUntilLoaded()
			await store.waitForConfigurationWritesForContract()

			store.reprocessEntry(id: entry.id)
			try await wait { await probe.starts == 1 }
			try await wait { store.partialTranscript(for: entry.id) != nil }
			try expect(store.entry(id: entry.id)?.transcript == entry.transcript, "Live partials must never replace prior completed text")
			let oldReceipt = try JSONDecoder().decode(JournalRecord.self, from: Data(contentsOf: manifest(entry.id, root)))
			let held = try block(entry.id, root)
			let location = JournalLocation(latitude: 1, longitude: 2, city: "Saved later")
			store.persist(.location(location), entryID: entry.id)
			await store.waitForPendingWrites()
			try expect(store.hasUnsavedNoteChanges && store.entry(id: entry.id)?.location == location, "Failed location edit must remain visible and retryable")
			try restore(entry.id, root, held)
			await probe.finish("A new completed transcript")
			try await wait { store.processingStates[entry.id]?.status == .complete }
			try expect(store.entry(id: entry.id)?.location == location && store.entry(id: entry.id)?.transcript == "A new completed transcript",
				"A stage receipt must preserve pending intended edits")
			store.publish(oldReceipt)
			try expect(store.entry(id: entry.id)?.transcript == "A new completed transcript", "Older receipts must not replace newer stage output")
			await store.retrySavingChanges()
			let reloaded = try await JournalRepository(rootURL: root).load()
			try expect(!store.hasUnsavedNoteChanges && reloaded.entries[0].location == location
				&& reloaded.entries[0].transcript == "A new completed transcript", "Narrow retry must preserve both field owners after relaunch")
			let deleted = await store.deleteEntry(id: entry.id)
			try expect(deleted, "Fixture deletion must commit")
			store.publish(oldReceipt)
			try expect(store.entries.isEmpty, "A late saved receipt cannot restore a tombstoned note in the interface")
		} catch { await probe.release(); throw error }
	}

	private static func stageWriteFailureChecks() async throws {
		let root = try temporaryRoot()
		let entry = try seed(root: root)
		let probe = Probe()
		let store = JournalStore(storageRootURL: root, processingServices: services(probe))
		defer { try? FileManager.default.removeItem(at: root) }
		do {
			try await store.waitUntilLoaded()
			await store.waitForConfigurationWritesForContract()

			store.reprocessEntry(id: entry.id)
			try await wait { await probe.starts == 1 }
			let held = try block(entry.id, root)
			await probe.finish("Uncommitted replacement")
			try await wait { store.processingPhase(for: entry.id) == .failed }
			try expect(await probe.reflections == 0, "Failed transcript commit must prevent the next service from starting")
			try expect(store.entry(id: entry.id)?.transcript == entry.transcript && store.entry(id: entry.id)?.summary == entry.summary,
				"A stage write failure must preserve prior completed transcript and analysis")
			try restore(entry.id, root, held)
			store.resumeStaleProcessing()
			try await Task.sleep(for: .milliseconds(20))
			try expect(await probe.starts == 1, "Foreground must not override a storage suspension")
			store.retryProcessingEntry(id: entry.id)
			try await wait { await probe.starts == 2 }
			await probe.finish("Durably retried transcript")
			try await wait { store.processingStates[entry.id]?.status == .complete }
			try expect(await probe.reflections == 1, "Retry must continue only after the transcript commit succeeds")
			let loaded = try await JournalRepository(rootURL: root).load()
			try expect(loaded.entries[0].transcript == "Durably retried transcript", "Successful retry must survive restart")
		} catch { await probe.release(); throw error }
	}

	private static func drainBoundaryChecks() async throws {
		let root = try temporaryRoot()
		let first = try seed(root: root)
		let second = try seed(root: root, append: true)
		let probe = Probe()
		let store = JournalStore(storageRootURL: root, processingServices: services(probe))
		defer { try? FileManager.default.removeItem(at: root) }
		do {
			try await store.waitUntilLoaded()
			await store.waitForConfigurationWritesForContract()

			store.processingIdleCheckpoint = { [weak store] in
				guard let store, await probe.starts == 1 else { return }
				store.processingIdleCheckpoint = nil
				store.reprocessEntry(id: second.id)
				try? await wait { store.processingStates[second.id]?.status == .queued }
			}
			store.reprocessEntry(id: first.id)
			try await wait { await probe.starts == 1 }
			await probe.finish("First finished")
			try await wait { await probe.starts == 2 }
			await probe.finish("Second finished")
			try await wait { store.processingStates[second.id]?.status == .complete }
			try expect(await probe.maximumActive == 1, "A newly queued note at worker exit must run without overlapping another pipeline")
		} catch { await probe.release(); throw error }
	}

	private static func services(_ probe: Probe) -> ProcessingServices {
		ProcessingServices(transcribe: { _, _, _, update in try await probe.transcribe(update) },
			reflect: { transcript, _ in await probe.reflect(transcript) })
	}

	private actor Probe {
		var starts = 0
		var reflections = 0
		var active = 0
		var maximumActive = 0
		var continuation: CheckedContinuation<TranscriptionResult, any Error>?

		func transcribe(_ update: @Sendable (TranscriptionProgress) -> Void) async throws -> TranscriptionResult {
			starts += 1
			active += 1
			maximumActive = max(maximumActive, active)
			defer { active -= 1 }
			update(TranscriptionProgress(transcript: "A useful but unfinished draft", modelName: "Fixture partial"))
			return try await withCheckedThrowingContinuation { continuation = $0 }
		}
		func finish(_ text: String) {
			continuation?.resume(returning: TranscriptionResult(transcript: text, modelName: "Fixture complete"))
			continuation = nil
		}
		func release() { continuation?.resume(throwing: CancellationError()); continuation = nil }
		func reflect(_ text: String) -> ReflectionResult {
			reflections += 1
			return ReflectionResult(headline: "New saved analysis", summary: text, modelName: "Fixture model")
		}
	}

	private static func seed(root: URL, append: Bool = false) throws -> JournalEntry {
		let entry = JournalEntry(duration: 30, transcript: "Previously completed text", summary: "Previous useful summary",
			headline: "Previous useful title", audioFilename: "\(UUID().uuidString).m4a")
		let file = try AVAudioFile(forWriting: root.appendingPathComponent("Recordings/\(entry.audioFilename!)"), settings: RecordingAudioFormat.captureSettings)
		let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: 4_410)!
		buffer.frameLength = 4_410
		for index in 0..<4_410 { buffer.floatChannelData![0][index] = 0 }
		try file.write(from: buffer)
		file.close()
		let url = root.appendingPathComponent("entries.json")
		var entries = append ? try JSONDecoder().decode([JournalEntry].self, from: Data(contentsOf: url)) : []
		entries.append(entry)
		try JSONEncoder().encode(entries).write(to: url)
		return entry
	}

	private static func temporaryRoot() throws -> URL {
		let root = FileManager.default.temporaryDirectory.appendingPathComponent("processing-worker-\(UUID().uuidString)")
		try FileManager.default.createDirectory(at: root.appendingPathComponent("Recordings"), withIntermediateDirectories: true)
		return root
	}
	private static func manifest(_ id: UUID, _ root: URL) -> URL { root.appendingPathComponent("Records/\(id.uuidString).json") }
	private static func block(_ id: UUID, _ root: URL) throws -> URL {
		let held = root.appendingPathComponent("held-\(id.uuidString).json")
		try FileManager.default.moveItem(at: manifest(id, root), to: held)
		try FileManager.default.createDirectory(at: manifest(id, root), withIntermediateDirectories: true)
		return held
	}
	private static func restore(_ id: UUID, _ root: URL, _ held: URL) throws {
		try FileManager.default.removeItem(at: manifest(id, root))
		try FileManager.default.moveItem(at: held, to: manifest(id, root))
	}
	private static func wait(_ condition: () async -> Bool) async throws {
		let deadline = ContinuousClock.now.advanced(by: .seconds(5))
		while !(await condition()) {
			guard ContinuousClock.now < deadline else { throw Failure(message: "Timed out waiting for a processing boundary") }
			try await Task.sleep(for: .milliseconds(1))
		}
	}
	private static func expect(_ condition: Bool, _ message: String) throws {
		guard condition else { throw Failure(message: message) }
	}
	private struct Failure: Error { let message: String }
}
#endif
