#if DEBUG
import AVFoundation
import Foundation

@MainActor
enum MemoTaskContractChecks {
	static func runFromLaunchArguments() async {
		guard ProcessInfo.processInfo.arguments.contains("-memo-task-contract-tests") else { return }
		do {
			try groundingChecks()
			try promptChecks()
			try await extractionChecks()
			try eventChecks()
			try wireChecks()
			try await repositoryChecks()
			try await outboxChecks()
			try deletionAndLinkChecks()
			try presentationChecks()
			print("MEMO TASK CONTRACT: exact evidence and spoken times, event context, passage coverage, TaskEvent resolution, wire JSON, reminder drafts, delivery states, outbox, delete prompt, and memo links passed")
			fflush(stdout)
		} catch { fatalError("MEMO TASK CONTRACT: \(error)") }
	}

	nonisolated private static let transcript = "The run felt good. Next time I should bring electrolytes. Remember to call Maya tomorrow at 3pm about the dentist."
	nonisolated private static let now = Date(timeIntervalSince1970: 1_800_000_000)

	private static func groundingChecks() throws {
		let drafts = [
			TaskDraft(title: "bring electrolytes.", why: "You faded early.", evidence: " “Next time I should bring electrolytes.” ",
				when: "none", link: .every, timing: .before),
			TaskDraft(title: "Call Maya about the dentist", why: "", evidence: "call Maya tomorrow at 3pm about the dentist",
				when: "Tomorrow at 3PM", link: .none, timing: .during),
			TaskDraft(title: "Buy a telescope", why: "You want one.", evidence: "I should buy a telescope.", when: ""),
			TaskDraft(title: "Bring electrolytes", why: "Duplicate.", evidence: "Next time I should bring electrolytes.", when: ""),
			TaskDraft(title: "Stretch", why: "Paraphrased.", evidence: "next time i should bring electrolytes", when: ""),
			TaskDraft(title: "  ", why: "Empty.", evidence: "The run felt good.", when: ""),
			TaskDraft(title: "Call Maya at noon", why: "Invented time.", evidence: "Remember to call Maya", when: "at noon"),
			TaskDraft(title: "I need to", why: "Nothing to do.", evidence: "The run felt good.", when: ""),
			TaskDraft(title: "Water the plants", why: "Invented around a real quote.", evidence: "The run felt good.", when: ""),
			TaskDraft(title: "I should remember to call Maya", why: "Self-talk.", evidence: "Remember to call Maya tomorrow", when: ""),
		]
		let valid = TaskEngine.validate(drafts, transcript: transcript, hasEvent: true)
		try expect(valid == [
			.init(title: "Bring electrolytes", notes: "You faded early.\n\n“Next time I should bring electrolytes.”", when: nil,
				link: .every, timing: .before),
			.init(title: "Call Maya about the dentist", notes: "“call Maya tomorrow at 3pm about the dentist”",
				when: "tomorrow at 3pm", link: .none, timing: .during),
			.init(title: "Call Maya at noon", notes: "Invented time.\n\n“Remember to call Maya”", when: nil, link: .none, timing: .before),
			.init(title: "Call Maya", notes: "Self-talk.\n\n“Remember to call Maya tomorrow”", when: nil, link: .none, timing: .before),
		], "Only exact transcript evidence survives, each title once, and a time phrase only as the transcript's own words: \(valid)")
		let unlinked = TaskEngine.validate([drafts[0]], transcript: transcript, hasEvent: false)
		try expect(unlinked.map(\.link) == [.none], "Without an attached event no task links to one")
		try expect(TaskEngine.spokenTime("NEXT TIME", in: transcript) == "Next time" && TaskEngine.spokenTime("n/a", in: transcript) == nil,
			"A spoken time is copied from the transcript, ignoring case")
	}

	private static func promptChecks() throws {
		let event = calendarEvent("standup", start: now.addingTimeInterval(-600), recurring: true)
		let during = TaskEngine.prompt(passage: transcript, event: event, recordedAt: now)
		try expect(during.contains("Attached calendar event: Team standup,") && during.contains(", repeating.")
			&& during.contains("The memo was recorded while it was happening.") && during.contains("Memo:\n\(transcript)\nEnd of memo."),
			"The model sees the attached event, its timing, and the whole memo")
		let before = TaskEngine.prompt(passage: transcript, event: event, recordedAt: now.addingTimeInterval(-3_600))
		try expect(before.contains("recorded before it started"), "A memo recorded before the event says so")
		let none = TaskEngine.prompt(passage: transcript, event: nil, recordedAt: now, part: (2, 3))
		try expect(none.contains("Attached calendar event: none.") && none.contains("part 2 of 3"), "A memo without an event says none")
		try expect(TaskEngine.instructions.contains("Being recorded during the event is never a reason to link"),
			"The instructions forbid linking only because the memo was recorded during the event")
	}

