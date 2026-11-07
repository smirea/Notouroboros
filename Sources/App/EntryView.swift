import EventKit
import EventKitUI
import MapKit
import SwiftUI
import UIKit

struct EntryView: View {
	@Environment(\.dismiss) private var dismiss
	@Bindable var store: JournalStore
	let entry: JournalEntry
	@State private var playback = AudioPlayback()
	@State private var presentedCalendarEvent: PresentedCalendarEvent?
	@State private var isMissingCalendarEventAlertPresented = false
	@State private var calendarOpenID = UUID()
	@State private var showsNoteActions = false
	@State private var sharedEntry: JournalEntryExport?
	@State private var entryPendingDeletion: JournalEntry?
	@Namespace private var noteActionsNamespace
	private struct AudioLoadKey: Hashable {
		var url: URL
		var captureActive: Bool
	}

	private var currentEntry: JournalEntry {
		store.entry(id: entry.id) ?? entry
	}

	var body: some View {
		ZStack {
			AppStyle.background.ignoresSafeArea()

			List {
				VStack(alignment: .leading, spacing: 6) {
					HStack(alignment: .firstTextBaseline, spacing: 16) {
						Text(currentEntry.location.map(store.displayName(for:)) ?? "Voice memo")
							.font(.system(size: 25, weight: .semibold))
							.foregroundStyle(.white)
							.lineLimit(1)
							.truncationMode(.tail)
						Spacer(minLength: 0)
						Text(currentEntry.createdAt.compactHeaderText)
							.font(.system(size: 25, weight: .semibold))
							.foregroundStyle(.white)
							.lineLimit(1)
							.fixedSize(horizontal: true, vertical: false)
							.layoutPriority(1)
					}

					if let calendarEvent = currentEntry.calendarEvent {
						Button {
							openCalendarEvent(calendarEvent)
						} label: {
							HStack(spacing: 10) {
								Image(systemName: "calendar")
									.foregroundStyle(AppStyle.accent)
								Text(calendarEvent.title)
									.font(.system(size: 16, weight: .semibold))
									.foregroundStyle(.white)
									.lineLimit(1)
								Spacer(minLength: 0)
							}
							.frame(maxWidth: .infinity, minHeight: 40, alignment: .leading)
							.contentShape(Rectangle())
						}
						.buttonStyle(.plain)
						.accessibilityHint("Opens the event details")
					}
				}
				.padding(.top, 10)
				.entryListRow()

				if store.hasUnsavedChanges(for: entry.id) {
					Button("Note changes not saved. Try Again") {
						Task { await store.retrySavingChanges() }
					}
					.font(.footnote)
					.foregroundStyle(AppStyle.accent)
					.entryListRow()
				}

				if let phase = store.processingPhase(for: entry.id) {
					EntryProcessingStatusView(phase: phase, failure: store.processingFailure(for: entry.id)) {
						store.retryProcessingEntry(id: entry.id)
					}
						.transition(.move(edge: .top).combined(with: .opacity))
						.entryListRow()
				}

				VStack(alignment: .leading, spacing: 16) {
					Text(currentEntry.headline)
						.font(.system(size: 22, weight: .semibold))
						.foregroundStyle(.white)
						.multilineTextAlignment(.center)
						.fixedSize(horizontal: false, vertical: true)
						.frame(maxWidth: .infinity, alignment: .center)

					if store.settings.showModelNames,
						currentEntry.summary?.isEmpty != false,
						let model = currentEntry.summaryModel {
						ModelAttribution(model: model)
					}

					if let audioURL = store.audioURL(for: currentEntry) {
						EntryAudioPlayer(playback: playback, duration: currentEntry.duration)
							.task(id: AudioLoadKey(url: audioURL, captureActive: store.isCapturePriorityActive)) {
								guard !store.isCapturePriorityActive else { return }
								await playback.load(url: audioURL, fallbackDuration: currentEntry.duration)
							}
					}
				}
				.entryListRow()

				if let summary = currentEntry.summary, !summary.isEmpty {
					VStack(alignment: .leading, spacing: 10) {
						Text(summary)
							.font(.system(size: 18, weight: .medium))
							.foregroundStyle(Color.white.opacity(0.94))
							.lineSpacing(5)
							.fixedSize(horizontal: false, vertical: true)

						if store.settings.showModelNames,
							let model = currentEntry.summaryModel {
							ModelAttribution(model: model)
						}
					}
						.entryListRow()
				}

				let taskRows = MemoTasksPresentation.rows(tasks: currentEntry.tasks, delivery: store.taskDeliveries[entry.id],
					remote: store.remoteTasks[entry.id])
				if !taskRows.isEmpty {
					Text("Tasks")
						.font(.footnote.weight(.semibold))
						.foregroundStyle(AppStyle.secondary)
						.accessibilityAddTraits(.isHeader)
						.entryListRow(bottom: 2)
					ForEach(taskRows) { row in
						MemoTaskRowView(row: row)
							.listRowInsets(EdgeInsets(top: 0, leading: 24, bottom: 0, trailing: 24))
							.listRowBackground(AppStyle.background)
							.listRowSeparator(row.id == taskRows.last?.id ? .hidden : .visible)
							.listRowSeparatorTint(Color.white.opacity(0.14))
					}
					let note = MemoTasksPresentation.note(delivery: store.taskDeliveries[entry.id])
					let model = store.settings.showModelNames ? currentEntry.taskModel : nil
					if note != nil || model != nil {
						VStack(alignment: .leading, spacing: 10) {
							if let note {
								Text(note)
									.font(.footnote)
									.foregroundStyle(AppStyle.secondary)
									.fixedSize(horizontal: false, vertical: true)
							}
							if let model { ModelAttribution(model: model) }
						}
						.padding(.top, 6)
						.entryListRow()
					} else {
						Color.clear.frame(height: 22).entryListRow(bottom: 0)
					}
				}

				if store.settings.showTranscripts, !currentEntry.transcript.isEmpty {
					VStack(alignment: .leading, spacing: 12) {
						SummaryToPopup(
							text: currentEntry.transcript,
							accessibilityName: "Transcript"
						)
							.contentTransition(.opacity)

						if store.settings.showModelNames,
							let model = currentEntry.transcriptModel {
							ModelAttribution(model: model)
						}
					}
						.entryListRow()
				}

				if store.settings.showTranscripts, let partial = store.partialTranscript(for: entry.id), !partial.transcript.isEmpty {
					VStack(alignment: .leading, spacing: 10) {
						Text("Incomplete transcript")
							.font(.footnote.weight(.semibold))
							.foregroundStyle(AppStyle.secondary)
						SummaryToPopup(text: partial.transcript, accessibilityName: "Incomplete transcript")
						if store.settings.showModelNames { ModelAttribution(model: partial.modelName) }
					}
					.entryListRow()
				}

				if let location = currentEntry.location {
					EntryLocationMap(store: store, location: location)
						.transition(.move(edge: .bottom).combined(with: .opacity))
						.entryListRow()
				}

				Color.clear
					.frame(height: 64)
					.listRowInsets(EdgeInsets())
					.listRowBackground(AppStyle.background)
					.listRowSeparator(.hidden)
			}
			.listStyle(.plain)
			.scrollContentBackground(.hidden)
			.scrollIndicators(.hidden)
			.environment(\.defaultMinListRowHeight, 0)
		}
		.overlay {
			ZStack(alignment: .bottomLeading) {
				if showsNoteActions {
					Color.clear
						.contentShape(Rectangle())
						.onTapGesture { setNoteActionsPresented(false) }
						.accessibilityHidden(true)
				}

				noteActionsMenu
					.padding(.leading, 20)
					.padding(.bottom, 10)
			}
			.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomLeading)
		}
		.presentationBackground(AppStyle.background)
		.toolbar(.hidden, for: .navigationBar)
		.background(NativeBackSwipeEnabler())
		.animation(.easeOut(duration: 0.22), value: store.processingPhase(for: entry.id))
		.animation(.easeOut(duration: 0.28), value: currentEntry.location)
		.task(id: entry.id) {
			#if DEBUG
			if ProcessInfo.processInfo.arguments.contains("-demo-delete-prompt") { entryPendingDeletion = currentEntry }
			#endif
			if case .blocked = store.taskDeliveries[entry.id] { store.scheduleTaskDelivery(repair: true) }
			await store.refreshRemoteTasks(for: entry.id)
		}
		.onDisappear {
			calendarOpenID = UUID()
			playback.stop()
		}
		.modifier(MemoDeletionConfirmation(store: store, entry: $entryPendingDeletion) { dismiss() })
		.sheet(item: $presentedCalendarEvent) { presentedEvent in
			CalendarEventDetail(event: presentedEvent.event)
		}
		.sheet(item: $sharedEntry) { entry in
			JournalEntryShareSheet(export: entry)
		}
		.alert("Event unavailable", isPresented: $isMissingCalendarEventAlertPresented) {
			Button("OK", role: .cancel) {}
		} message: {
			Text("This exact event occurrence couldn’t be found in its original calendar on this iPhone.")
		}
		.accessibilityAction(.escape) { dismiss() }
	}

	private var noteActionsMenu: some View {
		GlassEffectContainer(spacing: 16) {
			if showsNoteActions {
				noteActionsPanel
					.glassEffect(.regular.interactive(), in: .rect(cornerRadius: 24))
					.glassEffectID("note-actions-panel", in: noteActionsNamespace)
					.glassEffectTransition(.matchedGeometry)
			} else {
				Button {
					setNoteActionsPresented(true)
				} label: {
					Image(systemName: "ellipsis")
						.font(.system(size: 18, weight: .bold))
						.foregroundStyle(.white)
						.frame(width: 50, height: 50)
						.contentShape(Circle())
				}
				.buttonStyle(.plain)
				.glassEffect(.regular.interactive(), in: Circle())
				.glassEffectID("note-actions-button", in: noteActionsNamespace)
				.glassEffectTransition(.matchedGeometry)
				.accessibilityLabel("Note actions")
			}
		}
	}

	private var noteActionsPanel: some View {
		VStack(spacing: 0) {
			Toggle(isOn: showModelNamesBinding) {
				Label("Show Models", systemImage: "apple.intelligence")
					.lineLimit(1)
			}
			.toggleStyle(.switch)
			.controlSize(.small)
			.padding(.horizontal, 16)
			.frame(height: 52)

			Divider()

			Button {
				setNoteActionsPresented(false)
				store.reprocessEntry(id: entry.id)
			} label: {
				Label("Reprocess", systemImage: "dice.fill")
					.frame(maxWidth: .infinity, alignment: .leading)
					.contentShape(Rectangle())
			}
			.buttonStyle(.plain)
			.padding(.horizontal, 16)
			.frame(height: 52)
			.disabled(
				!store.canReprocessEntry(id: entry.id)
					|| store.processingPhase(for: entry.id)?.isActive == true
			)

			Divider()

			Button {
				setNoteActionsPresented(false)
				Task { @MainActor in
					try? await Task.sleep(for: .milliseconds(250))
					do {
						let savedEntry = try await store.committedEntryForExport(id: entry.id)
						sharedEntry = try JournalEntryExport(entry: savedEntry)
					}
					catch { store.storageErrorMessage = "Couldn’t prepare the note for sharing. " + error.localizedDescription }
				}
			} label: {
				Label("Share", systemImage: "square.and.arrow.up")
					.frame(maxWidth: .infinity, alignment: .leading)
					.contentShape(Rectangle())
			}
			.buttonStyle(.plain)
			.padding(.horizontal, 16)
			.frame(height: 52)

			Divider()

			Button(role: .destructive) {
				setNoteActionsPresented(false)
				entryPendingDeletion = currentEntry
			} label: {
				Label("Delete", systemImage: "trash")
					.frame(maxWidth: .infinity, alignment: .leading)
					.contentShape(Rectangle())
			}
			.buttonStyle(.plain)
			.foregroundStyle(.red)
			.padding(.horizontal, 16)
			.frame(height: 52)
		}
		.frame(width: 260)
	}

	private func setNoteActionsPresented(_ isPresented: Bool) {
		withAnimation(.spring(duration: 0.42, bounce: 0.12)) {
			showsNoteActions = isPresented
		}
	}

	private var showModelNamesBinding: Binding<Bool> {
		Binding(
			get: { store.settings.showModelNames },
			set: { store.setShowModelNames($0) }
		)
	}

	private func openCalendarEvent(_ event: JournalCalendarEvent) {
		let requestID = UUID()
		calendarOpenID = requestID
		let resolved = store.calendarSync.resolve(event)
		Task {
			let destination = await CalendarEventNavigation.destination(
				stored: event, resolved: resolved?.snapshot, preferredApp: store.settings.preferredCalendarApp,
				openURL: { await UIApplication.shared.open($0) },
				isCurrent: { calendarOpenID == requestID && store.entry(id: entry.id)?.calendarEvent == event }
			)
			guard !Task.isCancelled, calendarOpenID == requestID, store.entry(id: entry.id)?.calendarEvent == event else { return }
			switch destination {
			case .native:
				if let resolved { presentedCalendarEvent = PresentedCalendarEvent(event: resolved.event) }
			case .unavailable: isMissingCalendarEventAlertPresented = true
			case .provider, .superseded: break
			}
		}
	}
}

