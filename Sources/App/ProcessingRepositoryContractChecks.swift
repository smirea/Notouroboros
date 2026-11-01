#if DEBUG
import AVFAudio
import Foundation

@MainActor
enum ProcessingRepositoryContractChecks {
	static func runFromLaunchArguments() async {
		guard ProcessInfo.processInfo.arguments.contains("-processing-repository-contract-tests") else { return }
		do {
			try await recordingChecks()
			try await restartChecks()
			try await leaseChecks()
			try await failureChecks()
			try await editChecks()
			try await completionChecks()
			try await migrationChecks()
			try await analysisChecks()
			print("PROCESSING REPOSITORY CONTRACT: durable stages, restart/cancellation, stale leases, write failure retry, narrow edits, retired reminder decoding, and deletion passed")
			fflush(stdout)
		} catch { fatalError("PROCESSING REPOSITORY CONTRACT: \(error)") }
	}

	private static func recordingChecks() async throws {
		let root = try temporaryRoot()
		defer { try? FileManager.default.removeItem(at: root) }
		let repository = JournalRepository(rootURL: root)
		_ = try await repository.load()
		let finished = try await repository.beginRecording(calendarEvent: nil)
		try writeAudio(root.appendingPathComponent("Recordings/\(finished.audioFilename!)"))
		_ = try await repository.finishRecording(id: finished.id)
		let committed = try diskRecord(finished.id, root: root)
		try expect(committed.state == .saved && committed.processing?.stage == .finalizeAudio && committed.processing?.status == .queued,
			"Finishing capture must durably queue finalization in the recording's own manifest")
		let finalization = try await claim(repository, stage: .finalizeAudio)
		let request = try await repository.prepareAudioFinalization(id: finished.id)
		try writeAudio(request.stagingURL)
		let media = try AVAudioFile(forReading: request.stagingURL)
		_ = try await repository.commitFinalizedAudio(FinalizedAudio(request: request, preparedURL: request.stagingURL,
			duration: Double(media.length) / media.processingFormat.sampleRate), lease: finalization)
		let interrupted = try await repository.beginRecording(calendarEvent: nil)
		try writeAudio(root.appendingPathComponent("Recordings/\(interrupted.id.uuidString).caf"))
		let restarted = try await JournalRepository(rootURL: root).load()
		let recovered = restarted.records.first { $0.id == interrupted.id }
		try expect(restarted.entries.count == 2 && recovered?.state == .saved && recovered?.entry?.createdAt == interrupted.createdAt,
			"Recovery must preserve the capture ID and date instead of inventing a second note")
		try expect(recovered?.processing?.stage == .finalizeAudio && recovered?.processing?.status == .queued,
			"Recovered native audio must have a durable processing job")
		try expect(restarted.records.first { $0.id == finished.id }?.processing?.requestID == committed.processing?.requestID,
			"Restart must preserve an existing processing request")
		let finalized = restarted.records.first { $0.id == finished.id }
		try expect(finalized?.processing?.stage == .transcribe && finalized?.processing?.completedStages.contains(.finalizeAudio) == true
			&& finalized?.entry?.audioFilename?.hasSuffix(".m4a") == true,
			"Restart after media publication must resume transcription without redoing finalization")
	}

