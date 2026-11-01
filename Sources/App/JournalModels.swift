import CryptoKit
import Foundation

struct JournalLocation: Codable, Hashable, Sendable {
	var latitude: Double
	var longitude: Double
	var city: String?

	var displayName: String {
		city ?? "Recorded location"
	}
}

struct JournalCalendarEvent: Codable, Hashable, Identifiable, Sendable {
	private enum CodingKeys: String, CodingKey {
		case id
		case localIdentifier
		case externalIdentifier
		case providerURL
		case calendarIdentifier
		case calendarTitle
		case title
		case startDate
		case endDate
		case isAllDay
		case location
		case notes
		case isRecurring
		case occurrenceDate
	}

	var id: String
	var localIdentifier: String?
	var externalIdentifier: String?
	var providerURL: URL?
	var calendarIdentifier: String
	var calendarTitle: String
	var title: String
	var startDate: Date
	var endDate: Date
	var isAllDay: Bool
	var location: String?
	var notes: String?
	var isRecurring: Bool
	var occurrenceDate: Date?

	init(
		id: String,
		localIdentifier: String? = nil,
		externalIdentifier: String? = nil,
		providerURL: URL? = nil,
		calendarIdentifier: String,
		calendarTitle: String,
		title: String,
		startDate: Date,
		endDate: Date,
		isAllDay: Bool,
		location: String? = nil,
		notes: String? = nil,
		isRecurring: Bool = false,
		occurrenceDate: Date? = nil
	) {
		self.id = id
		self.localIdentifier = localIdentifier
		self.externalIdentifier = externalIdentifier
		self.providerURL = providerURL
		self.calendarIdentifier = calendarIdentifier
		self.calendarTitle = calendarTitle
		self.title = title
		self.startDate = startDate
		self.endDate = endDate
		self.isAllDay = isAllDay
		self.location = location
		self.notes = notes
		self.isRecurring = isRecurring
		self.occurrenceDate = occurrenceDate
	}

	init(from decoder: Decoder) throws {
		let container = try decoder.container(keyedBy: CodingKeys.self)
		id = try container.decode(String.self, forKey: .id)
		localIdentifier = try container.decodeIfPresent(String.self, forKey: .localIdentifier)
		externalIdentifier = try container.decodeIfPresent(String.self, forKey: .externalIdentifier)
		providerURL = try container.decodeIfPresent(URL.self, forKey: .providerURL)
		calendarIdentifier = try container.decode(String.self, forKey: .calendarIdentifier)
		calendarTitle = try container.decode(String.self, forKey: .calendarTitle)
		title = try container.decode(String.self, forKey: .title)
		startDate = try container.decode(Date.self, forKey: .startDate)
		endDate = try container.decode(Date.self, forKey: .endDate)
		isAllDay = try container.decode(Bool.self, forKey: .isAllDay)
		location = try container.decodeIfPresent(String.self, forKey: .location)
		notes = try container.decodeIfPresent(String.self, forKey: .notes)
		isRecurring = try container.decodeIfPresent(Bool.self, forKey: .isRecurring) ?? false
		occurrenceDate = try container.decodeIfPresent(Date.self, forKey: .occurrenceDate)
	}
}

struct JournalEntry: Identifiable, Codable, Hashable, Sendable {
	private enum CodingKeys: String, CodingKey {
		case id
		case createdAt
		case duration
		case transcript
		case summary
		case headline
		case audioFilename
		case location
		case calendarEvent
		case summaryModel
		case transcriptModel
		case analysis
		case tasks
		case taskModel
	}

	let id: UUID
	var createdAt: Date
	var duration: TimeInterval
	var transcript: String
	var summary: String?
	var headline: String
	var audioFilename: String?
	var location: JournalLocation?
	var calendarEvent: JournalCalendarEvent?
	var summaryModel: String?
	var transcriptModel: String?
	var analysis: MemoAnalysis?
	var tasks: [MemoTask]
	var taskModel: String?

	init(
		id: UUID = UUID(),
		createdAt: Date = .now,
		duration: TimeInterval,
		transcript: String,
		summary: String? = nil,
		headline: String,
		audioFilename: String? = nil,
		location: JournalLocation? = nil,
		calendarEvent: JournalCalendarEvent? = nil,
		summaryModel: String? = nil,
		transcriptModel: String? = nil,
		analysis: MemoAnalysis? = nil,
		tasks: [MemoTask] = [],
		taskModel: String? = nil
	) {
		self.id = id
		self.createdAt = createdAt
		self.duration = duration
		self.transcript = transcript
		self.summary = summary
		self.headline = headline
		self.audioFilename = audioFilename
		self.location = location
		self.calendarEvent = calendarEvent
		self.summaryModel = summaryModel
		self.transcriptModel = transcriptModel
		self.analysis = analysis
		self.tasks = tasks
		self.taskModel = taskModel
	}