private struct JournalEntryShareSheet: UIViewControllerRepresentable {
	let export: JournalEntryExport

	func makeUIViewController(context: Context) -> UIActivityViewController {
		UIActivityViewController(activityItems: [export.fileURL],
			applicationActivities: [CopyJSONTextActivity(jsonText: export.jsonText)])
	}

	func updateUIViewController(
		_ uiViewController: UIActivityViewController,
		context: Context
	) {}
}

private struct JournalEntryExport: Identifiable {
	let id: UUID
	let fileURL: URL
	let jsonText: String

	init(entry: JournalEntry) throws {
		id = entry.id
		let data = try entry.jsonData()
		fileURL = FileManager.default.temporaryDirectory
			.appendingPathComponent("Notouroboros_\(entry.id.uuidString).json")
		jsonText = String(decoding: data, as: UTF8.self)
		try data.write(to: fileURL, options: .atomic)
	}
}

private final class CopyJSONTextActivity: UIActivity {
	private let jsonText: String

	init(jsonText: String) {
		self.jsonText = jsonText
		super.init()
	}

	override class var activityCategory: UIActivity.Category { .action }
	override var activityType: UIActivity.ActivityType? {
		UIActivity.ActivityType("com.stefan.notouroboros.copy-json-text")
	}
	override var activityTitle: String? { "Copy JSON Text" }
	override var activityImage: UIImage? { UIImage(systemName: "doc.on.doc") }

