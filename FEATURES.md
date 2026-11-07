> Keep one concise bullet for every user-visible feature and interaction. This file is the app's behavioral contract: review it whenever the app changes so existing interactions and specific behaviors are not accidentally lost or broken. Keep it brief and avoid implementation details or precise styling.

# General

- Supports only the latest iOS and uses native interactions and components where possible.
- Uses a consistent dark interface, saturated blue accent, and Liquid Glass controls.
- Never places content in decorative background boxes; uses spacing, typography, alignment, and dividers for hierarchy.
- Uses native horizontal back navigation wherever a back button is hidden.
- Loads local note metadata without blocking the interface, preserves damaged originals, and keeps readable notes available while reporting storage problems.
- Stores notes and audio locally for offline use and includes them in device backups. Transient stage failures become eligible for retry after 1, 5, and 15 minutes, then wait for manual Retry; unavailable services and unreadable audio wait for manual Retry immediately.
- Saving, Retry, and Reprocess request continued processing when started in the foreground, with native system progress while transcription and analysis continue after switching apps or locking the screen. Interrupted work also requests an automatic background retry when iOS grants time, and resumes on reopening; force-closing the app stops current processing, and background completion timing depends on iOS. Canceling system progress preserves the audio and completed stages.
- Mirrors completed recordings to `iCloud Drive/Notouroboros` as matching `YYYY-MM-DD_<city>__<UUID>.m4a` and `.json` files, backfills existing notes, and replaces temporary `Unknown` city names only after the new pair is complete. Skips unchanged exports, checks missing or failed exports again on foreground, and defers new export passes during recording.
- Stores app settings, named locations, and API keys in a versioned, backed-up `config.json` and mirrors it beside iCloud Drive exports. A readable local configuration stays authoritative; first-install edits remain saved locally while restoration is pending and are retained when remote configuration arrives, including an explicitly cleared API key.
- Preserves unreadable local configuration and leaves damaged, unsupported, or conflicting remote configuration unresolved during first-install restoration, instead of replacing it with defaults. Notes and recording remain available independently; Settings reports pending exports or configuration problems with a retry action.
- Remembers completed exports and pending deletions across restarts, retries transient iCloud failures after 5 seconds, 30 seconds, and 3 minutes, then waits for a change, foreground visit, account change, or manual retry. A local iCloud export does not claim upload to other devices.
- Treats local data as authoritative: iCloud note exports are not imported, and deleting a note removes its local audio and exports. A failed deletion keeps the note available to retry; pending audio cleanup retries on launch without restoring deliberately deleted notes.
- Reports unsaved note changes with a persistent retry action. A failed note save does not block saving or sharing other notes. iCloud exports use saved metadata, and sharing waits for that note’s changes to save.
- Stores each note's transcript, title, summary, location, attached event, tasks, and model provenance in its JSON export.
- Prefers ElevenLabs transcription when enabled and reachable while Apple Speech supplies live partials and automatic fallback, and alerts when ElevenLabs could not be used; titles, summaries, and weekly reviews remain on-device and address the note owner as **you**.
- Saves processing progress per note and resumes the unfinished stage after a restart. Keeps completed transcript and analysis during reprocessing, labels incomplete transcript text, and offers Retry for failed stages without treating partial results as complete.
- Processes long transcripts in ordered, bounded passages that cover the complete input. A failed passage keeps prior completed results and offers Retry.
- Gives recording priority over transcription and on-device analysis, including weekly reviews. Optional work pauses through recording interruptions and user pauses, then resumes after capture stops; timed-out native work cannot overlap its replacement.
- Generates summaries only for recordings longer than 20 seconds.
- Never extracts reminders or tasks from memos.
- Tasks a memo already sent to ProcrastiMate, the source of truth for tasks, stay there; this app keeps no reminders of its own. Tasks saved but not yet sent retry after 5 seconds, 30 seconds, and 3 minutes, then on the next foreground visit, and wait while ProcrastiMate is missing or signed out.
- Reprocessing never sends tasks again.
- Captures each recording's original coordinates and city when available, then resolves shared place names using the behavior in [`docs/location-model.md`](docs/location-model.md).
- Silently refreshes and caches included events from one month ago through three months ahead when the app opens or returns to the foreground, at most once per day, without changing calendar data.

# Home Screen

- Shows the current date, Settings, and all notes in a continuously scrolling reverse-chronological list.
- Each note shows its date, time, duration, title, and any active processing status; tapping it opens the **Note Screen**.
- Swiping a note left reveals a trash button; tapping it requires deletion confirmation. When ProcrastiMate holds the note's tasks, the confirmation keeps them by default and offers deleting them too; the note is deleted either way and a failed task deletion is reported.
- Shows an empty state when there are no notes.
- Floating Review and Record buttons open their respective screens.

# Record Screen

