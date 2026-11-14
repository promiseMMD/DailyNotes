import 'dart:convert';

import 'package:sqflite_common/sqlite_api.dart';

/// Experimental, isolated persistence proof for DN-147, DN-148 and DN-150.
/// No UI references this module. The schema and IDs are NOT approved contracts.
class LocalJournalSpike {
  LocalJournalSpike._(this._db, this._clock, this._afterRevisionWritten);

  final Database _db;
  final DateTime Function() _clock;
  final Future<void> Function()? _afterRevisionWritten;

  /// Caller owns the database file path and factory. Opens a single connection.
  ///
  /// [afterRevisionWrittenForTest] injects failure *within* a transaction
  /// after content was staged but before the corresponding outbox event.
  /// [afterMigrationMarkerForTest] simulates a failure in v1 -> v2 migration.
  /// Only isolated tests should set [singleInstance] to false.
  static Future<LocalJournalSpike> open({
    required DatabaseFactory factory,
    required String path,
    DateTime Function()? clock,
    Future<void> Function()? afterRevisionWrittenForTest,
    Future<void> Function()? afterMigrationMarkerForTest,
    bool singleInstance = true,
  }) async {
    final db = await factory.openDatabase(
      path,
      options: OpenDatabaseOptions(
        version: 2,
        singleInstance: singleInstance,
        onConfigure: (db) async {
          await db.execute('PRAGMA foreign_keys = ON');
        },
        onCreate: (db, version) async {
          await db.execute('''
CREATE TABLE entities (
  id TEXT PRIMARY KEY,
  kind TEXT NOT NULL CHECK(kind = 'diary'),
  revision INTEGER NOT NULL CHECK(revision > 0),
  created_utc TEXT NOT NULL,
  modified_utc TEXT NOT NULL
)''');
          await db.execute('''
CREATE TABLE diary_revisions (
  entity_id TEXT NOT NULL,
  revision INTEGER NOT NULL CHECK(revision > 0),
  body TEXT NOT NULL,
  saved_utc TEXT NOT NULL,
  PRIMARY KEY(entity_id, revision),
  FOREIGN KEY(entity_id) REFERENCES entities(id)
)''');
          await db.execute('''
CREATE TABLE local_outbox (
  sequence INTEGER PRIMARY KEY AUTOINCREMENT,
  event_key TEXT NOT NULL UNIQUE,
  entity_id TEXT NOT NULL,
  revision INTEGER NOT NULL,
  operation TEXT NOT NULL,
  payload_json TEXT NOT NULL,
  created_utc TEXT NOT NULL,
  state TEXT NOT NULL DEFAULT 'pending' CHECK(state = 'pending'),
  FOREIGN KEY(entity_id, revision)
    REFERENCES diary_revisions(entity_id, revision)
)''');
          await _createMigrationEvidence(db, 'created_v2');
        },
        onUpgrade: (db, oldVersion, newVersion) async {
          if (oldVersion != 1 || newVersion != 2) {
            throw StateError('Unsupported experimental migration: $oldVersion -> $newVersion');
          }
          // sqflite invokes onUpgrade inside a transaction.
          await _createMigrationEvidence(db, 'upgraded_v1_to_v2');
          if (afterMigrationMarkerForTest != null) {
            await afterMigrationMarkerForTest();
          }
        },
      ),
    );
    return LocalJournalSpike._(
      db,
      clock ?? DateTime.now,
      afterRevisionWrittenForTest,
    );
  }

  static Future<void> _createMigrationEvidence(DatabaseExecutor db, String marker) async {
    // Additive probe only: existing entities/revisions/outbox remain untouched.
    await db.execute('''
CREATE TABLE spike_migration_evidence (
  marker TEXT PRIMARY KEY,
  schema_version INTEGER NOT NULL CHECK(schema_version = 2)
)''');
    await db.insert('spike_migration_evidence', {
      'marker': marker,
      'schema_version': 2,
    });
  }

