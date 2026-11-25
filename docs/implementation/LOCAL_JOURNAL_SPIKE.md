# Local transaction + outbox spike (development-only)

Status: **experimental — not connected to the app UI, not approved as final schema, not safe for real personal data**.

## Why this change exists

V2.51 DN-147/DN-148/DN-150 confirm a modular business architecture,
a local transaction coupled to a persistent sync-intent queue, and shared
entity identity with separate business revisions. The final physical
database schema, entity ID format, event protocol and sync lifecycle
are explicitly **pending discussion**; this experiment does not decide them.

This development-only spike uses SQLite's single transaction for:
1. the latest local entity pointer,
2. an append-only diary revision,
3. a pending outbox operation (NOT an already synchronized event).

No public editing screen calls the spike; no WebDAV request, network,
remote acknowledgment, deletion, restore, attachment or encryption is
implemented. Existing UI keeps saying data saving is unavailable.

## Files and blast radius

- `lib/src/experimental/local_journal_spike.dart`: isolated prototype API.
- `test/local_journal_spike_test.dart`: FFI-backed real SQLite-file tests.
- `pubspec.yaml`: SQLite Android plugin and host-test FFI dependencies.
- `.github/workflows/flutter-preview.yml`: fault-injection gate before UI
  widget tests and debug preview build.

No modifications to the user-approved V2.51 requirement text,
visible app pages, current app data or the main branch.

## Intended acceptance evidence

Only after the corresponding GitHub Actions CI is verified:

- Save creates a revision and a pending event together.
- Closing and reopening a SQLite file retains both.
- An edit creates an immutable historical revision and second event.
- Stale revision update is rejected, with original content unaffected.
- Injected exception between revision insert and event insert rolls
  the entire transaction back, for both new and existing entries.
- Two diary entries on the same day remain separate.
- Invalid inputs produce no pending events.
- Existing navigation widget tests and Debug APK build still pass.

These tests show **transaction semantics and reopening**, NOT full
hardware power-loss durability, corruption recovery, OS process-kill
handling, WAL checkpoint validation, encrypted storage, backup
restorability, Android-specific database migration, race behavior
across multiple independent connections or end-to-end auto-save.

## Unresolved P0/P1 acceptance blockers

- Choosing and approving the complete schema and ID protocol;
  managing migrations, process death and database/attachment recovery.
- Wiring actual editor save/error states and unsaved content protection.
- Persistent outbox lifecycle, snapshot/checkpoint/acknowledgement
  rules, remote WebDAV, idempotency, conflicts, device identity,
  tombstones, attachments and restore.
- Backup recovery tests plus four-stage acceptance including
  real Xiaomi Android hardware.
- Nonfatal errors must not be displayed as 'saved' or 'synced'.
- Data health must not display 'healthy' without actual checks.

## Review policy

This is a stand-alone, replaceable prototype on
`feat/local-transaction-spike-v0` derived from the validated UI branch.
It cannot merge as a production persistence implementation until the
spec's unresolved contracts are approved and real-device tests pass.