	override func canPerform(withActivityItems activityItems: [Any]) -> Bool {
		true
	}

	override func perform() {
		UIPasteboard.general.string = jsonText
		activityDidFinish(true)
	}
}

private extension View {
	func entryListRow(bottom: CGFloat = 32) -> some View {
		listRowInsets(EdgeInsets(top: 0, leading: 24, bottom: bottom, trailing: 24))
			.listRowBackground(AppStyle.background)
			.listRowSeparator(.hidden)
	}
}

private struct EntryAudioPlayer: View {
	@Bindable var playback: AudioPlayback
	let duration: TimeInterval

	private var shownDuration: TimeInterval {
		playback.duration > 0 ? playback.duration : duration
	}

	private var progress: Double {
		guard shownDuration > 0 else { return 0 }
		return playback.currentTime / shownDuration
	}

	var body: some View {
		HStack(spacing: 12) {
			Button(action: playback.togglePlayback) {
				Image(systemName: playback.isPlaying ? "pause.fill" : "play.fill")
					.font(.system(size: 13, weight: .semibold))
					.foregroundStyle(.white)
					.frame(width: 40, height: 40)
					.background(AppStyle.accent, in: Circle())
			}
			.buttonStyle(.plain)
			.disabled(!playback.isReady)
			.accessibilityLabel(playback.isPlaying ? "Pause recording" : "Play recording")

			ScrubbableWaveform(
				levels: playback.levels,
				progress: progress,
				onSeek: playback.seek
			)
			.frame(height: 38)

			Text(max(0, shownDuration - playback.currentTime).clockText)
				.font(.system(size: 13, weight: .medium, design: .monospaced))
				.monospacedDigit()
				.foregroundStyle(AppStyle.secondary)
				.frame(width: 42, alignment: .trailing)
				.accessibilityLabel("Remaining time")
		}
		.padding(.vertical, 2)
	}
}