  /// Persists a *complete* diary body as a new local revision.
  ///
  /// The entity state, immutable revision and pending event MUST commit
  /// together. The caller must provide an expected revision; stale editors
  /// cannot silently overwrite newer text.
  ///
  /// No network I/O or sync acknowledgement occurs here.
  Future<DiaryVersion> saveDiary({
    required String entityId,
    required String body,
    required int expectedRevision,
  }) async {
    if (entityId.trim().isEmpty) {
      throw ArgumentError.value(entityId, 'entityId', 'must not be empty');
    }
    if (body.trim().isEmpty) {
      throw ArgumentError.value(body, 'body', 'empty drafts are not handled by this spike');
    }
    if (expectedRevision < 0) {
      throw ArgumentError.value(expectedRevision, 'expectedRevision');
    }

    final timestamp = _clock().toUtc().toIso8601String();

    return _db.transaction<DiaryVersion>((txn) async {
      final current = await txn.query(
        'entities',
        columns: ['revision', 'kind'],
        where: 'id = ?',
        whereArgs: [entityId],
        limit: 1,
      );

      final actualRevision =
          current.isEmpty ? 0 : current.single['revision'] as int;
      if (actualRevision != expectedRevision) {
        throw RevisionMismatch(expectedRevision, actualRevision);
      }

      final nextRevision = actualRevision + 1;
      if (current.isEmpty) {
        await txn.insert('entities', {
          'id': entityId,
          'kind': 'diary',
          'revision': nextRevision,
          'created_utc': timestamp,
          'modified_utc': timestamp,
        });
      } else {
        if (current.single['kind'] != 'diary') {
          throw StateError('Entity type mismatch');
        }
        final updated = await txn.update(
          'entities',
          {'revision': nextRevision, 'modified_utc': timestamp},
          where: 'id = ? AND revision = ?',
          whereArgs: [entityId, actualRevision],
        );
        if (updated != 1) {
          throw RevisionMismatch(expectedRevision, actualRevision);
        }
      }

      await txn.insert('diary_revisions', {
        'entity_id': entityId,
        'revision': nextRevision,
        'body': body,
        'saved_utc': timestamp,
      });

      // Deliberately injectable only for the fault-injection test.
      if (_afterRevisionWritten != null) {
        await _afterRevisionWritten();
      }

      // No remote event is sent here; this is strictly a durable local queue.
      await txn.insert('local_outbox', {
        'event_key': 'diary:$entityId:$nextRevision',
        'entity_id': entityId,
        'revision': nextRevision,
        'operation': 'diary.upsert.spike',
        'payload_json': jsonEncode({
          'entityId': entityId,
          'revision': nextRevision,
          'body': body,
          'savedUtc': timestamp,
        }),
        'created_utc': timestamp,
        'state': 'pending',
      });

      return DiaryVersion(
        entityId: entityId,
        revision: nextRevision,
        body: body,
        savedUtc: timestamp,
      );
    });
  }

  /// Returns the latest committed revision, or null for an unknown entry.
  Future<DiaryVersion?> readDiary(String entityId) async {
    final rows = await _db.rawQuery('''
SELECT r.entity_id, r.revision, r.body, r.saved_utc
FROM diary_revisions r
JOIN entities e ON e.id = r.entity_id AND e.revision = r.revision
WHERE r.entity_id = ?''', [entityId]);
    if (rows.isEmpty) return null;
    return _versionFromRow(rows.single);
  }

  /// Reads an older revision without mutating the current record.
  Future<DiaryVersion?> readRevision(String entityId, int revision) async {
    final rows = await _db.query(
      'diary_revisions',
      where: 'entity_id = ? AND revision = ?',
      whereArgs: [entityId, revision],
    );
    if (rows.isEmpty) return null;
    return _versionFromRow(rows.single);
  }

  /// Ordered by DB sequence, independent of repeated timestamps.
  Future<List<PendingLocalEvent>> pendingEvents() async {
    final rows = await _db.query(
      'local_outbox',
      where: 'state = ?',
      whereArgs: ['pending'],
      orderBy: 'sequence ASC',
    );
    return rows
        .map(
          (r) => PendingLocalEvent(
            eventKey: r['event_key'] as String,
            entityId: r['entity_id'] as String,
            revision: r['revision'] as int,
            operation: r['operation'] as String,
            payload: jsonDecode(r['payload_json'] as String)
                as Map<String, dynamic>,
          ),
        )
        .toList(growable: false);
  }

