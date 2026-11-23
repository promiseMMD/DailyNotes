import 'dart:convert';

import 'package:appflowy_editor/appflowy_editor.dart';
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:moodiary_data/moodiary_data.dart';
import 'package:moodiary_di/moodiary_di.dart';
import 'package:moodiary_i18n/moodiary_i18n.dart';
import 'package:moodiary_mobile/app/dailynotes/data/daily_notes_store.dart';
import 'package:moodiary_mobile/app/dailynotes/notes/rich_note_editor_page.dart';
import 'package:moodiary_storage/moodiary_storage.dart';
import 'package:moodiary_storage/testing.dart';
import 'package:mui/mui.dart';

Widget _app(DailyNotesStore store, DailyNote note) => TranslationProvider(
  child: MaterialApp(
    theme: buildMuiTheme(brightness: Brightness.light),
    localizationsDelegates: const [
      AppFlowyEditorLocalizations.delegate,
      ...GlobalMaterialLocalizations.delegates,
      GlobalMuiLocalizations.delegate,
    ],
    builder: (context, child) => MaterialUiCompatibilityBridge(child: child!),
    home: RichNoteEditorPage(store: store, note: note),
  ),
);

Future<void> _chooseFolder(WidgetTester tester) async {
  await tester.tap(find.byKey(const ValueKey('note-document-more')));
  await tester.pumpAndSettle();
  await tester.tap(find.byKey(const ValueKey('note-document-folder')));
  await tester.pumpAndSettle();
}

class _FailingRefreshStore extends DailyNotesStore {
  _FailingRefreshStore(super.database);
  bool failRefresh = false;

  @override
  Future<void> refresh() => failRefresh
      ? Future<void>.error(StateError('read_failed'))
      : super.refresh();
}