	private static func restartChecks() async throws {
		let root = try temporaryRoot()
		defer { try? FileManager.default.removeItem(at: root) }
		let (repository, entry) = try await seed(root)
		_ = try await repository.requestProcessing(id: entry.id)
		let transcription = try await claim(repository, stage: .transcribe)
		_ = try await repository.commitTranscription(.init(transcript: "Durable transcript", modelName: "fixture"), lease: transcription)
		let restarted = JournalRepository(rootURL: root)
		_ = try await restarted.load()
		let reflection = try await claim(restarted, stage: .reflect)
		try expect(reflection.requestID == transcription.requestID, "Relaunch must resume the next stage of the same request")
		let interruptedAgain = JournalRepository(rootURL: root)
		_ = try await interruptedAgain.load()
		let resumed = try await claim(interruptedAgain, stage: .reflect)
		try expect(resumed.attemptID != reflection.attemptID && resumed.requestID == reflection.requestID,
			"A running stage must relaunch queued and acquire a fresh attempt")
		try await stale { _ = try await interruptedAgain.commitReflection(reflectionResult, lease: reflection) }
		_ = try await interruptedAgain.pauseProcessing(resumed, canceled: true)
		let canceledRestart = JournalRepository(rootURL: root)
		_ = try await canceledRestart.load()
		let canceledWork = try await canceledRestart.claimProcessing(now: .distantFuture)
		let canceled = await canceledRestart.record(id: entry.id)
		try expect(canceledWork == nil && canceled?.processing?.status == .canceled,
			"Explicit cancellation must survive launch and must not be automatically retried")
		try expect(canceled?.entry?.transcript == "Durable transcript"
			&& canceled?.processing?.completedStages.contains(.transcribe) == true,
			"Canceling a later stage must preserve the previous stage's committed output")
	}

	private static func leaseChecks() async throws {
		let root = try temporaryRoot()
		defer { try? FileManager.default.removeItem(at: root) }
		let (repository, entry) = try await seed(root)
		_ = try await repository.requestProcessing(id: entry.id)
		let obsoleteRequest = try await claim(repository, stage: .transcribe)
		_ = try await repository.requestProcessing(id: entry.id)
		let firstAttempt = try await claim(repository, stage: .transcribe)
		let output = TranscriptionResult(transcript: "Current transcript", modelName: "fixture")
		try await stale { _ = try await repository.commitTranscription(output, lease: obsoleteRequest) }
		for invalid in [
			ProcessingLease(entryID: entry.id, requestID: firstAttempt.requestID, attemptID: UUID(), inputRevision: firstAttempt.inputRevision, stage: .transcribe),
			ProcessingLease(entryID: entry.id, requestID: firstAttempt.requestID, attemptID: firstAttempt.attemptID, inputRevision: firstAttempt.inputRevision + 1, stage: .transcribe),
			ProcessingLease(entryID: entry.id, requestID: firstAttempt.requestID, attemptID: firstAttempt.attemptID, inputRevision: firstAttempt.inputRevision, stage: .reflect)
		] { try await stale { _ = try await repository.commitTranscription(output, lease: invalid) } }
		_ = try await repository.pauseProcessing(firstAttempt)
		let current = try await claim(repository, stage: .transcribe)
		try await stale { _ = try await repository.commitTranscription(output, lease: firstAttempt) }
		_ = try await repository.commitTranscription(output, lease: current)
		try await stale { _ = try await repository.commitTranscription(output, lease: current) }
		let reflecting = try await claim(repository, stage: .reflect)
		_ = try await repository.delete(id: entry.id)
		try await stale { _ = try await repository.commitReflection(reflectionResult, lease: reflecting) }
		let retry = await repository.nextProcessingRetry()
		let deletedWork = try await repository.claimProcessing(now: .distantFuture)
		try expect(retry == nil && deletedWork == nil && (try diskRecord(entry.id, root: root)).processing == nil,
			"Deletion must invalidate the lease and remove all pending processing/retry state")
		let (retryRepository, retryEntry) = try await seed(root)
		_ = try await retryRepository.requestProcessing(id: retryEntry.id)
		let failedLease = try await claim(retryRepository, stage: .transcribe)
		_ = try await retryRepository.failProcessing(failedLease, message: "Temporarily unavailable", retryAfter: .distantFuture)
		let scheduled = await retryRepository.nextProcessingRetry()
		try expect(scheduled == .distantFuture, "A failed processing job must expose its durable future retry")
		_ = try await retryRepository.delete(id: retryEntry.id)
		let deletedRetry = await retryRepository.nextProcessingRetry()
		let restarted = JournalRepository(rootURL: root)
		_ = try await restarted.load()
		let restartedWork = try await restarted.claimProcessing(now: .distantFuture)
		try expect(deletedRetry == nil && restartedWork == nil,
			"Deleting a failed job must erase its future retry and remain unschedulable after restart")
	}