	private static func extractionChecks() async throws {
		let event = calendarEvent("run", start: now.addingTimeInterval(-3_600), recurring: true)
		let next = calendarEvent("run", start: now.addingTimeInterval(7 * 86_400), recurring: true)
		let probe = PromptProbe()
		let drafts = [TaskDraft(title: "Bring electrolytes", why: "You faded.", evidence: "Next time I should bring electrolytes.",
			when: "", link: .next, timing: .before)]
		let result = await TaskEngine.extract(transcript: transcript, event: event, recordedAt: now, calendar: [event, next], now: now,
			modelIsAvailable: { true }, services: services(probe, context: 20_000, drafts: drafts))
		try expect(result.outcome == .complete && result.modelName == TaskEngine.modelName && result.tasks.count == 1
			&& result.tasks[0].event?.occurrences.map(\.start) == [next.startDate.epochMilliseconds],
			"A linked task resolves to the next occurrence after the recording")
		let fitting = await probe.prompts
		try expect(fitting.count == 1, "A fitting memo is one request")

		let unavailable = await TaskEngine.extract(transcript: transcript, event: nil, recordedAt: now, calendar: [],
			modelIsAvailable: { false }, services: services(probe, context: 20_000, drafts: drafts))
		try expect(unavailable.outcome == .unavailable && unavailable.tasks.isEmpty, "An unavailable model fails the stage instead of finding nothing")
		let silent = await TaskEngine.extract(transcript: " \n", event: nil, recordedAt: now, calendar: [],
			modelIsAvailable: { true }, services: services(probe, context: 20_000, drafts: drafts))
		try expect(silent.outcome == .skipped, "Silence skips extraction")

		let sentences = (0..<60).map { "Sentence \($0) says I should file report \($0)." }
		let long = sentences.joined(separator: " ")
		let longProbe = PromptProbe()
		let everyDraft = sentences.map { TaskDraft(title: "File report", why: "", evidence: $0, when: "") }
		let chunked = await TaskEngine.extract(transcript: long, event: nil, recordedAt: now, calendar: [],
			modelIsAvailable: { true }, services: services(longProbe, context: 1_200, drafts: everyDraft))
		let prompts = await longProbe.prompts
		try expect(chunked.outcome == .complete && prompts.count > 1 && sentences.allSatisfy { sentence in prompts.contains { $0.contains(sentence) } },
			"A long memo is covered by ordered passages, every sentence reaching the model")
		try expect(chunked.tasks.count == 1, "The same task from several passages is kept once")
	}

	private static func eventChecks() throws {
		let calendarID = "work"
		func occurrence(_ day: Int, rid: Bool = false) -> JournalCalendarEvent {
			var event = calendarEvent("gym", start: now.addingTimeInterval(Double(day) * 86_400), recurring: true)
			event.calendarIdentifier = calendarID
			event.id = "gym-\(day)"
			if rid { event.externalIdentifier = "gym-series/RID=\(day)" }
			event.occurrenceDate = event.startDate.addingTimeInterval(rid ? -1_800 : 0)
			return event
		}
		let attached = occurrence(0)
		let calendar = (1...80).map { occurrence($0, rid: $0 == 2) } + [occurrence(-7)]
		try expect(TaskEventResolver.seriesID(occurrence(2, rid: true)) == "gym-series", "A detached occurrence's /RID= suffix is dropped")
		let every = TaskEventResolver.resolve(.every, attached: attached, events: calendar, recordedAt: now, now: now)
		try expect(every?.series == true && every?.id == "gym-series" && every?.occurrences.count == 10
			&& every?.occurrences.first?.start == attached.startDate.epochMilliseconds
			&& every?.occurrences[2].original == occurrence(2, rid: true).occurrenceDate!.epochMilliseconds
			&& every?.edge == .before && every?.minutes == 60 && every?.title == "Team gym",
			"Every occurrence lists up to 10 upcoming ones, soonest first, with original dates, an hour before")
		let sparse = TaskEventResolver.resolve(.every, edge: .after, attached: attached, events: [occurrence(30), occurrence(70)],
			recordedAt: now, now: now)
		try expect(sparse?.occurrences.map(\.start) == [attached.startDate, occurrence(30).startDate].map(\.epochMilliseconds)
			&& sparse?.minutes == 0 && sparse?.edge == .after, "The series window is 60 days and only before carries a lead")
		let next = TaskEventResolver.resolve(.next, attached: attached, events: calendar, recordedAt: now.addingTimeInterval(60), now: now)
		try expect(next?.series == false && next?.occurrences.map(\.start) == [occurrence(1).startDate.epochMilliseconds],
			"Next is the first occurrence after the recording")
		let alone = TaskEventResolver.resolve(.every, attached: attached, events: [], recordedAt: now.addingTimeInterval(-60), now: now)
		try expect(alone?.series == true && alone?.occurrences.count == 1, "A repeating event follows its series even when only one occurrence is cached")
		var oneOff = attached
		oneOff.isRecurring = false
		let single = TaskEventResolver.resolve(.every, attached: oneOff, events: [], recordedAt: now.addingTimeInterval(-60), now: now)
		try expect(single?.series == false && single?.occurrences.count == 1, "A one-off event stands alone")
		try expect(TaskEventResolver.resolve(.none, attached: attached, events: calendar, recordedAt: now, now: now) == nil, "None links nothing")
	}

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
		let repository = JournalRepository(rootURL: root)
		_ = try await repository.load()
		let first = [task("Bring water"), task("Call Maya")]
		_ = try await repository.updateDraftReminders(id: entry.id) { $0 = first }
		let drafted = await repository.record(id: entry.id)
		let unsent = await repository.taskDeliveryJobs(repair: true)
		try expect(drafted?.taskDelivery == .draft && unsent.isEmpty, "Reminder drafts are never sent before Save Reminders")
		_ = try await repository.updateDraftReminders(id: entry.id) { $0[0].title = "Bring a water bottle"; $0.removeLast() }
		let edited = await repository.record(id: entry.id)
		try expect(edited?.entry?.tasks.map(\.title) == ["Bring a water bottle"] && edited?.taskDelivery == .draft,
			"Drafts can be renamed and removed")
		_ = try await repository.updateDraftReminders(id: entry.id) { $0.removeAll() }
		let cleared = try await repository.saveReminders(id: entry.id)
		let emptied = await repository.record(id: entry.id)
		try expect(cleared == nil && emptied?.taskDelivery == .notExtracted, "Removing every draft leaves nothing to save")