private struct ScrubbableWaveform: View {
	let levels: [Double]
	let progress: Double
	let onSeek: (Double) -> Void

	var body: some View {
		GeometryReader { geometry in
			ZStack(alignment: .leading) {
				bars(color: AppStyle.accent.opacity(0.34), width: geometry.size.width)
				bars(color: AppStyle.accent, width: geometry.size.width)
					.mask(alignment: .leading) {
						Rectangle()
							.frame(width: geometry.size.width * max(0, min(1, progress)))
					}
			}
			.contentShape(Rectangle())
			.gesture(
				DragGesture(minimumDistance: 0)
					.onChanged { value in
						guard geometry.size.width > 0 else { return }
						onSeek(value.location.x / geometry.size.width)
					}
			)
		}
		.accessibilityElement()
		.accessibilityLabel("Playback position")
		.accessibilityValue("\(Int(progress * 100)) percent")
		.accessibilityAdjustableAction { direction in
			switch direction {
			case .increment: onSeek(min(1, progress + 0.05))
			case .decrement: onSeek(max(0, progress - 0.05))
			@unknown default: break
			}
		}
	}

	private func bars(color: Color, width: CGFloat) -> some View {
		HStack(spacing: 2) {
			ForEach(Array(levels.enumerated()), id: \.offset) { _, level in
				Capsule()
					.fill(color)
					.frame(
						width: max(1, (width - CGFloat(levels.count - 1) * 2) / CGFloat(levels.count)),
						height: max(3, 34 * level)
					)
			}
		}
		.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
	}
}

