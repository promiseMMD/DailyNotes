import 'dart:async';
import 'dart:io';

import 'package:dailynotes/src/experimental/diary_autosave_session.dart';
import 'package:dailynotes/src/experimental/local_journal_spike.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

void main() {
  setUpAll(sqfliteFfiInit);

  late Directory directory;
  late String path;
  late LocalJournalSpike journal;
  final sessions = <ExperimentalDiarySession>[];

  Future<LocalJournalSpike> openJournal({
    Future<void> Function()? fault,
  }) =>
      LocalJournalSpike.open(
        factory: databaseFactoryFfi,
        path: path,
        singleInstance: false,
        afterRevisionWrittenForTest: fault,
      );

  Future<ExperimentalDiarySession> createSession(String entityId) async {
    final session = await ExperimentalDiarySession.open(
      journal: journal,
      entityId: entityId,
    );
    sessions.add(session);
    return session;
  }

  setUp(() async {
    directory = await Directory.systemTemp.createTemp('daily-editor-spike-');
    path = '${directory.path}/editor.db';
    journal = await openJournal();
    sessions.clear();
  });

  tearDown(() async {
    for (final session in sessions) {
      session.dispose();
    }
    await journal.close();
    await directory.delete(recursive: true);
  });

  test('new empty editor is not an automatically-created diary', () async {
    final session = await createSession('new');
    expect(session.phase, ExperimentalSavePhase.untouched);
    expect(session.canLeaveSafely, isTrue);
    expect((await journal.readDiary('new')), isNull);
    expect(await journal.pendingEvents(), isEmpty);
  });

  test('local saved only after transactional body and event commit', () async {
    final arrivedAtFault = Completer<void>();
    final allowCommit = Completer<void>();
    await journal.close();
    journal = await openJournal(fault: () async {
      if (!arrivedAtFault.isCompleted) arrivedAtFault.complete();
      await allowCommit.future;
    });
    final session = await createSession('slow');
    session.changeText('text not yet committed');
    await arrivedAtFault.future;

    expect(session.phase, ExperimentalSavePhase.writing);
    expect(session.savedRevision, 0);
    expect(session.canLeaveSafely, isFalse);

    allowCommit.complete();
    await session.waitForIdle();
    expect(session.phase, ExperimentalSavePhase.savedLocally);
    expect(session.savedRevision, 1);
    expect(session.canLeaveSafely, isTrue);
    expect((await journal.readDiary('slow'))?.body, 'text not yet committed');
    expect(await journal.pendingEvents(), hasLength(1));
  });

  test('rapid editing serializes revisions and ends with latest visible text',
      () async {
    final started = Completer<void>();
    final release = Completer<void>();
    await journal.close();
    journal = await openJournal(fault: () async {
      if (!started.isCompleted) started.complete();
      await release.future;
    });
    final session = await createSession('rapid');
    session.changeText('a');
    await started.future;
    session.changeText('ab');
    session.changeText('abc');
    session.changeText('abcd');

    expect(session.phase, ExperimentalSavePhase.writing);
    expect(session.text, 'abcd');
    release.complete();
    await session.waitForIdle();

    expect(session.phase, ExperimentalSavePhase.savedLocally);
    expect(session.persistedBody, 'abcd');
    expect(session.savedRevision, 2);
    expect((await journal.readRevision('rapid', 1))?.body, 'a');
    expect((await journal.readDiary('rapid'))?.body, 'abcd');
    expect((await journal.pendingEvents()).map((e) => e.revision),
        orderedEquals([1, 2]));
    expect((await journal.auditLocalState()).issues, isEmpty);
  });

  test('a DB exception retains unsaved text; explicit retry commits once',
      () async {
    var shouldFail = true;
    await journal.close();
    journal = await openJournal(fault: () async {
      if (shouldFail) throw StateError('test write failure');
    });
    final session = await createSession('recover');
    session.changeText('important test draft');
    await session.waitForIdle();

    expect(session.phase, ExperimentalSavePhase.failed);
    expect(session.canLeaveSafely, isFalse);
    expect(session.text, 'important test draft');
    expect(session.savedRevision, 0);
    expect(await journal.readDiary('recover'), isNull);
    expect(await journal.pendingEvents(), isEmpty);

    session.changeText('important edited draft');
    await session.waitForIdle();
    expect(session.phase, ExperimentalSavePhase.failed);
    expect(await journal.pendingEvents(), isEmpty); // No hidden retry.

    shouldFail = false;
    await session.retry();
    expect(session.phase, ExperimentalSavePhase.savedLocally);
    expect(session.savedRevision, 1);
    expect((await journal.readDiary('recover'))?.body,
        'important edited draft');
    expect(await journal.pendingEvents(), hasLength(1));
    expect(session.canLeaveSafely, isTrue);
  });

  test('stale concurrent session cannot silently overwrite a newer editor',
      () async {
    final first = await createSession('conflict');
    final second = await createSession('conflict');
    first.changeText('newer editor saved');
    await first.waitForIdle();
    second.changeText('stale text should be protected');
    await second.waitForIdle();

    expect(second.phase, ExperimentalSavePhase.failed);
    expect(second.canLeaveSafely, isFalse);
    expect(second.lastError, isA<RevisionMismatch>());
    expect(second.text, 'stale text should be protected');
    await second.retry(); // Still stale: manual retry does not override.
    expect(second.phase, ExperimentalSavePhase.failed);
    expect((await journal.readDiary('conflict'))?.body,
        'newer editor saved');
    expect(await journal.pendingEvents(), hasLength(1));
  });

  test('empty after saved is blocked, does not delete committed history',
      () async {
    final session = await createSession('dont-delete');
    session.changeText('retain this');
    await session.waitForIdle();
    session.changeText('');
    await session.waitForIdle();

    expect(session.phase, ExperimentalSavePhase.failed);
    expect(session.canLeaveSafely, isFalse);
    expect((await journal.readDiary('dont-delete'))?.body, 'retain this');
    expect((await journal.readRevision('dont-delete', 1))?.body,
        'retain this');
    expect(await journal.pendingEvents(), hasLength(1));
  });

  test('type then revert before pumping does not create phantom record',
      () async {
    final session = await createSession('cancel-before-write');
    session.changeText('intermediate');
    session.changeText('');
    await session.waitForIdle();

    expect(session.phase, ExperimentalSavePhase.untouched);
    expect(session.canLeaveSafely, isTrue);
    expect(await journal.readDiary('cancel-before-write'), isNull);
    expect(await journal.pendingEvents(), isEmpty);
  });

  test('successful diary text restores from disk in a fresh session',
      () async {
    final session = await createSession('persisted');
    session.changeText('a local committed sample');
    await session.waitForIdle();
    expect(session.savedRevision, 1);
    session.dispose();
    sessions.remove(session);
    await journal.close();
    journal = await openJournal();

    final reopened = await createSession('persisted');
    expect(reopened.text, 'a local committed sample');
    expect(reopened.savedRevision, 1);
    expect(reopened.phase, ExperimentalSavePhase.savedLocally);
    expect(reopened.canLeaveSafely, isTrue);
    expect(await journal.pendingEvents(), hasLength(1)); // Still unsynced.
  });
}
