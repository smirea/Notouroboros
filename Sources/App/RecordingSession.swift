import Foundation
import Observation
import UIKit

struct RecordingContext: Identifiable {
	let id = UUID()
}

@MainActor
@Observable
final class RecordingSession {
	let recorder: AudioRecorder
	private(set) var context: RecordingContext?
	private(set) var hasStartedRecording = false
	private(set) var isFinishing = false
	private(set) var isDiscarding = false
	var errorMessage: String?
	var saveErrorMessage: String?
	var discardErrorMessage: String?
	@ObservationIgnored private var finishedRecording: FinishedRecording?

	var canFinish: Bool { recorder.hasRecording || finishedRecording != nil }
	var duration: TimeInterval { finishedRecording?.duration ?? recorder.duration }
	var isCommitting: Bool { isFinishing || isDiscarding }
	var statusMessage: String? {
		if isFinishing { return "Saving recording…" }
		if isDiscarding { return "Discarding recording…" }
		if finishedRecording != nil { return "Recording stopped. Finish to save or discard it." }
		return recorder.statusMessage
	}

	@ObservationIgnored private let store: JournalStore
	@ObservationIgnored let activityManager: RecordingActivityManager
	@ObservationIgnored private let now: () -> Date
	@ObservationIgnored private let heartbeatInterval: Duration
	@ObservationIgnored private var heartbeatTask: Task<Void, Never>?
	@ObservationIgnored private var activityCaptureID: UUID?
	@ObservationIgnored private var activityState: RecordingActivityAttributes.ContentState?
	@ObservationIgnored private(set) var startupTask: Task<Void, Never>?
	@ObservationIgnored private var generation: UUID?
	@ObservationIgnored private var capturePriorityOwner: UUID?
	@ObservationIgnored private var activeURL: URL?
	@ObservationIgnored private var calendarEvent: JournalCalendarEvent?
	@ObservationIgnored private var lastCheckpointSecond = 0

	var isVisualDemo: Bool {
		ProcessInfo.processInfo.arguments.contains("-demo-recording")
	}

	init(store: JournalStore, recorder: AudioRecorder = AudioRecorder(),
		activityManager: RecordingActivityManager? = nil, now: @escaping () -> Date = Date.init,
		heartbeatInterval: Duration = .seconds(20)) {
		self.store = store
		self.recorder = recorder
		self.activityManager = activityManager ?? RecordingActivityManager(operations: store.isIsolatedStorage ? .disabled : nil)
		self.now = now
		self.heartbeatInterval = heartbeatInterval
		recorder.onStateChange = { [weak self] in self?.recordingStateChanged() }
	}

	deinit { heartbeatTask?.cancel() }

	func present(startsImmediately: Bool) {
		guard context == nil else { return }
		context = RecordingContext()
		hasStartedRecording = false
		isFinishing = false
		isDiscarding = false
		discardErrorMessage = nil
		errorMessage = nil
		saveErrorMessage = nil
		finishedRecording = nil
		if startsImmediately { start(calendarEvent: nil) }
	}

	func start(calendarEvent: JournalCalendarEvent?) {
		guard context != nil, !hasStartedRecording else { return }
		hasStartedRecording = true
		self.calendarEvent = calendarEvent
		lastCheckpointSecond = 0
		let generation = UUID()
		self.generation = generation
		if isVisualDemo {
			let date = now()
			activityCaptureID = generation
			activityState = makeActivityState(status: .recording, elapsed: 113, at: date, location: "Chicago")
			activityManager.start(captureID: generation, startedAt: date, state: activityState!)
			#if DEBUG
			if ProcessInfo.processInfo.arguments.contains("-demo-audio-reset") {
				recorder.showStoppedDemo(duration: 113)
				stopActivity(elapsed: 113)
			}
			#endif
			return
		}
		startupTask = Task { [weak self] in
			await self?.beginRecording(generation: generation)
		}
	}

	func finish() async -> UUID? {
		guard !isVisualDemo, !isCommitting else { return nil }
		if finishedRecording == nil { finishedRecording = recorder.finish() }
		guard let recording = finishedRecording else { return nil }
		isFinishing = true
		defer { isFinishing = false }
		generation = nil
		stopActivity(elapsed: duration)
		UIApplication.shared.isIdleTimerDisabled = false
		await releaseCapturePriority()
		do {
			let entryID = try await store.finishRecording(
				at: recording.url, calendarEvent: calendarEvent)
			activeURL = nil
			finishedRecording = nil
			context = nil
			return entryID
		} catch {
			saveErrorMessage = "Your audio is still on this device. Try Finish again. " + error.localizedDescription
			return nil
		}
	}

	@discardableResult
	func discard() async -> Bool {
		guard !isCommitting else { return false }
		isDiscarding = true
		defer { isDiscarding = false }
		generation = nil
		startupTask?.cancel()
		startupTask = nil
		if finishedRecording == nil { finishedRecording = recorder.finish() }
		if recorder.state == .starting { _ = recorder.cancel() }
		stopActivity(elapsed: duration)
		UIApplication.shared.isIdleTimerDisabled = false
		await releaseCapturePriority()
		do {
			if let url = finishedRecording?.url ?? activeURL {
				try await store.cancelRecording(at: url)
			}
			store.cancelRecordingLocationCapture()
			finishedRecording = nil
			activeURL = nil
			context = nil
			errorMessage = nil
			discardErrorMessage = nil
			return true
		} catch {
			let retained = canFinish ? "Its audio is still on this device. Try discarding again, or Finish to save it." : "Recording will not start. Try discarding again."
			discardErrorMessage = "The recording hasn’t been discarded. " + retained + " " + error.localizedDescription
			return false
		}
	}