private struct ModelAttribution: View {
	let model: String

	var body: some View {
		Text(model)
			.font(.system(size: 12, weight: .medium))
			.foregroundStyle(AppStyle.tertiary)
			.frame(maxWidth: .infinity, alignment: .trailing)
	}
}

private struct PresentedCalendarEvent: Identifiable {
	let id = UUID()
	let event: EKEvent
}

private struct CalendarEventDetail: UIViewControllerRepresentable {
	let event: EKEvent
	@Environment(\.dismiss) private var dismiss

	func makeCoordinator() -> Coordinator {
		Coordinator { dismiss() }
	}

	func makeUIViewController(context: Context) -> UINavigationController {
		let controller = EKEventViewController()
		controller.event = event
		controller.allowsEditing = false
		controller.allowsCalendarPreview = true
		controller.delegate = context.coordinator
		return UINavigationController(rootViewController: controller)
	}

	func updateUIViewController(_ controller: UINavigationController, context: Context) {}

	final class Coordinator: NSObject, EKEventViewDelegate {
		let onDone: () -> Void

		init(onDone: @escaping () -> Void) {
			self.onDone = onDone
		}

		func eventViewController(_ controller: EKEventViewController, didCompleteWith action: EKEventViewAction) {
			onDone()
		}
	}
}

private struct EntryLocationMap: View {
	@Bindable var store: JournalStore
	let location: JournalLocation
	@State private var isEditing = false
	@State private var name = ""
	@State private var address = ""
	@State private var resolvedAddress = ""
	@State private var editedPin: LocationCoordinate
	@State private var editedLocationID: UUID?
	@State private var isSaving = false
	@State private var mapPosition: MapCameraPosition
	@State private var search: MapLocationSearch
	@FocusState private var focusedField: Field?

	private enum Field {
		case address
		case name
	}

	init(store: JournalStore, location: JournalLocation) {
		self.store = store
		self.location = location
		let coordinate = LocationCoordinate(location)
		let namedLocation = store.namedLocation(for: location)
		let pin = namedLocation?.pin ?? coordinate
		_editedPin = State(initialValue: pin)
		_editedLocationID = State(initialValue: namedLocation?.id)
		_mapPosition = State(initialValue: Self.position(for: pin))
		_search = State(initialValue: MapLocationSearch(center: coordinate))
	}