	init(from decoder: Decoder) throws {
		let container = try decoder.container(keyedBy: CodingKeys.self)
		id = try container.decode(UUID.self, forKey: .id)
		createdAt = try container.decode(Date.self, forKey: .createdAt)
		duration = try container.decode(TimeInterval.self, forKey: .duration)
		transcript = try container.decode(String.self, forKey: .transcript)
		summary = try container.decodeIfPresent(String.self, forKey: .summary)
		headline = try container.decode(String.self, forKey: .headline)
		audioFilename = try container.decodeIfPresent(String.self, forKey: .audioFilename)
		location = try container.decodeIfPresent(JournalLocation.self, forKey: .location)
		calendarEvent = try container.decodeIfPresent(JournalCalendarEvent.self, forKey: .calendarEvent)
		summaryModel = try container.decodeIfPresent(String.self, forKey: .summaryModel)
		transcriptModel = try container.decodeIfPresent(String.self, forKey: .transcriptModel)
		analysis = try container.decodeIfPresent(MemoAnalysis.self, forKey: .analysis)
		tasks = try container.decodeIfPresent([MemoTask].self, forKey: .tasks) ?? []
		taskModel = try container.decodeIfPresent(String.self, forKey: .taskModel)
	}
}

extension JournalEntry {
	func jsonData() throws -> Data {
		let encoder = JSONEncoder()
		encoder.dateEncodingStrategy = .iso8601
		encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
		return try encoder.encode(self)
	}
}

struct MemoAnalysis: Codable, Hashable, Sendable {
	var sourceFingerprint: String
	var notes: String

	init(transcript: String, notes: String) {
		sourceFingerprint = Self.fingerprint(transcript)
		self.notes = notes
	}

	func matches(_ transcript: String) -> Bool { sourceFingerprint == Self.fingerprint(transcript) }

	private static func fingerprint(_ transcript: String) -> String {
		SHA256.hash(data: Data(("memo-analysis-v1\n" + transcript).utf8)).map { String(format: "%02x", $0) }.joined()
	}
}

struct DailyRecordingMinutes: Identifiable, Equatable, Sendable {
	var date: Date
	var minutes: Double
	var id: Date { date }

	static func week(entries: [JournalEntry], weekStart: Date, calendar: Calendar = .current) -> [Self] {
		guard weekStart.timeIntervalSinceReferenceDate.isFinite else { return [] }
		let start = calendar.startOfDay(for: weekStart)
		let boundaries = (0...7).compactMap { calendar.date(byAdding: .day, value: $0, to: start) }
		guard boundaries.count == 8 else { return [] }
		var days = boundaries.dropLast().map { Self(date: $0, minutes: 0) }
		for entry in entries where entry.duration.isFinite && entry.duration > 0
			&& entry.createdAt.timeIntervalSinceReferenceDate.isFinite {
			guard let index = days.indices.first(where: {
				entry.createdAt >= boundaries[$0] && entry.createdAt < boundaries[$0 + 1]
			}) else { continue }
			let minutes = entry.duration / 60
			days[index].minutes += min(minutes, Double.greatestFiniteMagnitude - days[index].minutes)
		}
		return days
	}
}

struct WeeklyReview: Sendable {
	var weekStart: Date
	var title: String
	var body: String
	var recordingMinutes: [DailyRecordingMinutes] = []
	var outcome: ModelProcessingOutcome = .complete
}

struct ReflectionResult: Sendable {
	var headline: String
	var summary: String?
	var modelName: String
	var outcome: ModelProcessingOutcome = .complete
	var analysisContext: String? = nil
}

enum EntryProcessingPhase: Equatable, Sendable {
	case finalizing
	case finalizationFailed
	case partial
	case failed
	case canceled
	case transcribing
	case queued
	case reflecting
	case complete

	var title: String {
		switch self {
		case .finalizing: "Preparing audio"
		case .finalizationFailed: "Audio preparation needs retry"
		case .partial: "Transcript incomplete"
		case .failed: "Processing needs retry"
		case .canceled: "Processing paused"
		case .transcribing: "Transcribing"
		case .queued: "Waiting"
		case .reflecting: "Analyzing"
		case .complete: "Ready"
		}
	}

	var isActive: Bool { ![.finalizationFailed, .partial, .failed, .canceled, .complete].contains(self) }

}

