import AVFoundation
import Foundation
import Observation
import Speech
import os

private let logger = Logger(subsystem: "com.stefan.notouroboros", category: "LiveReminders")

/// Streams the microphone into Apple Speech alongside the file recorder. It is best effort: when speech is unavailable
/// the recording continues without live reminders.
@MainActor
final class LiveSpeechListener {
	/// Built when capture starts: its input is unusable before the recorder activates the audio session.
	private var engine: AVAudioEngine?
	private var analyzer: SpeechAnalyzer?
	private var analyzerFormat: AVAudioFormat?
	private var input: AsyncStream<AnalyzerInput>.Continuation?
	private var results: Task<Void, Never>?
	private var configurationObserver: Task<Void, Never>?
	private var wantsAudio = false
	/// Finish or cancel can land while `start` awaits speech assets; whatever `start` builds afterwards is discarded.
	private var isClosed = false

	/// `onPhrase` receives each finalized phrase. Apple Speech finalizes at pauses in speech.
	func start(onPhrase: @escaping @MainActor (String) -> Void) async throws {
		let module: any SpeechModule
		let phrases: @MainActor () async throws -> Void
		if SpeechTranscriber.isAvailable, let locale = await SpeechTranscriber.supportedLocale(equivalentTo: .current) {
			let transcriber = SpeechTranscriber(locale: locale, transcriptionOptions: [], reportingOptions: [], attributeOptions: [])
			module = transcriber
			phrases = { for try await result in transcriber.results { Self.deliver(result.text, to: onPhrase) } }
		} else if let locale = await DictationTranscriber.supportedLocale(equivalentTo: .current) {
			let transcriber = DictationTranscriber(locale: locale, preset: .longDictation)
			module = transcriber
			phrases = { for try await result in transcriber.results { Self.deliver(result.text, to: onPhrase) } }
		} else {
			logger.notice("Live reminders are off: Apple Speech is unavailable for this locale")
			return
		}
		if let installation = try await AssetInventory.assetInstallationRequest(supporting: [module]) {
			try await installation.downloadAndInstall()
		}
		guard let format = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [module]) else {
			logger.notice("Live reminders are off: no audio format for Apple Speech")
			return
		}
		let (stream, continuation) = AsyncStream.makeStream(of: AnalyzerInput.self)
		let analyzer = SpeechAnalyzer(modules: [module])
		try await analyzer.start(inputSequence: stream)
		guard !isClosed else {
			continuation.finish()
			await analyzer.cancelAndFinishNow()
			return
		}
		self.analyzer = analyzer
		analyzerFormat = format
		input = continuation
		results = Task {
			do { try await phrases() } catch { logger.error("Live speech ended: \(error.localizedDescription)") }
		}
		configurationObserver = Task { [weak self] in
			for await notification in NotificationCenter.default.notifications(named: .AVAudioEngineConfigurationChange) {
				guard let self, (notification.object as AnyObject?) === self.engine else { continue }
				self.restartAudio()
			}
		}
		restartAudio()
	}

	private static func deliver(_ text: AttributedString, to onPhrase: @MainActor (String) -> Void) {
		let phrase = String(text.characters)
		if !phrase.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { onPhrase(phrase) }
	}

	func setCapturing(_ capturing: Bool) {
		guard capturing != wantsAudio else { return }
		wantsAudio = capturing
		if capturing {
			restartAudio()
		} else {
			stopAudio()
			// Without more audio, Apple Speech would hold the last words until capture resumes.
			if let analyzer { Task { try? await analyzer.finalize(through: nil) } }
		}
	}

	func finish() async {
		isClosed = true
		stopAudio()
		configurationObserver?.cancel()
		input?.finish()
		input = nil
		try? await analyzer?.finalizeAndFinishThroughEndOfInput()
		await results?.value
		analyzer = nil
	}

	func cancel() {
		isClosed = true
		stopAudio()
		configurationObserver?.cancel()
		input?.finish()
		input = nil
		results?.cancel()
		if let analyzer { Task { await analyzer.cancelAndFinishNow() } }
		analyzer = nil
	}

	/// Route changes alter the input format, so the engine, tap, and converter are rebuilt on every start.
	private func restartAudio() {
		stopAudio()
		guard wantsAudio, let input, let analyzerFormat else { return }
		let engine = AVAudioEngine()
		self.engine = engine
		let node = engine.inputNode
		let format = node.outputFormat(forBus: 0)
		guard format.sampleRate > 0, let converter = AVAudioConverter(from: format, to: analyzerFormat) else { return }
		node.installTap(onBus: 0, bufferSize: 4_096, format: format, block: Self.tap(converter: converter, to: analyzerFormat, input: input))
		engine.prepare()
		do { try engine.start() } catch {
			logger.error("Live reminders could not listen: \(error.localizedDescription)")
			node.removeTap(onBus: 0)
		}
	}

	private func stopAudio() {
		guard let engine else { return }
		self.engine = nil
		engine.stop()
		engine.inputNode.removeTap(onBus: 0)
	}

	/// Runs on the realtime audio thread, so it must not inherit main-actor isolation.
	private nonisolated static func tap(converter: AVAudioConverter, to format: AVAudioFormat,
		input: AsyncStream<AnalyzerInput>.Continuation) -> AVAudioNodeTapBlock {
		return { buffer, _ in
			let ratio = format.sampleRate / buffer.format.sampleRate
			let capacity = AVAudioFrameCount((Double(buffer.frameLength) * ratio).rounded(.up)) + 1
			guard let output = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: capacity) else { return }
			nonisolated(unsafe) var consumed = false
			var error: NSError?
			converter.convert(to: output, error: &error) { _, status in
				if consumed { status.pointee = .noDataNow; return nil }
				consumed = true
				status.pointee = .haveData
				return buffer
			}
			if error == nil, output.frameLength > 0 { input.yield(AnalyzerInput(buffer: output)) }
		}
	}
}