		_ = try await repository.updateDraftReminders(id: entry.id) { $0 = first }
		let saved = try await repository.saveReminders(id: entry.id)
		try expect(saved?.taskDelivery == .pending(retry: nil), "Save Reminders queues the drafts for ProcrastiMate")
		let job = try only(await repository.taskDeliveryJobs(now: now))
		try expect(job.tasks == first && job.id == entry.id && job.recordedAt == entry.createdAt, "The outbox sends the memo's reminders")
		let locked = try await repository.updateDraftReminders(id: entry.id) { $0.removeAll() }
		try expect(locked == nil, "Saved reminders are no longer drafts")

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
		let link = LinkProbe()
		let services = ProcessingServices(transcribe: { _, _, _, _ in TranscriptionResult(transcript: transcript, modelName: "Fixture") },
			reflect: { _, _ in ReflectionResult(headline: "Fixture", modelName: "Fixture") })
		let store = JournalStore(storageRootURL: root, processingServices: services, procrastiMate: link.client())
		try await store.waitUntilLoaded()
		await store.waitForConfigurationWritesForContract()

		link.status = .unavailable(.notInstalled)
		await store.updateDraftReminders(for: entry.id) { $0 = tasks }
		await store.waitForTaskDeliveryForContract()
		try expect(store.taskDeliveries[entry.id] == .draft && link.puts.isEmpty, "Drafts wait for Save Reminders")
		await store.saveReminders(for: entry.id)
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

	private static func calendarEvent(_ name: String, start: Date, recurring: Bool) -> JournalCalendarEvent {
		JournalCalendarEvent(id: name, externalIdentifier: "\(name)-series", calendarIdentifier: "work", calendarTitle: "Work",
			title: "Team \(name)", startDate: start, endDate: start.addingTimeInterval(1_800), isAllDay: false,
			isRecurring: recurring, occurrenceDate: start)
	}

	private static func services(_ probe: PromptProbe, context: Int, drafts: [TaskDraft]) -> TaskModelServices {
		TaskModelServices(budget: { _, _, _ in
			try ModelContextBudget(contextSize: context, instructionTokens: 0, schemaTokens: 0, outputTokens: 0, safetyTokens: 0,
				count: { $0.utf8.count })
		}, extract: { _, prompt in
			await probe.record(prompt)
			return drafts.filter { prompt.contains($0.evidence) }
		})
	}

	private actor PromptProbe {
		var prompts: [String] = []
		func record(_ prompt: String) { prompts.append(prompt) }
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

	private static func seed(_ root: URL, append: Bool = false) throws -> JournalEntry {
		let entry = JournalEntry(createdAt: now, duration: 1, transcript: transcript, headline: "Fixture memo", audioFilename: "\(UUID().uuidString).m4a")
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
		if append { try? FileManager.default.removeItem(at: root.appendingPathComponent("records-migration-v1.complete")) }
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