	private var namedLocation: NamedJournalLocation? {
		store.namedLocation(for: location)
	}

	private var shownPin: LocationCoordinate {
		isEditing ? editedPin : namedLocation?.pin ?? LocationCoordinate(location)
	}

	private var shownName: String {
		let editedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
		if isEditing, !editedName.isEmpty {
			return editedName
		}
		return namedLocation?.name ?? location.displayName
	}

	private var coordinate: CLLocationCoordinate2D {
		CLLocationCoordinate2D(latitude: shownPin.latitude, longitude: shownPin.longitude)
	}

	private var nearbyLocations: [NearbyNamedLocation] {
		store.nearbyNamedLocations(to: location, excluding: editedLocationID)
	}

	var body: some View {
		VStack(alignment: .leading, spacing: 13) {
			locationControls

			ZStack {
				Map(
					position: $mapPosition,
					interactionModes: []
				) {
					Marker(shownName, coordinate: coordinate)
						.tint(AppStyle.accent)
				}
				.mapStyle(.standard(elevation: .flat))
				.frame(height: 220)
				.allowsHitTesting(false)

				Button {
					ExternalLinks.openGoogleMaps(coordinate: shownPin)
				} label: {
					Rectangle()
						.fill(.clear)
						.contentShape(Rectangle())
				}
				.buttonStyle(.plain)
				.accessibilityLabel("Open \(shownName) in Google Maps")
			}
		}
		.animation(.snappy(duration: 0.38, extraBounce: 0.04), value: isEditing)
		.animation(.smooth(duration: 0.3), value: shownPin)
	}

	private var locationControls: some View {
		VStack(alignment: .leading, spacing: 12) {
			if isEditing {
				HStack(spacing: 11) {
					Image(systemName: "building.2")
						.foregroundStyle(AppStyle.secondary)
						.frame(width: 20)

					TextField("Address", text: $address)
						.textContentType(.fullStreetAddress)
						.textInputAutocapitalization(.words)
						.submitLabel(.search)
						.focused($focusedField, equals: .address)
						.onChange(of: address) { _, newValue in
							guard focusedField == .address else { return }
							search.search(for: newValue)
						}
						.onSubmit { resolveTypedAddress() }

					if search.isResolving {
						ProgressView()
							.controlSize(.small)
					}
				}
				.transition(.move(edge: .bottom).combined(with: .opacity))

				Divider()
					.overlay(Color.white.opacity(0.18))
					.transition(.opacity)
			}

			HStack(spacing: 11) {
				Image(systemName: "mappin.circle.fill")
					.foregroundStyle(AppStyle.accent)
					.frame(width: 20)
					.contentShape(Rectangle())
					.onTapGesture {
						guard !isEditing else { return }
						beginEditing()
					}
					.accessibilityHidden(true)

				if isEditing {
					TextField("Location name", text: $name)
						.font(.system(size: 17, weight: .semibold))
						.foregroundStyle(AppStyle.accent)
						.textInputAutocapitalization(.words)
						.submitLabel(.done)
						.focused($focusedField, equals: .name)
						.onSubmit { save() }
						.transition(.opacity)

					editorControls
						.transition(.scale(scale: 0.8).combined(with: .opacity))
				} else {
					Button {
						beginEditing()
					} label: {
						Text(shownName)
							.font(.system(size: 17, weight: .semibold))
							.foregroundStyle(AppStyle.accent)
							.contentShape(Rectangle())
					}
					.buttonStyle(.plain)
					.accessibilityHint("Edits this location")
					.transition(.opacity)
				}
			}

			if focusedField == .address, !search.suggestions.isEmpty {
				addressSuggestions
					.transition(.move(edge: .top).combined(with: .opacity))
			}

			if isEditing, !nearbyLocations.isEmpty {
				nearbyLocationList
					.transition(.move(edge: .top).combined(with: .opacity))
			}
		}
	}