/// Reminders found in a recording as it happens. Each pause in speech is a natural point to look at what was said since
/// the last look. Before Finish the list is the record screen's; after, new finds go to the saved note's drafts.
@MainActor
@Observable
final class LiveReminders {
	private(set) var items: [MemoTask] = []
	@ObservationIgnored private let event: JournalCalendarEvent?
	@ObservationIgnored private let calendar: [JournalCalendarEvent]
	@ObservationIgnored private let recordedAt = Date.now
	@ObservationIgnored private let listener = LiveSpeechListener()
	@ObservationIgnored private var unexamined = ""
	/// Folded titles already offered, including removed ones, so a removed reminder is not offered again.
	@ObservationIgnored private var offered = Set<String>()
	@ObservationIgnored private var pause: Task<Void, Never>?
	@ObservationIgnored private var examination: Task<Void, Never>?
	@ObservationIgnored private var deliver: (@MainActor ([MemoTask]) -> Void)?
	@ObservationIgnored private var isHandedOff = false
	/// Finds that arrive between the hand-off and the saved note's id.
	@ObservationIgnored private var late: [MemoTask] = []
	@ObservationIgnored private var isCanceled = false

	init(event: JournalCalendarEvent?, calendar: [JournalCalendarEvent]) {
		self.event = event
		self.calendar = calendar
	}

	func start() {
		Task {
			#if DEBUG
			if let phrases = Self.debugPhrases {
				for phrase in phrases {
					try? await Task.sleep(for: .seconds(2))
					guard !isCanceled else { return }
					hear(phrase)
				}
				return
			}
			#endif
			do { try await listener.start { self.hear($0) } }
			catch { logger.error("Live reminders could not start: \(error.localizedDescription)") }
		}
	}

	func setCapturing(_ capturing: Bool) {
		listener.setCapturing(capturing)
		if !capturing { examineNow() }
	}

	/// The list to save with the note. From here on new finds wait for `finish` instead of joining the list.
	func handOff() -> [MemoTask] {
		isHandedOff = true
		items += late
		late = []
		return items
	}

	/// Whatever the last words still yield is added to the saved note's drafts.
	func finish(deliveringLateFinds deliver: @escaping @MainActor ([MemoTask]) -> Void) {
		self.deliver = deliver
		if !late.isEmpty { deliver(late) }
		late = []
		Task {
			await listener.finish()
			examineNow()
		}
	}

	func cancel() {
		isCanceled = true
		listener.cancel()
		pause?.cancel()
		examination?.cancel()
	}

	func remove(_ key: UUID) {
		items.removeAll { $0.key == key }
	}

	func rename(_ key: UUID, to title: String) {
		guard let index = items.firstIndex(where: { $0.key == key }) else { return }
		items[index].title = title
		offered.insert(title.foldedWords)
	}

	private func hear(_ phrase: String) {
		guard !isCanceled else { return }
		unexamined += unexamined.isEmpty ? phrase : " " + phrase
		pause?.cancel()
		pause = Task {
			try? await Task.sleep(for: .seconds(1.5))
			guard !Task.isCancelled else { return }
			examineNow()
		}
	}

	/// Examinations run one at a time so each passage is looked at once and in order.
	private func examineNow() {
		pause?.cancel()
		let passage = unexamined.trimmingCharacters(in: .whitespacesAndNewlines)
		guard !passage.isEmpty, !isCanceled else { return }
		unexamined = ""
		let previous = examination
		let event = event, calendar = calendar, recordedAt = recordedAt
		examination = Task {
			await previous?.value
			let result = await Self.extract(passage, event: event, recordedAt: recordedAt, calendar: calendar)
			logger.debug("Examined \(passage.count) characters: \(result.tasks.count) reminders, \(String(describing: result.outcome))")
			guard !isCanceled else { return }
			let found = result.tasks.filter { offered.insert($0.title.foldedWords).inserted }
			guard !found.isEmpty else { return }
			if let deliver { deliver(found) } else if isHandedOff { late += found } else { items += found }
		}
	}

	private nonisolated static func extract(_ passage: String, event: JournalCalendarEvent?, recordedAt: Date,
		calendar: [JournalCalendarEvent]) async -> TaskExtractionResult {
		#if DEBUG
		if let fixture = MemoSeed.fixtureTaskServices(transcript: passage) {
			return await TaskEngine.extract(transcript: passage, event: event, recordedAt: recordedAt, calendar: calendar,
				modelIsAvailable: { true }, services: fixture)
		}
		#endif
		return await TaskEngine.extract(transcript: passage, event: event, recordedAt: recordedAt, calendar: calendar)
	}

	#if DEBUG
	/// `-live-transcript "First phrase|Second phrase"` stands in for the microphone, one phrase every two seconds.
	private static var debugPhrases: [String]? {
		let arguments = ProcessInfo.processInfo.arguments
		guard let index = arguments.firstIndex(of: "-live-transcript"), arguments.indices.contains(index + 1) else { return nil }
		return arguments[index + 1].split(separator: "|").map(String.init)
	}
	#endif
}
