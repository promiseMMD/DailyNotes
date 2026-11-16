import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:moodiary_data/moodiary_data.dart';
import 'package:moodiary_di/moodiary_di.dart';
import 'package:moodiary_mobile/app/dailynotes/data/daily_notes_store.dart';
import 'package:moodiary_storage/moodiary_storage.dart';
import 'package:moodiary_storage/testing.dart';

void main() {
  late MoodiaryDatabase db;
  late DailyNotesStore store;
  setUpAll(() => getIt.registerSingleton<IKVStorage>(MemoryKVStorage()));
  tearDownAll(() => getIt.reset());
  setUp(() async {
    db = MoodiaryDatabase.forTesting(NativeDatabase.memory());
    store = DailyNotesStore(db, clock: () => DateTime.utc(2026, 11, 15));
    await store.open();
  });
  tearDown(() async {
    store.dispose();
    await db.close();
  });

  test(
    'reopening retains entities, references, task completion and outbox',
    () async {
      final folder = await store.createFolder('Engineering');
      final note = await store.saveNote(
        title: 'Pump',
        body: 'Inspection',
        folderId: folder.id,
        tags: ['maintenance', 'maintenance'],
      );
      final topic = await store.createTopic('Equipment');
      await store.linkNote(note.id, topic.id);
      final task = await store.saveTask(
        title: 'Check pump',
        dueAt: DateTime(2026, 11, 16),
      );
      await store.toggleTask(task.id);
      final reopened = DailyNotesStore(db);
      await reopened.open();
      expect(reopened.notes.single.id, note.id);
      expect(reopened.notes.single.tags, ['maintenance']);
      expect(reopened.notesForTopic(topic.id).single.id, note.id);
      expect(reopened.tasks.single.completed, isTrue);
      expect(reopened.tasks.single.dueAt, DateTime(2026, 11, 16));
      expect(reopened.pendingOperationCount, 6);
      expect(reopened.notes.length, 1);
      reopened.dispose();
    },
  );

  test(
    'outbox failure rolls back business row and never publishes success',
    () async {
      final failing = DailyNotesStore(
        db,
        beforeOutboxWrite: () async {
          throw StateError('simulated_storage_failure');
        },
      );
      await failing.open();
      var notices = 0;
      failing.addListener(() => notices++);
      await expectLater(
        failing.saveNote(title: 'Important', body: 'Unsaved'),
        throwsStateError,
      );
      expect(failing.notes, isEmpty);
      expect(failing.pendingOperationCount, 0);
      expect(notices, 0);
      final rows = await db
          .customSelect('SELECT COUNT(*) AS n FROM dn_records')
          .getSingle();
      final events = await db
          .customSelect('SELECT COUNT(*) AS n FROM dn_outbox')
          .getSingle();
      expect(rows.read<int>('n'), 0);
      expect(events.read<int>('n'), 0);
      failing.dispose();
    },
  );

  test('concurrent creates do not overwrite records or queue events', () async {
    await Future.wait(
      List.generate(
        12,
        (i) => store.saveNote(title: 'Note $i', body: 'Body $i'),
      ),
    );
    expect(store.notes.length, 12);
    expect(store.notes.map((n) => n.id).toSet().length, 12);
    expect(store.pendingOperationCount, 12);
  });

  test(
    'unlink does not delete original and relink uses one relation',
    () async {
      final note = await store.saveNote(title: 'Original', body: 'One body');
      final a = await store.createTopic('A');
      final b = await store.createTopic('B');
      await store.linkNote(note.id, a.id);
      await store.linkNote(note.id, a.id);
      await store.linkNote(note.id, b.id);
      await store.unlinkNote(note.id, a.id);
      expect(store.notes.single.body, 'One body');
      expect(store.notesForTopic(a.id), isEmpty);
      expect(store.notesForTopic(b.id).single.id, note.id);
      await store.linkNote(note.id, a.id);
      final links = await db
          .customSelect('SELECT COUNT(*) AS n FROM dn_links')
          .getSingle();
      expect(links.read<int>('n'), 2);
      expect(store.notesForTopic(a.id).length, 1);
    },
  );

  test(
    'soft delete and restore preserve note body, folder, tags and valid links',
    () async {
      final folder = await store.createFolder('Records');
      final topic = await store.createTopic('References');
      final note = await store.saveNote(
        title: '',
        body: 'Complete original',
        folderId: folder.id,
        tags: ['one', 'two'],
      );
      await store.linkNote(note.id, topic.id);
      await store.deleteNote(note.id);
      expect(store.notes, isEmpty);
      expect(store.deletedNotes.single.body, 'Complete original');
      expect(store.notesForTopic(topic.id), isEmpty);
      await store.restoreNote(note.id);
      await store.restoreNote(note.id);
      expect(store.notes.single.folderId, folder.id);
      expect(store.notes.single.tags, ['one', 'two']);
      expect(store.notesForTopic(topic.id).single.id, note.id);
      expect(store.deletedNotes, isEmpty);
    },
  );

  test(
    'tree restoration preserves structure without restoring trashed notes',
    () async {
      final root = await store.createTopic('Parent');
      final child = await store.createTopic('Child', parentId: root.id);
      final note = await store.saveNote(
        title: 'Source',
        body: 'Still recoverable',
      );
      await store.linkNote(note.id, child.id);
      await store.deleteNote(note.id);
      await store.deleteTopic(root.id);
      expect(store.topics, isEmpty);
      await store.restoreTopic(root.id);
      expect(store.topics.length, 2);
      expect(
        store.topics.singleWhere((t) => t.id == child.id).parentId,
        root.id,
      );
      expect(store.notesForTopic(child.id), isEmpty);
      expect(store.deletedNotes.single.id, note.id);
      await store.restoreNote(note.id);
      expect(store.notesForTopic(child.id).single.id, note.id);
    },
  );

  test(
    'single-node deletion promotes children and safe restore returns them',
    () async {
      final root = await store.createTopic('Parent');
      final child = await store.createTopic('Child', parentId: root.id);
      await store.deleteTopic(root.id, includeChildren: false);
      expect(store.topics.single.parentId, isNull);
      expect(store.topics.single.id, child.id);
      await store.restoreTopic(root.id);
      expect(
        store.topics.singleWhere((t) => t.id == child.id).parentId,
        root.id,
      );
    },
  );

  test(
    'restoring descendant alone falls back to root when parent stays deleted',
    () async {
      final root = await store.createTopic('Parent');
      final child = await store.createTopic('Child', parentId: root.id);
      await store.deleteTopic(root.id);
      await store.restoreTopic(child.id);
      expect(store.topics.single.id, child.id);
      expect(store.topics.single.parentId, isNull);
      expect(store.deletedTopics.single.id, root.id);
    },
  );

  test(
    'draft survives reopening, does not become formal note or sync event',
    () async {
      await store.saveDraft('append:parent', {
        'text': 'Unsubmitted draft',
        'day': '2026-11-15',
      });
      expect(store.notes, isEmpty);
      expect(store.pendingOperationCount, 0);
      final reopened = DailyNotesStore(db);
      await reopened.open();
      expect(reopened.draft('append:parent')?['text'], 'Unsubmitted draft');
      await reopened.removeDraft('append:parent');
      expect(reopened.draft('append:parent'), isNull);
      reopened.dispose();
    },
  );

  test(
    'explicit reset clears extension entities, drafts, relations and queue',
    () async {
      final note = await store.saveNote(
        title: 'Private',
        body: 'Clear with consent',
      );
      final topic = await store.createTopic('Knowledge');
      await store.createFolder('Folder');
      await store.saveTask(title: 'Task');
      await store.linkNote(note.id, topic.id);
      await store.saveDraft('append:private', {'text': 'Private draft'});
      await db.clearAll();
      final reopened = DailyNotesStore(db);
      await reopened.open();
      expect(reopened.notes, isEmpty);
      expect(reopened.tasks, isEmpty);
      expect(reopened.topics, isEmpty);
      expect(reopened.folders, isEmpty);
      expect(reopened.pendingOperationCount, 0);
      expect(reopened.draft('append:private'), isNull);
      final links = await db
          .customSelect('SELECT COUNT(*) AS n FROM dn_links')
          .getSingle();
      expect(links.read<int>('n'), 0);
      reopened.dispose();
    },
  );

  test(
    'invalid parent and empty content cannot create rows or events',
    () async {
      await expectLater(
        store.saveNote(title: ' ', body: '\n'),
        throwsStateError,
      );
      await expectLater(
        store.createTopic('Child', parentId: 'missing'),
        throwsStateError,
      );
      await expectLater(store.saveTask(title: ''), throwsStateError);
      expect(store.pendingOperationCount, 0);
      expect(store.notes, isEmpty);
      expect(store.tasks, isEmpty);
      expect(store.topics, isEmpty);
    },
  );
  test('rich documents persist with their outbox and plain editors cannot overwrite them', () async {
    const doc =
        '{"document":{"type":"page","children":[{"type":"paragraph","data":{"delta":[{"insert":"hello"}]}}]}}';
    final note = await store.saveRichNote(
      title: 'Rich',
      plainText: 'hello',
      documentJson: doc,
      documentVersion: 1,
    );
    final reopened = DailyNotesStore(db);
    await reopened.open();
    expect(reopened.notes.single.documentJson, doc);
    expect(reopened.notes.single.documentVersion, 1);
    expect(reopened.pendingOperationCount, 1);
    await expectLater(
      reopened.saveNote(id: note.id, title: 'Rich', body: 'flattened'),
      throwsStateError,
    );
    expect(reopened.notes.single.documentJson, doc);
    expect(reopened.pendingOperationCount, 1);
    reopened.dispose();
  });

  test('invalid rich data or unknown version never commits', () async {
    await expectLater(
      store.saveRichNote(
        title: 'x',
        plainText: 'x',
        documentJson: '{}',
        documentVersion: 1,
      ),
      throwsFormatException,
    );
    await expectLater(
      store.saveRichNote(
        title: 'x',
        plainText: 'x',
        documentJson: '{"document":{}}',
        documentVersion: 2,
      ),
      throwsStateError,
    );
    expect(store.notes, isEmpty);
    expect(store.pendingOperationCount, 0);
  });
}