	private var editorControls: some View {
		GlassEffectContainer(spacing: 8) {
			HStack(spacing: 8) {
				Button {
					endEditing()
				} label: {
					Image(systemName: "xmark")
						.font(.system(size: 12, weight: .bold))
						.frame(width: 34, height: 34)
						.contentShape(Circle())
				}
				.buttonStyle(.plain)
				.glassEffect(.regular.interactive(), in: Circle())
				.accessibilityLabel("Cancel")

				Button {
					save()
				} label: {
					Image(systemName: "checkmark")
						.font(.system(size: 12, weight: .bold))
						.frame(width: 34, height: 34)
						.contentShape(Circle())
				}
				.buttonStyle(.plain)
				.glassEffect(.regular.interactive(), in: Circle())
				.disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || isSaving)
				.accessibilityLabel("Save location")
			}
		}
	}

	private var addressSuggestions: some View {
		VStack(spacing: 0) {
			ForEach(Array(search.suggestions.enumerated()), id: \.offset) { index, suggestion in
				Button {
					select(suggestion)
				} label: {
					VStack(alignment: .leading, spacing: 3) {
						Text(suggestion.title)
							.font(.system(size: 15, weight: .medium))
							.foregroundStyle(.white)
							.lineLimit(1)
						if !suggestion.subtitle.isEmpty {
							Text(suggestion.subtitle)
								.font(.system(size: 13))
								.foregroundStyle(AppStyle.tertiary)
								.lineLimit(1)
						}
					}
					.frame(maxWidth: .infinity, alignment: .leading)
					.padding(.vertical, 9)
					.contentShape(Rectangle())
				}
				.buttonStyle(.plain)

				if index < search.suggestions.count - 1 {
					Divider()
						.overlay(Color.white.opacity(0.12))
				}
			}
		}
	}

	private var nearbyLocationList: some View {
		VStack(alignment: .leading, spacing: 0) {
			Text("Nearby locations")
				.font(.system(size: 13, weight: .semibold))
				.foregroundStyle(AppStyle.tertiary)
				.padding(.bottom, 4)

			ForEach(Array(nearbyLocations.enumerated()), id: \.element.id) { index, nearby in
				Button {
					withAnimation(.snappy(duration: 0.34)) {
						store.assign(location, to: nearby.id)
						endEditing()
					}
				} label: {
					HStack(spacing: 10) {
						Text(nearby.location.name)
							.font(.system(size: 15, weight: .medium))
							.foregroundStyle(.white)
							.lineLimit(1)

						Spacer(minLength: 12)

						Text("×\(nearby.useCount)")
							.font(.system(size: 13, weight: .medium))
							.foregroundStyle(AppStyle.secondary)
							.monospacedDigit()

						Text(formattedDistance(nearby.distance))
							.font(.system(size: 13))
							.foregroundStyle(AppStyle.tertiary)
							.monospacedDigit()
							.frame(minWidth: 54, alignment: .trailing)
					}
					.frame(maxWidth: .infinity)
					.padding(.vertical, 10)
					.contentShape(Rectangle())
				}
				.buttonStyle(.plain)
				.accessibilityLabel(
					"\(nearby.location.name), used \(nearby.useCount) times, \(formattedDistance(nearby.distance)) away"
				)

				if index < nearbyLocations.count - 1 {
					Divider()
						.overlay(Color.white.opacity(0.12))
				}
			}
		}
	}

	private func beginEditing() {
		let existing = namedLocation
		name = existing?.name ?? ""
		address = existing?.address ?? ""
		resolvedAddress = address
		editedPin = existing?.pin ?? LocationCoordinate(location)
		editedLocationID = existing?.id
		search.clear()
		withAnimation(.snappy(duration: 0.38, extraBounce: 0.04)) {
			isEditing = true
		}
		focusedField = .name

		guard existing?.address == nil else { return }
		Task {
			guard let candidate = await search.reverseGeocode(LocationCoordinate(location)),
				isEditing,
				address.isEmpty
			else { return }
			address = candidate.address
			resolvedAddress = candidate.address
			editedPin = candidate.coordinate
			updateMapPosition()
		}
	}

	private func endEditing() {
		focusedField = nil
		search.clear()
		withAnimation(.snappy(duration: 0.34, extraBounce: 0.02)) {
			isEditing = false
		}
		let pin = namedLocation?.pin ?? LocationCoordinate(location)
		editedPin = pin
		mapPosition = Self.position(for: pin)
	}

	private func select(_ suggestion: MKLocalSearchCompletion) {
		Task {
			guard let candidate = await search.resolve(suggestion), isEditing else { return }
			address = candidate.address
			resolvedAddress = candidate.address
			editedPin = candidate.coordinate
			search.clear()
			focusedField = .name
			updateMapPosition()
		}
	}

	private func resolveTypedAddress() {
		Task {
			if let candidate = await search.resolveAddress(address), isEditing {
				address = candidate.address
				resolvedAddress = candidate.address
				editedPin = candidate.coordinate
				search.clear()
				updateMapPosition()
			}
			focusedField = .name
		}
	}

	private func save() {
		guard !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
			!isSaving
		else { return }
		isSaving = true
		Task {
			let trimmedAddress = address.trimmingCharacters(in: .whitespacesAndNewlines)
			if !trimmedAddress.isEmpty,
				trimmedAddress != resolvedAddress,
				let candidate = await search.resolveAddress(address),
				isEditing {
				address = candidate.address
				resolvedAddress = candidate.address
				editedPin = candidate.coordinate
			}
			guard isEditing else {
				isSaving = false
				return
			}
			store.saveNamedLocation(
				id: editedLocationID,
				name: name,
				address: address,
				pin: editedPin,
				for: location
			)
			isSaving = false
			endEditing()
		}
	}

	private func updateMapPosition() {
		withAnimation(.smooth(duration: 0.35)) {
			mapPosition = Self.position(for: editedPin)
		}
	}

	private func formattedDistance(_ distance: CLLocationDistance) -> String {
		let formatter = MKDistanceFormatter()
		formatter.unitStyle = .abbreviated
		return formatter.string(fromDistance: distance)
	}

	private static func position(for coordinate: LocationCoordinate) -> MapCameraPosition {
		.region(MKCoordinateRegion(
			center: CLLocationCoordinate2D(
				latitude: coordinate.latitude,
				longitude: coordinate.longitude
			),
			latitudinalMeters: 2_400,
			longitudinalMeters: 2_400
		))
	}
}

