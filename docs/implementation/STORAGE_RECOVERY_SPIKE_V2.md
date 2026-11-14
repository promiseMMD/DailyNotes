# DailyNotes storage recovery experiment — round 2

**Status:** isolated laboratory prototype, **NOT** a production database schema,
not connected to the UI, not safe for personal diary data. Based on V2.51:
DN-020/021/047 (save-state correctness), DN-147/148/150 (local transaction
and revision intent), DN-149/152 (four-stage verification gates).
This document does not amend or silently finalize those requirements.

## Change impact (minimal)

- Changed `lib/src/experimental/local_journal_spike.dart` only inside the
  experimental module: add a V2 additive migration marker; provide a
  read-only evidence-only consistency audit; allow isolated multi-connection
  tests. The existing V1 tables and operation payload are untouched.
- Added `test/local_journal_recovery_test.dart` with **frozen V1 SQL fixture**
  and 7 focused tests (migration, failed migration, reopen, two independent
  connections, missing outbox, payload modification, broken head pointer).
- Added a separate migration/recovery test gate to CI.
- `lib/src/app.dart` is unchanged; all real editing, saving, backup and
  WebDAV actions remain disabled. Neither main branch nor the V2.51
  specification has been changed.

## Deliberate V1 → V2 experiment

The only added table is `spike_migration_evidence` holding a schema
version marker. V1's `entities`, `diary_revisions` and `local_outbox`
are preserved verbatim. The upgrade callback runs inside sqflite's
migration transaction, so a deliberately injected exception must leave
V1 rows, outbox and `user_version` intact; retry can then migrate cleanly.

An "upgrade was successful" marker does **not** prove user backups,
hardware durability, plaintext encryption or production schema suitability.

## Read-only consistency checks

The isolated `auditLocalState()` reports:
- SQLite quick structural check and foreign-key errors
- Entity current head not pointing to a revision
- Missing/duplicate per-revision local outbox operations
- Outbox identity, operation and JSON payload mismatch versus history

It **must not** silently modify, repair, delete, resynchronize or announce
"healthy" in the app. A passing report covers only those local checks,
not deleted bytes, external backup integrity or hardware power cuts.

## Stale editors and concurrent sessions

The two-connection test uses `singleInstance: false` only in the test:
a writer with a stale expected revision must fail rather than overwrite
a newer revision; subsequent changes using the correct expected revision
append both history and a pending outbox event.

**Important remaining gap:** sequential operations on two connections do
not simulate two truly simultaneous transactions, multiple Android
processes, many independent devices, lock contention, WAL checkpoint
failure or retry scheduling.

## Acceptance criteria for this phase

- Frozen V1 fixture can migrate to V2 without changing old user body/history
  or duplicating the previously pending outbox event.
- Failed migration rolls back schema/version/data, and retry succeeds.
- Independently opened database sessions reject stale edits.
- Artificial missing outbox, corrupt payload and broken current pointer
  are reported, not repaired.
- Original local fault-injection tests and Widget tests still pass.
- Full Flutter analyze and Android debug build succeed.
- GitHub CI run and exact final commit SHA are recorded before reporting done.

## Remaining P0/P1 issues

1. Final data model/IDs/indexes and migration policy remain **unapproved**.
2. Reliable autosave with visible success/failure, editor draft fallback and
   exit protection are not yet implemented.
3. OS process-kill, real power interruption, corruption and real-device
   crash recovery need dedicated fault injection and device acceptance.
4. Real SQLite encryption, attachment lifecycle, WebDAV incremental sync,
   remote checkpoints, version conflicts, tombstones and restorative backup
   testing are unimplemented.
5. This audit is not wired to the visible "Data health check" page; the page
   remains correctly labeled "未检查".

**Do not merge as production persistence. Do not use important personal data.**
