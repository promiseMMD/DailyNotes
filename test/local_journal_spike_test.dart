import 'dart:io';

import 'package:dailynotes/src/experimental/local_journal_spike.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

void main() {
  setUpAll(() {
    sqfliteFfiInit();
  });

  late Directory tempDir;
  late String path;
  late LocalJournalSpike journal;

  Future<LocalJournalSpike> openJournal({
    Future<void> Function()? fault,
  }) {
    return LocalJournalSpike.open(
      factory: databaseFactoryFfi,
      path: path,
      clock: () => DateTime.utc(2026, 11, 14, 12),
      afterRevisionWrittenForTest: fault,
    );
  }

  setUp(() async {
    tempDir = await Directory.systemTemp.createTemp('dailynotes-spike-');
    path = '${tempDir.path}/local_spike.db';
    journal = await openJournal();
  });

  tearDown(() async {
    await journal.close();
    await tempDir.delete(recursive: true);
  });

  test('first save atomically creates revision and pending sync intent', () async {
    final saved = await journal.saveDiary(
      entityId: 'diary-1',
      body: '测试记录：中文 + emoji 🌱',
      expectedRevision: 0,
    );

    expect(saved.revision, 1);
    expect((await journal.readDiary('diary-1'))?.body, saved.body);
    final events = await journal.pendingEvents();
    expect(events, hasLength(1));
    expect(events.single.revision, 1);
    expect(events.single.payload['body'], saved.body);
    expect(events.single.operation, 'diary.upsert.spike');
  });

  test('restart-style close and reopen preserves content and unacked outbox', () async {
    await journal.saveDiary(
      entityId: 'reopen-1',
      body: 'The record must survive a DB reopen.',
      expectedRevision: 0,
    );
    await journal.close();
    journal = await openJournal();

    expect((await journal.readDiary('reopen-1'))?.revision, 1);
    expect(await journal.pendingEvents(), hasLength(1));
  });

  test('edits retain immutable earlier revision and ordered outbox', () async {
    await journal.saveDiary(
      entityId: 'diary-edit',
      body: 'first',
      expectedRevision: 0,
    );
    await journal.saveDiary(
      entityId: 'diary-edit',
      body: 'second',
      expectedRevision: 1,
    );
    final now = await journal.readDiary('diary-edit');
    final older = await journal.readRevision('diary-edit', 1);
    final events = await journal.pendingEvents();

    expect(now?.body, 'second');
    expect(now?.revision, 2);
    expect(older?.body, 'first');
    expect(events.map((x) => x.revision), orderedEquals([1, 2]));
    expect(events.map((x) => x.eventKey).toSet(), hasLength(2));
  });

  test('stale caller cannot overwrite a newer revision or append an event', () async {
    await journal.saveDiary(
      entityId: 'diary-conflict',
      body: 'important content',
      expectedRevision: 0,
    );

    await expectLater(
      journal.saveDiary(
        entityId: 'diary-conflict',
        body: 'stale overwrite',
        expectedRevision: 0,
      ),
      throwsA(isA<RevisionMismatch>()),
    );
    expect((await journal.readDiary('diary-conflict'))?.body, 'important content');
    expect(await journal.pendingEvents(), hasLength(1));
  });

  test('fault after revision insert rolls back entity, revision and event', () async {
    await journal.close();
    journal = await openJournal(fault: () async {
      throw StateError('simulated unexpected interruption');
    });
    await expectLater(
      journal.saveDiary(
        entityId: 'faulty',
        body: 'must not be partially committed',
        expectedRevision: 0,
      ),
      throwsA(isA<StateError>()),
    );

    expect(await journal.readDiary('faulty'), isNull);
    expect(await journal.pendingEvents(), isEmpty);

    await journal.close();
    journal = await openJournal();
    expect(await journal.readDiary('faulty'), isNull);
    expect(await journal.pendingEvents(), isEmpty);

    final recovered = await journal.saveDiary(
      entityId: 'faulty',
      body: 'good transaction after recovery',
      expectedRevision: 0,
    );
    expect(recovered.revision, 1);
    expect(await journal.pendingEvents(), hasLength(1));
  });

  test('failed edit rolls back to old revision and original pending events', () async {
    await journal.saveDiary(
      entityId: 'protected',
      body: 'keep',
      expectedRevision: 0,
    );
    await journal.close();
    journal = await openJournal(fault: () async => throw StateError('fault'));

    await expectLater(
      journal.saveDiary(
        entityId: 'protected',
        body: 'not saved',
        expectedRevision: 1,
      ),
      throwsA(isA<StateError>()),
    );
    expect((await journal.readDiary('protected'))?.body, 'keep');
    expect(await journal.readRevision('protected', 2), isNull);
    expect(await journal.pendingEvents(), hasLength(1));
  });

  test('two entries on the same date remain separate by entity identity', () async {
    await journal.saveDiary(
      entityId: 'diary-morning',
      body: 'morning',
      expectedRevision: 0,
    );
    await journal.saveDiary(
      entityId: 'diary-evening',
      body: 'evening',
      expectedRevision: 0,
    );

    expect((await journal.readDiary('diary-morning'))?.body, 'morning');
    expect((await journal.readDiary('diary-evening'))?.body, 'evening');
    expect(await journal.pendingEvents(), hasLength(2));
  });

  test('rejects empty identity and empty text without writing anything', () async {
    await expectLater(
      journal.saveDiary(entityId: '', body: 'text', expectedRevision: 0),
      throwsArgumentError,
    );
    await expectLater(
      journal.saveDiary(entityId: 'diary-empty', body: '  ', expectedRevision: 0),
      throwsArgumentError,
    );
    expect(await journal.pendingEvents(), isEmpty);
  });
}
