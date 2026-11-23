import 'dart:async';
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

String _document(String text) => jsonEncode(
  Document(
    root: pageNode(children: [paragraphNode(text: text)]),
  ).toJson(),
);

Widget _app(DailyNotesStore store, DailyNote note) => TranslationProvider(
  child: MaterialApp(
    theme: buildMuiTheme(brightness: Brightness.light),
    localizationsDelegates: const [
      AppFlowyEditorLocalizations.delegate,
      ...GlobalMaterialLocalizations.delegates,
      GlobalMuiLocalizations.delegate,
    ],
    // Match the application's current material_ui compatibility wrapper.
    // ignore: deprecated_member_use
    builder: (context, child) => MaterialUiCompatibilityBridge(child: child!),
    home: RichNoteEditorPage(store: store, note: note),
  ),
);

Future<void> _unlock(WidgetTester tester) async {
  await tester.tap(find.byTooltip(l10n.dailynotes.unlockEditing));
  await tester.pumpAndSettle();
}

Future<void> _chooseFolder(WidgetTester tester, String folderId) async {
  await tester.tap(find.byKey(const ValueKey('note-document-more')));
  await tester.pumpAndSettle();
  await tester.tap(find.byKey(const ValueKey('note-document-folder')));
  await tester.pumpAndSettle();
  await tester.tap(find.byKey(ValueKey('note-folder-$folderId')));
  await tester.pumpAndSettle();
}