@MainActor
private enum ExternalLinks {
	static func openGoogleMaps(coordinate location: LocationCoordinate) {
		let coordinate = "\(location.latitude),\(location.longitude)"
		var components = URLComponents(string: "https://www.google.com/maps/search/")
		components?.queryItems = [
			URLQueryItem(name: "api", value: "1"),
			URLQueryItem(name: "query", value: coordinate)
		]
		guard let webURL = components?.url else { return }

		if let appURL = URL(string: "comgooglemaps://?q=\(coordinate)"),
			UIApplication.shared.canOpenURL(appURL) {
			UIApplication.shared.open(appURL) { didOpen in
				guard !didOpen else { return }
				Task { @MainActor in UIApplication.shared.open(webURL) }
			}
			return
		}

		UIApplication.shared.open(webURL)
	}
}

private struct EntryProcessingStatusView: View {
	let phase: EntryProcessingPhase
	let failure: String?
	let retry: () -> Void

	var body: some View {
		VStack(alignment: .leading, spacing: 8) {
			HStack(spacing: 11) {
				Group {
					if phase == .complete { Image(systemName: "checkmark") }
					else if !phase.isActive { Image(systemName: "exclamationmark.circle") }
					else { ProgressView().controlSize(.small) }
				}
				.foregroundStyle(AppStyle.accent)
				.tint(AppStyle.accent)
				.frame(width: 24, height: 30)
				Text(phase.title)
					.font(.system(size: 14, weight: .semibold))
					.foregroundStyle(.white)
				Spacer()
				if !phase.isActive, phase != .complete { Button("Retry", action: retry).font(.subheadline.weight(.semibold)) }
			}
			if let failure { Text(failure).font(.footnote).foregroundStyle(AppStyle.secondary) }
		}
		.padding(.vertical, 4)
	}
}