void main() {
  setUpAll(() async {
    getIt.registerSingleton<IKVStorage>(MemoryKVStorage());
    await setupPluralResolvers();
    await LocaleSettings.setLocale(AppLocale.zh);
  });
  tearDownAll(() => getIt.reset());

  testWidgets(
    'folder selection shows full paths and moves only after confirmation',
    (tester) async {
      final db = MoodiaryDatabase.forTesting(NativeDatabase.memory());
      final store = DailyNotesStore(db);
      await store.open();
      final alpha = await store.createFolder('Alpha');
      final beta = await store.createFolder('Beta');
      final first = await store.createFolder('Shared', parentId: alpha.id);
      final second = await store.createFolder('Shared', parentId: beta.id);
      final topic = await store.createTopic('Knowledge');
      final secondTopic = await store.createTopic('Related');
      final editor = EditorState(
        document: Document(
          root: pageNode(children: [paragraphNode(text: '保留正文')]),
        ),
      );
      final document = jsonEncode(editor.document.toJson());
      editor.dispose();
      final note = await store.saveRichNote(
        title: 'Original',
        plainText: '保留正文',
        documentJson: document,
        documentVersion: 1,
        tags: ['tag', 'second'],
      );
      await store.linkNote(note.id, topic.id);
      await store.linkNote(note.id, secondTopic.id);
      await tester.binding.setSurfaceSize(const Size(430, 900));
      addTearDown(() async {
        await tester.pumpWidget(const SizedBox());
        store.dispose();
        await db.close();
        await tester.binding.setSurfaceSize(null);
      });
      await tester.pumpWidget(_app(store, note));
      await tester.pumpAndSettle();
      await tester.tap(find.byTooltip(l10n.dailynotes.unlockEditing));
      await tester.pumpAndSettle();
      await _chooseFolder(tester);
      expect(find.text('Alpha / Shared'), findsOneWidget);
      expect(find.text('Beta / Shared'), findsOneWidget);
      await tester.tap(find.byKey(ValueKey('note-folder-${first.id}')));
      await tester.pumpAndSettle();
      expect(find.textContaining('Alpha / Shared'), findsOneWidget);
      expect(store.notes.single.folderId, isNull);
      await tester.tap(find.text(l10n.dailynotes.cancel).last);
      await tester.pumpAndSettle();
      expect(store.notes.single.folderId, isNull);
      await _chooseFolder(tester);
      await tester.tap(find.byKey(ValueKey('note-folder-${second.id}')));
      await tester.pumpAndSettle();
      expect(find.textContaining('Beta / Shared'), findsOneWidget);
      await tester.tap(find.text(l10n.dailynotes.confirm).last);
      await tester.pump(const Duration(milliseconds: 700));
      await tester.pumpAndSettle();
      expect(store.notes.single.folderId, second.id);
      expect(store.notes.single.documentJson, document);
      expect(store.notes.single.tags, ['tag', 'second']);
      expect(store.topicsForNote(note.id).map((topic) => topic.id).toSet(), {
        topic.id,
        secondTopic.id,
      });
    },
  );

  for (final change in ['rename', 'remove', 'external_rename']) {
    testWidgets('changed $change destination is rejected before moving', (
      tester,
    ) async {
      final db = MoodiaryDatabase.forTesting(NativeDatabase.memory());
      final store = DailyNotesStore(db);
      await store.open();
      final parent = await store.createFolder('Parent');
      final target = await store.createFolder('Target', parentId: parent.id);
      final original = await store.saveNote(title: 'Keep', body: 'Body');
      DailyNotesStore? other;
      await tester.binding.setSurfaceSize(const Size(430, 900));
      addTearDown(() async {
        await tester.pumpWidget(const SizedBox());
        store.dispose();
        other?.dispose();
        await db.close();
        await tester.binding.setSurfaceSize(null);
      });
      await tester.pumpWidget(_app(store, original));
      await tester.pumpAndSettle();
      await tester.tap(find.byTooltip(l10n.dailynotes.unlockEditing));
      await tester.pumpAndSettle();
      await _chooseFolder(tester);
      await tester.tap(find.byKey(ValueKey('note-folder-${target.id}')));
      await tester.pumpAndSettle();
      expect(find.textContaining('Parent / Target'), findsOneWidget);
      if (change == 'rename') {
        await store.renameFolder(parent.id, 'Renamed');
      } else if (change == 'external_rename') {
        other = DailyNotesStore(db);
        await other.open();
        await other.renameFolder(parent.id, 'Renamed elsewhere');
      } else {
        final plan = await store.planFolderRemoval(target.id);
        await store.removeFolder(plan);
      }
      final events = (other ?? store).pendingOperationCount;
      await tester.tap(find.text(l10n.dailynotes.confirm).last);
      await tester.pumpAndSettle();
      expect(find.text(l10n.dailynotes.moveTargetChanged), findsOneWidget);
      expect(store.notes.single.id, original.id);
      expect(store.notes.single.folderId, isNull);
      expect(store.notes.single.body, 'Body');
      expect(store.pendingOperationCount, events);
    });
  }

  testWidgets(
    'failed destination refresh keeps the note in its original folder',
    (tester) async {
      final db = MoodiaryDatabase.forTesting(NativeDatabase.memory());
      final store = _FailingRefreshStore(db);
      await store.open();
      final target = await store.createFolder('Target');
      final original = await store.saveNote(title: 'Keep', body: 'Body');
      final events = store.pendingOperationCount;
      await tester.binding.setSurfaceSize(const Size(430, 900));
      addTearDown(() async {
        await tester.pumpWidget(const SizedBox());
        store.dispose();
        await db.close();
        await tester.binding.setSurfaceSize(null);
      });
      await tester.pumpWidget(_app(store, original));
      await tester.pumpAndSettle();
      await tester.tap(find.byTooltip(l10n.dailynotes.unlockEditing));
      await tester.pumpAndSettle();
      await _chooseFolder(tester);
      await tester.tap(find.byKey(ValueKey('note-folder-${target.id}')));
      await tester.pumpAndSettle();
      store.failRefresh = true;
      await tester.tap(find.text(l10n.dailynotes.confirm).last);
      await tester.pumpAndSettle();
      expect(find.text(l10n.dailynotes.moveTargetCheckFailed), findsOneWidget);
      expect(store.notes.single.folderId, isNull);
      expect(store.notes.single.body, 'Body');
      expect(store.pendingOperationCount, events);
    },
  );
}
