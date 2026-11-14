import 'dart:io';

import 'package:dailynotes/src/experimental/local_journal_spike.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

void main() {
  setUpAll(sqfliteFfiInit);

  late Directory directory;
  late String path;
  late LocalJournalSpike journal;
  DateTime now = DateTime.utc(2026, 11, 14, 2, 0);

  Future<LocalJournalSpike> open() => LocalJournalSpike.open(
        factory: databaseFactoryFfi,
        path: path,
        clock: () => now,
        singleInstance: false,
      );

  setUp(() async {
    directory = await Directory.systemTemp.createTemp('dn-interactions-');
    path = '${directory.path}/preview-v1.db';
    now = DateTime.utc(2026, 11, 14, 2, 0);
    journal = await open();
  });

  tearDown(() async {
    await journal.close();
    await directory.delete(recursive: true);
  });

  test('index exposes only latest committed revision, not all edit history',
      () async {
    await journal.saveDiary(
      entityId: 'entry-A',
      body: 'first draft',
      expectedRevision: 0,
    );
    now = DateTime.utc(2026, 11, 14, 2, 1);
    await journal.saveDiary(
      entityId: 'entry-A',
      body: 'new content',
      expectedRevision: 1,
    );
    now = DateTime.utc(2026, 11, 14, 3, 0);
    await journal.saveDiary(
      entityId: 'entry-B',
      body: 'another diary',
      expectedRevision: 0,
    );

    final all = await journal.listCommittedDiaries();
    expect(all, hasLength(2));
    expect(all.map((e) => e.entityId), orderedEquals(['entry-B', 'entry-A']));
    expect(all[1].revision, 2);
    expect(all[1].body, 'new content');
    expect((await journal.readRevision('entry-A', 1))!.body, 'first draft');
    expect(await journal.pendingEvents(), hasLength(3));
    expect((await journal.auditLocalState()).issues, isEmpty);
  });

  test('index survives SQLite close/reopen; no phantom empty entries',
      () async {
    expect(await journal.listCommittedDiaries(), isEmpty);
    await journal.saveDiary(
      entityId: 'saved',
      body: 'real local test body',
      expectedRevision: 0,
    );
    await journal.close();
    journal = await open();

    final list = await journal.listCommittedDiaries();
    expect(list, hasLength(1));
    expect(list.single.entityId, 'saved');
    expect(list.single.body, 'real local test body');
    expect(list.single.revision, 1);
  });

  test('injected transaction rollback never yields a visible list row',
      () async {
    await journal.close();
    journal = await LocalJournalSpike.open(
      factory: databaseFactoryFfi,
      path: path,
      singleInstance: false,
      afterRevisionWrittenForTest: () async {
        throw StateError('failure before outbox');
      },
    );
    await expectLater(
      journal.saveDiary(
        entityId: 'rollback',
        body: 'not committed',
        expectedRevision: 0,
      ),
      throwsStateError,
    );
    expect(await journal.listCommittedDiaries(), isEmpty);
    expect(await journal.pendingEvents(), isEmpty);
  });

  test('read-only index imposes a bounded page size', () async {
    await expectLater(
      journal.listCommittedDiaries(limit: 0),
      throwsRangeError,
    );
    await expectLater(
      journal.listCommittedDiaries(limit: 1001),
      throwsRangeError,
    );
  });
}