  /// Read-only consistency evidence, NEVER a claim that a backup is restorable.
  /// Runs without repair, mutations or networking. Callers must not treat a
  /// clean result as proof against power loss, filesystem errors or corruption.
  Future<SpikeAuditResult> auditLocalState() async {
    final issues = <String>[];
    final integrity = await _db.rawQuery('PRAGMA quick_check');
    if (integrity.length != 1 || integrity.first.values.first != 'ok') {
      issues.add('SQLite quick_check failed');
    }
    final foreignKeys = await _db.rawQuery('PRAGMA foreign_key_check');
    if (foreignKeys.isNotEmpty) {
      issues.add('Broken foreign key references: ${foreignKeys.length}');
    }

    final missingHeads = await _db.rawQuery('''
SELECT e.id
FROM entities e LEFT JOIN diary_revisions r
  ON r.entity_id = e.id AND r.revision = e.revision
WHERE r.entity_id IS NULL''');
    if (missingHeads.isNotEmpty) {
      issues.add('Entity current revision has no historical row');
    }

    final rows = await _db.rawQuery('''
SELECT r.entity_id, r.revision, r.body, r.saved_utc,
       o.event_key, o.operation, o.payload_json
FROM diary_revisions r
LEFT JOIN local_outbox o
  ON o.entity_id = r.entity_id AND o.revision = r.revision
ORDER BY r.entity_id, r.revision''');

    final seenRevisions = <String>{};
    for (final row in rows) {
      final id = row['entity_id'] as String;
      final revision = row['revision'] as int;
      final key = '$id:$revision';
      if (!seenRevisions.add(key)) {
        issues.add('Duplicate outbox operation for revision $key');
      }
      if (row['event_key'] == null) {
        issues.add('Missing outbox operation for revision $key');
        continue;
      }
      if (row['event_key'] != 'diary:$id:$revision' ||
          row['operation'] != 'diary.upsert.spike') {
        issues.add('Unexpected outbox identity or operation for $key');
      }
      try {
        final parsed = jsonDecode(row['payload_json'] as String);
        if (parsed is! Map<String, dynamic> ||
            parsed['entityId'] != id ||
            parsed['revision'] != revision ||
            parsed['body'] != row['body'] ||
            parsed['savedUtc'] != row['saved_utc']) {
          issues.add('Payload mismatch for $key');
        }
      } catch (_) {
        issues.add('Invalid outbox JSON for $key');
      }
    }

    return SpikeAuditResult(
      revisionCount: seenRevisions.length,
      issues: List.unmodifiable(issues),
    );
  }

  DiaryVersion _versionFromRow(Map<String, Object?> row) {
    return DiaryVersion(
      entityId: row['entity_id'] as String,
      revision: row['revision'] as int,
      body: row['body'] as String,
      savedUtc: row['saved_utc'] as String,
    );
  }

  Future<void> close() => _db.close();
}

/// Limited, experimental, read-only audit; not the production data-health UI.
class SpikeAuditResult {
  const SpikeAuditResult({required this.revisionCount, required this.issues});

  final int revisionCount;
  final List<String> issues;
  bool get isInternallyConsistent => issues.isEmpty;
}

class DiaryVersion {
  const DiaryVersion({
    required this.entityId,
    required this.revision,
    required this.body,
    required this.savedUtc,
  });

  final String entityId;
  final int revision;
  final String body;
  final String savedUtc;
}

class PendingLocalEvent {
  const PendingLocalEvent({
    required this.eventKey,
    required this.entityId,
    required this.revision,
    required this.operation,
    required this.payload,
  });

  final String eventKey;
  final String entityId;
  final int revision;
  final String operation;
  final Map<String, dynamic> payload;
}

class RevisionMismatch implements Exception {
  const RevisionMismatch(this.expected, this.actual);

  final int expected;
  final int actual;

  @override
  String toString() =>
      'RevisionMismatch(expected: $expected, actual: $actual)';
}
