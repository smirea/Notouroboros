# ProcrastiMate tasks

ProcrastiMate is the source of truth for tasks. This app finds the to-dos in each memo and sends them there; it keeps no reminders of its own. The cross-app contract (routes, shared keychain item, URL schemes, and delete behavior) is decided in ProcrastiMate's `docs/decisions/integrations.md`.

## Data

- `JournalEntry.tasks` holds the extracted `MemoTask`s: a stable `key`, `title`, `notes` (why, with the quoted evidence), `when` (a spoken time copied verbatim from the transcript, or nil), and `event` (a ProcrastiMate `TaskEvent`, or nil). They are part of the exported note.
- `JournalRecord.taskDelivery` is the device-local outbox state: `notExtracted`, `draft` (found while recording, editable until **Save Reminders**), `pending(retry:)`, `blocked(notInstalled | signedOut)`, or `delivered([key: server id])`. A delivered receipt with a nil id means ProcrastiMate skipped a key it had already seen.
- `JournalRecord.remoteTasks` caches ProcrastiMate's view from `GET /api/memo-tasks` (title, completion, due, event) for the note screen.

## Extraction

Extraction happens only while recording. `LiveReminders` streams the microphone into Apple Speech (`SpeechTranscriber`, or `DictationTranscriber` where it is unavailable) through an `AVAudioEngine` tap beside the file recorder. Each pause in speech, a user pause, and Finish send the text heard since the last look to `TaskEngine` on its own admission lane, since the shared model lane is suspended during capture. Titles already offered, including removed ones, are not offered again. Finish stores the list as `draft`; whatever the last words yield afterwards is appended to the note's drafts. `TaskEngine` sends the passage, or ordered sub-passages when it does not fit the context budget, with the attached event's title and time as context. Validation keeps a task only when its evidence is an exact transcript excerpt and at least half of its title's words come from that evidence, strips self-talk such as "I should" from titles, keeps `when` only as the transcript's own words, drops repeated titles, and never links a task to an event when the memo has none. A linked task becomes a `TaskEvent` the way ProcrastiMate's `CalendarSync.taskEvent` builds one: the series id drops `/RID=`, `next` is the first occurrence after the recording, `every` lists up to 10 upcoming occurrences within 60 days (a repeating event follows its series even when only one occurrence is cached), `original` is the occurrence date in epoch milliseconds, and `before` carries a 60-minute lead.

Reprocessing never extracts. Notes that reached the retired `tasks` or `reminders` processing stages load as complete and are not sent.

## Delivery

The outbox is drained by one worker in `JournalStore`, like the iCloud mirror. For each pending memo it checks `canOpenURL(procrastimate://)` and the shared keychain item (service `procrastimate-link`, account `default`, group `FNYFHG5SV7.com.stefan.shared`), then sends `PUT {apiURL}/api/memo-tasks` with the bearer token and the `notouroboros-<install uuid>` device headers. A transient failure retries after 5 seconds, 30 seconds, and 3 minutes, then on the next foreground visit. A `401` or a missing item blocks the memo as signed out; a missing app blocks it as not installed. Blocked memos are retried at launch, on foreground, and when their note opens. Only saved reminders (`pending` or `blocked`) enter the outbox; drafts never do. A failed outbox write stops automatic retries until the next foreground visit, and the delivery's background time ends the worker when iOS reclaims it.

Deleting a memo whose tasks ProcrastiMate holds asks whether to delete them too; keeping them is the default. Deleting them calls `DELETE /api/memo-tasks?memoId=` without blocking the memo deletion, and a failure is reported once. The request is not retried after the app exits. A memo deleted while its `PUT` is still in flight is not asked about; its tasks arrive and stay, which is the default choice.
