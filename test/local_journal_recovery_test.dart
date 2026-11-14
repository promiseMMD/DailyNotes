import 'dart:convert';
import 'dart:io';

import 'package:dailynotes/src/experimental/local_journal_spike.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

/// Frozen V1 fixture: do not alter when changing the experimental V2 schema.
Future<void> seedV1(String path) async {
  final db = await databaseFactoryFfi.openDatabase(
    path,
    options: OpenDatabaseOptions(
      version: 1,
      singleInstance: false,
      onConfigure: (db) async => db.execute('PRAGMA foreign_keys=ON'),
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
  FOREIGN KEY(entity_id, revision) REFERENCES diary_revisions(entity_id, revision)
)''');
      },
    ),
  );
  const stamp = '2026-11-14T12:00:00.000Z';
  await db.transaction((tx) async {
    await tx.insert('entities', {
      'id': 'legacy', 'kind': 'diary', 'revision': 1,
      'created_utc': stamp, 'modified_utc': stamp,
    });
    await tx.insert('diary_revisions', {
      'entity_id': 'legacy', 'revision': 1,
      'body': 'old preserved body', 'saved_utc': stamp,
    });
    await tx.insert('local_outbox', {
      'event_key': 'diary:legacy:1', 'entity_id': 'legacy',
      'revision': 1, 'operation': 'diary.upsert.spike',
      'payload_json': jsonEncode({
        'entityId': 'legacy', 'revision': 1, 'body': 'old preserved body',
        'savedUtc': stamp,
      }),
      'created_utc': stamp, 'state': 'pending',
    });
  });
  await db.close();
}

void main() {
  setUpAll(sqfliteFfiInit);
  late Directory directory;
  late String path;
  LocalJournalSpike? opened;

  Future<LocalJournalSpike> openSpike({
    Future<void> Function()? failMigration,
  }) async {
    final j = await LocalJournalSpike.open(
      factory: databaseFactoryFfi,
      path: path,
      singleInstance: false,
      afterMigrationMarkerForTest: failMigration,
    );
    opened = j;
    return j;
  }

  Future<Database> raw() => databaseFactoryFfi.openDatabase(
    path, options: OpenDatabaseOptions(singleInstance: false),
  );

  setUp(() async {
    directory = await Directory.systemTemp.createTemp('daily-recovery-');
    path = '${directory.path}/journal.db';
  });

  tearDown(() async {
    await opened?.close();
    await directory.delete(recursive: true);
  });

  test('new V2 database has migration evidence, no fabricated data', () async {
    final j = await openSpike();
    expect((await j.auditLocalState()).issues, isEmpty);
    final db = await raw();
    expect(await db.getVersion(), 2);
    expect((await db.query('spike_migration_evidence')).single['marker'], 'created_v2');
    await db.close();
  });

  test('upgrade V1->V2 preserves old body and pending outbox exactly once', () async {
    await seedV1(path);
    final j = await openSpike();
    expect((await j.readDiary('legacy'))?.body, 'old preserved body');
    expect((await j.pendingEvents()).single.eventKey, 'diary:legacy:1');
    expect((await j.auditLocalState()).issues, isEmpty);
    final db = await raw();
    expect(await db.getVersion(), 2);
    expect((await db.query('spike_migration_evidence')).single['marker'],
        'upgraded_v1_to_v2');
    await db.close();

    await j.close();
    opened = null;
    final again = await openSpike();
    expect(await again.pendingEvents(), hasLength(1));
    final v2 = await again.saveDiary(
      entityId: 'legacy', body: 'new data', expectedRevision: 1,
    );
    expect(v2.revision, 2);
    expect((await again.readRevision('legacy', 1))?.body, 'old preserved body');
    expect(await again.pendingEvents(), hasLength(2));
  });

  test('interrupted migration is atomic and safe to retry', () async {
    await seedV1(path);
    await expectLater(
      LocalJournalSpike.open(
        factory: databaseFactoryFfi,
        path: path,
        singleInstance: false,
        afterMigrationMarkerForTest: () async => throw StateError('migrate fault'),
      ),
      throwsA(isA<StateError>()),
    );
    final db = await raw();
    expect(await db.getVersion(), 1);
    expect(await db.rawQuery(
      "SELECT name FROM sqlite_master WHERE name='spike_migration_evidence'",
    ), isEmpty);
    expect((await db.query('diary_revisions')).single['body'], 'old preserved body');
    expect(await db.query('local_outbox'), hasLength(1));
    await db.close();

    final recovered = await openSpike();
    expect((await recovered.readDiary('legacy'))?.body, 'old preserved body');
    expect(await recovered.pendingEvents(), hasLength(1));
  });

  test('two independent connections reject an obsolete editor version', () async {
    final first = await openSpike();
    final second = await LocalJournalSpike.open(
      factory: databaseFactoryFfi, path: path, singleInstance: false,
    );
    try {
      await first.saveDiary(
        entityId: 'dual', body: 'editor one', expectedRevision: 0,
      );
      await expectLater(
        second.saveDiary(
          entityId: 'dual', body: 'stale overwrite', expectedRevision: 0,
        ),
        throwsA(isA<RevisionMismatch>()),
      );
      expect((await second.readDiary('dual'))?.body, 'editor one');
      await second.saveDiary(
        entityId: 'dual', body: 'editor two using new revision',
        expectedRevision: 1,
      );
      expect((await first.readRevision('dual', 1))?.body, 'editor one');
      expect((await first.readDiary('dual'))?.revision, 2);
      expect(await first.pendingEvents(), hasLength(2));
      expect((await first.auditLocalState()).issues, isEmpty);
    } finally {
      await second.close();
    }
  });

  test('audit detects missing outbox without silently repairing anything', () async {
    final j = await openSpike();
    await j.saveDiary(entityId: 'missing', body: 'keep', expectedRevision: 0);
    final db = await raw();
    await db.delete('local_outbox', where: 'entity_id=?', whereArgs: ['missing']);
    await db.close();
    final audit = await j.auditLocalState();
    expect(audit.isInternallyConsistent, isFalse);
    expect(audit.issues.join(' '), contains('Missing outbox'));
    expect((await j.readDiary('missing'))?.body, 'keep');
    expect(await j.pendingEvents(), isEmpty);
  });

  test('audit detects modified payload and retains original revision', () async {
    final j = await openSpike();
    await j.saveDiary(entityId: 'payload', body: 'keep', expectedRevision: 0);
    final db = await raw();
    await db.update('local_outbox',
      {'payload_json': '{"entityId":"payload","revision":1,"body":"wrong"}'},
      where: 'entity_id=?', whereArgs: ['payload']);
    await db.close();
    final audit = await j.auditLocalState();
    expect(audit.isInternallyConsistent, isFalse);
    expect(audit.issues.join(' '), contains('Payload mismatch'));
    expect((await j.readDiary('payload'))?.body, 'keep');
    expect((await j.pendingEvents()).single.payload['body'], 'wrong');
  });

  test('audit detects a dangling current revision pointer', () async {
    final j = await openSpike();
    await j.saveDiary(entityId: 'head', body: 'keep', expectedRevision: 0);
    final db = await raw();
    await db.update('entities', {'revision': 777},
        where: 'id=?', whereArgs: ['head']);
    await db.close();
    final audit = await j.auditLocalState();
    expect(audit.isInternallyConsistent, isFalse);
    expect(audit.issues.join(' '), contains('current revision'));
  });
}
