#if DEBUG
import AVFoundation
import Foundation

@MainActor
enum MemoTaskContractChecks {
	static func runFromLaunchArguments() async {
		guard ProcessInfo.processInfo.arguments.contains("-memo-task-contract-tests") else { return }
		do {
			try wireChecks()
			try await repositoryChecks()
			try await outboxChecks()
			try deletionAndLinkChecks()
			try presentationChecks()
			print("MEMO TASK CONTRACT: wire JSON, retired drafts, delivery states, outbox, delete prompt, and memo links passed")
			fflush(stdout)
		} catch { fatalError("MEMO TASK CONTRACT: \(error)") }
	}

	nonisolated private static let transcript = "The run felt good. Next time I should bring electrolytes. Remember to call Maya tomorrow at 3pm about the dentist."
	nonisolated private static let now = Date(timeIntervalSince1970: 1_800_000_000)

	private static func wireChecks() throws {
		let memo = UUID(uuidString: "6F1C2B3A-0000-4000-8000-00000000ABCD")!
		let key = UUID(uuidString: "A1B2C3D4-0000-4000-8000-000000000001")!
		let event = TaskEvent(id: "gym-series", title: "Gym", allDay: false, series: true, edge: .before, minutes: 60,
			occurrences: [.init(start: 1_800_000_000_000, end: 1_800_003_600_000, original: 1_800_000_000_000)])
		let request = MemoTasksRequest(memoID: memo, recordedAt: Date(timeIntervalSince1970: 1_799_999_999.5), tasks: [
			MemoTask(key: key, title: "Bring water", notes: "“bring water”", when: nil, event: event),
			MemoTask(key: key, title: "Call Maya", notes: "", when: "tomorrow at 3pm", event: nil),
		])
		let encoder = JSONEncoder()
		encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
		let json = String(decoding: try encoder.encode(request), as: UTF8.self)
		let expected = #"{"memoId":"6f1c2b3a-0000-4000-8000-00000000abcd","recordedAt":1799999999500,"tasks":[{"event":{"allDay":false,"edge":"before","id":"gym-series","minutes":60,"occurrences":[{"end":1800003600000,"original":1800000000000,"start":1800000000000}],"series":true,"title":"Gym"},"key":"a1b2c3d4-0000-4000-8000-000000000001","notes":"“bring water”","title":"Bring water","when":null},{"event":null,"key":"a1b2c3d4-0000-4000-8000-000000000001","notes":"","title":"Call Maya","when":"tomorrow at 3pm"}]}"#
		try expect(json == expected, "The PUT body matches ProcrastiMate's contract exactly: \(json)")
		let response = Data(#"{"tasks":[{"key":"a1b2c3d4-0000-4000-8000-000000000001","id":"t-1","title":"Bring water","completedAt":1800000000000,"due":{"date":"2027-01-15","time":null},"event":null}]}"#.utf8)
		let remote = try ProcrastiMateWire.tasks(from: response)
		try expect(remote == [RemoteMemoTask(key: key, id: "t-1", title: "Bring water", completedAt: Date(timeIntervalSince1970: 1_800_000_000),
			due: .init(date: "2027-01-15", time: nil), event: nil)], "The memo task list decodes keys, completion, and due dates")
		try expect(ProcrastiMateLink.credentials(from: Data(#"{"apiURL":"https://example.com","token":"abc"}"#.utf8))
			== ProcrastiMateCredentials(apiURL: URL(string: "https://example.com")!, token: "abc")
			&& ProcrastiMateLink.credentials(from: Data(#"{"apiURL":"https://example.com","token":""}"#.utf8)) == nil
			&& ProcrastiMateLink.credentials(from: Data("not json".utf8)) == nil,
			"The shared keychain item parses at the boundary; anything unusable reads as signed out")
	}

	private static func repositoryChecks() async throws {
		let root = try temporaryRoot()
		defer { try? FileManager.default.removeItem(at: root) }
		let entry = try seed(root)
		let first = [task("Bring water"), task("Call Maya")]
		try await stored(first, delivery: #"{"draft":{}}"#, for: entry.id, root: root)
		let retired = JournalRepository(rootURL: root)
		let load = try await retired.load()
		let drafted = await retired.record(id: entry.id)
		let unsent = await retired.taskDeliveryJobs(repair: true)
		try expect(load.issues.isEmpty && drafted?.taskDelivery == .notExtracted && drafted?.entry?.tasks.isEmpty == true
			&& drafted?.entry?.taskModel == nil && unsent.isEmpty,
			"A note with retired reminder drafts loads without tasks and sends nothing")

		try await stored(first, delivery: #"{"pending":{}}"#, for: entry.id, root: root)
		let repository = JournalRepository(rootURL: root)
		_ = try await repository.load()
		let job = try only(await repository.taskDeliveryJobs(now: now))
		try expect(job.tasks == first && job.id == entry.id && job.recordedAt == entry.createdAt, "The outbox sends the memo's saved tasks")

		let failed = try await repository.failTasks(job, message: "Offline", now: now)
		guard case let .pending(retry)? = failed?.taskDelivery, retry?.attempts == 1, retry?.retryAfter == now.addingTimeInterval(5) else {
			throw Failure(message: "A transient failure backs off like the iCloud mirror")
		}
		let early = await repository.taskDeliveryJobs(now: now)
		let due = await repository.taskDeliveryJobs(now: now.addingTimeInterval(5))
		let wake = await repository.nextTaskDeliveryRetry()
		try expect(early.isEmpty && due.count == 1 && wake == now.addingTimeInterval(5), "A failed delivery waits for its retry date")
		_ = try await repository.blockTasks(job, .notInstalled)
		let timer = await repository.taskDeliveryJobs(now: .distantFuture)
		let foreground = await repository.taskDeliveryJobs(repair: true)
		try expect(timer.isEmpty && foreground.count == 1, "Blocked tasks wait for a foreground check instead of the timer")

		let remote = [RemoteMemoTask(key: first[0].key, id: "t-1", title: "Bring water", completedAt: nil, due: nil, event: nil)]
		_ = try await repository.acknowledgeTasks(job, remote: remote)
		let delivered = await repository.record(id: entry.id)
		try expect(delivered?.entry?.tasks == first && delivered?.taskDelivery == .delivered([.init(key: first[0].key, id: "t-1"),
			.init(key: first[1].key, id: nil)]) && delivered?.remoteTasks == remote,
			"What ProcrastiMate accepted becomes the memo's tasks, and a key it skipped keeps no id")
		let resend = await repository.taskDeliveryJobs(repair: true)
		try expect(resend.isEmpty, "Delivered memos never resend")

		let reloaded = JournalRepository(rootURL: root)
		_ = try await reloaded.load()
		let relaunched = await reloaded.record(id: entry.id)
		try expect(relaunched?.taskDelivery == delivered?.taskDelivery, "Delivery state survives relaunch")
		_ = try await reloaded.delete(id: entry.id)
		let gone = await reloaded.record(id: entry.id)
		try expect(gone?.taskDelivery == .notExtracted, "Deleting a memo clears its outbox")
	}

	private static func outboxChecks() async throws {
		let root = try temporaryRoot()
		defer { try? FileManager.default.removeItem(at: root) }
		let entry = try seed(root)
		let tasks = [task("Bring water"), task("Call Maya")]
		try await stored(tasks, delivery: #"{"pending":{}}"#, for: entry.id, root: root)
		let link = LinkProbe()
		let services = ProcessingServices(transcribe: { _, _, _, _ in TranscriptionResult(transcript: transcript, modelName: "Fixture") },
			reflect: { _, _ in ReflectionResult(headline: "Fixture", modelName: "Fixture") })
		let store = JournalStore(storageRootURL: root, processingServices: services, procrastiMate: link.client())
		try await store.waitUntilLoaded()
		await store.waitForConfigurationWritesForContract()

		link.status = .unavailable(.notInstalled)
		store.resumeStaleProcessing()
		try await wait { store.taskDeliveries[entry.id] == .blocked(.notInstalled) }
		try expect(link.puts.isEmpty, "Nothing is sent while ProcrastiMate is missing")

		link.status = .unavailable(.signedOut)
		store.resumeStaleProcessing()
		try await wait { store.taskDeliveries[entry.id] == .blocked(.signedOut) }

		let credentials = ProcrastiMateCredentials(apiURL: URL(string: "https://example.com")!, token: "token")
		link.status = .linked(credentials)
		link.failure = ProcrastiMateError.http(503)
		store.resumeStaleProcessing()
		try await wait { if case .pending(retry: .some) = store.taskDeliveries[entry.id] { true } else { false } }
		link.failure = ProcrastiMateError.unauthorized
		store.resumeStaleProcessing()
		try await wait { store.taskDeliveries[entry.id] == .blocked(.signedOut) }

		link.failure = nil
		store.resumeStaleProcessing()
		try await wait { store.taskDeliveries[entry.id]?.receipts.count == 2 }
		try expect(link.puts.last?.memoID == entry.id && link.puts.last?.tasks == tasks && link.puts.count == 3,
			"Once the link appears the pending tasks go out on their own")
		try expect(store.asksAboutTasksOnDeletion(entry.id), "A memo with tasks in ProcrastiMate asks before deletion")

		let previousRequest = store.processingStates[entry.id]?.requestID
		store.reprocessEntry(id: entry.id)
		try await wait { store.processingStates[entry.id]?.requestID != previousRequest && store.processingStates[entry.id]?.status == .complete }
		await store.waitForTaskDeliveryForContract()
		try expect(link.puts.count == 3 && store.entry(id: entry.id)?.tasks == tasks,
			"Reprocessing a delivered memo keeps its tasks and sends nothing again")

		link.list = [RemoteMemoTask(key: tasks[0].key, id: "t-0", title: "Bring water", completedAt: now, due: nil, event: nil)]
		await store.refreshRemoteTasks(for: entry.id)
		try expect(store.remoteTasks[entry.id] == link.list, "Opening a note caches ProcrastiMate's view")

		let deleted = await store.deleteEntry(id: entry.id, deletingTasks: true)
		try await wait { link.deletions == [entry.id] }
		try expect(deleted && store.entries.isEmpty && store.taskDeliveries[entry.id] == nil, "Deleting tasks too calls DELETE and still deletes the memo")
	}

	private static func deletionAndLinkChecks() throws {
		let key = UUID()
		let delivered = MemoTaskDelivery.delivered([.init(key: key, id: "t-1")])
		let live = [RemoteMemoTask(key: key, id: "t-1", title: "A", completedAt: nil, due: nil, event: nil)]
		try expect(MemoDeletionPrompt.asksAboutTasks(delivery: delivered, remote: nil)
			&& MemoDeletionPrompt.asksAboutTasks(delivery: delivered, remote: live)
			&& !MemoDeletionPrompt.asksAboutTasks(delivery: delivered, remote: [])
			&& !MemoDeletionPrompt.asksAboutTasks(delivery: .delivered([.init(key: key, id: nil)]), remote: nil)
			&& !MemoDeletionPrompt.asksAboutTasks(delivery: .pending(retry: nil), remote: nil)
			&& !MemoDeletionPrompt.asksAboutTasks(delivery: .blocked(.notInstalled), remote: nil)
			&& !MemoDeletionPrompt.asksAboutTasks(delivery: nil, remote: nil),
			"Only a memo with tasks still in ProcrastiMate asks whether to delete them")
		let id = UUID()
		try expect(AppDeepLink(url: URL(string: "notouroboros://entry?id=\(id.uuidString.lowercased())")!) == .entry(id),
			"ProcrastiMate's lowercase memo links open the memo")
		try expect(ProcrastiMateLink.taskURL("t-1")?.absoluteString == "procrastimate://task/t-1", "Task rows open ProcrastiMate's task link")
	}

	private static func presentationChecks() throws {
		let calendar = Calendar(identifier: .gregorian)
		let event = TaskEvent(id: "gym", title: "Gym", allDay: false, series: true, edge: .before, minutes: 60,
			occurrences: [.init(start: 0, end: 1, original: 0)])
		let local = [MemoTask(key: UUID(), title: "Bring water", notes: "", when: "tomorrow at 3pm", event: nil),
			MemoTask(key: UUID(), title: "Stretch", notes: "", when: nil, event: event)]
		let pending = MemoTasksPresentation.rows(tasks: local, delivery: .blocked(.notInstalled), remote: nil, now: now, calendar: calendar)
		try expect(pending.map(\.title) == ["Bring water", "Stretch"] && pending.map(\.detail) == ["Tomorrow at 3pm", "Before every Gym"]
			&& pending.allSatisfy { $0.taskID == nil && !$0.isDone }, "Before delivery the note shows the extracted tasks, not links")
		try expect(MemoTasksPresentation.note(delivery: .blocked(.notInstalled)) == "Could save these todos if you also had ProcrastiMate."
			&& MemoTasksPresentation.note(delivery: .blocked(.signedOut)) == "Sign in to ProcrastiMate to save these todos."
			&& MemoTasksPresentation.note(delivery: .delivered([])) == nil, "Blocked tasks explain what ProcrastiMate needs")
		let receipts = MemoTaskDelivery.delivered([.init(key: local[0].key, id: "t-0"), .init(key: local[1].key, id: nil)])
		let cached = MemoTasksPresentation.rows(tasks: local, delivery: receipts, remote: nil, now: now, calendar: calendar)
		try expect(cached.map(\.taskID) == ["t-0"], "Before a fetch, delivered rows link only tasks ProcrastiMate holds")
		let tomorrow = calendar.date(byAdding: .day, value: 1, to: now)!
		let remote = [RemoteMemoTask(key: local[0].key, id: "t-0", title: "Bring a water bottle", completedAt: now,
			due: .init(date: tomorrow.formatted(.iso8601.year().month().day()), time: nil), event: nil)]
		let live = MemoTasksPresentation.rows(tasks: local, delivery: receipts, remote: remote, now: now, calendar: calendar)
		try expect(live == [MemoTaskRow(id: local[0].key, title: "Bring a water bottle", isDone: true, detail: "Tomorrow", taskID: "t-0")],
			"After a fetch the note shows ProcrastiMate's title, done state, and due date")
	}

	private static func task(_ title: String) -> MemoTask {
		MemoTask(key: UUID(), title: title, notes: "Why", when: nil, event: nil)
	}

	@MainActor
	private final class LinkProbe {
		var status = ProcrastiMateLinkStatus.unavailable(.notInstalled)
		var failure: Error?
		var puts: [MemoTasksRequest] = []
		var list: [RemoteMemoTask] = []
		var deletions: [UUID] = []

		func client() -> ProcrastiMateClient {
			ProcrastiMateClient(status: { [unowned self] in status }, put: { [unowned self] _, request in
				try await MainActor.run {
					puts.append(request)
					if let failure { throw failure }
					return request.tasks.map { RemoteMemoTask(key: $0.key, id: "id-\($0.title)", title: $0.title, completedAt: nil, due: nil, event: nil) }
				}
			}, list: { [unowned self] _, _ in await MainActor.run { list } },
			delete: { [unowned self] _, id in await MainActor.run { deletions.append(id) } })
		}
	}

	/// Writes tasks and a raw delivery state into the memo's manifest, as an older build left them.
	private static func stored(_ tasks: [MemoTask], delivery: String, for id: UUID, root: URL) async throws {
		_ = try await JournalRepository(rootURL: root).load()
		let url = root.appendingPathComponent("Records/\(id.uuidString).json")
		var record = try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as! [String: Any]
		var entry = record["entry"] as! [String: Any]
		entry["tasks"] = try JSONSerialization.jsonObject(with: JSONEncoder().encode(tasks))
		entry["taskModel"] = "Fixture"
		record["entry"] = entry
		record["taskDelivery"] = try JSONSerialization.jsonObject(with: Data(delivery.utf8))
		try JSONSerialization.data(withJSONObject: record).write(to: url)
	}

	private static func seed(_ root: URL) throws -> JournalEntry {
		let entry = JournalEntry(createdAt: now, duration: 1, transcript: transcript, headline: "Fixture memo", audioFilename: "\(UUID().uuidString).m4a")
		let file = try AVAudioFile(forWriting: root.appendingPathComponent("Recordings/\(entry.audioFilename!)"), settings: RecordingAudioFormat.captureSettings)
		let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: 4_410)!
		buffer.frameLength = 4_410
		for index in 0..<4_410 { buffer.floatChannelData![0][index] = 0 }
		try file.write(from: buffer)
		file.close()
		try JSONEncoder().encode([entry]).write(to: root.appendingPathComponent("entries.json"))
		return entry
	}

	private static func temporaryRoot() throws -> URL {
		let root = FileManager.default.temporaryDirectory.appendingPathComponent("memo-tasks-\(UUID().uuidString)")
		try FileManager.default.createDirectory(at: root.appendingPathComponent("Recordings"), withIntermediateDirectories: true)
		return root
	}

	private static func only<T>(_ values: [T]) throws -> T {
		guard values.count == 1 else { throw Failure(message: "Expected exactly one value, found \(values.count)") }
		return values[0]
	}

	private static func wait(_ condition: () async -> Bool) async throws {
		let deadline = ContinuousClock.now.advanced(by: .seconds(5))
		while !(await condition()) {
			guard ContinuousClock.now < deadline else { throw Failure(message: "Timed out waiting for a task delivery boundary") }
			try await Task.sleep(for: .milliseconds(5))
		}
	}

	private static func expect(_ condition: Bool, _ message: String) throws {
		guard condition else { throw Failure(message: message) }
	}

	private struct Failure: Error { let message: String }
}
#endif
