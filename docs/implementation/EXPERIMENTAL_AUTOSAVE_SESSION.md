# DailyNotes — experimental diary editor autosave round

**Scope:** isolated experimental code; **not connected** to the bottom-bar create action,
not a production editor or ready-to-use diary, and not a change to V2.51.
Implementation branch: `feat/experimental-autosave-session-v0`.

## Why this phase was selected

V2.51 DN-020 and DN-021 confirm automatic local saving without a "complete"
button, successful local commit must precede the message "saved". DN-047
requires visible failure, manual retry, copy fallback and warning before
leaving with unsaved content. DN-148 requires business data and persistent
outbox operation to commit together. The final autosave timing, blank
entry policy, crash-safe draft persistence, physical schema and
distributed conflicts are not confirmed; **none are finalized by this spike**.

## Files and minimal change scope

- `lib/src/experimental/diary_autosave_session.dart`: new state machine
  which serializes committed revisions and preserves the latest in-memory draft.
- `lib/src/experimental/diary_autosave_editor.dart`: independent full-screen
  body-first editor proof with local/cloud status separation, explicit retry,
  copying unsaved text and blocked Back while saving or failed.
- `test/diary_autosave_session_test.dart`: 8 cases.
- `test/diary_autosave_editor_test.dart`: 3 widget cases.
- `.github/workflows/flutter-preview.yml`: additional independent tests.
- **Unchanged:** `lib/src/app.dart`, SQL schema, all existing data, V2.51,
  live navigation, WebDAV, main branch and prior PRs.

## Important state distinctions

- `untouched`: new empty editor, no record created.
- `writing`: at least one unconfirmed local write is outstanding;
  cannot claim it is committed, cannot leave.
- `savedLocally`: latest visible content matches a successfully committed
  SQLite revision; does **not** mean WebDAV synced or backed up.
- `failed`: never silently overwrites/loses the visible in-memory text.
  Stops automatic retries until the user explicitly requests one.
  The user may copy the text; exit is blocked while unsaved.
- Edit during a pending write: the first snapshot completes, newer input
  then generates the next revision; the only "saved" label is for the
  latest visible body. Stale revisions are rejected.

The experimental trigger is to attempt a save on every edit, coalescing
changes arriving while a transaction is pending. **This is not the
approved final debounce/cadence policy.** Empty final drafts are
blocked rather than treated as a delete or an implicitly saved record.

## What tests must prove

1. Empty opening creates no phantom entry.
2. No "saved" label before a gated SQLite transaction commits.
3. Rapid edits preserve final text and ordered, immutable revisions.
4. Injected write error: visible in-memory draft preserved, no partial
   database row or event; retry only when explicitly requested.
5. Stale simultaneous editor session cannot overwrite another version.
6. Empty body after save never accidentally deletes prior history.
7. Type-and-revert before a queued operation starts creates no record.
8. Reopening an actual SQLite file yields the last committed body.
9. Editor UI shows saved/failure and separately shows WebDAV as unsynced;
   unsafe Back is blocked by a warning.
10. Previous SQLite fault/migration tests, UI regression and Android
    debug preview build continue to pass.

## Unresolved P0/P1 blockers (still not production usable)

- **P0** actual app entry and editor binding are intentionally absent;
  no safe real-user write flow and no accepted UI fidelity audit.
- **P0** unsaved drafts remain in volatile memory in this experiment;
  process kill or power loss before commit may lose the last keystrokes.
  Durable draft journal and recovery UX are not implemented.
- **P0** DB corruption, file-system full, low storage, migration from
  release-signed Android data, backup restore and multi-device WebDAV
  still require end-to-end failure injection and device acceptance.
- **P1** autosave debounce, empty note semantics, stable unique ID
  generation, date metadata, conflict resolution UI, and final schema
  remain pending design approval.
- **P1** clipboard copying is a manual escape; it is not backup.
- **P1** explicit safe-leave handling does not override Android process
  termination and cannot guarantee a power-off draft recovery.
- Existing design candidates are still *not approved*, and the
  health-check page must still show "未检查".

Formal delivery still requires all DN-149/DN-152 four phases, zero
unresolved P0/P1 defects, and actual real-device results.