	private static func failureChecks() async throws {
		let root = try temporaryRoot()
		defer { try? FileManager.default.removeItem(at: root) }
		let (repository, entry) = try await seed(root)
		_ = try await repository.requestProcessing(id: entry.id)
		let lease = try await claim(repository, stage: .transcribe)
		let partial = TranscriptionProgress(transcript: "Incomplete replacement", modelName: "fixture")
		_ = try await repository.savePartial(partial, lease: lease)
		_ = try await repository.failProcessing(lease, message: "Provider interrupted", partial: partial, retryAfter: .distantFuture,
			fallback: ReflectionResult(headline: "Must not replace complete analysis", summary: nil, modelName: "fallback"))
		let failed = try diskRecord(entry.id, root: root)
		try expect(failed.entry == entry && failed.processing?.status == .partial && failed.processing?.partialTranscript == partial,
			"Partial failure must preserve the last complete transcript/analysis while recording incomplete progress separately")
		_ = try await repository.retryProcessing(id: entry.id)
		let retry = try await claim(repository, stage: .transcribe)
		let before = try diskRecord(entry.id, root: root)
		let manifest = recordURL(entry.id, root: root)
		let preserved = root.appendingPathComponent("preserved.json")
		try FileManager.default.moveItem(at: manifest, to: preserved)
		try FileManager.default.createDirectory(at: manifest, withIntermediateDirectories: true)
		let output = TranscriptionResult(transcript: "Complete replacement", modelName: "replacement")
		var didFail = false
		do { _ = try await repository.commitTranscription(output, lease: retry) } catch { didFail = true }
		let retained = await repository.record(id: entry.id)
		try expect(didFail && retained?.entry == before.entry && retained?.processing == before.processing && retained?.revision == before.revision,
			"An actual manifest write failure must not advance the stage or publish replacement data")
		try FileManager.default.removeItem(at: manifest)
		try FileManager.default.moveItem(at: preserved, to: manifest)
		_ = try await repository.commitTranscription(output, lease: retry)
		let saved = try diskRecord(entry.id, root: root)
		try expect(saved.entry?.transcript == output.transcript && saved.processing?.stage == .reflect && saved.processing?.partialTranscript == nil,
			"The same valid lease must commit exactly once after storage is repaired")
	}

	private static func editChecks() async throws {
		let root = try temporaryRoot()
		defer { try? FileManager.default.removeItem(at: root) }
		let (repository, entry) = try await seed(root)
		_ = try await repository.requestProcessing(id: entry.id)
		let transcription = try await claim(repository, stage: .transcribe)
		_ = try await repository.commitTranscription(.init(transcript: "Fresh transcript", modelName: "new speech"), lease: transcription)
		let location = JournalLocation(latitude: 41.88, longitude: -87.63, city: "Chicago")
		_ = try await repository.apply(.location(location), to: entry.id)
		let reflection = try await claim(repository, stage: .reflect)
		_ = try await repository.commitReflection(reflectionResult, lease: reflection)
		let committed = try diskRecord(entry.id, root: root)
		try expect(committed.entry?.transcript == "Fresh transcript" && committed.entry?.headline == reflectionResult.headline
			&& committed.entry?.location == location,
			"Delayed location edits must preserve newly committed stage outputs")
	}

