import SwiftUI

struct MemoTaskRow: Identifiable, Equatable {
	var id: UUID
	var title: String
	var isDone: Bool
	var detail: String?
	/// ProcrastiMate's task id; nil until ProcrastiMate holds the task.
	var taskID: String?
}

/// What the note screen shows for a memo's tasks: ProcrastiMate's live view once delivered, the extraction before.
enum MemoTasksPresentation {
	static func rows(tasks: [MemoTask], delivery: MemoTaskDelivery?, remote: [RemoteMemoTask]?,
		now: Date = .now, calendar: Calendar = .current) -> [MemoTaskRow] {
		switch delivery {
		case let .delivered(receipts) where receipts.contains(where: { $0.id != nil }):
			if let remote {
				return remote.map { task in
					MemoTaskRow(id: task.key, title: task.title, isDone: task.completedAt != nil,
						detail: task.event.map(eventText) ?? task.due.flatMap { dueText($0, now: now, calendar: calendar) },
						taskID: task.id)
				}
			}
			let ids = Dictionary(receipts.compactMap { receipt in receipt.id.map { (receipt.key, $0) } }, uniquingKeysWith: { first, _ in first })
			return tasks.compactMap { task in
				ids[task.key].map { MemoTaskRow(id: task.key, title: task.title, isDone: false, detail: detail(task), taskID: $0) }
			}
		case .pending, .blocked:
			return tasks.map { MemoTaskRow(id: $0.key, title: $0.title, isDone: false, detail: detail($0), taskID: nil) }
		case .delivered, .notExtracted, nil:
			return []
		}
	}

	static func note(delivery: MemoTaskDelivery?) -> String? {
		switch delivery {
		case let .blocked(problem): problem.message
		case let .pending(retry): retry?.message ?? "Saving to ProcrastiMate."
		case .delivered, .notExtracted, nil: nil
		}
	}

	private static func detail(_ task: MemoTask) -> String? {
		if let event = task.event { return eventText(event) }
		guard let when = task.when, let first = when.first else { return nil }
		return first.uppercased() + when.dropFirst()
	}

	static func eventText(_ event: TaskEvent) -> String {
		let edge = switch event.edge {
		case .before: "Before"
		case .start: "At the start of"
		case .during: "During"
		case .after: "After"
		}
		return "\(edge) \(event.series ? "every " : "")\(event.title)"
	}

	static func dueText(_ due: RemoteMemoTask.Due, now: Date, calendar: Calendar) -> String? {
		let parts = due.date.split(separator: "-").compactMap { Int($0) }
		guard parts.count == 3 else { return nil }
		var components = DateComponents(year: parts[0], month: parts[1], day: parts[2])
		if let time = due.time?.split(separator: ":").compactMap({ Int($0) }), time.count == 2 {
			components.hour = time[0]
			components.minute = time[1]
		}
		guard let date = calendar.date(from: components) else { return nil }
		let day: String
		if calendar.isDate(date, inSameDayAs: now) { day = "Today" }
		else if let tomorrow = calendar.date(byAdding: .day, value: 1, to: now), calendar.isDate(date, inSameDayAs: tomorrow) { day = "Tomorrow" }
		else if let yesterday = calendar.date(byAdding: .day, value: -1, to: now), calendar.isDate(date, inSameDayAs: yesterday) { day = "Yesterday" }
		else { day = date.formatted(.dateTime.weekday(.abbreviated).month(.abbreviated).day()) }
		return due.time == nil ? day : "\(day), \(date.formatted(date: .omitted, time: .shortened))"
	}
}

struct MemoTaskRowView: View {
	@Environment(\.openURL) private var openURL
	let row: MemoTaskRow

	var body: some View {
		if let url = row.taskID.flatMap(ProcrastiMateLink.taskURL) {
			Button { openURL(url) } label: { label(opens: true) }
				.buttonStyle(.plain)
				.accessibilityHint("Opens this task in ProcrastiMate")
		} else {
			label(opens: false)
		}
	}

	private func label(opens: Bool) -> some View {
		HStack(alignment: .top, spacing: 11) {
			Image(systemName: row.isDone ? "checkmark.circle.fill" : "circle")
				.font(.system(size: 17, weight: .medium))
				.foregroundStyle(row.isDone ? AppStyle.tertiary : AppStyle.accent)
				.padding(.top, 2)
				.accessibilityLabel(row.isDone ? "Done" : "Not done")

			VStack(alignment: .leading, spacing: 4) {
				Text(row.title)
					.font(.system(size: 16, weight: .semibold))
					.foregroundStyle(row.isDone ? AppStyle.tertiary : .white)
					.strikethrough(row.isDone, color: AppStyle.tertiary)
					.fixedSize(horizontal: false, vertical: true)
				if let detail = row.detail {
					Text(detail)
						.font(.system(size: 12, weight: .medium))
						.foregroundStyle(AppStyle.secondary)
						.fixedSize(horizontal: false, vertical: true)
				}
			}

			Spacer(minLength: 4)

			if opens {
				Image(systemName: "arrow.up.forward")
					.font(.system(size: 12, weight: .semibold))
					.foregroundStyle(AppStyle.tertiary)
					.padding(.top, 4)
					.accessibilityHidden(true)
			}
		}
		.frame(maxWidth: .infinity, alignment: .leading)
		.contentShape(Rectangle())
		.padding(.vertical, 10)
		.accessibilityElement(children: .combine)
	}
}

/// The delete confirmation for a memo. When ProcrastiMate holds its tasks, keeping them is the default choice.
struct MemoDeletionConfirmation: ViewModifier {
	@Bindable var store: JournalStore
	@Binding var entry: JournalEntry?
	var willDelete: () -> Void = {}

	func body(content: Content) -> some View {
		content.alert(
			"Delete voice memo?",
			isPresented: Binding(get: { entry != nil }, set: { if !$0 { entry = nil } }),
			presenting: entry
		) { entry in
			if store.asksAboutTasksOnDeletion(entry.id) {
				Button("Delete Note Only") { delete(entry, tasks: false) }
				Button("Delete Note and Tasks", role: .destructive) { delete(entry, tasks: true) }
			} else {
				Button("Delete", role: .destructive) { delete(entry, tasks: false) }
			}
			Button("Cancel", role: .cancel) {}
		} message: { entry in
			Text(store.asksAboutTasksOnDeletion(entry.id)
				? "This permanently deletes the note and its recording. Its tasks stay in ProcrastiMate unless you delete them too."
				: "This permanently deletes the note and its recording.")
		}
	}

	private func delete(_ entry: JournalEntry, tasks: Bool) {
		willDelete()
		Task { await store.deleteEntry(id: entry.id, deletingTasks: tasks) }
	}
}