void main() {
  setUpAll(() async {
    getIt.registerSingleton<IKVStorage>(MemoryKVStorage());
    await setupPluralResolvers();
    await LocaleSettings.setLocale(AppLocale.zh);
  });
  tearDownAll(() => getIt.reset());

  test(
    'stale note save and deletion cannot replace a newer revision',
    () async {
      final db = MoodiaryDatabase.forTesting(NativeDatabase.memory());
      final store = DailyNotesStore(db);
      final other = DailyNotesStore(db);
      await store.open();
      await other.open();
      addTearDown(() async {
        store.dispose();
        other.dispose();
        await db.close();
      });
      final original = await store.saveRichNote(
        title: 'Original',
        plainText: 'initial',
        documentJson: _document('initial'),
        documentVersion: 1,
      );
      expect(original.storageRevision, 1);
      expect(original.toJson(), isNot(contains('storageRevision')));
      final updated = await other.saveRichNote(
        id: original.id,
        title: 'Newer',
        plainText: 'newer',
        documentJson: _document('newer'),
        documentVersion: 1,
        expectedRevision: original.storageRevision,
      );
      expect(updated.storageRevision, 2);
      final events = other.pendingOperationCount;
      await expectLater(
        store.saveRichNote(
          id: original.id,
          title: 'Stale',
          plainText: 'stale',
          documentJson: _document('stale'),
          documentVersion: 1,
          expectedRevision: original.storageRevision,
        ),
        throwsA(isA<DailyNoteRevisionConflict>()),
      );
      await expectLater(
        store.deleteNote(
          original.id,
          expectedRevision: original.storageRevision,
        ),
        throwsA(isA<DailyNoteRevisionConflict>()),
      );
      await store.refresh();
      expect(store.notes.single.body, 'newer');
      expect(store.notes.single.storageRevision, 2);
      expect(store.deletedNotes, isEmpty);
      expect(store.pendingOperationCount, events);
    },
  );

  test('destination revisions are checked in the same transaction as save', () async {
    final db = MoodiaryDatabase.forTesting(NativeDatabase.memory());
    final store = DailyNotesStore(db);
    final other = DailyNotesStore(db);
    await store.open();
    await other.open();
    addTearDown(() async {
      store.dispose();
      other.dispose();
      await db.close();
    });
    final parent = await store.createFolder('Parent');
    final target = await store.createFolder('Target', parentId: parent.id);
    final note = await store.saveNote(title: 'Keep', body: 'original');
    final snapshot = store.folderPathSnapshot(target.id)!;
    expect(snapshot.path, 'Parent / Target');
    await other.renameFolder(parent.id, 'Changed');
    // A rename back is still a different path revision and needs confirmation.
    await other.renameFolder(parent.id, 'Parent');
    final events = other.pendingOperationCount;
    await expectLater(
      store.saveRichNote(
        id: note.id,
        title: note.title,
        plainText: 'new draft',
        documentJson: _document('new draft'),
        documentVersion: 1,
        folderId: target.id,
        expectedRevision: note.storageRevision,
        expectedFolderPath: snapshot,
      ),
      throwsA(isA<DailyFolderPathConflict>()),
    );
    await store.refresh();
    expect(store.notes.single.folderId, isNull);
    expect(store.notes.single.body, 'original');
    expect(store.notes.single.storageRevision, note.storageRevision);
    expect(store.pendingOperationCount, events);
    final fresh = store.folderPathSnapshot(target.id)!;
    final moved = await store.saveRichNote(
      id: note.id,
      title: note.title,
      plainText: 'new draft',
      documentJson: _document('new draft'),
      documentVersion: 1,
      folderId: target.id,
      expectedRevision: note.storageRevision,
      expectedFolderPath: fresh,
    );
    expect(moved.folderId, target.id);
    expect(moved.body, 'new draft');
    expect(moved.storageRevision, 2);
  });

  testWidgets('conflicting edit stays in memory and retry cannot overwrite', (
    tester,
  ) async {
    final db = MoodiaryDatabase.forTesting(NativeDatabase.memory());
    final store = DailyNotesStore(db);
    final other = DailyNotesStore(db);
    await store.open();
    await other.open();
    final note = await store.saveRichNote(
      title: 'Note',
      plainText: 'initial',
      documentJson: _document('initial'),
      documentVersion: 1,
    );
    await tester.binding.setSurfaceSize(const Size(430, 900));
    addTearDown(() async {
      await tester.pumpWidget(const SizedBox());
      store.dispose();
      other.dispose();
      await db.close();
      await tester.binding.setSurfaceSize(null);
    });
    await tester.pumpWidget(_app(store, note));
    await tester.pumpAndSettle();
    await _unlock(tester);
    final editor = tester
        .widget<AppFlowyEditor>(find.byType(AppFlowyEditor))
        .editorState;
    await editor.insertText(7, ' my draft', path: [0]);
    await other.saveRichNote(
      id: note.id,
      title: 'Note',
      plainText: 'newer elsewhere',
      documentJson: _document('newer elsewhere'),
      documentVersion: 1,
      expectedRevision: note.storageRevision,
    );
    final events = other.pendingOperationCount;
    await tester.pump(const Duration(milliseconds: 700));
    await tester.pumpAndSettle();
    expect(find.text(l10n.dailynotes.noteRevisionConflict), findsOneWidget);
    expect(editor.document.toJson().toString(), contains('my draft'));
    await tester.tap(find.text(l10n.dailynotes.retry));
    await tester.pumpAndSettle();
    await store.refresh();
    expect(store.notes.single.body, 'newer elsewhere');
    expect(store.pendingOperationCount, events);
    expect(editor.document.toJson().toString(), contains('my draft'));
    await tester.tap(find.byIcon(LucideIcons.arrowLeft).first);
    await tester.pumpAndSettle();
    expect(find.text(l10n.dailynotes.unsavedExitTitle), findsOneWidget);
    expect(find.text(l10n.dailynotes.copyRichJson), findsOneWidget);
    expect(find.text(l10n.dailynotes.emergencyExport), findsOneWidget);
  });

  testWidgets('destination changed after confirmation can be selected again', (
    tester,
  ) async {
    final db = MoodiaryDatabase.forTesting(NativeDatabase.memory());
    final store = DailyNotesStore(db);
    final other = DailyNotesStore(db);
    await store.open();
    await other.open();
    final parent = await store.createFolder('Parent');
    final target = await store.createFolder('Target', parentId: parent.id);
    final note = await store.saveNote(title: 'Note', body: 'original');
    await tester.binding.setSurfaceSize(const Size(430, 900));
    addTearDown(() async {
      await tester.pumpWidget(const SizedBox());
      store.dispose();
      other.dispose();
      await db.close();
      await tester.binding.setSurfaceSize(null);
    });
    await tester.pumpWidget(_app(store, note));
    await tester.pumpAndSettle();
    await _unlock(tester);
    await _chooseFolder(tester, target.id);
    await tester.tap(find.text(l10n.dailynotes.confirm).last);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 200));
    expect(store.notes.single.folderId, isNull);
    await other.renameFolder(parent.id, 'Changed');
    final events = other.pendingOperationCount;
    await tester.pump(const Duration(milliseconds: 700));
    await tester.pumpAndSettle();
    expect(find.text(l10n.dailynotes.noteMoveSaveConflict), findsOneWidget);
    await store.refresh();
    expect(store.notes.single.folderId, isNull);
    expect(store.notes.single.body, 'original');
    expect(store.pendingOperationCount, events);
    await _chooseFolder(tester, target.id);
    expect(find.textContaining('Changed / Target'), findsWidgets);
    await tester.tap(find.text(l10n.dailynotes.confirm).last);
    await tester.pump(const Duration(milliseconds: 700));
    await tester.pumpAndSettle();
    expect(store.notes.single.folderId, target.id);
    expect(store.notes.single.body, 'original');
    expect(find.byTooltip(l10n.dailynotes.savedLocally), findsOneWidget);
  });

  testWidgets('delete from a stale page leaves the newer note intact', (
    tester,
  ) async {
    final db = MoodiaryDatabase.forTesting(NativeDatabase.memory());
    final store = DailyNotesStore(db);
    final other = DailyNotesStore(db);
    await store.open();
    await other.open();
    final note = await store.saveRichNote(
      title: 'Note',
      plainText: 'initial',
      documentJson: _document('initial'),
      documentVersion: 1,
    );
    await tester.binding.setSurfaceSize(const Size(430, 900));
    addTearDown(() async {
      await tester.pumpWidget(const SizedBox());
      store.dispose();
      other.dispose();
      await db.close();
      await tester.binding.setSurfaceSize(null);
    });
    await tester.pumpWidget(_app(store, note));
    await tester.pumpAndSettle();
    await _unlock(tester);
    await other.saveRichNote(
      id: note.id,
      title: 'Note',
      plainText: 'newer elsewhere',
      documentJson: _document('newer elsewhere'),
      documentVersion: 1,
      expectedRevision: note.storageRevision,
    );
    final events = other.pendingOperationCount;
    await tester.tap(find.byKey(const ValueKey('note-document-more')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('note-document-delete')));
    await tester.pumpAndSettle();
    await tester.tap(find.text(l10n.dailynotes.delete).last);
    await tester.pumpAndSettle();
    expect(find.text(l10n.dailynotes.noteDeleteConflict), findsOneWidget);
    await store.refresh();
    expect(store.notes.single.body, 'newer elsewhere');
    expect(store.deletedNotes, isEmpty);
    expect(store.pendingOperationCount, events);
  });

  testWidgets('edits made during deletion remain open for recovery', (
    tester,
  ) async {
    final db = MoodiaryDatabase.forTesting(NativeDatabase.memory());
    var block = false;
    final started = Completer<void>();
    final release = Completer<void>();
    final store = DailyNotesStore(
      db,
      beforeOutboxWrite: () async {
        if (block) {
          block = false;
          started.complete();
          await release.future;
        }
      },
    );
    await store.open();
    final note = await store.saveRichNote(
      title: 'Note',
      plainText: 'initial',
      documentJson: _document('initial'),
      documentVersion: 1,
    );
    await tester.binding.setSurfaceSize(const Size(430, 900));
    addTearDown(() async {
      if (!release.isCompleted) release.complete();
      await tester.pumpWidget(const SizedBox());
      store.dispose();
      await db.close();
      await tester.binding.setSurfaceSize(null);
    });
    await tester.pumpWidget(_app(store, note));
    await tester.pumpAndSettle();
    await _unlock(tester);
    final editor = tester
        .widget<AppFlowyEditor>(find.byType(AppFlowyEditor))
        .editorState;
    await tester.tap(find.byKey(const ValueKey('note-document-more')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('note-document-delete')));
    await tester.pumpAndSettle();
    block = true;
    await tester.tap(find.text(l10n.dailynotes.delete).last);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    expect(started.isCompleted, isTrue);
    await editor.insertText(7, ' late draft', path: [0]);
    release.complete();
    await tester.pumpAndSettle();
    expect(store.deletedNotes.single.body, 'initial');
    expect(find.text(l10n.dailynotes.noteDeletedWithDraft), findsOneWidget);
    expect(editor.document.toJson().toString(), contains('late draft'));
    await tester.tap(find.byIcon(LucideIcons.arrowLeft).first);
    await tester.pumpAndSettle();
    expect(find.text(l10n.dailynotes.unsavedExitTitle), findsOneWidget);
    expect(find.text(l10n.dailynotes.copyRichJson), findsOneWidget);
  });

  testWidgets('edits made during a save use its committed revision', (
    tester,
  ) async {
    final db = MoodiaryDatabase.forTesting(NativeDatabase.memory());
    var block = false;
    final started = Completer<void>();
    final release = Completer<void>();
    final store = DailyNotesStore(
      db,
      beforeOutboxWrite: () async {
        if (block) {
          block = false;
          started.complete();
          await release.future;
        }
      },
    );
    await store.open();
    final note = await store.saveRichNote(
      title: 'Note',
      plainText: 'initial',
      documentJson: _document('initial'),
      documentVersion: 1,
    );
    await tester.binding.setSurfaceSize(const Size(430, 900));
    addTearDown(() async {
      if (!release.isCompleted) release.complete();
      await tester.pumpWidget(const SizedBox());
      store.dispose();
      await db.close();
      await tester.binding.setSurfaceSize(null);
    });
    await tester.pumpWidget(_app(store, note));
    await tester.pumpAndSettle();
    await _unlock(tester);
    final editor = tester
        .widget<AppFlowyEditor>(find.byType(AppFlowyEditor))
        .editorState;
    block = true;
    await editor.insertText(7, ' A', path: [0]);
    await tester.pump(const Duration(milliseconds: 700));
    await tester.pump();
    expect(started.isCompleted, isTrue);
    await editor.insertText(9, ' B', path: [0]);
    await tester.pump();
    expect(find.byTooltip(l10n.dailynotes.saving), findsOneWidget);
    expect(find.byTooltip(l10n.dailynotes.savedLocally), findsNothing);
    release.complete();
    await tester.pumpAndSettle();
    expect(store.notes.single.body, 'initial A B');
    expect(store.notes.single.storageRevision, 3);
    expect(find.byTooltip(l10n.dailynotes.savedLocally), findsOneWidget);
  });
}
