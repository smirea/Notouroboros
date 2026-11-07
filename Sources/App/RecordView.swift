import SwiftUI
import UIKit

struct RecordView: View {
	@Bindable var store: JournalStore
	@Bindable var session: RecordingSession
	let onClose: () -> Void
	let onFinished: (UUID) -> Void

	private var recorder: AudioRecorder { session.recorder }
	@State private var isAttachedToEvent = false
	@State private var eventAttachmentWasChanged = false
	@State private var selectedEventKey: String?
	@State private var selectedDate = Date.now
	@State private var showsDatePicker = false

	private var isVisualDemo: Bool {
		session.isVisualDemo
	}

	private var demoIsRecording: Bool {
		isVisualDemo && !ProcessInfo.processInfo.arguments.contains("-demo-audio-reset")
	}

	private var shownDuration: TimeInterval {
		isVisualDemo ? 113 : session.duration
	}

	private var events: [JournalCalendarEvent] {
		store.settings.calendarSyncEnabled ? store.calendarSync.events(on: selectedDay) : []
	}

	private var selectedCalendarEvent: JournalCalendarEvent? {
		guard isAttachedToEvent, let selectedEventKey else { return nil }
		return RecordingEventSelection.event(for: selectedEventKey, in: events)
	}

	private var selectedDay: Date {
		Calendar.current.startOfDay(for: selectedDate)
	}

	var body: some View {
		ZStack {
			AppStyle.background.ignoresSafeArea()

			if session.hasStartedRecording || isVisualDemo {
				recordingView
			} else {
				setupView
			}
		}
		.presentationBackground(AppStyle.background)
		.interactiveDismissDisabled()
		.onAppear {
			guard !session.hasStartedRecording else { return }
			prepareEventSelection()
		}
		.onChange(of: selectedDay) { _, _ in
			guard !session.hasStartedRecording else { return }
			prepareEventSelection()
		}
		.onChange(of: isAttachedToEvent) { _, isAttached in
			if isAttached {
				selectClosestEvent()
			} else {
				selectedEventKey = nil
			}
		}
		.onChange(of: store.settings.calendarSyncEnabled) { _, enabled in
			if !enabled {
				isAttachedToEvent = false
				selectedEventKey = nil
			}
		}
		.onChange(of: events) { _, _ in
			guard store.settings.calendarSyncEnabled, !events.isEmpty else {
				isAttachedToEvent = false
				selectedEventKey = nil
				return
			}
			if selectedEventKey != nil, selectedCalendarEvent == nil {
				selectedEventKey = nil
				eventAttachmentWasChanged = true
				return
			}
			guard !eventAttachmentWasChanged else { return }
			isAttachedToEvent = store.settings.calendarSyncEnabled && !events.isEmpty
			if isAttachedToEvent {
				selectClosestEvent()
			}
		}
		#if DEBUG
		.task {
			guard isVisualDemo else { return }
			try? await Task.sleep(for: .milliseconds(600))
			let arguments = ProcessInfo.processInfo.arguments
			if arguments.contains("-demo-save-error") {
				session.saveErrorMessage = "Your audio is still on this device. Try Finish again. The note couldn’t be written."
			}
			if arguments.contains("-demo-discard-error") {
				session.discardErrorMessage = "The recording hasn’t been discarded. Its audio is still on this device. Try discarding again, or Finish to save it."
			}
		}
		#endif
		.alert("Recording unavailable", isPresented: Binding(
			get: { session.errorMessage != nil },
			set: { if !$0 { session.errorMessage = nil } }
		)) {
			Button("Close", action: cancel)
		} message: {
			Text(session.errorMessage ?? "")
		}
		.alert("Couldn’t save recording", isPresented: Binding(
			get: { session.saveErrorMessage != nil },
			set: { if !$0 { session.saveErrorMessage = nil } }
		)) {
			Button("OK", role: .cancel) { session.saveErrorMessage = nil }
		} message: {
			Text(session.saveErrorMessage ?? "")
		}
		.alert("Couldn’t discard recording", isPresented: Binding(
			get: { session.discardErrorMessage != nil },
			set: { if !$0 { session.discardErrorMessage = nil } }
		)) {
			Button("Try Again", action: cancel)
			Button("Keep Audio", role: .cancel) { session.discardErrorMessage = nil }
		} message: {
			Text(session.discardErrorMessage ?? "")
		}
		.sheet(isPresented: $showsDatePicker) {
			NavigationStack {
				DatePicker(
					"Event date",
					selection: $selectedDate,
					in: store.calendarSync.selectableDateRange,
					displayedComponents: .date
				)
				.datePickerStyle(.graphical)
				.labelsHidden()
				.tint(AppStyle.accent)
				.padding(.horizontal, 20)
				.navigationTitle("Select date")
				.navigationBarTitleDisplayMode(.inline)
				.toolbar {
					ToolbarItem(placement: .confirmationAction) {
						Button("Done") { showsDatePicker = false }
					}
				}
			}
			.preferredColorScheme(.dark)
			.presentationDetents([.medium])
			.presentationDragIndicator(.visible)
		}
	}

