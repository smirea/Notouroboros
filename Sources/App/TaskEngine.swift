import Foundation
import FoundationModels

@Generable(description: "The to-dos a voice memo's owner gave themselves")
private struct GeneratedTaskBatch {
	@Guide(description: "Every distinct to-do, possibly none")
	var tasks: [GeneratedTask]
}

@Generable(description: "One to-do grounded in the memo")
private struct GeneratedTask {
	@Guide(description: "A short imperative to-do that keeps the memo's names and details")
	var title: String

	@Guide(description: "One sentence on why it matters, addressing the memo's owner as you")
	var why: String

	@Guide(description: "The exact words copied from the memo that ask for this action")
	var evidence: String

	@Guide(description: "The exact words copied from the memo that say when to do it, or empty")
	var when: String

	@Guide(description: "Whether the memo ties this action to the attached calendar event")
	var event: GeneratedEventLink

	@Guide(description: "When the action happens relative to a linked event")
	var timing: GeneratedTiming
}

@Generable
private enum GeneratedEventLink {
	case none, next, every

	var link: MemoEventLink {
		switch self {
		case .none: .none
		case .next: .next
		case .every: .every
		}
	}
}

@Generable
private enum GeneratedTiming {
	case before, during, after

	var edge: TaskEvent.Edge {
		switch self {
		case .before: .before
		case .during: .during
		case .after: .after
		}
	}
}

/// What the model proposes for one task, before grounding.
struct TaskDraft: Equatable, Sendable {
	var title: String
	var why: String
	var evidence: String
	var when: String
	var link: MemoEventLink = .none
	var timing: TaskEvent.Edge = .before
}

struct TaskExtractionResult: Sendable {
	var tasks: [MemoTask]
	var modelName: String?
	var outcome: ModelProcessingOutcome = .complete
}

private struct TaskResponseIncomplete: Error {}

struct TaskModelServices: Sendable {
	var budget: @Sendable (String, GenerationSchema, Int) async throws -> ModelContextBudget
	var extract: @Sendable (String, String) async throws -> [TaskDraft]

	static let live = Self(
		budget: { try await ModelContextBudget.make(instructions: $0, schema: $1, outputTokens: $2) },
		extract: { instructions, prompt in
			let response = try await LanguageModelSession(instructions: instructions)
				.respond(to: prompt, generating: GeneratedTaskBatch.self)
			guard response.rawContent.isComplete else { throw TaskResponseIncomplete() }
			return response.content.tasks.map { task in
				TaskDraft(title: task.title, why: task.why, evidence: task.evidence, when: task.when,
					link: task.event.link, timing: task.timing.edge)
			}
		})
}

enum TaskEngine {
	static let modelName = "SystemLanguageModel.default · guided tasks"
	/// Reminders are found while recording, when the shared model lane is suspended for capture priority.
	static let admission = ServiceAdmission()
	static var schema: GenerationSchema { GeneratedTaskBatch.generationSchema }

	static let instructions = """
		You read a voice memo its owner recorded for themselves and list the to-dos they gave themselves. A to-do is a concrete action the owner means to take later.

		- Include only actions the owner commits to, such as "I need to", "I should", "remember to", "don't forget", "next time I'll", or an instruction to themselves.
		- Leave out reflections, things that already happened, other people's obligations, hypotheticals, cancelled or rejected ideas, and vague wishes.
		- When unsure, leave the to-do out. Returning no to-dos is normal.
		- One to-do per distinct action. Never repeat an action in different words.
		- title: a short imperative such as "Book the dentist appointment". Keep the memo's names, amounts, and details.
		- why: one sentence on why it matters, addressing the owner as you.
		- evidence: copy the exact words from the memo that ask for the action. Copy, never paraphrase.
		- when: copy the exact words from the memo that say when to do it, such as "tomorrow at 3pm" or "every Monday". Leave it empty when the memo gives no time or the only time is the calendar event.
		- event: use next or every only when the memo ties the action to the attached calendar event, such as "before next week's standup" (next) or "every time I'm at the gym" (every). Being recorded during the event is never a reason to link. Otherwise none.
		- timing: before, during, or after the linked event. Use before unless the memo says otherwise.
		"""

