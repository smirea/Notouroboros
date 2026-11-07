# Testing

## Repeatable Simulator checks

Choose a dedicated iOS Simulator from `xcrun simctl list devices available`, then run:

```sh
python3 Scripts/run-simulator-checks.py --device <SIMULATOR_UUID>
```

The Python standard-library runner builds Debug, boots only the requested device when necessary, installs `Notouroboros.app`, and launches with `-demo`. It verifies every registered contract suite in one launch (the waveform flag runs two suites). The manifest in [`Scripts/simulator-checks.json`](../Scripts/simulator-checks.json) must match the app's registered launch hooks, source flags, and full success markers; source drift fails before launch.

`--app /path/to/Notouroboros.app` reuses an existing Debug Simulator build. `--artifacts /new/output/directory` selects a new log directory. `--timeout 180` controls each app run, and `--build-timeout 600` controls the build; both values are seconds. `--list` validates and lists the inventory without using a Simulator.

The runner returns nonzero for a failed command, missing or duplicate success marker, process exit before completion, or deadline. It terminates only this app and its own host subprocesses, with bounded cleanup. It never chooses a device automatically, erases or uninstalls anything, or deletes its artifact directory. The selected Simulator remains booted. Inspect `build.log`, `contracts.log`, and the success-only `summary.json` in the printed artifact directory.

Contracts exercise production logic with fixed inputs, injected service responses, native temporary audio files, and real temporary filesystem faults. They require no microphone, calendar account, or iCloud account. Runtime tokenizer availability is reported separately; passing deterministic model substitutes does not establish native model semantic quality or physical-device performance.

The processing reliability suite also injects background scheduler grants, rejection, and expiration. It checks that extended runtime survives the short UIKit deadline, canceled stages preserve results and retry budgets, scheduled recovery completes the real worker without a foreground visit, task completion happens once, stale launches are rejected, and persisted retry dates replace and coalesce system requests. These checks do not establish native background scheduling availability.

## Visual fixtures

Install a Debug build and launch one fixture on the selected device:

```sh
xcrun simctl launch --terminate-running-process <SIMULATOR_UUID> \
  com.stefan.notouroboros -demo -demo-settings
xcrun simctl io <SIMULATOR_UUID> screenshot /path/to/settings.png
```

All rows below include `-demo`. Use native UI interactions when available to verify navigation, taps, scrolling, and larger text; a launch screenshot alone does not prove those interactions.

| State | Additional launch flags |
| --- | --- |
| Note or recording | `-demo-entry` or `-demo-recording` |
| Note tasks, delivered | `-demo-tasks` |
| Note tasks waiting | `-demo-tasks -demo-tasks-state` plus `pending`, `retry`, `not-installed`, or `signed-out` |
| Delete confirmation with tasks | `-demo-tasks -demo-delete-prompt` |
| Recording after audio reset | `-demo-recording -demo-audio-reset` |
| Audio preparation retry | `-demo-entry -demo-finalization-failed` |
| Incomplete or failed processing | `-demo-entry -demo-processing-partial` or `-demo-entry -demo-processing-failed` |
| Weekly recorded minutes | `-demo-review` |
| Empty week, unavailable analysis, or unreadable library | `-demo-review` plus `-demo-review-empty`, `-demo-review-unavailable`, or `-demo-review-data-unavailable` |
| Settings Calendar heading | `-demo-settings -demo-settings-calendar` |
| Cloud pending or damaged configuration | `-demo-settings` plus `-demo-cloud-pending` or `-demo-configuration-damaged` |
| Two calendar occurrences sharing a native identifier | `-demo-calendar-occurrences`; add `-demo-calendar-ambiguous` for an unavailable group |

The weekly chart uses saved durations grouped by recording date; it is independent of transcript length or model output.

## Seeded memos without a microphone

Debug builds can create a memo from text to run title and summary analysis. Launch without `-demo`:

```sh
xcrun simctl launch --console <SIMULATOR_UUID> com.stefan.notouroboros \
  -seed-memo "Next week before the standup I should bring the release slides." -seed-event-title "Standup"
```

The app prints `SEEDED_MEMO <lowercase id>`. `-seed-event-title` attaches the next cached calendar event with that title, or a synthetic event shaped by `-seed-event-start <ISO 8601>`, `-seed-event-minutes`, and `-seed-event-recurring`. Open a seeded note with `xcrun simctl openurl <SIMULATOR_UUID> "notouroboros://entry?id=<id>"`. ProcrastiMate delivery is covered by the memo task contract suite; `-procrastimate-link` stands in for the shared keychain item there and in Debug launches.

## Optional native checks

On a physical iPhone, save an event-attached recording long enough to exceed the short background grace period, then switch apps or lock the screen. Check the system processing progress and reopen after completion: transcription and title/summary should be saved. Repeat with Apple Speech and ElevenLabs, with a second recording preempting processing, and with cancellation from system progress. Test a transient network failure and a later system-scheduled retry without reopening. Swiping the app away must preserve completed stages for recovery, but cannot guarantee processing while force-closed. Run these checks without an attached debugger, which can prevent normal suspension. iOS decides when deferred recovery runs; Simulator contracts cannot prove these device policies or Foundation Models availability under load.

For an isolated native scheduler smoke check, launch Debug with `-demo -processing-background-native-smoke`. It registers during initialization and requests continued runtime for a synthetic 60-second transcription through the real processing worker, using temporary storage. After `BACKGROUND_NATIVE_GRANTED`, switch apps and look for `BACKGROUND_NATIVE_COMPLETED`. `BACKGROUND_NATIVE_UNAVAILABLE` or `BACKGROUND_NATIVE_INTERRUPTED` does not pass the background test. The iOS 26.5 Simulator returned scheduler error 1 (unavailable) during validation; no native progress screenshot or device completion is claimed.

These checks are separate from the canonical run and report actual system API results. Use a dedicated Simulator and synthetic inputs. They do not prove physical microphone behavior, device power-loss durability, or real cloud transport.

For process-kill recovery, generate a fresh UUID and launch with `-demo -audio-crash-writer <UUID>`. Wait for `AUDIO_CAPTURE_READY`, then kill that launched app process. Relaunch with `-demo -audio-recovery-verify <same-UUID>` and require `AUDIO_RECOVERY_VERIFIED` for that ID. The writer uses native AAC encoding without a microphone. `-audio-publication-writer <new-UUID>` instead emits `AUDIO_PUBLICATION_READY` after M4A publication but before the manifest commit; kill and verify it the same way. Both fixtures use temporary storage. Capture and filesystem buffers can still lose the latest tail.

For native Live Activities, launch with `-demo -recording-activity-native-smoke`. To inspect recording presentation, use `-demo -recording-activity-native-preview running` (also `paused`, `interrupted`, `waiting`, or `stale`) and clean up with `-demo -recording-activity-native-preview-cleanup`. Preview cleanup removes only its fixture activities. For startup orphan cleanup, use `-demo -recording-activity-native-orphan-seed`, terminate the app, and relaunch with `-demo -recording-activity-native-orphan-verify`.

A native recording timer is explicitly estimated and capped at its freshness limit. iOS can delay stale redraws; the next stale rendering uses the exact last-confirmed duration. API request success does not establish update frequency or device background behavior.

The existing model helper builds and queries the first booted iPhone Simulator; keep only the intended Simulator booted when using it:

```sh
Scripts/query-local-model.sh "Explain why the sky is blue in one sentence."
```

Availability, successful generation, and semantic accuracy are separate observations. See the [reliability review](reliability-review.md) for the latest validation evidence and limits.