	private static func completionChecks() async throws {
		let root = try temporaryRoot()
		defer { try? FileManager.default.removeItem(at: root) }
		let (repository, entry) = try await seed(root, headline: "Processing ideas for next week")
		let migrated = await repository.record(id: entry.id)
		try expect(migrated?.processing?.status == .complete, "An arbitrary completed headline must not trigger a legacy requeue")
		let manifest = recordURL(entry.id, root: root)
		var old = try JSONSerialization.jsonObject(with: Data(contentsOf: manifest)) as! [String: Any]
		var oldEntry = old["entry"] as! [String: Any]
		oldEntry["reminders"] = [["text": "Bring notes", "selector": ["retired": true]]]
		oldEntry["reminderFeedback"] = [["kind": "voice", "text": "Retired correction"]]
		oldEntry["reminderModel"] = "retired model"
		old["entry"] = oldEntry
		var oldJob = old["processing"] as! [String: Any]
		oldJob["stage"] = "reminders"
		oldJob["status"] = "complete"
		oldJob["completedStages"] = ["finalizeAudio", "transcribe", "reflect", "reminders"]
		oldJob["skippedStages"] = ["reminders"]
		old["processing"] = oldJob
		try JSONSerialization.data(withJSONObject: old).write(to: manifest)
		let legacy = JournalRepository(rootURL: root)
		let loaded = try await legacy.load()
		let record = loaded.records.first { $0.id == entry.id }
		let legacyWork = try await legacy.claimProcessing(now: .distantFuture)
		try expect(loaded.issues.isEmpty && record?.entry?.transcript == entry.transcript && record?.entry?.tasks.isEmpty == true
			&& record?.processing?.status == .complete && record?.processing?.completedStages.contains(.reflect) == true
			&& record?.taskDelivery == .notExtracted && legacyWork == nil,
			"A note that finished reminders loads as complete and is not sent to ProcrastiMate")
		oldJob["status"] = "queued"
		oldJob["completedStages"] = ["finalizeAudio", "transcribe", "reflect"]
		old["processing"] = oldJob
		try JSONSerialization.data(withJSONObject: old).write(to: manifest)
		let resumed = JournalRepository(rootURL: root)
		let reloaded = try await resumed.load()
		let queued = try await resumed.claimProcessing(now: .distantFuture)
		try expect(reloaded.records.first { $0.id == entry.id }?.processing?.status == .complete && queued == nil,
			"A note queued for the retired reminders stage completes without running it")
	}