	static func extract(
		transcript: String,
		event: JournalCalendarEvent?,
		recordedAt: Date,
		calendar: [JournalCalendarEvent],
		now: Date = .now,
		modelIsAvailable: @Sendable () -> Bool = { SystemLanguageModel.default.availability == .available },
		services: TaskModelServices = .live
	) async -> TaskExtractionResult {
		guard !Task.isCancelled else { return TaskExtractionResult(tasks: [], outcome: .cancelled) }
		guard !transcript.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
			return TaskExtractionResult(tasks: [], outcome: .skipped)
		}
		do {
			guard modelIsAvailable() else { throw ModelProcessingError.unavailable }
			let drafts = try await generate(transcript: transcript, event: event, recordedAt: recordedAt, services: services)
			try Task.checkCancellation()
			let tasks = validate(drafts, transcript: transcript, hasEvent: event != nil).map { task in
				MemoTask(key: UUID(), title: task.title, notes: task.notes, when: task.when,
					event: event.flatMap { TaskEventResolver.resolve(task.link, edge: task.timing, attached: $0,
						events: calendar, recordedAt: recordedAt, now: now) })
			}
			return TaskExtractionResult(tasks: tasks, modelName: modelName)
		} catch {
			return TaskExtractionResult(tasks: [], outcome: .failure(error,
				message: "The on-device model could not finish finding tasks. Try again."))
		}
	}

	struct ValidTask: Equatable, Sendable {
		var title: String
		var notes: String
		var when: String?
		var link: MemoEventLink
		var timing: TaskEvent.Edge
	}

	/// Keeps only drafts whose evidence is an exact transcript excerpt, and a `when` only when the transcript says it.
	static func validate(_ drafts: [TaskDraft], transcript: String, hasEvent: Bool) -> [ValidTask] {
		var titles = Set<String>()
		return drafts.compactMap { draft in
			let evidence = unquoted(draft.evidence)
			let title = cleanTitle(draft.title)
			guard !evidence.isEmpty, transcript.contains(evidence), !title.isEmpty, actionIsGrounded(title, in: evidence),
				titles.insert(title.foldedWords).inserted else { return nil }
			let why = unquoted(clean(draft.why))
			let quote = "“\(evidence)”"
			return ValidTask(title: title, notes: why.isEmpty ? quote : "\(why)\n\n\(quote)",
				when: spokenTime(draft.when, in: transcript), link: hasEvent ? draft.link : .none,
				timing: draft.timing == .during || draft.timing == .after ? draft.timing : .before)
		}
	}

	/// The transcript's own words for a time phrase the model copied, ignoring case.
	static func spokenTime(_ value: String, in transcript: String) -> String? {
		let phrase = unquoted(value)
		guard !phrase.isEmpty, !["none", "null", "n/a"].contains(phrase.lowercased()),
			let range = transcript.range(of: phrase, options: [.caseInsensitive, .diacriticInsensitive]) else { return nil }
		return String(transcript[range])
	}

	static func prompt(passage: String, event: JournalCalendarEvent?, recordedAt: Date, part: (index: Int, count: Int)? = nil) -> String {
		var lines: [String] = []
		if let event {
			let timing = recordedAt < event.startDate ? "before it started"
				: (recordedAt <= event.endDate ? "while it was happening" : "after it ended")
			let when = event.isAllDay
				? event.startDate.formatted(date: .complete, time: .omitted) + ", all day"
				: event.startDate.formatted(date: .complete, time: .shortened) + " to "
					+ event.endDate.formatted(date: .omitted, time: .shortened)
			lines.append("Attached calendar event: \(event.title), \(when)\(event.isRecurring ? ", repeating" : "").")
			lines.append("The memo was recorded \(timing).")
		} else {
			lines.append("Attached calendar event: none. Use none for every event.")
		}
		if let part { lines.append("This is part \(part.index) of \(part.count) of a long memo; list only the to-dos in this part.") }
		lines.append("Memo:\n\(passage)\nEnd of memo.")
		return lines.joined(separator: "\n")
	}

	private static func generate(transcript: String, event: JournalCalendarEvent?, recordedAt: Date,
		services: TaskModelServices) async throws -> [TaskDraft] {
		let budget = try await services.budget(instructions, schema, 1536)
		let whole = prompt(passage: transcript, event: event, recordedAt: recordedAt)
		if try await budget.fits(whole) {
			do { return try await request(whole, budget: budget, services: services) }
			catch { guard isRetryableContext(error) else { throw error } }
		}
		// Sized with a two-digit part line, since the count is unknown until chunking ends.
		let chunks = try await budget.chunks(transcript) { chunk in
			prompt(passage: chunk.text, event: event, recordedAt: recordedAt, part: (99, 99))
		}
		var drafts: [TaskDraft] = []
		for (index, chunk) in chunks.enumerated() {
			drafts += try await passage(chunk, part: (index + 1, chunks.count), event: event, recordedAt: recordedAt,
				budget: budget, services: services, retries: 3)
		}
		return drafts
	}

	private static func passage(_ chunk: ModelContextChunk, part: (index: Int, count: Int), event: JournalCalendarEvent?,
		recordedAt: Date, budget: ModelContextBudget, services: TaskModelServices, retries: Int) async throws -> [TaskDraft] {
		try Task.checkCancellation()
		do {
			return try await request(prompt(passage: chunk.text, event: event, recordedAt: recordedAt, part: part),
				budget: budget, services: services)
		} catch {
			guard retries > 0, isRetryableContext(error) else { throw error }
			var drafts: [TaskDraft] = []
			for half in try ModelContextBudget.bisect(chunk) {
				drafts += try await passage(half, part: part, event: event, recordedAt: recordedAt, budget: budget,
					services: services, retries: retries - 1)
			}
			return drafts
		}
	}

	private static func request(_ prompt: String, budget: ModelContextBudget, services: TaskModelServices) async throws -> [TaskDraft] {
		try await budget.requireFits(prompt)
		return try await admission.run(timeout: .seconds(45)) {
			try await services.extract(instructions, prompt)
		}
	}

	private static func isRetryableContext(_ error: any Error) -> Bool {
		ModelContextBudget.isContextError(error) || error is TaskResponseIncomplete
	}

	private static func clean(_ value: String) -> String {
		value.split(whereSeparator: \.isWhitespace).joined(separator: " ")
	}

	private static func unquoted(_ value: String) -> String {
		value.trimmingCharacters(in: .whitespacesAndNewlines)
			.trimmingCharacters(in: CharacterSet(charactersIn: "\"'“”‘’"))
			.trimmingCharacters(in: .whitespacesAndNewlines)
	}

	/// Most of the title's words must come from the evidence, so a title the model invented around a real quote is dropped.
	static func actionIsGrounded(_ title: String, in evidence: String) -> Bool {
		let ignored: Set = ["a", "an", "and", "at", "for", "i", "in", "me", "my", "of", "on", "or", "the", "this", "to", "with"]
		let titleWords = Set(title.foldedWords.split(separator: " ").map(String.init)).subtracting(ignored)
		let evidenceWords = Set(evidence.foldedWords.split(separator: " ").map(String.init)).subtracting(ignored)
		guard !titleWords.isEmpty else { return false }
		let matched = titleWords.filter { word in
			evidenceWords.contains { candidate in
				let length = min(4, word.count, candidate.count)
				return length >= 3 ? word.prefix(length) == candidate.prefix(length) : word == candidate
			}
		}
		return Double(matched.count) / Double(titleWords.count) >= 0.5
	}

	private static let selfTalk = ["i need to ", "i have to ", "i should ", "i want to ", "i will ", "i'll ", "i must ",
		"remember to ", "don't forget to ", "make sure to "]

	private static func cleanTitle(_ value: String) -> String {
		var title = unquoted(clean(value))
		while let prefix = selfTalk.first(where: { title.lowercased().hasPrefix($0) }) { title.removeFirst(prefix.count) }
		while title.hasSuffix(".") { title.removeLast() }
		guard let first = title.first else { return "" }
		return String((first.uppercased() + title.dropFirst()).prefix(200))
	}
}
