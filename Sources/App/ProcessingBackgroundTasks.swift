@preconcurrency import BackgroundTasks
import OSLog
import UIKit

@MainActor
final class ProcessingBackgroundTask {
	var onExpiration: (() -> Void)? {
		didSet { if expired { onExpiration?() } }
	}
	private(set) var expired = false
	private var completed = false
	private let report: (Int64, Int64, String) -> Void
	private let completion: (Bool) -> Void

	init(report: @escaping (Int64, Int64, String) -> Void = { _, _, _ in }, completion: @escaping (Bool) -> Void) {
		self.report = report
		self.completion = completion
	}

	convenience init(_ task: BGTask) {
		self.init(report: { completed, total, subtitle in
			guard let continued = task as? BGContinuedProcessingTask else { return }
			continued.progress.totalUnitCount = total
			continued.progress.completedUnitCount = completed
			continued.updateTitle("Processing voice memos", subtitle: subtitle)
		}, completion: { task.setTaskCompleted(success: $0) })
		task.expirationHandler = { [weak self] in
			Task { @MainActor in self?.expire() }
		}
	}

	func update(completed: Int64, total: Int64, subtitle: String) {
		guard !self.completed, !expired else { return }
		report(completed, max(1, total), subtitle)
	}

	func expire() {
		guard !completed, !expired else { return }
		expired = true
		onExpiration?()
	}

	func finish(success: Bool) {
		guard !completed else { return }
		completed = true
		onExpiration = nil
		completion(success && !expired)
	}
}

@MainActor
struct ProcessingBackgroundOperations {
	static let recoveryIdentifier = "com.stefan.notouroboros.processing.recovery"
	static let continuedPrefix = "com.stefan.notouroboros.processing.continued."

	var isForeground: () -> Bool
	var registerRecovery: (@escaping @MainActor (ProcessingBackgroundTask) -> Void) -> Bool
	var submitContinued: (String, @escaping @MainActor (ProcessingBackgroundTask) -> Void) throws -> Void
	var submitRecovery: (Date, Bool) throws -> Void
	var cancel: (String) -> Void

	static let live = Self(
		isForeground: { UIApplication.shared.applicationState != .background },
		registerRecovery: { launch in
			BGTaskScheduler.shared.register(forTaskWithIdentifier: recoveryIdentifier, using: .main) { task in
				MainActor.assumeIsolated { launch(ProcessingBackgroundTask(task)) }
			}
		},
		submitContinued: { identifier, launch in
			// Register the concrete ID: wildcard launch handlers are unreliable on early iOS 26 releases.
			guard BGTaskScheduler.shared.register(forTaskWithIdentifier: identifier, using: .main, launchHandler: { task in
				MainActor.assumeIsolated { launch(ProcessingBackgroundTask(task)) }
			}) else { throw BackgroundError.registration }
			let request = BGContinuedProcessingTaskRequest(identifier: identifier,
				title: "Processing voice memos", subtitle: "Preparing your recording")
			request.strategy = .fail
			try BGTaskScheduler.shared.submit(request)
		},
		submitRecovery: { date, needsNetwork in
			let request = BGProcessingTaskRequest(identifier: recoveryIdentifier)
			request.earliestBeginDate = date
			request.requiresNetworkConnectivity = needsNetwork
			request.requiresExternalPower = false
			try BGTaskScheduler.shared.submit(request)
		},
		cancel: { BGTaskScheduler.shared.cancel(taskRequestWithIdentifier: $0) })

	private enum BackgroundError: Error { case registration }
}

@MainActor
final class ProcessingBackgroundTasks {
	var onLaunch: (() -> Void)?
	var onExpiration: (() async -> Void)?
	var hasRuntime: Bool { active != nil && active?.expired == false }
	private let operations: ProcessingBackgroundOperations
	private var active: ProcessingBackgroundTask?
	private var pendingIdentifier: String?
	private var recoveryRequest: RecoveryRequest?
	private var recoveryRegistered = false
	private let logger = Logger(subsystem: "com.stefan.notouroboros", category: "BackgroundProcessing")

	private struct RecoveryRequest: Equatable {
		let date: Date
		let needsNetwork: Bool
	}

	init(operations: ProcessingBackgroundOperations = .live) {
		self.operations = operations
		recoveryRegistered = operations.registerRecovery { [weak self] task in
			guard let self else { task.finish(success: false); return }
			self.recoveryRequest = nil
			guard self.active == nil else { task.finish(success: true); return }
			self.cancelPending()
			self.accept(task)
		}
		if !recoveryRegistered { logger.error("Background recovery registration failed") }
	}

	func startUserInitiatedWork() {
		guard operations.isForeground(), active == nil, pendingIdentifier == nil else { return }
		let identifier = ProcessingBackgroundOperations.continuedPrefix + UUID().uuidString
		pendingIdentifier = identifier
		do {
			try operations.submitContinued(identifier) { [weak self] task in
				guard let self, self.pendingIdentifier == identifier else { task.finish(success: false); return }
				self.pendingIdentifier = nil
				self.accept(task)
			}
		} catch {
			pendingIdentifier = nil
			logger.notice("Continued processing unavailable; retaining foreground work and scheduled recovery: \(error.localizedDescription)")
		}
	}

	private func accept(_ task: ProcessingBackgroundTask) {
		active = task
		task.onExpiration = { [weak self, weak task] in
			guard let self, let task, self.active === task else { return }
			Task {
				guard self.active === task else { task.finish(success: false); return }
				await self.onExpiration?()
				if self.active === task { self.active = nil }
				task.finish(success: false)
			}
		}
		if !task.expired { onLaunch?() }
	}

	func scheduleRecovery(at date: Date?, needsNetwork: Bool) {
		guard recoveryRegistered else { return }
		guard let date else {
			operations.cancel(ProcessingBackgroundOperations.recoveryIdentifier)
			recoveryRequest = nil
			return
		}
		let request = RecoveryRequest(date: date, needsNetwork: needsNetwork)
		guard request != recoveryRequest else { return }
		do {
			try operations.submitRecovery(date, needsNetwork)
			recoveryRequest = request
		} catch { logger.error("Could not schedule processing recovery: \(error.localizedDescription)") }
	}

	func update(jobs: [EntryProcessing]) {
		let stages: [ProcessingStage] = [.finalizeAudio, .transcribe, .reflect]
		let completed = jobs.reduce(Int64(0)) { count, job in
			count + (job.status == .complete ? Int64(stages.count) : Int64(stages.firstIndex(of: job.stage) ?? 0))
		}
		let stage = jobs.first { $0.status == .running }?.stage
		let subtitle: String
		switch stage {
		case .finalizeAudio: subtitle = "Preparing audio"
		case .transcribe: subtitle = "Transcribing"
		case .reflect: subtitle = "Creating titles and summaries"
		case nil: subtitle = "Saving progress"
		}
		active?.update(completed: completed, total: Int64(jobs.count * stages.count), subtitle: subtitle)
	}

	func finish(success: Bool) {
		cancelPending()
		let task = active
		active = nil
		task?.finish(success: success)
	}

	private func cancelPending() {
		guard let identifier = pendingIdentifier else { return }
		pendingIdentifier = nil
		operations.cancel(identifier)
	}
}