extension JournalEntry {
	static let demo: [JournalEntry] = {
		let calendar = Calendar(identifier: .gregorian)
		let timeZone = TimeZone(identifier: "America/Chicago")!
		func date(_ year: Int, _ month: Int, _ day: Int, _ hour: Int, _ minute: Int) -> Date {
			var components = DateComponents()
			components.calendar = calendar
			components.timeZone = timeZone
			components.year = year
			components.month = month
			components.day = day
			components.hour = hour
			components.minute = minute
			return components.date!
		}
		let morningRun = JournalCalendarEvent(
			id: "demo-morning-run",
			externalIdentifier: "demo-morning-run-series",
			calendarIdentifier: "demo-personal",
			calendarTitle: "Personal",
			title: "Morning run",
			startDate: date(2026, 7, 12, 8, 0),
			endDate: date(2026, 7, 12, 9, 0),
			isAllDay: false,
			location: "Lakefront Trail",
			isRecurring: true
		)

		return [
			JournalEntry(
				createdAt: date(2026, 7, 12, 8, 47),
				duration: 94,
				transcript: "The morning run felt good, but I faded early. Next time I should bring electrolytes. I should also ask Maya tomorrow which dentist she recommended. For morning group runs this month I want to wear the red shorts so they are easy to spot.",
				summary: "The run felt encouraging, with a few concrete preparations you want to carry into the next one.",
				headline: "The run felt good enough to plan for the next one.",
				location: JournalLocation(latitude: 41.8781, longitude: -87.6298, city: "Chicago"),
				calendarEvent: morningRun,
				summaryModel: "SystemLanguageModel.default",
				transcriptModel: "Apple Speech · en-US",
				tasks: [
					MemoTask(key: UUID(uuidString: "D0000000-0000-4000-8000-000000000001")!, title: "Bring electrolytes",
						notes: "You faded early on this run.\n\n“Next time I should bring electrolytes.”", when: nil,
						event: TaskEventResolver.resolve(.every, attached: morningRun, events: [], recordedAt: date(2026, 7, 12, 8, 47),
							now: date(2026, 7, 12, 8, 47))),
					MemoTask(key: UUID(uuidString: "D0000000-0000-4000-8000-000000000002")!, title: "Ask Maya which dentist she recommended",
						notes: "You want a dentist recommendation.\n\n“I should also ask Maya tomorrow which dentist she recommended.”",
						when: "tomorrow", event: nil),
					MemoTask(key: UUID(uuidString: "D0000000-0000-4000-8000-000000000003")!, title: "Wear the red shorts to morning group runs",
						notes: "They make you easy to spot.\n\n“For morning group runs this month I want to wear the red shorts”",
						when: "this month", event: nil),
				],
				taskModel: TaskEngine.modelName
			),
			JournalEntry(
				createdAt: date(2026, 7, 12, 7, 21),
				duration: 58,
				transcript: "I need to plan the day before it gets away from me. The review is first, then lunch, then I can finish the draft.",
				summary: "You mapped out the review, lunch, and draft so the day would not get away from you.",
				headline: "Planning the day",
				summaryModel: "SystemLanguageModel.default",
				transcriptModel: "Apple Speech · en-US"
			),
			JournalEntry(
				createdAt: date(2026, 7, 11, 22, 25),
				duration: 312,
				transcript: "The Figma review went long again and I spent the afternoon redoing the deck instead of the work that’s due Friday. I keep saying yes to everything and then it’s six p.m.",
				summary: "The review and deck revisions consumed the afternoon while your own Friday work kept moving later.",
				headline: "You keep calling everyone else’s work urgent and your own the thing that can wait.",
				location: JournalLocation(latitude: 41.8781, longitude: -87.6298, city: "Chicago"),
				summaryModel: "SystemLanguageModel.default",
				transcriptModel: "Apple Speech · en-US"
			),
			JournalEntry(
				createdAt: date(2026, 7, 10, 21, 42),
				duration: 187,
				transcript: "The apartment stopped being the moment it became a choice you were making together.",
				summary: "The apartment mattered less as a place than as a decision you were making together.",
				headline: "The apartment stopped being the moment it became a choice you were making together.",
				summaryModel: "SystemLanguageModel.default",
				transcriptModel: "Apple Speech · en-US"
			)
		]
	}()
}

extension WeeklyReview {
	static var demo: WeeklyReview {
		let entries = JournalEntry.demo
		let start = entries[0].createdAt.startOfWeek()
		return WeeklyReview(weekStart: start, title: "You’re making room to prepare",
			body: "You mapped out the day before it could get away from you, and your run left you with concrete ideas for next time. Planning your draft, bringing electrolytes, and following up with Maya are small preparations you want to remember.",
			recordingMinutes: DailyRecordingMinutes.week(entries: entries, weekStart: start))
	}
}

extension Date {
	func startOfWeek(using calendar: Calendar = .current) -> Date {
		let start = calendar.dateInterval(of: .weekOfYear, for: self)?.start ?? self
		return calendar.startOfDay(for: start)
	}
}