	private static func migrationChecks() async throws {
		let root = try temporaryRoot()
		defer { try? FileManager.default.removeItem(at: root) }
		let repository = JournalRepository(rootURL: root)
		_ = try await repository.load()
		let entry = JournalEntry(duration: 1, transcript: "Durable original", headline: "Complete legacy note")
		try await repository.save([entry])
		let damagedURL = recordURL(UUID(), root: root)
		let damaged = Data("{ broken processing metadata".utf8)
		try damaged.write(to: damagedURL)
		let loaded = try await JournalRepository(rootURL: root).load()
		try expect(!loaded.issues.isEmpty && loaded.entries == [entry]
			&& loaded.records.first(where: { $0.id == entry.id })?.processing?.status == .complete,
			"One corrupt manifest must not prevent healthy notes from migrating their processing state")
		try expect(try Data(contentsOf: damagedURL) == damaged, "Processing migration must preserve corrupt originals")
		try FileManager.default.removeItem(at: damagedURL)
		let legacy = JournalEntry(duration: 1, transcript: "Readable before a migration write", headline: "Legacy note")
		try await repository.save([legacy])
		let legacyURL = recordURL(legacy.id, root: root)
		let original = try Data(contentsOf: legacyURL)
		let recordsURL = root.appendingPathComponent("Records")
		try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: recordsURL.path)
		defer { try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: recordsURL.path) }
		let blocked = try await JournalRepository(rootURL: root).load()
		try expect(blocked.entries.count == 2 && !blocked.issues.isEmpty
			&& blocked.records.first(where: { $0.id == legacy.id })?.processing == nil,
			"A real migration write failure must keep readable notes available and leave uncommitted work unclaimed")
		try expect(try Data(contentsOf: legacyURL) == original, "Failed processing migration must preserve original manifest bytes")
	}

	private static func analysisChecks() async throws {
		let root = try temporaryRoot()
		defer { try? FileManager.default.removeItem(at: root) }
		let (repository, entry) = try await seed(root)
		_ = try await repository.requestProcessing(id: entry.id, startAt: .reflect)
		let originalLease = try await claim(repository, stage: .reflect)
		var result = reflectionResult
		result.analysisContext = "Complete internal analysis from every passage"
		_ = try await repository.commitReflection(result, lease: originalLease)
		let restarted = JournalRepository(rootURL: root)
		_ = try await restarted.load()
		let saved = await restarted.record(id: entry.id)
		try expect(saved?.entry?.analysis?.matches(entry.transcript) == true
			&& saved?.entry?.analysis?.notes == result.analysisContext,
			"Completed derived notes must be committed with reflection and survive restart")
		_ = try await restarted.requestProcessing(id: entry.id)
		let transcription = try await claim(restarted, stage: .transcribe)
		_ = try await restarted.commitTranscription(.init(transcript: "A new complete source", modelName: "Fixture"), lease: transcription)
		try await stale { _ = try await restarted.commitReflection(result, lease: originalLease) }
		let changed = await restarted.record(id: entry.id)
		try expect(changed?.entry?.analysis == nil && changed?.entry?.summary == result.summary,
			"New transcription must invalidate derived notes without deleting prior visible analysis; a stale reflection cannot restore them")
	}

	private static var reflectionResult: ReflectionResult {
		ReflectionResult(headline: "Updated reflection", summary: "Fresh complete analysis", modelName: "fixture")
	}

	private static func seed(_ root: URL, headline: String = "Previously completed note") async throws -> (JournalRepository, JournalEntry) {
		let repository = JournalRepository(rootURL: root)
		_ = try await repository.load()
		let id = UUID()
		let entry = JournalEntry(id: id, duration: 0.1, transcript: "Prior complete transcript", summary: "Prior complete analysis",
			headline: headline, audioFilename: "\(id.uuidString).m4a", summaryModel: "old model", transcriptModel: "old speech")
		try writeAudio(root.appendingPathComponent("Recordings/\(entry.audioFilename!)"))
		try await repository.save([entry])
		let restarted = JournalRepository(rootURL: root)
		_ = try await restarted.load()
		return (restarted, entry)
	}

	private static func claim(_ repository: JournalRepository, stage: ProcessingStage) async throws -> ProcessingLease {
		guard let work = try await repository.claimProcessing(), work.lease.stage == stage else {
			throw Failure("Expected claimable \(stage) work")
		}
		return work.lease
	}

	private static func stale(_ operation: () async throws -> Void) async throws {
		do { try await operation(); throw Failure("An obsolete processing result was accepted") }
		catch RepositoryError.staleProcessing {}
	}

	private static func temporaryRoot() throws -> URL {
		let root = FileManager.default.temporaryDirectory.appendingPathComponent("processing-repository-\(UUID().uuidString)", isDirectory: true)
		try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
		return root
	}

	private static func recordURL(_ id: UUID, root: URL) -> URL { root.appendingPathComponent("Records/\(id.uuidString).json") }
	private static func diskRecord(_ id: UUID, root: URL) throws -> JournalRecord {
		try JSONDecoder().decode(JournalRecord.self, from: Data(contentsOf: recordURL(id, root: root)))
	}

	private static func writeAudio(_ url: URL) throws {
		let settings = url.pathExtension == "caf" ? RecordingAudioFormat.pcmSettings : RecordingAudioFormat.captureSettings
		let file = try AVAudioFile(forWriting: url, settings: settings)
		let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: 4_410)!
		buffer.frameLength = 4_410
		for frame in 0..<4_410 { buffer.floatChannelData![0][frame] = sin(Float(frame) * 0.1) * 0.05 }
		try file.write(from: buffer)
		file.close()
	}

	private static func expect(_ condition: @autoclosure () throws -> Bool, _ message: String) throws {
		guard try condition() else { throw Failure(message) }
	}
	private struct Failure: Error, CustomStringConvertible {
		let description: String
		init(_ description: String) { self.description = description }
	}
}
#endif
