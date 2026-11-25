// The tested app still uses this bridge for its current Material migration.
// ignore_for_file: deprecated_member_use

import 'dart:convert';

import 'package:appflowy_editor/appflowy_editor.dart';
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:moodiary_data/moodiary_data.dart';
import 'package:moodiary_di/moodiary_di.dart';
import 'package:moodiary_i18n/moodiary_i18n.dart';
import 'package:moodiary_mobile/app/dailynotes/data/daily_notes_store.dart';
import 'package:moodiary_mobile/app/dailynotes/notes/rich_note_editor_page.dart';
import 'package:moodiary_mobile/app/dailynotes/notes/rich_note_outline.dart';
import 'package:moodiary_storage/moodiary_storage.dart';
import 'package:moodiary_storage/testing.dart';
import 'package:mui/mui.dart';

void main() {
  setUpAll(() async {
    getIt.registerSingleton<IKVStorage>(MemoryKVStorage());
    await setupPluralResolvers();
    await LocaleSettings.setLocale(AppLocale.zh);
  });
  tearDownAll(() => getIt.reset());

  testWidgets(
    'outline searches headings and scrolls without replacing editor contents',
    (tester) async {
      final db = MoodiaryDatabase.forTesting(NativeDatabase.memory());
      final store = DailyNotesStore(db);
      await store.open();
      final first = headingNode(level: 1, text: 'Alpha chapter');
      final second = headingNode(level: 2, text: 'Target chapter');
      final editor = EditorState(
        document: Document(
          root: pageNode(
            children: [
              first,
              for (var i = 0; i < 30; i++) paragraphNode(text: 'Body $i'),
              second,
              paragraphNode(text: 'Last paragraph'),
            ],
          ),
        ),
      );
      tester.view.physicalSize = const Size(430, 900);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      await tester.pumpWidget(
        TranslationProvider(
          child: MaterialApp(
            theme: buildMuiTheme(brightness: Brightness.light),
            localizationsDelegates: const [
              AppFlowyEditorLocalizations.delegate,
              ...GlobalMaterialLocalizations.delegates,
              GlobalMuiLocalizations.delegate,
            ],
            builder: (context, child) =>
                MaterialUiCompatibilityBridge(child: child!),
            home: RichNoteEditorPage(store: store, testEditor: editor),
          ),
        ),
      );
      await tester.pumpAndSettle();
      final original = jsonEncode(editor.document.toJson());
      await tester.tap(find.byKey(const ValueKey('note-document-more')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('note-document-outline')));
      await tester.pumpAndSettle();
      expect(find.text('Alpha chapter'), findsWidgets);
      expect(find.text('Target chapter'), findsOneWidget);
      await tester.enterText(find.byType(TextField).last, 'Target');
      await tester.pumpAndSettle();
      expect(find.text('Target chapter'), findsOneWidget);
      expect(find.byKey(ValueKey('outline-${first.id}')), findsOneWidget);
      await tester.tap(find.byKey(ValueKey('outline-${second.id}')));
      await tester.pumpAndSettle();
      expect(jsonEncode(editor.document.toJson()), original);
      expect(second.key.currentContext, isNotNull);
      expect(find.text(l10n.dailynotes.outlineUnavailable), findsNothing);
      await tester.pumpWidget(const SizedBox());
      store.dispose();
      await db.close();
    },
  );

  testWidgets('outline folds heading branches and search shows their path', (
    tester,
  ) async {
    final parent = headingNode(level: 1, text: '第一章');
    final child = headingNode(level: 2, text: '第一节');
    final nested = headingNode(level: 3, text: '目标标题');
    final sibling = headingNode(level: 2, text: '第二节');
    final next = headingNode(level: 1, text: '第二章');
    final editor = EditorState(
      document: Document(
        root: pageNode(children: [parent, child, nested, sibling, next]),
      ),
    );
    Node? selected;
    await tester.pumpWidget(
      TranslationProvider(
        child: MaterialApp(
          theme: buildMuiTheme(brightness: Brightness.light),
          localizationsDelegates: const [
            AppFlowyEditorLocalizations.delegate,
            ...GlobalMaterialLocalizations.delegates,
            GlobalMuiLocalizations.delegate,
          ],
          builder: (context, child) =>
              MaterialUiCompatibilityBridge(child: child!),
          home: Scaffold(
            body: RichNoteOutline(
              editor: editor,
              onSelect: (node) => selected = node,
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    final before = jsonEncode(editor.document.toJson());
    await tester.tap(find.byKey(ValueKey('outline-toggle-${parent.id}')));
    await tester.pumpAndSettle();
    expect(find.byKey(ValueKey('outline-${child.id}')), findsNothing);
    expect(find.byKey(ValueKey('outline-${nested.id}')), findsNothing);
    expect(find.byKey(ValueKey('outline-${sibling.id}')), findsNothing);
    expect(find.byKey(ValueKey('outline-${next.id}')), findsOneWidget);

    await tester.enterText(find.byType(TextField), '目标');
    await tester.pumpAndSettle();
    expect(find.byKey(ValueKey('outline-${parent.id}')), findsOneWidget);
    expect(find.byKey(ValueKey('outline-${child.id}')), findsOneWidget);
    expect(find.byKey(ValueKey('outline-${nested.id}')), findsOneWidget);
    expect(find.byKey(ValueKey('outline-${sibling.id}')), findsNothing);
    expect(find.byKey(ValueKey('outline-${next.id}')), findsNothing);
    expect(find.byKey(const ValueKey('outline-clear-search')), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('outline-clear-search')));
    await tester.pumpAndSettle();
    expect(
      tester.widget<TextField>(find.byType(TextField)).controller!.text,
      '',
    );
    expect(find.byKey(ValueKey('outline-${child.id}')), findsNothing);

    await tester.tap(find.byKey(ValueKey('outline-toggle-${parent.id}')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(ValueKey('outline-toggle-${child.id}')));
    await tester.pumpAndSettle();
    expect(find.byKey(ValueKey('outline-${nested.id}')), findsNothing);
    expect(find.byKey(ValueKey('outline-${sibling.id}')), findsOneWidget);
    await tester.tap(find.byKey(ValueKey('outline-${sibling.id}')));
    expect(selected, same(sibling));
    expect(jsonEncode(editor.document.toJson()), before);
    await tester.pumpWidget(const SizedBox());
    editor.dispose();
  });

  testWidgets('outline stays current through long-document edits and undo', (
    tester,
  ) async {
    final parent = headingNode(level: 1, text: '第一章');
    final nested = headingNode(level: 2, text: '原小节');
    final container = paragraphNode(text: '容器', children: [nested]);
    final editor = EditorState(
      document: Document(
        root: pageNode(
          children: [
            parent,
            for (var i = 0; i < 1000; i++) paragraphNode(text: '正文 $i'),
            container,
          ],
        ),
      ),
    );
    await tester.pumpWidget(
      TranslationProvider(
        child: MaterialApp(
          theme: buildMuiTheme(brightness: Brightness.light),
          localizationsDelegates: const [
            AppFlowyEditorLocalizations.delegate,
            ...GlobalMaterialLocalizations.delegates,
            GlobalMuiLocalizations.delegate,
          ],
          builder: (context, child) =>
              MaterialUiCompatibilityBridge(child: child!),
          home: Scaffold(
            body: RichNoteOutline(editor: editor, onSelect: (_) {}),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(ValueKey('outline-toggle-${parent.id}')));
    await tester.pumpAndSettle();
    expect(find.byKey(ValueKey('outline-${nested.id}')), findsNothing);

    await editor.insertText(0, '修改', path: [500]);
    await tester.pumpAndSettle();
    expect(find.byKey(ValueKey('outline-${nested.id}')), findsNothing);
    await editor.insertText(0, '新', path: nested.path);
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField), '新原小节');
    await tester.pumpAndSettle();
    expect(find.byKey(ValueKey('outline-${nested.id}')), findsOneWidget);
    expect(find.text('第一章'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('outline-clear-search')));
    await tester.pumpAndSettle();
    expect(find.byKey(ValueKey('outline-${nested.id}')), findsNothing);

    await editor.apply(
      editor.transaction..updateNode(nested, {HeadingBlockKeys.level: 1}),
    );
    await tester.pumpAndSettle();
    expect(find.byKey(ValueKey('outline-${nested.id}')), findsOneWidget);

    final inserted = headingNode(level: 1, text: '新增标题');
    await editor.apply(
      editor.transaction..insertNode([0], inserted, deepCopy: false),
      skipHistoryDebounce: true,
    );
    await tester.pumpAndSettle();
    expect(find.byKey(ValueKey('outline-${inserted.id}')), findsOneWidget);
    editor.undoManager.undo();
    await tester.pumpAndSettle();
    expect(find.byKey(ValueKey('outline-${inserted.id}')), findsNothing);
    await editor.apply(editor.transaction..deleteNode(container));
    await tester.pumpAndSettle();
    expect(find.byKey(ValueKey('outline-${nested.id}')), findsNothing);
    expect(find.text('第一章'), findsOneWidget);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
    editor.dispose();
  });

  testWidgets('outline and note actions fit a narrow phone', (tester) async {
    final db = MoodiaryDatabase.forTesting(NativeDatabase.memory());
    final store = DailyNotesStore(db);
    late DailyNote note;
    await tester.runAsync(() async {
      await store.open();
      final document = Document(
        root: pageNode(children: [headingNode(level: 1, text: 'Title')]),
      );
      note = await store.saveRichNote(
        title: 'Test',
        plainText: 'Title',
        documentJson: jsonEncode(document.toJson()),
        documentVersion: 1,
      );
      document.dispose();
    });
    tester.view.physicalSize = const Size(320, 700);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(
      TranslationProvider(
        child: MaterialApp(
          theme: buildMuiTheme(brightness: Brightness.light),
          localizationsDelegates: const [
            AppFlowyEditorLocalizations.delegate,
            ...GlobalMaterialLocalizations.delegates,
            GlobalMuiLocalizations.delegate,
          ],
          builder: (context, child) =>
              MaterialUiCompatibilityBridge(child: child!),
          home: RichNoteEditorPage(store: store, note: note),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    expect(find.byKey(const ValueKey('note-document-more')), findsOneWidget);
    await tester.tap(
      find.byKey(const ValueKey('note-document-outline-button')),
    );
    await tester.pumpAndSettle();
    expect(find.byType(RichNoteOutline), findsOneWidget);
    expect(find.text('Title'), findsWidgets);
    await tester.tap(
      find.descendant(
        of: find.byType(RichNoteOutline),
        matching: find.text('Title'),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(
      find.byKey(const ValueKey('note-document-outline-button')),
    );
    await tester.pumpAndSettle();
    expect(
      find.byKey(const ValueKey('outline-return-previous')),
      findsOneWidget,
    );
    await tester.enterText(find.byType(TextField).last, 'Title');
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('outline-clear-search')));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    await tester.binding.handlePopRoute();
    await tester.pumpAndSettle();
    expect(find.byType(RichNoteOutline), findsNothing);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
    store.dispose();
    await tester.runAsync(db.close);
  });

  testWidgets(
    'outline keeps unsaved edits and removes a deleted heading target',
    (tester) async {
      final db = MoodiaryDatabase.forTesting(NativeDatabase.memory());
      final store = DailyNotesStore(
        db,
        beforeOutboxWrite: () async => throw StateError('disk'),
      );
      await store.open();
      final heading = headingNode(level: 1, text: 'Temporary heading');
      final editor = EditorState(
        document: Document(
          root: pageNode(
            children: [
              heading,
              paragraphNode(text: 'unsaved body'),
            ],
          ),
        ),
      );
      tester.view.physicalSize = const Size(430, 900);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      await tester.pumpWidget(
        TranslationProvider(
          child: MaterialApp(
            theme: buildMuiTheme(brightness: Brightness.light),
            localizationsDelegates: const [
              AppFlowyEditorLocalizations.delegate,
              ...GlobalMaterialLocalizations.delegates,
              GlobalMuiLocalizations.delegate,
            ],
            builder: (context, child) =>
                MaterialUiCompatibilityBridge(child: child!),
            home: RichNoteEditorPage(store: store, testEditor: editor),
          ),
        ),
      );
      await tester.pumpAndSettle();
      await editor.insertText(12, ' latest', path: [1]);
      await tester.pump(const Duration(milliseconds: 600));
      await tester.pumpAndSettle();
      expect(find.textContaining('保存失败'), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('note-document-more')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('note-document-outline')));
      await tester.pumpAndSettle();
      expect(find.byKey(ValueKey('outline-${heading.id}')), findsOneWidget);
      expect(editor.document.toJson().toString(), contains('latest'));
      final transaction = editor.transaction..deleteNode(heading);
      await editor.apply(transaction);
      await tester.pumpAndSettle();
      expect(find.byKey(ValueKey('outline-${heading.id}')), findsNothing);
      expect(editor.document.toJson().toString(), contains('latest'));
      expect(store.notes, isEmpty);
      await tester.pumpWidget(const SizedBox());
      store.dispose();
      await db.close();
    },
  );

  testWidgets(
    'switching outline documents resets the search and follows the new editor',
    (tester) async {
      final oldEditor = EditorState(
        document: Document(
          root: pageNode(
            children: [headingNode(level: 1, text: 'Old heading')],
          ),
        ),
      );
      final newEditor = EditorState(
        document: Document(
          root: pageNode(
            children: [headingNode(level: 1, text: 'New heading')],
          ),
        ),
      );
      Widget screen(EditorState editor) => TranslationProvider(
        child: MaterialApp(
          theme: buildMuiTheme(brightness: Brightness.light),
          localizationsDelegates: const [
            AppFlowyEditorLocalizations.delegate,
            ...GlobalMaterialLocalizations.delegates,
            GlobalMuiLocalizations.delegate,
          ],
          builder: (context, child) =>
              MaterialUiCompatibilityBridge(child: child!),
          home: Scaffold(
            body: RichNoteOutline(editor: editor, onSelect: (_) {}),
          ),
        ),
      );
      await tester.pumpWidget(screen(oldEditor));
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(TextField), 'Old');
      await tester.pumpAndSettle();
      expect(find.text('Old heading'), findsOneWidget);
      await tester.pumpWidget(screen(newEditor));
      await tester.pumpAndSettle();
      expect(
        tester.widget<EditableText>(find.byType(EditableText)).controller.text,
        isEmpty,
      );
      expect(find.text('New heading'), findsOneWidget);
      expect(find.text('Old heading'), findsNothing);
      await newEditor.insertText(3, ' changed', path: [0]);
      await tester.pumpAndSettle();
      expect(find.text('New changed heading'), findsOneWidget);
      await oldEditor.insertText(3, ' stale', path: [0]);
      await tester.pumpAndSettle();
      expect(find.text('New changed heading'), findsOneWidget);
      expect(find.text('Old stale heading'), findsNothing);
      await tester.pumpWidget(const SizedBox());
      oldEditor.dispose();
      newEditor.dispose();
    },
  );

  testWidgets(
    'deleting an outline target before navigation cannot scroll to another block',
    (tester) async {
      final db = MoodiaryDatabase.forTesting(NativeDatabase.memory());
      final store = DailyNotesStore(db);
      await store.open();
      final heading = headingNode(level: 1, text: 'Transient heading');
      final editor = EditorState(
        document: Document(
          root: pageNode(
            children: [
              heading,
              paragraphNode(text: 'Keep this paragraph'),
            ],
          ),
        ),
      );
      await tester.pumpWidget(
        TranslationProvider(
          child: MaterialApp(
            theme: buildMuiTheme(brightness: Brightness.light),
            localizationsDelegates: const [
              AppFlowyEditorLocalizations.delegate,
              ...GlobalMaterialLocalizations.delegates,
              GlobalMuiLocalizations.delegate,
            ],
            builder: (context, child) =>
                MaterialUiCompatibilityBridge(child: child!),
            home: RichNoteEditorPage(store: store, testEditor: editor),
          ),
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('note-document-more')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('note-document-outline')));
      await tester.pumpAndSettle();
      final outline = tester.widget<RichNoteOutline>(
        find.byType(RichNoteOutline),
      );
      outline.onSelect(heading);
      await editor.apply(editor.transaction..deleteNode(heading));
      final afterDeletion = jsonEncode(editor.document.toJson());
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 250));
      expect(jsonEncode(editor.document.toJson()), afterDeletion);
      expect(
        editor.document.root.children.single.delta!.toPlainText(),
        'Keep this paragraph',
      );
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
      store.dispose();
      await db.close();
    },
  );
}