	private var setupView: some View {
		VStack(spacing: 0) {
			closeButton

			ScrollView {
				VStack(alignment: .leading, spacing: 24) {
					Button {
						showsDatePicker = true
					} label: {
						HStack(spacing: 9) {
							Text(selectedDate.compactHeaderText)
								.font(.system(size: 30, weight: .semibold))
								.foregroundStyle(.white)
							Image(systemName: "chevron.down")
								.font(.system(size: 14, weight: .bold))
								.foregroundStyle(AppStyle.accent)
						}
					}
					.buttonStyle(.plain)
					.accessibilityLabel("Recording date, \(selectedDate.compactHeaderText)")
					.accessibilityHint("Opens the calendar picker")

					Toggle(isOn: Binding(
						get: { isAttachedToEvent },
						set: {
							eventAttachmentWasChanged = true
							isAttachedToEvent = $0
						}
					)) {
						Label("Attached to event", systemImage: "calendar")
							.font(.system(size: 17, weight: .semibold))
					}
					.tint(AppStyle.accent)
					.disabled(!store.settings.calendarSyncEnabled || events.isEmpty)

					eventList
						.opacity(isAttachedToEvent ? 1 : 0.36)
						.scaleEffect(isAttachedToEvent ? 1 : 0.94, anchor: .top)
						.allowsHitTesting(isAttachedToEvent)
						.animation(.easeOut(duration: 0.2), value: isAttachedToEvent)
				}
				.padding(.horizontal, 24)
				.padding(.bottom, 120)
			}
			.scrollIndicators(.hidden)

			Button(action: startRecording) {
				Label("Start recording", systemImage: "mic.fill")
					.font(.system(size: 17, weight: .semibold))
					.foregroundStyle(.white)
					.frame(maxWidth: .infinity)
					.frame(height: 58)
					.background(AppStyle.accent, in: Capsule())
					.shadow(color: AppStyle.accent.opacity(0.34), radius: 18, y: 8)
			}
			.buttonStyle(.plain)
			.disabled(isAttachedToEvent && selectedCalendarEvent == nil)
			.padding(.horizontal, 24)
			.padding(.bottom, 28)
		}
	}

	@ViewBuilder
	private var eventList: some View {
		if events.isEmpty {
			Text(store.settings.calendarSyncEnabled ? "No events on this date" : "Calendar sync is off")
				.font(.system(size: 15, weight: .medium))
				.foregroundStyle(AppStyle.secondary)
				.frame(maxWidth: .infinity, alignment: .leading)
				.padding(.vertical, 20)
		} else {
			let rows = RecordingEventSelection.rows(in: events)
			let lastKey = rows.last?.id
			LazyVStack(spacing: 0) {
				ForEach(rows) { row in
					let event = row.event
					let unavailable = !row.isAvailable
					Button {
						eventAttachmentWasChanged = true
						selectedEventKey = row.id
					} label: {
						EventSelectionRow(
							event: event,
							isSelected: selectedEventKey == row.id,
							isUnavailable: unavailable
						)
					}
					.buttonStyle(.plain)
					.disabled(unavailable)
					.accessibilityValue(unavailable ? "Event unavailable" : (selectedEventKey == row.id ? "Selected" : "Not selected"))
					if row.id != lastKey {
						Divider().overlay(Color.white.opacity(0.14))
					}
				}
			}
		}
	}