- Opens event setup instantly from Home using cached events, with a tappable date and the included events for that day in chronological order.
- Explains and disables event attachment when Calendar sync is off or the selected day has no events.
- Selects an ongoing timed event by default, otherwise the event closest to the current time.
- Turning **Attached to event** off clears, shrinks, and dims the list; tapping an event selects that exact occurrence for the new note, including repeated events sharing an identifier. Ambiguous occurrences are unavailable; recording waits for a valid selection or attachment to be turned off.
- Start Recording begins with the selected event attached; a widget launch starts immediately without setup.
- Shows an error and returns home when recording cannot start.
- Records without a fixed time limit and shows a live waveform, elapsed time, pause/resume, finish, and discard controls.
- Finishing opens the **Note Screen** only after the note is saved; a failed save preserves the audio and allows Finish to be retried. Discarding returns Home only after deletion is saved; a failed discard keeps the stopped audio and controls available to retry or finish.
- Opening a note link while recording keeps the recording on screen; only an explicit discard deletes active audio, and discarding during microphone permission prevents recording from starting later.
- Recording controls provide haptic feedback when enabled in Settings.
- Continues with the screen locked or app backgrounded, pauses for audio interruptions, and recovers from route changes when the microphone becomes available.
- Distinguishes interrupted or unavailable input from a user pause; Pause cancels automatic recovery, and recording failures freeze elapsed time instead of appearing to keep recording.
- After an audio-system reset or encoder failure, keeps the captured audio available to finish, disables Resume for that recording, allows the screen to sleep, and uses a fresh recorder for the next one.
- Preserves audio continuously for crash recovery under the same note identity, including after an abrupt app exit; the latest buffered audio may be lost. Captures location without blocking recording.
- Prepares finished audio in the background for standard M4A playback and export, keeps the original until preparation is safely saved, and retains failed preparation for automatic or manual Reprocess retry.

# Note Screen

- Has no visible back button and uses the native leading-edge back swipe. `notouroboros://entry?id=<uuid>` opens a note, with the UUID in either case, as ProcrastiMate's task links do.
- Shows a saved place name or the captured city with the compact date, truncating long names; without location it shows `Voice memo` and omits the map.
- Shows an attached event below the header with a calendar icon.
- Tapping an attached event resolves the exact occurrence in its original calendar; missing or ambiguous events show an unavailable message. Uses a current provider link for nonrecurring events when preferred, with native detail as fallback; recurring events use native detail because attached links may target the whole series.
- Shows the generated title, processing status, and audio controls with waveform progress and remaining time; playback stops on exit.
- Prepares the waveform without delaying playback, reuses recently viewed waveforms, and pauses waveform work while recording or after leaving a note.
- Playback pauses for interruptions or disconnected outputs, waits for an explicit Play afterward, and restores its position without autoplay after an audio-system reset.
- Keeps playback position when audio preparation finishes, continues only if playback was still active, and shows a retry status instead of a progress spinner when preparation fails.
- Shows a short generated summary for recordings longer than 20 seconds and attributes the analysis model below the summary or title.
- When a note has tasks in ProcrastiMate, a Tasks section below the summary lists them, plus `Could save these todos if you also had ProcrastiMate.` when ProcrastiMate is missing or a sign-in note when it is signed out. After delivery it shows ProcrastiMate's title, done state, and due date, refreshed each time the note opens; tapping a task opens it in ProcrastiMate.
- A bottom-left glass button morphs into note actions that persist **Show Models** app-wide with the whole toggle row tappable, reprocess the saved audio through transcription and all generated analysis even after leaving the note while safely queuing other reprocesses, share complete metadata as a `.json` file with a separate **Copy JSON Text** action, and delete the note with the same confirmation as Home.
- When enabled in Settings, shows a four-line transcript preview and its transcription model.
- Tapping the transcript opens a selectable full-screen reader with Copy, Close, and native back-swipe controls.
- Shows the resolved place above a noninteractive Apple map; tapping only its label morphs it into an inline name editor with an editable Apple Maps address and autocomplete.
- The location editor lists other named places within 10 miles alphabetically with note counts and distance; selecting one assigns this note coordinate to that place.
- Saved place names apply to notes within 200 meters, while the selected address controls the map pin and Google Maps destination.
- Tapping anywhere on the map opens the resolved pin in the Google Maps app, with Google Maps web as a fallback.

# Review Screen

- Generates the current week's review on open, showing a loading state followed by the week, title, and reflection; interrupted or unavailable analysis shows a retry action while keeping the recording metric visible.
- Charts actual minutes from available saved recordings for each of the week’s seven local calendar days, including zero days, with day labels and a numerical scale. Each recording’s full duration is grouped by its recording date; unavailable local data is reported instead of shown as a zero week.
- Builds reviews from dated analysis notes covering each memo, reusing saved notes only when their source transcript still matches, and combines large weeks in bounded stages.
- Uses the standard back button and native back swipe to return home.

# Settings Screen

- Opens as a sheet, applies and saves changes immediately, reads current settings after restoration, reports save failures with a retry action, and dismisses with Done. Section headings scroll with their controls without covering them.
- Controls screen wake while recording, recording haptics, transcript visibility, and the default-on ElevenLabs transcription preference.
- Stores an optional ElevenLabs API key in `config.json` and prefers it over the bundled fallback.
- Calendar sync requests Full Access for read-only event access and lets each calendar be included or excluded.
- Calendar settings can prefer direct Google Calendar links, with an exact native event view as fallback.
- Delete All Entries requires confirmation and removes every note, recording, and iCloud Drive export; if a deletion fails, reports it in Settings and retains the affected notes for retry.

# Lock Screen and Dynamic Island

- A Lock Screen circular microphone widget opens the app and starts a recording.
- When permitted, recording shows a Live Activity with the app icon, location, date, capture state, and elapsed time; recording starts independently of Live Activity availability.
- Paused, interrupted, and unavailable-input states freeze the displayed time. Running time is marked as an estimate and stops at a fixed freshness limit; iOS can delay refreshing an expired activity’s status. When refreshed, stale content shows the last confirmed duration and asks you to open the app.
- Finishing, discarding, or a recording failure ends its Live Activity with a frozen final duration. Reopening the app clears activities left by a previous process.
- Tapping a recording Live Activity returns to an active recording or opens its saved or recovered note. An old activity never starts a new recording.
