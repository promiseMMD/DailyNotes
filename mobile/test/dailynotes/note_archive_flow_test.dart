import 'dart:async';
import 'dart:convert';

import 'package:appflowy_editor/appflowy_editor.dart';
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:moodiary_data/moodiary_data.dart';
import 'package:moodiary_di/moodiary_di.dart';
import 'package:moodiary_i18n/moodiary_i18n.dart';
import 'package:moodiary_mobile/app/dailynotes/data/daily_notes_store.dart';
import 'package:moodiary_mobile/app/dailynotes/navigation/daily_notes_archive_page.dart';
import 'package:moodiary_mobile/app/dailynotes/navigation/daily_notes_drawer.dart';
import 'package:moodiary_mobile/app/dailynotes/notes/notes_page.dart';
import 'package:moodiary_mobile/app/dailynotes/notes/rich_note_editor_page.dart';
import 'package:moodiary_storage/moodiary_storage.dart';
import 'package:moodiary_storage/testing.dart';
import 'package:mui/mui.dart';

Widget _app(Widget home) => TranslationProvider(
  child: MaterialApp(
    theme: buildMuiTheme(brightness: Brightness.light),
    localizationsDelegates: const [
      AppFlowyEditorLocalizations.delegate,
      ...GlobalMaterialLocalizations.delegates,
      GlobalMuiLocalizations.delegate,
    ],
    builder: (context, child) => MaterialUiCompatibilityBridge(child: child!),
    home: home,
  ),
);

Future<void> _menu(WidgetTester tester) async {
  await tester.tap(find.byKey(const ValueKey('note-document-more')));
  await tester.pumpAndSettle();
}

Future<void> _archiveAction(WidgetTester tester) async {
  await _menu(tester);
  await tester.tap(find.byKey(const ValueKey('note-document-archive')));
  await tester.pumpAndSettle();
}

Future<void> _unlock(WidgetTester tester) async {
  await tester.tap(find.byTooltip('解锁编辑'));
  await tester.pumpAndSettle();
}

class _DelayedStore extends DailyNotesStore {
  _DelayedStore(super.database);
  final gate = Completer<void>();
  int archiveRequests = 0;

  @override
  Future<void> setNoteArchived(String id, {required bool archived}) async {
    archiveRequests++;
    await gate.future;
    await super.setNoteArchived(id, archived: archived);
  }
}

