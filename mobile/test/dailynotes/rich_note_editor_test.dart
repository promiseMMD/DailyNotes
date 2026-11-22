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

void main() {
  setUpAll(() async {
    getIt.registerSingleton<IKVStorage>(MemoryKVStorage());
    await setupPluralResolvers();
    await LocaleSettings.setLocale(AppLocale.zh);
  });
  tearDownAll(() => getIt.reset());

  testWidgets(
    'toolbar formatting is saved as rich content and reopens read-only',
    (tester) async {
      final db = MoodiaryDatabase.forTesting(NativeDatabase.memory());
      final store = DailyNotesStore(db);
      await store.open();
      final editor = EditorState(
        document: Document(
          root: pageNode(children: [paragraphNode(text: 'alpha beta')]),
        ),
      );
      tester.view.physicalSize = const Size(430, 900);
      tester.view.devicePixelRatio = 1;
      tester.view.viewInsets = const FakeViewPadding(bottom: 300);
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      addTearDown(tester.view.resetViewInsets);
      Widget app(Widget home) => TranslationProvider(
        child: MaterialApp(
          theme: buildMuiTheme(brightness: Brightness.light),
          localizationsDelegates: const [
            AppFlowyEditorLocalizations.delegate,
            ...GlobalMaterialLocalizations.delegates,
            GlobalMuiLocalizations.delegate,
          ],
          builder: (context, child) =>
              MaterialUiCompatibilityBridge(child: child!),
          home: home,
        ),
      );
      await tester.pumpWidget(
        app(RichNoteEditorPage(store: store, testEditor: editor)),
      );
      await tester.pumpAndSettle();
      editor.selection = Selection.single(
        path: [0],
        startOffset: 0,
        endOffset: 5,
      );
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('rich-toolbar-format')));
      await tester.pumpAndSettle();
      await tester.tap(
        find.descendant(
          of: find.byKey(const ValueKey('rich-format-panel')),
          matching: find.byTooltip(l10n.editor.toolbar.bold),
        ),
      );
      await tester.pumpAndSettle();
      final inlineCode = find.byKey(
        ValueKey('rich-format-${l10n.editor.toolbar.inlineCode}'),
      );
      final arrow = find.byKey(const ValueKey('rich-format-code-more'));
      await tester.ensureVisible(arrow);
      await tester.tap(arrow);
      await tester.pumpAndSettle();
      await tester.tap(inlineCode);
      await tester.pumpAndSettle();
      final link = find.byKey(const ValueKey('rich-format-link'));
      await tester.ensureVisible(link);
      await tester.tap(link);
      await tester.pumpAndSettle();
      await tester.enterText(
        find.byKey(const ValueKey('rich-link-text')),
        'alpha!',
      );
      await tester.enterText(
        find.byKey(const ValueKey('rich-link-address')),
        'example.com',
      );
      await tester.tap(find.byKey(const ValueKey('rich-link-save')));
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('rich-format-panel')), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('rich-format-font')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('rich-font-serif')));
      await tester.pump(const Duration(milliseconds: 600));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('rich-format-font')));
      await tester.pumpAndSettle();
      await tester.binding.handlePopRoute();
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('rich-format-panel')), findsOneWidget);
      expect(find.byKey(const ValueKey('rich-format-font')), findsOneWidget);
      await tester.binding.handlePopRoute();
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('rich-format-panel')), findsNothing);
      expect(find.byType(RichNoteEditorPage), findsOneWidget);
      expect(store.notes, hasLength(1));
      expect(store.notes.single.documentJson, contains('"bold":true'));
      expect(store.notes.single.documentJson, contains('"code":true'));
      expect(
        store.notes.single.documentJson,
        contains('"href":"https://example.com"'),
      );
      expect(
        store.notes.single.documentJson,
        contains('"font_family":"serif"'),
      );
      expect(store.notes.single.body, 'alpha! beta');
      final saved = store.notes.single;
      await tester.pumpWidget(const SizedBox());
      tester.view.viewInsets = FakeViewPadding.zero;
      await tester.pumpWidget(
        app(RichNoteEditorPage(store: store, note: saved)),
      );
      await tester.pumpAndSettle();
      final reopened = tester.widget<AppFlowyEditor>(
        find.byType(AppFlowyEditor),
      );
      expect(reopened.editorState.editable, isFalse);
      expect(
        jsonEncode(reopened.editorState.document.toJson()),
        contains('"bold":true'),
      );
      expect(
        jsonEncode(reopened.editorState.document.toJson()),
        contains('"code":true'),
      );
      expect(
        jsonEncode(reopened.editorState.document.toJson()),
        contains('"font_family":"serif"'),
      );
      await tester.pumpWidget(const SizedBox());
      store.dispose();
      await db.close();
    },
  );

  testWidgets('rich editor changes are saved in the note and its outbox', (
    tester,
  ) async {
    final db = MoodiaryDatabase.forTesting(NativeDatabase.memory());
    final store = DailyNotesStore(db);
    await store.open();
    final editor = EditorState.blank(withInitialText: true);
    await tester.binding.setSurfaceSize(const Size(430, 900));
    await tester.pumpWidget(
      TranslationProvider(
        child: MaterialApp(
          theme: buildMuiTheme(brightness: Brightness.light),
          localizationsDelegates: const [
            AppFlowyEditorLocalizations.delegate,
            ...GlobalMaterialLocalizations.delegates,
          ],
          home: RichNoteEditorPage(store: store, testEditor: editor),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(
      tester.widget<AppFlowyEditor>(find.byType(AppFlowyEditor)).autoFocus,
      isTrue,
    );
    expect(editor.selection, isNotNull);
    await editor.insertText(0, '富文本测试', path: [0]);
    await tester.pump(const Duration(milliseconds: 600));
    await tester.pumpAndSettle();
    expect(store.notes, hasLength(1));
    expect(store.notes.single.body, contains('富文本测试'));
    expect(store.notes.single.documentJson, contains('富文本测试'));
    expect(store.notes.single.documentVersion, 1);
    expect(store.pendingOperationCount, greaterThan(0));
    expect(find.byTooltip('本机已保存'), findsOneWidget);
    expect(find.text('本机已保存'), findsNothing);
    await tester.tap(find.byTooltip('本机已保存'));
    await tester.pumpAndSettle();
    expect(find.text('本机已保存'), findsOneWidget);
    expect(find.text('当前笔记尚未接入 WebDAV 同步'), findsOneWidget);
    await tester.tap(find.text('确认').last);
    await tester.pumpAndSettle();
    await tester.pumpWidget(const SizedBox());
    store.dispose();
    await db.close();
    await tester.binding.setSurfaceSize(null);
  });
  testWidgets('failed transaction keeps editor text and never reports saved', (
    tester,
  ) async {
    final db = MoodiaryDatabase.forTesting(NativeDatabase.memory());
    final store = DailyNotesStore(
      db,
      beforeOutboxWrite: () async => throw StateError('disk'),
    );
    await store.open();
    final editor = EditorState.blank(withInitialText: true);
    await tester.binding.setSurfaceSize(const Size(430, 900));
    await tester.pumpWidget(
      TranslationProvider(
        child: MaterialApp(
          theme: buildMuiTheme(brightness: Brightness.light),
          localizationsDelegates: const [
            AppFlowyEditorLocalizations.delegate,
            ...GlobalMaterialLocalizations.delegates,
          ],
          home: RichNoteEditorPage(store: store, testEditor: editor),
        ),
      ),
    );
    await tester.pumpAndSettle();
    await editor.insertText(0, '未保存', path: [0]);
    await tester.pump(const Duration(milliseconds: 600));
    await tester.pumpAndSettle();
    expect(store.notes, isEmpty);
    expect(find.textContaining('保存失败'), findsOneWidget);
    expect(find.textContaining('本机已保存'), findsNothing);
    expect(editor.document.toJson().toString(), contains('未保存'));
    await tester.tap(find.byIcon(LucideIcons.arrowLeft));
    await tester.pumpAndSettle();
    expect(find.text('复制文档 JSON'), findsOneWidget);
    expect(find.text('应急导出 ZIP'), findsOneWidget);
    expect(find.text('重试'), findsWidgets);
    await tester.tap(find.text('放弃未保存内容'));
    await tester.pumpAndSettle();
    expect(find.text('确认丢失未保存内容？'), findsOneWidget);
    await tester.tap(find.text('取消').last);
    await tester.pumpAndSettle();
    expect(editor.document.toJson().toString(), contains('未保存'));

    await tester.pumpWidget(const SizedBox());
    store.dispose();
    await db.close();
    await tester.binding.setSurfaceSize(null);
  });

  testWidgets('saved document reopens read-only with original content', (
    tester,
  ) async {
    final db = MoodiaryDatabase.forTesting(NativeDatabase.memory());
    final store = DailyNotesStore(db);
    await store.open();
    final source = EditorState.blank(withInitialText: true);
    await source.insertText(0, '已保存文本', path: [0]);
    final note = await store.saveRichNote(
      title: 'Title',
      plainText: '已保存文本',
      documentJson: jsonEncode(source.document.toJson()),
      documentVersion: 1,
    );
    source.dispose();
    await tester.binding.setSurfaceSize(const Size(430, 900));
    await tester.pumpWidget(
      TranslationProvider(
        child: MaterialApp(
          theme: buildMuiTheme(brightness: Brightness.light),
          localizationsDelegates: const [
            AppFlowyEditorLocalizations.delegate,
            ...GlobalMaterialLocalizations.delegates,
          ],
          home: RichNoteEditorPage(store: store, note: note),
        ),
      ),
    );
    await tester.pumpAndSettle();
    final editor = tester.widget<AppFlowyEditor>(find.byType(AppFlowyEditor));
    expect(editor.editorState.editable, isFalse);
    expect(editor.autoFocus, isFalse);
    expect(editor.editorState.document.toJson().toString(), contains('已保存文本'));
    expect(find.byTooltip('解锁编辑'), findsOneWidget);
    final before = jsonEncode(editor.editorState.document.toJson());
    final pending = store.pendingOperationCount;
    AppFlowyClipboard.lastText = null;
    unawaited(
      editor.editorState.updateSelectionWithReason(
        Selection.single(path: [0], startOffset: 0, endOffset: 3),
        reason: SelectionUpdateReason.uiEvent,
      ),
    );
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('rich-floating-copy')), findsOneWidget);
    expect(find.byKey(const ValueKey('rich-floating-bold')), findsNothing);
    expect(tester.testTextInput.isVisible, isFalse);
    await tester.tap(find.byKey(const ValueKey('rich-floating-copy')));
    await tester.pumpAndSettle();
    expect(AppFlowyClipboard.lastText, '已保存');
    expect(jsonEncode(editor.editorState.document.toJson()), before);
    expect(store.pendingOperationCount, pending);
    await tester.pumpWidget(const SizedBox());
    store.dispose();
    await db.close();
    await tester.binding.setSurfaceSize(null);
  });
  testWidgets('unknown node fields remain protected and cannot be edited', (
    tester,
  ) async {
    final db = MoodiaryDatabase.forTesting(NativeDatabase.memory());
    final store = DailyNotesStore(db);
    await store.open();
    const raw =
        '{"document":{"type":"page","children":[{"type":"paragraph","future_field":"must keep"}]}}';
    final note = DailyNote(
      id: 'future',
      title: 'Title',
      body: 'preview',
      documentJson: raw,
      documentVersion: 1,
      createdAt: DateTime(2026),
      updatedAt: DateTime(2026),
    );
    await tester.pumpWidget(
      TranslationProvider(
        child: MaterialApp(
          theme: buildMuiTheme(brightness: Brightness.light),
          localizationsDelegates: const [
            AppFlowyEditorLocalizations.delegate,
            ...GlobalMaterialLocalizations.delegates,
          ],
          home: RichNoteEditorPage(store: store, note: note),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('文档格式暂不支持或内容损坏，已保留原文，请勿覆盖。'), findsOneWidget);
    expect(find.text('复制原始文档 JSON'), findsOneWidget);
    expect(store.pendingOperationCount, 0);
    await tester.pumpWidget(const SizedBox());
    store.dispose();
    await db.close();
  });
  testWidgets(
    'delete moves a rich note to trash and restoration preserves the document',
    (tester) async {
      final db = MoodiaryDatabase.forTesting(NativeDatabase.memory());
      final store = DailyNotesStore(db);
      await store.open();
      final source = EditorState.blank(withInitialText: true);
      await source.insertText(0, '保留格式', path: [0]);
      final original = jsonEncode(source.document.toJson());
      final note = await store.saveRichNote(
        title: 'Title',
        plainText: '保留格式',
        documentJson: original,
        documentVersion: 1,
      );
      source.dispose();
      await tester.binding.setSurfaceSize(const Size(430, 900));
      await tester.pumpWidget(
        TranslationProvider(
          child: MaterialApp(
            theme: buildMuiTheme(brightness: Brightness.light),
            localizationsDelegates: const [
              AppFlowyEditorLocalizations.delegate,
              ...GlobalMaterialLocalizations.delegates,
            ],
            home: Builder(
              builder: (context) => Scaffold(
                body: TextButton(
                  onPressed: () => Navigator.of(context).push(
                    MaterialPageRoute<void>(
                      builder: (_) =>
                          RichNoteEditorPage(store: store, note: note),
                    ),
                  ),
                  child: const Text('open'),
                ),
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('note-document-more')));
      await tester.pumpAndSettle();
      expect(
        tester
            .widget<SimpleDialogOption>(
              find.byKey(const ValueKey('note-document-delete')),
            )
            .onPressed,
        isNull,
      );
      await tester.binding.handlePopRoute();
      await tester.pumpAndSettle();
      expect(store.notes.single.id, note.id);
      expect(store.deletedNotes, isEmpty);
      await tester.tap(find.byTooltip('解锁编辑'));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('note-document-more')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('note-document-delete')));
      await tester.pumpAndSettle();
      final editor = tester
          .widget<AppFlowyEditor>(find.byType(AppFlowyEditor))
          .editorState;
      editor.editable = false;
      await tester.tap(find.text('删除').last);
      await tester.pumpAndSettle();
      expect(store.notes.single.id, note.id);
      expect(store.deletedNotes, isEmpty);
      editor.editable = true;
      await tester.pump();
      await tester.tap(find.byKey(const ValueKey('note-document-more')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('note-document-delete')));
      await tester.pumpAndSettle();
      expect(find.text('删除这篇笔记？'), findsOneWidget);
      await tester.tap(find.text('删除').last);
      await tester.pumpAndSettle();
      expect(store.notes, isEmpty);
      expect(store.deletedNotes.single.documentJson, original);
      await store.restoreNote(note.id);
      expect(store.notes.single.documentJson, original);
      await tester.pumpWidget(const SizedBox());
      store.dispose();
      await db.close();
      await tester.binding.setSurfaceSize(null);
    },
  );
  testWidgets('delete is blocked if the latest rich edit cannot be saved', (
    tester,
  ) async {
    final db = MoodiaryDatabase.forTesting(NativeDatabase.memory());
    var fail = false;
    final store = DailyNotesStore(
      db,
      beforeOutboxWrite: () async {
        if (fail) throw StateError('disk');
      },
    );
    await store.open();
    final source = EditorState.blank(withInitialText: true);
    await source.insertText(0, 'original', path: [0]);
    final note = await store.saveRichNote(
      title: 'Title',
      plainText: 'original',
      documentJson: jsonEncode(source.document.toJson()),
      documentVersion: 1,
    );
    source.dispose();
    await tester.binding.setSurfaceSize(const Size(430, 900));
    await tester.pumpWidget(
      TranslationProvider(
        child: MaterialApp(
          theme: buildMuiTheme(brightness: Brightness.light),
          localizationsDelegates: const [
            AppFlowyEditorLocalizations.delegate,
            ...GlobalMaterialLocalizations.delegates,
          ],
          home: RichNoteEditorPage(store: store, note: note),
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('解锁编辑'));
    await tester.pumpAndSettle();
    final editor = tester
        .widget<AppFlowyEditor>(find.byType(AppFlowyEditor))
        .editorState;
    fail = true;
    await editor.insertText(8, ' latest', path: [0]);
    await tester.pump(const Duration(milliseconds: 600));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('note-document-more')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('note-document-delete')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('删除').last);
    await tester.pumpAndSettle();
    expect(store.notes.single.id, note.id);
    expect(store.deletedNotes, isEmpty);
    expect(editor.document.toJson().toString(), contains('latest'));
    expect(find.textContaining('保存失败'), findsWidgets);
    await tester.pumpWidget(const SizedBox());
    store.dispose();
    await db.close();
    await tester.binding.setSurfaceSize(null);
  });
  testWidgets(
    'moving a rich note and editing tags preserve its original document',
    (tester) async {
      final db = MoodiaryDatabase.forTesting(NativeDatabase.memory());
      final store = DailyNotesStore(db);
      await store.open();
      final folder = await store.createFolder('设备');
      final source = EditorState.blank(withInitialText: true);
      await source.insertText(0, '带格式的正文', path: [0]);
      final document = jsonEncode(source.document.toJson());
      final note = await store.saveRichNote(
        title: 'Title',
        plainText: '带格式的正文',
        documentJson: document,
        documentVersion: 1,
      );
      source.dispose();
      await tester.binding.setSurfaceSize(const Size(430, 900));
      await tester.pumpWidget(
        TranslationProvider(
          child: MaterialApp(
            theme: buildMuiTheme(brightness: Brightness.light),
            localizationsDelegates: const [
              AppFlowyEditorLocalizations.delegate,
              ...GlobalMaterialLocalizations.delegates,
            ],
            home: RichNoteEditorPage(store: store, note: note),
          ),
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.byTooltip('解锁编辑'));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('note-document-more')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('note-document-folder')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('设备').last);
      await tester.pumpAndSettle();
      expect(find.text('移动笔记'), findsOneWidget);
      await tester.tap(find.text('确认').last);
      await tester.pump(const Duration(milliseconds: 600));
      await tester.pumpAndSettle();
      expect(store.notes.single.folderId, folder.id);
      expect(store.notes.single.documentJson, document);
      await tester.tap(find.byKey(const ValueKey('note-document-more')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('note-document-tags')));
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(TextField).last, '维护, 观察');
      await tester.tap(find.text('确认').last);
      await tester.pump(const Duration(milliseconds: 600));
      await tester.pumpAndSettle();
      expect(store.notes.single.tags, ['维护', '观察']);
      expect(store.notes.single.documentJson, document);
      await tester.pumpWidget(const SizedBox());
      store.dispose();
      await db.close();
      await tester.binding.setSurfaceSize(null);
    },
  );
  testWidgets(
    'locking after a rich save failure preserves edits through unlock and retry',
    (tester) async {
      final db = MoodiaryDatabase.forTesting(NativeDatabase.memory());
      var fail = false;
      final store = DailyNotesStore(
        db,
        beforeOutboxWrite: () async {
          if (fail) throw StateError('disk');
        },
      );
      await store.open();
      final source = EditorState.blank(withInitialText: true);
      await source.insertText(0, 'original', path: [0]);
      final note = await store.saveRichNote(
        title: 'Title',
        plainText: 'original',
        documentJson: jsonEncode(source.document.toJson()),
        documentVersion: 1,
      );
      source.dispose();
      await tester.binding.setSurfaceSize(const Size(430, 900));
      await tester.pumpWidget(
        TranslationProvider(
          child: MaterialApp(
            theme: buildMuiTheme(brightness: Brightness.light),
            localizationsDelegates: const [
              AppFlowyEditorLocalizations.delegate,
              ...GlobalMaterialLocalizations.delegates,
            ],
            home: RichNoteEditorPage(store: store, note: note),
          ),
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.byTooltip('解锁编辑'));
      await tester.pumpAndSettle();
      final editor = tester
          .widget<AppFlowyEditor>(find.byType(AppFlowyEditor))
          .editorState;
      fail = true;
      await editor.insertText(8, ' latest', path: [0]);
      await tester.pump(const Duration(milliseconds: 600));
      await tester.pumpAndSettle();
      await tester.tap(find.byTooltip('锁定编辑'));
      await tester.pumpAndSettle();
      expect(editor.editable, isFalse);
      expect(find.textContaining('保存失败'), findsOneWidget);
      expect(editor.document.toJson().toString(), contains('latest'));
      await tester.tap(find.byTooltip('解锁编辑'));
      await tester.pumpAndSettle();
      expect(editor.editable, isTrue);
      fail = false;
      await tester.tap(find.text('重试'));
      await tester.pumpAndSettle();
      expect(store.notes.single.body, contains('latest'));
      expect(find.byTooltip('本机已保存'), findsOneWidget);
      await tester.pumpWidget(const SizedBox());
      store.dispose();
      await db.close();
      await tester.binding.setSurfaceSize(null);
    },
  );
}
