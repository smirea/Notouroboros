#if DEBUG
import Foundation

/// Debug launch keys that create a memo from text instead of the microphone, so the real analysis runs on a Simulator:
///
///     -seed-memo "Next time I should bring the slides to the standup."
///     -seed-event-title "Standup"        attach the next cached calendar event with this title, or a synthetic one
///     -seed-event-start 2026-10-20T09:00:00Z  -seed-event-minutes 30  -seed-event-recurring   (synthetic event only)
@MainActor
enum MemoSeed {
	static func run(store: JournalStore) async {
		guard let transcript = argument("-seed-memo"), !store.isDemoMode else { return }
		do {
			try await store.waitUntilLoaded()
			if argument("-seed-event-title") != nil { await store.refreshCalendar() }
			let entry = JournalEntry(createdAt: .now, duration: 0, transcript: transcript, headline: "Seeded memo",
				calendarEvent: event(from: store.calendarSync.events), transcriptModel: "Seeded transcript")
			try await store.seedMemoForTesting(entry, at: .reflect)
			print("SEEDED_MEMO \(entry.id.uuidString.lowercased())")
		} catch {
			print("SEEDED_MEMO_FAILED \(error.localizedDescription)")
		}
		fflush(stdout)
	}

	private static func event(from cached: [JournalCalendarEvent]) -> JournalCalendarEvent? {
		guard let title = argument("-seed-event-title") else { return nil }
		if let match = cached.filter({ $0.title == title && $0.endDate > .now }).min(by: { $0.startDate < $1.startDate }) {
			return match
		}
		let start = argument("-seed-event-start").flatMap { try? Date($0, strategy: .iso8601) } ?? .now
		let minutes = argument("-seed-event-minutes").flatMap(Double.init) ?? 30
		return JournalCalendarEvent(id: "seed-event", externalIdentifier: "seed-event-series", calendarIdentifier: "seed",
			calendarTitle: "Seed", title: title, startDate: start, endDate: start.addingTimeInterval(minutes * 60), isAllDay: false,
			isRecurring: ProcessInfo.processInfo.arguments.contains("-seed-event-recurring"), occurrenceDate: start)
	}

	nonisolated private static func argument(_ flag: String) -> String? {
		let arguments = ProcessInfo.processInfo.arguments
		guard let index = arguments.firstIndex(of: flag), arguments.indices.contains(index + 1) else { return nil }
		return arguments[index + 1]
	}
}
#endif