void main() {
  setUpAll(() async {
    getIt.registerSingleton<IKVStorage>(MemoryKVStorage());
    await setupPluralResolvers();
    await LocaleSettings.setLocale(AppLocale.zh);
  });
  tearDownAll(() => getIt.reset());

  testWidgets('archive from note, browse folder and restore nearest path', (
    tester,
  ) async {
    final db = MoodiaryDatabase.forTesting(NativeDatabase.memory());
    final store = DailyNotesStore(db);
    await store.open();
    final root = await store.createFolder('Projects');
    final child = await store.createFolder('2026', parentId: root.id);
    await store.createFolder('No archived notes');
    final topic = await store.createTopic('Reference');
    final source = EditorState(
      document: Document(
        root: pageNode(children: [paragraphNode(text: 'original text')]),
      ),
    );
    final document = jsonEncode(source.document.toJson());
    source.dispose();
    final note = await store.saveRichNote(
      title: 'Child note',
      plainText: 'original text',
      documentJson: document,
      documentVersion: 1,
      folderId: child.id,
    );
    final retained = await store.saveNote(
      title: 'Root archived',
      body: 'root',
      folderId: root.id,
    );
    await store.setNoteArchived(retained.id, archived: true);
    await store.saveNote(title: 'Normal note', body: 'normal');
    await store.linkNote(note.id, topic.id);
    final pending = store.pendingOperationCount;
    final shell = GlobalKey<ScaffoldState>();
    await tester.binding.setSurfaceSize(const Size(430, 900));
    addTearDown(() async {
      await tester.pumpWidget(const SizedBox());
      store.dispose();
      await db.close();
      await tester.binding.setSurfaceSize(null);
    });
    await tester.pumpWidget(
      _app(
        Scaffold(
          key: shell,
          drawer: DailyNotesDrawer(store: store),
          body: DailyNotesNotesPage(store: store),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('Child note'), findsOneWidget);
    expect(find.text('Root archived'), findsNothing);
    await tester.tap(find.text('Child note'));
    await tester.pumpAndSettle();
    await _menu(tester);
    expect(
      tester
          .widget<SimpleDialogOption>(
            find.byKey(const ValueKey('note-document-archive')),
          )
          .onPressed,
      isNull,
    );
    await tester.binding.handlePopRoute();
    await tester.pumpAndSettle();
    await _unlock(tester);
    final editor = tester
        .widget<AppFlowyEditor>(find.byType(AppFlowyEditor))
        .editorState;
    editor.selection = Selection.single(
      path: [0],
      startOffset: 0,
      endOffset: 4,
    );
    await tester.pumpAndSettle();
    final selection = editor.selection;
    await _archiveAction(tester);
    expect(find.byType(RichNoteEditorPage), findsOneWidget);
    expect(store.isNoteArchived(note.id), isTrue);
    expect(
      tester.widget<AppFlowyEditor>(find.byType(AppFlowyEditor)).editorState,
      same(editor),
    );
    expect(editor.selection, selection);
    expect(
      store.notes.firstWhere((n) => n.id == note.id).documentJson,
      document,
    );
    expect(store.topicsForNote(note.id).single.id, topic.id);
    expect(store.pendingOperationCount, pending);
    await tester.binding.handlePopRoute();
    await tester.pumpAndSettle();
    expect(find.text('Child note'), findsNothing);
    expect(find.text('Normal note'), findsOneWidget);
    shell.currentState!.openDrawer();
    await tester.pumpAndSettle();
    await tester.tap(find.text('归档管理'));
    await tester.pumpAndSettle();
    expect(find.byType(DailyNotesArchivePage), findsOneWidget);
    expect(find.text('日记'), findsOneWidget);
    expect(find.text('长期记录'), findsOneWidget);
    await tester.tap(find.text('日记'));
    await tester.pumpAndSettle();
    expect(find.text('此类记录的归档尚未开放。'), findsOneWidget);
    await tester.tap(find.text('笔记'));
    await tester.pumpAndSettle();
    expect(find.text('No archived notes'), findsNothing);
    await tester.tap(find.byKey(ValueKey('archive-folder-${root.id}')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('知识库'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('普通笔记'));
    await tester.pumpAndSettle();
    expect(find.byKey(ValueKey('archive-folder-${child.id}')), findsOneWidget);
    expect(
      find.byKey(ValueKey('archive-folder-note-${retained.id}')),
      findsOneWidget,
    );
    await tester.tap(find.byKey(ValueKey('archive-folder-${child.id}')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(ValueKey('archive-folder-note-${note.id}')));
    await tester.pumpAndSettle();
    await _unlock(tester);
    await _menu(tester);
    expect(find.text('取消归档'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('note-document-archive')));
    await tester.pumpAndSettle();
    expect(find.byType(RichNoteEditorPage), findsOneWidget);
    expect(store.isNoteArchived(note.id), isFalse);
    await tester.binding.handlePopRoute();
    await tester.pumpAndSettle();
    expect(find.byKey(ValueKey('archive-folder-${child.id}')), findsNothing);
    expect(
      find.byKey(ValueKey('archive-folder-note-${retained.id}')),
      findsOneWidget,
    );
    expect(store.notes.firstWhere((n) => n.id == note.id).folderId, child.id);
    expect(store.topicsForNote(note.id).single.id, topic.id);
    await tester.binding
        .handlePopRoute(); // return from root folder to the archive root
    await tester.pumpAndSettle();
    await tester.binding.handlePopRoute(); // return to ordinary notes
    await tester.pumpAndSettle();
    expect(find.text('Child note'), findsOneWidget);
  });

  testWidgets(
    'knowledge archive keeps only eligible paths and original links',
    (tester) async {
      final db = MoodiaryDatabase.forTesting(NativeDatabase.memory());
      final store = DailyNotesStore(db);
      await store.open();
      final root = await store.createTopic('Root');
      final leaf = await store.createTopic('Leaf', parentId: root.id);
      final hidden = await store.createTopic('Hidden', parentId: root.id);
      final alternate = await store.createTopic('Alternate');
      final childNote = await store.saveNote(
        title: 'Linked child',
        body: 'child',
      );
      final rootNote = await store.saveNote(title: 'Linked root', body: 'root');
      final normal = await store.saveNote(
        title: 'Not archived',
        body: 'normal',
      );
      await store.linkNote(childNote.id, leaf.id);
      await store.linkNote(childNote.id, alternate.id);
      await store.linkNote(rootNote.id, root.id);
      await store.linkNote(normal.id, hidden.id);
      await store.setNoteArchived(childNote.id, archived: true);
      await store.setNoteArchived(rootNote.id, archived: true);
      await tester.binding.setSurfaceSize(const Size(430, 900));
      addTearDown(() async {
        await tester.pumpWidget(const SizedBox());
        store.dispose();
        await db.close();
        await tester.binding.setSurfaceSize(null);
      });
      await tester.pumpWidget(_app(DailyNotesArchivePage(store: store)));
      await tester.pumpAndSettle();
      await tester.tap(find.text('知识库'));
      await tester.pumpAndSettle();
      expect(find.byKey(ValueKey('archive-topic-${root.id}')), findsOneWidget);
      expect(
        find.byKey(ValueKey('archive-topic-${alternate.id}')),
        findsOneWidget,
      );
      await tester.tap(find.byKey(ValueKey('archive-topic-${root.id}')));
      await tester.pumpAndSettle();
      expect(find.byKey(ValueKey('archive-topic-${leaf.id}')), findsOneWidget);
      expect(find.byKey(ValueKey('archive-topic-${hidden.id}')), findsNothing);
      expect(
        find.byKey(ValueKey('archive-topic-note-${rootNote.id}')),
        findsOneWidget,
      );
      expect(
        find.byKey(ValueKey('archive-topic-note-${childNote.id}')),
        findsNothing,
      );
      await tester.tap(find.byKey(ValueKey('archive-topic-${leaf.id}')));
      await tester.pumpAndSettle();
      await tester.tap(
        find.byKey(ValueKey('archive-topic-note-${childNote.id}')),
      );
      await tester.pumpAndSettle();
      await _unlock(tester);
      await _archiveAction(tester);
      await tester.binding.handlePopRoute();
      await tester.pumpAndSettle();
      expect(find.byKey(ValueKey('archive-topic-${leaf.id}')), findsNothing);
      expect(
        find.byKey(ValueKey('archive-topic-note-${rootNote.id}')),
        findsOneWidget,
      );
      expect(store.topicsForNote(childNote.id).map((t) => t.id).toSet(), {
        leaf.id,
        alternate.id,
      });
      expect(store.unarchivedNotesForTopic(leaf.id).single.id, childNote.id);
      expect(store.archivedNotesForTopic(root.id).single.id, rootNote.id);
    },
  );

  testWidgets(
    'failed archive and unarchive keep committed state and report failure',
    (tester) async {
      final db = MoodiaryDatabase.forTesting(NativeDatabase.memory());
      final store = DailyNotesStore(db);
      await store.open();
      final note = await store.saveNote(title: 'Keep', body: 'body');
      final pending = store.pendingOperationCount;
      await tester.binding.setSurfaceSize(const Size(430, 900));
      addTearDown(() async {
        await tester.pumpWidget(const SizedBox());
        store.dispose();
        await db.close();
        await tester.binding.setSurfaceSize(null);
      });
      await tester.pumpWidget(
        _app(RichNoteEditorPage(store: store, note: note)),
      );
      await tester.pumpAndSettle();
      await _unlock(tester);
      await db.customStatement(
        "CREATE TRIGGER fail_archive BEFORE INSERT ON dn_metadata WHEN NEW.key LIKE 'archive:note:%' BEGIN SELECT RAISE(ABORT, 'disk'); END",
      );
      await _archiveAction(tester);
      expect(find.text('归档失败，请重试'), findsOneWidget);
      expect(store.isNoteArchived(note.id), isFalse);
      expect(store.unarchivedNotes.single.id, note.id);
      expect(store.pendingOperationCount, pending);
      await db.customStatement('DROP TRIGGER fail_archive');
      await tester.pump(const Duration(seconds: 5));
      await _archiveAction(tester);
      expect(store.isNoteArchived(note.id), isTrue);
      await db.customStatement(
        "CREATE TRIGGER fail_unarchive BEFORE DELETE ON dn_metadata WHEN OLD.key LIKE 'archive:note:%' BEGIN SELECT RAISE(ABORT, 'disk'); END",
      );
      await tester.pump(const Duration(seconds: 5));
      await _archiveAction(tester);
      expect(find.text('取消归档失败，请重试'), findsOneWidget);
      expect(store.isNoteArchived(note.id), isTrue);
      expect(store.archivedNotes.single.id, note.id);
      expect(find.byType(RichNoteEditorPage), findsOneWidget);
      expect(store.pendingOperationCount, pending);
    },
  );

  testWidgets('in-flight archive cannot be submitted twice', (tester) async {
    final db = MoodiaryDatabase.forTesting(NativeDatabase.memory());
    final store = _DelayedStore(db);
    await store.open();
    final note = await store.saveNote(title: 'Keep', body: 'body');
    await tester.binding.setSurfaceSize(const Size(430, 900));
    addTearDown(() async {
      if (!store.gate.isCompleted) store.gate.complete();
      await tester.pumpWidget(const SizedBox());
      store.dispose();
      await db.close();
      await tester.binding.setSurfaceSize(null);
    });
    await tester.pumpWidget(_app(RichNoteEditorPage(store: store, note: note)));
    await tester.pumpAndSettle();
    await _unlock(tester);
    final title = find.byType(TextField).first;
    await tester.tap(title);
    await tester.pump();
    final titleFocus = tester
        .widget<EditableText>(
          find.descendant(of: title, matching: find.byType(EditableText)).first,
        )
        .focusNode;
    expect(titleFocus.hasFocus, isTrue);
    await _archiveAction(tester);
    expect(titleFocus.hasFocus, isTrue);
    expect(store.archiveRequests, 1);
    expect(store.isNoteArchived(note.id), isFalse);
    await _menu(tester);
    expect(
      tester
          .widget<SimpleDialogOption>(
            find.byKey(const ValueKey('note-document-archive')),
          )
          .onPressed,
      isNull,
    );
    await tester.binding.handlePopRoute();
    await tester.pumpAndSettle();
    store.gate.complete();
    await tester.pumpAndSettle();
    expect(store.archiveRequests, 1);
    expect(store.isNoteArchived(note.id), isTrue);
  });

  testWidgets('archive does not hide a failed content save', (tester) async {
    final db = MoodiaryDatabase.forTesting(NativeDatabase.memory());
    var failSave = false;
    final store = DailyNotesStore(
      db,
      beforeOutboxWrite: () async {
        if (failSave) throw StateError('disk');
      },
    );
    await store.open();
    final note = await store.saveNote(title: 'Keep', body: 'original');
    final pending = store.pendingOperationCount;
    await tester.binding.setSurfaceSize(const Size(430, 900));
    addTearDown(() async {
      await tester.pumpWidget(const SizedBox());
      store.dispose();
      await db.close();
      await tester.binding.setSurfaceSize(null);
    });
    await tester.pumpWidget(_app(RichNoteEditorPage(store: store, note: note)));
    await tester.pumpAndSettle();
    await _unlock(tester);
    final editor = tester
        .widget<AppFlowyEditor>(find.byType(AppFlowyEditor))
        .editorState;
    failSave = true;
    await editor.insertText(8, ' unsaved', path: [0]);
    await tester.pump(const Duration(milliseconds: 600));
    await tester.pumpAndSettle();
    expect(find.text('保存失败，请重试'), findsWidgets);
    await _archiveAction(tester);
    expect(store.isNoteArchived(note.id), isTrue);
    expect(find.text('保存失败，请重试'), findsWidgets);
    expect(editor.document.toJson().toString(), contains('unsaved'));
    expect(store.archivedNotes.single.body, 'original');
    expect(store.pendingOperationCount, pending);
  });

  testWidgets('ordinary knowledge and link picker hide archived notes', (
    tester,
  ) async {
    final db = MoodiaryDatabase.forTesting(NativeDatabase.memory());
    final store = DailyNotesStore(db);
    await store.open();
    final topic = await store.createTopic('Knowledge root');
    final archived = await store.saveNote(title: 'Archived link', body: 'a');
    final linked = await store.saveNote(title: 'Visible link', body: 'v');
    final candidate = await store.saveNote(
      title: 'Visible candidate',
      body: 'c',
    );
    await store.linkNote(archived.id, topic.id);
    await store.linkNote(linked.id, topic.id);
    await store.setNoteArchived(archived.id, archived: true);
    await tester.binding.setSurfaceSize(const Size(430, 900));
    addTearDown(() async {
      await tester.pumpWidget(const SizedBox());
      store.dispose();
      await db.close();
      await tester.binding.setSurfaceSize(null);
    });
    await tester.pumpWidget(_app(DailyNotesNotesPage(store: store)));
    await tester.pumpAndSettle();
    await tester.tap(find.text('知识库'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Knowledge root'));
    await tester.pumpAndSettle();
    expect(find.text('Visible link'), findsOneWidget);
    expect(find.text('Archived link'), findsNothing);
    await tester.tap(find.text('关联已有笔记'));
    await tester.pumpAndSettle();
    expect(find.text('Archived link'), findsNothing);
    expect(find.text('Visible candidate'), findsOneWidget);
    expect(store.notesForTopic(topic.id).map((n) => n.id).toSet(), {
      archived.id,
      linked.id,
    });
    expect(store.unarchivedNotes.map((n) => n.id), contains(candidate.id));
  });

  testWidgets('refresh reads changes from a second store and restores path', (
    tester,
  ) async {
    final db = MoodiaryDatabase.forTesting(NativeDatabase.memory());
    final store = DailyNotesStore(db);
    await store.open();
    final folder = await store.createFolder('Remote folder');
    final note = await store.saveNote(
      title: 'Remote archive',
      body: 'content',
      folderId: folder.id,
    );
    final other = DailyNotesStore(db);
    await other.open();
    await tester.binding.setSurfaceSize(const Size(430, 900));
    addTearDown(() async {
      await tester.pumpWidget(const SizedBox());
      store.dispose();
      other.dispose();
      await db.close();
      await tester.binding.setSurfaceSize(null);
    });
    await tester.pumpWidget(_app(DailyNotesArchivePage(store: store)));
    await tester.pumpAndSettle();
    expect(find.byKey(ValueKey('archive-folder-${folder.id}')), findsNothing);
    await other.setNoteArchived(note.id, archived: true);
    await tester.tap(find.byTooltip('刷新'));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(ValueKey('archive-folder-${folder.id}')));
    await tester.pumpAndSettle();
    expect(
      find.byKey(ValueKey('archive-folder-note-${note.id}')),
      findsOneWidget,
    );
    await other.setNoteArchived(note.id, archived: false);
    await tester.tap(find.byTooltip('刷新'));
    await tester.pumpAndSettle();
    expect(
      find.byKey(ValueKey('archive-folder-note-${note.id}')),
      findsNothing,
    );
    expect(find.text('这里还没有已归档的笔记。'), findsOneWidget);
    expect(store.isNoteArchived(note.id), isFalse);
  });
}
