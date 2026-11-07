# Notouroboros

Notouroboros is an iPhone voice memo app that records, transcribes, organizes, and carries useful context into upcoming calendar events.

## Goals

1. Record reliably through screen lock, audio-route changes, and interruptions.
2. Preserve audio continuously while recording and recover interrupted sessions.
3. Keep recordings available offline and mirror them to a browsable iCloud Drive folder.

## Features

- Record, pause, resume, and finish voice memos
- Background recording with interruption and microphone-route recovery
- Recording checkpoints and recovery after an interrupted app session
- Live recording state on the Lock Screen and Dynamic Island
- Location, date, and elapsed time in the recording Live Activity
- One-tap Lock Screen recording widget
- Long-form, on-device transcription with live partial results
- Audio playback with waveform scrubbing
- Foundation Models guided titles, summaries for longer recordings, and weekly reviews with explicit incomplete or unavailable outcomes
- Shows a memo's existing ProcrastiMate tasks and keeps or deletes them with the memo (see [ProcrastiMate tasks](docs/procrastimate-tasks.md))
- Model provenance stored with generated content
- Read-only calendar sync with per-calendar inclusion
- Optional calendar-event attachment before recording
- Native note actions for model-label visibility, full reprocessing, and JSON sharing
- Exact calendar occurrence details, with current Google Calendar links for nonrecurring events and native details for recurring instances
- Reverse-chronological timeline, weekly reviews, and recorded locations
- Swipe-to-delete notes with confirmation
- Protected JSON and audio storage
- Browsable audio and metadata pairs in iCloud Drive

## Storage

The app keeps its working data in the private `Application Support/Notouroboros` container for reliable offline recording and playback. It also mirrors every completed recording to `iCloud Drive/Notouroboros` as a matching `.m4a` and `.json` pair named `YYYY-MM-DD_<city>__<UUID>`. The JSON contains the transcript, title, summary, location, attached event, extracted tasks, and model provenance. Existing recordings are backfilled when the app launches. Deleting a note removes both mirrored files; edits made directly to the exports are not imported back into the app.

Mirroring runs off the main actor with one coalescing worker. Each pass indexes the export directory once, writes only changed metadata, and reuses successfully copied audio while repairing missing files. Exact content acknowledgments and successful file signatures persist across restarts. Failed work remains eligible at the same revision with finite persisted backoff, and a foreground visit, account change, or manual retry rechecks it. A resolved city replaces its old export pair only after both new files succeed. Cleanup recognizes generated recording filenames and leaves unrelated files alone. New passes wait while recording has priority. These files are local iCloud provider exports; a completed local write does not establish upload to another device.

Configuration storage distinguishes readable, missing, unavailable, damaged, unsupported, and conflicting data. A readable local `config.json` remains authoritative. First-install changes are saved with their original baseline until discovery can safely restore or conditionally create cloud configuration; an unavailable provider never causes a defaults overwrite. Settings updates apply individual current-value edits, and restoration preserves explicit API-key clearing. Notes export independently of unresolved configuration. See [cloud storage behavior](docs/cloud-storage.md) for commit and provider boundaries.

The local library uses one protected, atomic manifest per recording in `Records/`, with a stable ID assigned before capture begins. Migration preserves the original `entries.json` byte for byte and imports healthy notes individually; damaged records are reported and left untouched. Saves update only changed manifests off the main actor. Deletion intent is persisted before audio cleanup, and failed recording saves retain the audio for retry.

Permanent captures use continuous AAC in an ADTS `.aac` file, so already-written packets remain readable after abrupt process termination. After Finish or recovery, a native background export remuxes AAC into M4A without another lossy encode. Older PCM CAF captures can also be converted. The app validates the output, publishes it, and atomically commits the original note's manifest before removing the source. A failed export or metadata save keeps the source for retry; a restart between publication and manifest commit reuses the validated M4A. Pending source files are playable locally and are not mirrored to iCloud until preparation succeeds. Codec and filesystem buffers can still lose the latest tail of a recording.

Processing is a durable part of each manifest: audio preparation, transcription, and reflection commit their own fields before advancing. A single worker owns the actual stage tasks, and request/attempt/source revisions reject stale results. Incomplete Apple text is stored separately from completed transcripts; failure and cancellation preserve prior completed content. Retry resumes the failed stage, while Reprocess starts a replacement transcription. Local edits retry narrow field changes rather than replaying older copies of the entire note. A failed save does not block another note’s writes or sharing.

Save, Retry, and Reprocess request iOS continued-processing runtime while the app is in the foreground. One system task covers the serial pipeline, reports committed stage progress, and lets it continue after switching apps or locking the screen. A short UIKit assertion bridges execution until extended runtime arrives. Pending work and finite retry dates also schedule a `BGProcessingTask`, registered during app initialization, so iOS can resume saved stages without opening a screen. Expiration checkpoints the stage, cancels its owned work, and releases runtime; existing recording priority and native service quarantine still apply. iOS controls availability and timing, and force-closing the app stops running continued tasks. No always-running thread or server processing is used.

On-device requests account for the runtime context window, instructions, complete prompt, schema, and an output reserve. Native token counting is used on iOS 26.4 and later, with conservative UTF-8 accounting on earlier supported systems. Long reflections cover every ordered passage and reduce the resulting notes until the final request fits; each reduction must become smaller. Completed analysis notes include a versioned source fingerprint and are reused by weekly reviews only while the transcript matches. Failed or incomplete calls never commit a partially processed memo as complete. Every actual model response retains its own deadline and recording cancellation priority.

## Requirements

- Xcode 26 or newer
- iOS 26 or newer
- An iPhone or iPhone Simulator

## Run

Open `Notouroboros.xcodeproj`, select the `Notouroboros` scheme, and run on an iOS 26 iPhone target. Add `-demo` for sample content.

Run the isolated Debug checks on an explicitly selected iOS Simulator:

```sh
python3 Scripts/run-simulator-checks.py --device <SIMULATOR_UUID>
```

The runner builds and installs the app, and checks every registered contract suite. It requires complete success markers and saves build/runtime logs in a new temporary artifact directory. Use `--app /path/to/Notouroboros.app` to reuse an existing Debug Simulator build, or `--list` to validate the check inventory without launching anything.

These checks cover recording and playback ownership, recovery, storage faults, processing cancellation, cloud-provider boundaries, calendar selection, and measured weekly recording time. Synthetic services and temporary storage make them repeatable; passing does not establish microphone hardware reliability, real iCloud upload, calendar-provider behavior, or native model accuracy.

See [testing and visual fixtures](docs/testing.md) for optional process-kill recovery, native Live Activity, model, and screenshot checks. The [reliability review](docs/reliability-review.md) records architectural decisions, measured results, and remaining validation limits.

## TestFlight

The Xcode Cloud `Default` workflow archives every push to `master` and distributes successful builds to the internal `me` testing group. Xcode Cloud manages sequential build numbers.
