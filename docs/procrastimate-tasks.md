# ProcrastiMate tasks

ProcrastiMate is the source of truth for tasks. This app no longer extracts tasks from memos. Memos that already sent tasks keep showing ProcrastiMate's view of them, and memos with saved but unsent tasks still deliver them; it keeps no reminders of its own. The cross-app contract (routes, shared keychain item, URL schemes, and delete behavior) is decided in ProcrastiMate's `docs/decisions/integrations.md`.

## Data

- `JournalEntry.tasks` holds the memo's `MemoTask`s: a stable `key`, `title`, `notes` (why, with the quoted evidence), `when` (a spoken time copied verbatim from the transcript, or nil), and `event` (a ProcrastiMate `TaskEvent`, or nil). They are part of the exported note.
- `JournalRecord.taskDelivery` is the device-local outbox state: `notExtracted`, `pending(retry:)`, `blocked(notInstalled | signedOut)`, or `delivered([key: server id])`. A delivered receipt with a nil id means ProcrastiMate skipped a key it had already seen.
- `JournalRecord.remoteTasks` caches ProcrastiMate's view from `GET /api/memo-tasks` (title, completion, due, event) for the note screen.

## Retired extraction

On-device extraction (after transcription, then live while recording) was removed. Notes that reached the retired `tasks` or `reminders` processing stages load as complete and are not sent. A note left with unsaved reminder drafts loads with no tasks and `notExtracted`.

## Delivery

The outbox is drained by one worker in `JournalStore`, like the iCloud mirror. For each pending memo it checks `canOpenURL(procrastimate://)` and the shared keychain item (service `procrastimate-link`, account `default`, group `FNYFHG5SV7.com.stefan.shared`), then sends `PUT {apiURL}/api/memo-tasks` with the bearer token and the `notouroboros-<install uuid>` device headers. A transient failure retries after 5 seconds, 30 seconds, and 3 minutes, then on the next foreground visit. A `401` or a missing item blocks the memo as signed out; a missing app blocks it as not installed. Blocked memos are retried at launch, on foreground, and when their note opens. Only `pending` or `blocked` memos enter the outbox. A failed outbox write stops automatic retries until the next foreground visit, and the delivery's background time ends the worker when iOS reclaims it.

Deleting a memo whose tasks ProcrastiMate holds asks whether to delete them too; keeping them is the default. Deleting them calls `DELETE /api/memo-tasks?memoId=` without blocking the memo deletion, and a failure is reported once. The request is not retried after the app exits. A memo deleted while its `PUT` is still in flight is not asked about; its tasks arrive and stay, which is the default choice.