	private var recordingView: some View {
		VStack(spacing: 0) {
			closeButton

			Spacer()

			WaveformView(levels: displayLevels)
				.frame(height: 54)
				.padding(.horizontal, 52)
				.offset(y: -45)

			Text(shownDuration.clockText)
				.font(.system(size: 20, weight: .regular, design: .monospaced))
				.monospacedDigit()
				.padding(.top, 12)
				.offset(y: -40)

			if let statusMessage = session.statusMessage {
				Text(statusMessage)
					.font(.system(size: 14, weight: .medium))
					.foregroundStyle(AppStyle.secondary)
					.multilineTextAlignment(.center)
					.padding(.horizontal, 54)
					.offset(y: -34)
			}

			Spacer()

			HStack(spacing: 34) {
				Button(action: togglePause) {
					Image(systemName: demoIsRecording || recorder.wantsToRecord ? "pause.fill" : "play.fill")
						.font(.system(size: 13, weight: .semibold))
						.foregroundStyle(AppStyle.accent)
						.frame(width: 48, height: 48)
						.glassEffect(.regular.interactive(), in: Circle())
				}
				.buttonStyle(.plain)
				.disabled(!demoIsRecording && !recorder.canTogglePause)
				.accessibilityLabel(demoIsRecording || recorder.wantsToRecord ? "Pause" : "Resume")

				Button(action: finish) {
					Image(systemName: "checkmark")
						.font(.system(size: 20, weight: .medium))
						.foregroundStyle(.white)
						.frame(width: 62, height: 62)
						.background(AppStyle.accent, in: Circle())
						.shadow(color: AppStyle.accent.opacity(0.38), radius: 18, y: 7)
				}
				.buttonStyle(.plain)
				.disabled(!isVisualDemo && (!session.canFinish || session.isCommitting))
				.accessibilityLabel("Finish recording")
			}
			.padding(.bottom, 63)
			.offset(x: -52)
		}
	}

	private var closeButton: some View {
		HStack {
			Spacer()
			Button(action: cancel) {
				Image(systemName: "trash.fill")
					.font(.system(size: 15, weight: .semibold))
					.foregroundStyle(.red)
					.frame(width: 44, height: 44)
					.glassEffect(.regular.tint(.red.opacity(0.12)).interactive(), in: Circle())
			}
			.buttonStyle(.plain)
			.disabled(session.isCommitting)
			.accessibilityLabel("Discard recording")
			.padding(.top, 18)
		}
		.padding(.trailing, 8)
	}

	private var displayLevels: [Double] {
		if isVisualDemo {
			return [
				0.04, 0.04, 0.04, 0.04, 0.04, 0.04, 0.04, 0.04,
				0.04, 0.04, 0.04, 0.04, 0.04, 0.04, 0.04, 0.04,
				0.40, 0.72, 0.92, 0.86, 0.78, 0.70, 0.82, 0.74, 0.65, 0.78,
				0.60, 0.53, 0.45, 0.38, 0.30, 0.22, 0.16, 0.12, 0.08,
				0.04, 0.04, 0.04, 0.04, 0.04, 0.04,
				0.25, 0.34, 0.42, 0.38, 0.31, 0.36, 0.44, 0.39, 0.34, 0.31, 0.28, 0.24, 0.21
			]
		}
		if recorder.levels.allSatisfy({ $0 <= 0.08 }) {
			return recorder.levels.enumerated().map { index, _ in
				let center = Double(recorder.levels.count) / 2
				let distance = abs(Double(index) - center) / center
				return max(0.06, (1 - distance) * 0.42 + Double(index % 5) * 0.055)
			}
		}
		return recorder.levels
	}

	private func prepareEventSelection() {
		eventAttachmentWasChanged = false
		isAttachedToEvent = false
		selectedEventKey = nil
		isAttachedToEvent = store.settings.calendarSyncEnabled && !events.isEmpty
		if isAttachedToEvent {
			selectClosestEvent()
		}
	}

	private func selectClosestEvent() {
		selectedEventKey = RecordingEventSelection.closestKey(in: events, at: eventSelectionReferenceDate)
	}

