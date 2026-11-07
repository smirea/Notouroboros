import Foundation

/// One action from a memo. ProcrastiMate owns the task once it arrives; `key` names it there
/// forever, so a retry never duplicates it and a task Stefan deleted never comes back.
struct MemoTask: Codable, Hashable, Identifiable, Sendable {
	let key: UUID
	var title: String
	var notes: String
	/// The spoken time phrase copied verbatim from the transcript, which ProcrastiMate parses as of the recording.
	var when: String?
	var event: TaskEvent?

	var id: UUID { key }
}

/// ProcrastiMate's `TaskEvent` wire shape (`shared/values.ts`). Times are epoch milliseconds.
struct TaskEvent: Codable, Hashable, Sendable {
	enum Edge: String, Codable, Sendable { case before, start, during, after }

	struct Occurrence: Codable, Hashable, Sendable {
		var start: Int64
		var end: Int64
		/// EventKit's occurrence date, which stays put when the occurrence moves.
		var original: Int64
	}

	var id: String
	var title: String
	var allDay: Bool
	var series: Bool
	var edge: Edge
	var minutes: Int
	var occurrences: [Occurrence]
}

/// The memo's outbox state. Device-local: it is not part of the exported note.
enum MemoTaskDelivery: Codable, Equatable, Sendable {
	/// The memo has no tasks for ProcrastiMate.
	case notExtracted
	/// Extracted tasks wait for a `PUT`. `retry` follows the iCloud backoff after a transient failure.
	case pending(retry: CloudRetryState?)
	/// Extracted tasks wait for ProcrastiMate to be installed or signed in.
	case blocked(MemoTaskLinkProblem)
	/// ProcrastiMate accepted the tasks. An empty list means the memo had none to send.
	case delivered([MemoTaskReceipt])

	var awaitsDelivery: Bool {
		switch self {
		case .pending, .blocked: true
		case .notExtracted, .delivered: false
		}
	}

	var receipts: [MemoTaskReceipt] {
		if case let .delivered(receipts) = self { receipts } else { [] }
	}
}

enum MemoTaskLinkProblem: String, Codable, Sendable {
	case notInstalled, signedOut

	var message: String {
		switch self {
		case .notInstalled: "Could save these todos if you also had ProcrastiMate."
		case .signedOut: "Sign in to ProcrastiMate to save these todos."
		}
	}
}

/// `id` is nil when ProcrastiMate skipped the key because it had seen it before, such as a task Stefan deleted.
struct MemoTaskReceipt: Codable, Equatable, Sendable {
	var key: UUID
	var id: String?
}

/// ProcrastiMate's live view of a memo task, cached from `GET /api/memo-tasks` for display.
struct RemoteMemoTask: Codable, Equatable, Identifiable, Sendable {
	struct Due: Codable, Equatable, Sendable {
		var date: String
		var time: String?
	}

	var key: UUID
	var id: String
	var title: String
	var completedAt: Date?
	var due: Due?
	var event: TaskEvent?
}

struct MemoTasksRequest: Encodable, Sendable {
	var memoID: UUID
	var recordedAt: Date
	var tasks: [MemoTask]

	private enum Keys: String, CodingKey { case memoId, recordedAt, tasks, key, title, notes, when, event }

	// ProcrastiMate requires `when` and `event` even when null, and lowercase UUIDs.
	func encode(to encoder: Encoder) throws {
		var container = encoder.container(keyedBy: Keys.self)
		try container.encode(memoID.uuidString.lowercased(), forKey: .memoId)
		try container.encode(recordedAt.epochMilliseconds, forKey: .recordedAt)
		var list = container.nestedUnkeyedContainer(forKey: .tasks)
		for task in tasks {
			var item = list.nestedContainer(keyedBy: Keys.self)
			try item.encode(task.key.uuidString.lowercased(), forKey: .key)
			try item.encode(task.title, forKey: .title)
			try item.encode(task.notes, forKey: .notes)
			try item.encode(task.when, forKey: .when)
			try item.encode(task.event, forKey: .event)
		}
	}
}

/// Whether deleting a memo asks about its ProcrastiMate tasks. A fetched empty list means Stefan already removed them.
enum MemoDeletionPrompt {
	static func asksAboutTasks(delivery: MemoTaskDelivery?, remote: [RemoteMemoTask]?) -> Bool {
		guard let delivery, delivery.receipts.contains(where: { $0.id != nil }) else { return false }
		return remote.map { !$0.isEmpty } ?? true
	}
}

extension Date {
	var epochMilliseconds: Int64 { Int64((timeIntervalSince1970 * 1000).rounded()) }
}