	private func beginRecording(generation: UUID) async {
		guard self.generation == generation, !Task.isCancelled else { return }
		capturePriorityOwner = generation
		await store.beginCapturePriority(owner: generation)
		guard self.generation == generation, !Task.isCancelled else {
			await releaseCapturePriority(owner: generation)
			return
		}
		do {
			let url = try await store.destinationForNewRecording(calendarEvent: calendarEvent)
			guard self.generation == generation, !Task.isCancelled else {
				do { try await store.cancelRecording(at: url) }
				catch { store.storageErrorMessage = "Cancelled recording cleanup is pending. " + error.localizedDescription }
				await releaseCapturePriority(owner: generation)
				return
			}
			activeURL = url
			try await recorder.start(at: url)
			guard self.generation == generation, !Task.isCancelled else { return }
			startupTask = nil
			if let captureID = UUID(uuidString: url.deletingPathExtension().lastPathComponent), let status = activityStatus {
				let date = now()
				activityCaptureID = captureID
				activityState = makeActivityState(status: status, elapsed: recorder.duration, at: date)
				activityManager.start(captureID: captureID, startedAt: date, state: activityState!) { [weak self] in
					self?.generation == generation
				}
				startHeartbeat(generation: generation)
			}
			if store.settings.hapticsEnabled {
				UIImpactFeedbackGenerator(style: .light).impactOccurred()
			}
			let locationTask = store.beginRecordingLocationCapture()
			Task { [weak self] in
				let location = await locationTask.value
				guard let self, self.generation == generation else { return }
				self.setActivityLocation(location.map(self.store.displayName(for:)) ?? "Location unavailable")
			}
			UIApplication.shared.isIdleTimerDisabled = store.settings.keepScreenAwakeWhileRecording
		} catch {
			await releaseCapturePriority(owner: generation)
			guard self.generation == generation else { return }
			startupTask = nil
			errorMessage = error.localizedDescription
		}
	}

	private func recordingStateChanged() {
		if let status = activityStatus {
			if activityState?.status != status { refreshActivity() }
		} else if recorder.state != .starting {
			stopActivity(elapsed: recorder.duration)
		}
		if case .stopped = recorder.state {
			UIApplication.shared.isIdleTimerDisabled = false
			if let owner = capturePriorityOwner {
				capturePriorityOwner = nil
				Task { await store.endCapturePriority(owner: owner) }
			}
		}
		guard let activeURL, recorder.hasRecording else { return }
		let second = Int(recorder.duration)
		if second >= lastCheckpointSecond + 5 {
			lastCheckpointSecond = second
			store.checkpointRecording(at: activeURL, duration: recorder.duration)
		}
	}

	func refreshActivity() {
		guard generation != nil, let captureID = activityCaptureID, let previous = activityState,
			let status = activityStatus else { return }
		let elapsed = recorder.duration.isFinite ? max(0, recorder.duration) : previous.elapsed
		guard status != .recording || previous.status != status || elapsed > previous.elapsed else { return }
		let state = makeActivityState(status: status, elapsed: elapsed, at: now(), location: previous.locationName)
		activityState = state
		activityManager.update(captureID: captureID, state: state)
	}

	private var activityStatus: RecordingActivityAttributes.Status? {
		switch recorder.state {
		case .recording: .recording
		case .pausedByUser: .paused
		case .interrupted: .interrupted
		case .waitingForInput: .waitingForInput
		case .idle, .starting, .stopped: nil
		}
	}

	private func makeActivityState(status: RecordingActivityAttributes.Status, elapsed: TimeInterval,
		at date: Date, location: String = "Finding location…") -> RecordingActivityAttributes.ContentState {
		.init(isPaused: status != .recording, locationName: location, elapsed: elapsed.isFinite ? max(0, elapsed) : 0,
			resumedAt: status == .recording ? date : nil, status: status, confirmedAt: date,
			freshUntil: date.addingTimeInterval(90))
	}

	private func startHeartbeat(generation: UUID) {
		heartbeatTask?.cancel()
		let interval = heartbeatInterval
		heartbeatTask = Task { [weak self] in
			while !Task.isCancelled {
				do { try await Task.sleep(for: interval) } catch { return }
				guard !Task.isCancelled, let self, self.generation == generation else { return }
				self.refreshActivity()
			}
		}
	}

	private func setActivityLocation(_ location: String) {
		guard let captureID = activityCaptureID, var state = activityState else { return }
		state.locationName = location
		activityState = state
		activityManager.update(captureID: captureID, state: state)
	}

	private func stopActivity(elapsed: TimeInterval) {
		heartbeatTask?.cancel()
		heartbeatTask = nil
		guard let captureID = activityCaptureID, var state = activityState else { return }
		activityCaptureID = nil
		activityState = nil
		state.elapsed = elapsed.isFinite ? max(0, elapsed) : state.elapsed
		state.isPaused = true
		state.resumedAt = nil
		state.status = .stopped
		state.confirmedAt = now()
		state.freshUntil = state.confirmedAt
		activityManager.end(captureID: captureID, state: state)
	}

	private func releaseCapturePriority(owner: UUID? = nil) async {
		guard let owner = owner ?? capturePriorityOwner else { return }
		if capturePriorityOwner == owner { capturePriorityOwner = nil }
		await store.endCapturePriority(owner: owner)
	}
}