	private var eventSelectionReferenceDate: Date {
		let now = Date.now
		let components = Calendar.current.dateComponents([.hour, .minute, .second], from: now)
		return Calendar.current.date(
			bySettingHour: components.hour ?? 0,
			minute: components.minute ?? 0,
			second: components.second ?? 0,
			of: selectedDate
		) ?? selectedDate
	}

	private func startRecording() {
		guard !isAttachedToEvent || selectedCalendarEvent != nil else { return }
		session.start(calendarEvent: selectedCalendarEvent)
	}

	private func finish() {
		Task {
			guard let entryID = await session.finish() else { return }
			impact(.medium)
			onFinished(entryID)
		}
	}

	private func cancel() {
		Task {
			guard await session.discard() else { return }
			notification(.warning)
			onClose()
		}
	}

	private func togglePause() {
		recorder.togglePause()
		impact(.soft)
	}

	private func impact(_ style: UIImpactFeedbackGenerator.FeedbackStyle) {
		guard store.settings.hapticsEnabled else { return }
		UIImpactFeedbackGenerator(style: style).impactOccurred()
	}

	private func notification(_ type: UINotificationFeedbackGenerator.FeedbackType) {
		guard store.settings.hapticsEnabled else { return }
		UINotificationFeedbackGenerator().notificationOccurred(type)
	}
}

private struct EventSelectionRow: View {
	let event: JournalCalendarEvent
	let isSelected: Bool
	let isUnavailable: Bool

	private var timeText: String {
		if event.isAllDay {
			return "All day"
		}
		let start = event.startDate.formatted(date: .omitted, time: .shortened)
		let end = event.endDate.formatted(date: .omitted, time: .shortened)
		return "\(start)–\(end)"
	}

	var body: some View {
		HStack(spacing: 13) {
			VStack(alignment: .leading, spacing: 5) {
				Text(event.title)
					.font(.system(size: 17, weight: .semibold))
					.foregroundStyle(.white)
					.multilineTextAlignment(.leading)
					.lineLimit(2)

				Text("\(timeText) · \(event.calendarTitle)")
					.font(.system(size: 13, weight: .medium))
					.foregroundStyle(AppStyle.secondary)
					.lineLimit(1)
				if isUnavailable {
					Text("Event unavailable")
						.font(.caption)
						.foregroundStyle(AppStyle.secondary)
				}
			}

			Spacer(minLength: 8)

			Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
				.font(.system(size: 21, weight: .semibold))
				.foregroundStyle(isSelected ? AppStyle.accent : AppStyle.tertiary)
		}
		.padding(.vertical, 15)
		.contentShape(Rectangle())
	}
}

enum RecordingEventSelection {
	struct Row: Identifiable {
		let id: String
		let event: JournalCalendarEvent
		let isAvailable: Bool
	}

	static func event(for key: String, in events: [JournalCalendarEvent]) -> JournalCalendarEvent? {
		let matches = Set(events.filter { $0.focusKey == key })
		return matches.count == 1 ? matches.first : nil
	}

	static func rows(in events: [JournalCalendarEvent]) -> [Row] {
		let snapshots = events.map { (key: $0.focusKey, event: $0) }
		let counts = Dictionary(grouping: snapshots, by: \.key).mapValues { Set($0.map(\.event)).count }
		var keys: Set<String> = []
		return snapshots.compactMap {
			guard keys.insert($0.key).inserted else { return nil }
			return Row(id: $0.key, event: $0.event, isAvailable: counts[$0.key] == 1)
		}
	}

	static func closestKey(in events: [JournalCalendarEvent], at now: Date) -> String? {
		let events = rows(in: events).filter(\.isAvailable).map(\.event)
		let ongoing = events.filter { !$0.isAllDay && $0.startDate <= now && now <= $0.endDate }
		if let current = ongoing.max(by: { $0.startDate < $1.startDate }) { return current.focusKey }
		let timed = events.filter { !$0.isAllDay }
		return (timed.isEmpty ? events : timed).min { distance($0, from: now) < distance($1, from: now) }?.focusKey
	}

	private static func distance(_ event: JournalCalendarEvent, from date: Date) -> TimeInterval {
		if date < event.startDate { return event.startDate.timeIntervalSince(date) }
		if date > event.endDate { return date.timeIntervalSince(event.endDate) }
		return 0
	}
}
