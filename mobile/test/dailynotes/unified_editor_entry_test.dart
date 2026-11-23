import 'dart:convert';

import 'package:appflowy_editor/appflowy_editor.dart' as af;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:moodiary_data/moodiary_data.dart';
import 'package:moodiary_di/moodiary_di.dart';
import 'package:moodiary_editor/moodiary_editor.dart' show MoodiaryEditor;
import 'package:moodiary_i18n/moodiary_i18n.dart';
import 'package:moodiary_mobile/app/dailynotes/data/daily_notes_store.dart';
import 'package:moodiary_mobile/app/dailynotes/diary/diary_entry_gateway.dart';
import 'package:moodiary_mobile/app/dailynotes/diary/rich_diary_page.dart';
import 'package:moodiary_mobile/app/dailynotes/editor/document_canvas.dart';
import 'package:moodiary_mobile/app/dailynotes/editor/document_envelope.dart';
import 'package:moodiary_mobile/app/dailynotes/notes/appflowy_preview_page.dart';
import 'package:moodiary_mobile/app/dailynotes/notes/notes_page.dart';
import 'package:moodiary_mobile/app/home/mod_continuous.dart';
import 'package:moodiary_mobile/app/home/mod_month_composer.dart';
import 'package:moodiary_mobile/app/home/mod_month_native.dart';
import 'package:moodiary_mobile/app/home/mod_month_store.dart';
import 'package:moodiary_mobile/app/router/router.dart';
import 'package:moodiary_models/moodiary_models.dart';
import 'package:moodiary_storage/moodiary_storage.dart';
import 'package:moodiary_storage/testing.dart';
import 'package:mui/mui.dart';

class _ReadbackFailureRepository extends DiaryRepository {
  _ReadbackFailureRepository(super.database);
  bool _failReadback = false;
  bool _injected = false;

  @override
  Future<bool> insertADiaryIfAbsent(Diary diary) async {
    final inserted = await super.insertADiaryIfAbsent(diary);
    if (inserted && !_injected) {
      _injected = true;
      _failReadback = true;
    }
    return inserted;
  }

  @override
  Future<Diary?> getDiaryByBusinessId(String id) async {
    if (_failReadback) {
      _failReadback = false;
      throw StateError('readback_interrupted');
    }
    return super.getDiaryByBusinessId(id);
  }
}

void main() {
  setUpAll(() async {
    getIt.registerSingleton<IKVStorage>(MemoryKVStorage());
    getIt.registerSingleton<OpenDiaryRegistry>(OpenDiaryRegistry());
    await setupPluralResolvers();
    await LocaleSettings.setLocale(AppLocale.zh);
  });
  tearDownAll(() => getIt.reset());

  Widget app(Widget home) => TranslationProvider(
    child: MaterialApp(
      theme: buildMuiTheme(brightness: Brightness.light),
      localizationsDelegates: const [
        af.AppFlowyEditorLocalizations.delegate,
        ...GlobalMaterialLocalizations.delegates,
        GlobalMuiLocalizations.delegate,
      ],
      // The test reproduces the app's current compatibility wrapper.
      // ignore: deprecated_member_use
      builder: (context, child) => MaterialUiCompatibilityBridge(child: child!),
      home: home,
    ),
  );

  Future<void> phone(WidgetTester tester) async {
    tester.view.physicalSize = const Size(430, 900);
    tester.view.devicePixelRatio = 1;
    tester.view.viewInsets = const FakeViewPadding(bottom: 300);
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    addTearDown(tester.view.resetViewInsets);
  }

  Future<void> applyInlineCode(WidgetTester tester) async {
    await tester.tap(find.byKey(const ValueKey('rich-toolbar-more')));
    await tester.pumpAndSettle();
    final action = find.byKey(const ValueKey('rich-overflow-code'));
    await tester.ensureVisible(action);
    await tester.tap(action);
    await tester.pumpAndSettle();
  }

  Future<void> applyAaLink(WidgetTester tester, {String? text}) async {
    final link = find.byKey(const ValueKey('rich-format-link'));
    await tester.ensureVisible(link);
    await tester.tap(link);
    await tester.pumpAndSettle();
    if (text != null) {
      await tester.enterText(
        find.byKey(const ValueKey('rich-link-text')),
        text,
      );
    }
    await tester.enterText(
      find.byKey(const ValueKey('rich-link-address')),
      'example.com',
    );
    await tester.tap(find.byKey(const ValueKey('rich-link-save')));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('rich-format-panel')), findsOneWidget);
  }

  Future<void> insertHeading(
    WidgetTester tester,
    af.EditorState editor, {
    required List<int> path,
    required int offset,
    required String text,
  }) async {
    tester
        .widget<DailyNotesDocumentCanvas>(find.byType(DailyNotesDocumentCanvas))
        .focusNode
        .requestFocus();
    editor.selection = af.Selection.single(path: path, startOffset: offset);
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('rich-toolbar-insert')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('rich-insert-h2')));
    await tester.pumpAndSettle();
    final insertedPath = [...path]..last += 1;
    await editor.insertText(0, text, path: insertedPath);
  }

  testWidgets('the actual new-diary route opens the shared editor', (
    tester,
  ) async {
    await phone(tester);
    final db = MoodiaryDatabase.forTesting(NativeDatabase.memory());
    getIt.registerSingleton<DiaryRepository>(DiaryRepository(db));
    final router = createMobileRouter(
      initialLocation: NewDiaryRoute.path,
      navigatorKey: GlobalKey<NavigatorState>(),
    );
    await tester.pumpWidget(
      TranslationProvider(
        child: MaterialApp.router(
          theme: buildMuiTheme(brightness: Brightness.light),
          localizationsDelegates: const [
            af.AppFlowyEditorLocalizations.delegate,
            ...GlobalMaterialLocalizations.delegates,
            GlobalMuiLocalizations.delegate,
          ],
          builder: (context, child) =>
              // The test reproduces the app's current compatibility wrapper.
              // ignore: deprecated_member_use
              MaterialUiCompatibilityBridge(child: child!),
          routerConfig: router,
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.byType(RichDiaryPage), findsOneWidget);
    expect(find.byType(DailyNotesDocumentCanvas), findsOneWidget);
    expect(find.byType(MoodiaryEditor), findsNothing);
    final canvasEditor = tester.widget<af.AppFlowyEditor>(
      find.byType(af.AppFlowyEditor),
    );
    expect(
      canvasEditor.editorStyle.padding,
      const EdgeInsets.symmetric(horizontal: 20),
    );
    expect(canvasEditor.editorStyle.mobileDragHandleBallSize, const Size(8, 8));
    expect(
      tester.widget<TextField>(find.byType(TextField).first).decoration!.filled,
      isFalse,
    );
    expect(getIt<OpenDiaryRegistry>().snapshot(), hasLength(1));
    expect(getIt<OpenDiaryRegistry>().editingSnapshot(), hasLength(1));
    await canvasEditor.editorState.insertText(0, '路由测试', path: [0]);
    canvasEditor.editorState.selection = af.Selection.single(
      path: [0],
      startOffset: 0,
      endOffset: 4,
    );
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('rich-toolbar-format')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('rich-format-font')));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('rich-format-font-page')), findsOneWidget);
    tester.testTextInput.log.clear();
    await tester.binding.handlePopRoute();
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('rich-format-panel')), findsOneWidget);
    await tester.binding.handlePopRoute();
    await tester.pumpAndSettle();
    expect(find.byType(RichDiaryPage), findsOneWidget);
    expect(
      tester.testTextInput.log.map((call) => call.method),
      isNot(contains('TextInput.show')),
    );
    await tester.pump(const Duration(milliseconds: 700));
    await tester.pumpAndSettle();
    await tester.pumpWidget(const SizedBox());
    expect(getIt<OpenDiaryRegistry>().snapshot(), isEmpty);
    router.dispose();
    await getIt.unregister<DiaryRepository>();
    await db.close();
  });

  testWidgets('preview uses the same document canvas as the real editor', (
    tester,
  ) async {
    await phone(tester);
    await tester.pumpWidget(app(const AppFlowyPreviewPage()));
    await tester.pumpAndSettle();
    expect(find.byType(DailyNotesDocumentCanvas), findsOneWidget);
    expect(find.byType(af.MobileToolbarV2), findsNothing);
    expect(find.byKey(const ValueKey('rich-toolbar-insert')), findsOneWidget);
    final editor = tester
        .widget<af.AppFlowyEditor>(find.byType(af.AppFlowyEditor))
        .editorState;
    await editor.insertText(0, 'preview', path: [0]);
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('rich-toolbar-more')));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('rich-overflow-undo')), findsNothing);
    expect(find.byKey(const ValueKey('rich-overflow-redo')), findsNothing);
    await tester.binding.handlePopRoute();
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('document-top-undo')));
    await tester.pumpAndSettle();
    expect(editor.document.root.children.single.delta!.toPlainText(), isEmpty);
    await tester.tap(find.byKey(const ValueKey('document-top-redo')));
    await tester.pumpAndSettle();
    expect(
      editor.document.root.children.single.delta!.toPlainText(),
      'preview',
    );
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets(
    'existing plain note opens in the shared canvas and retains blank lines',
    (tester) async {
      await phone(tester);
      final db = MoodiaryDatabase.forTesting(NativeDatabase.memory());
      final store = DailyNotesStore(db);
      await store.open();
      final note = await store.saveNote(title: '旧笔记', body: '第一行\n\n第三行');
      await tester.pumpWidget(app(DailyNotesNotesPage(store: store)));
      await tester.pumpAndSettle();
      await tester.tap(find.text('旧笔记').first);
      await tester.pumpAndSettle();
      expect(find.byType(DailyNotesDocumentCanvas), findsOneWidget);
      await tester.tap(find.byTooltip(l10n.dailynotes.unlockEditing));
      await tester.pumpAndSettle();
      final editor = tester
          .widget<af.AppFlowyEditor>(find.byType(af.AppFlowyEditor))
          .editorState;
      await editor.insertText(3, '续', path: [2]);
      await insertHeading(tester, editor, path: [2], offset: 4, text: '笔记标题');
      await tester.pump(const Duration(milliseconds: 700));
      await tester.pumpAndSettle();
      final saved = store.notes.singleWhere((value) => value.id == note.id);
      expect(saved.body, '第一行\n\n第三行续\n笔记标题');
      expect(saved.documentJson, isNotNull);
      expect(saved.documentJson, contains('"type":"heading"'));
      expect(saved.documentJson, contains('笔记标题'));
      await tester.pumpWidget(const SizedBox());
      store.dispose();
      await db.close();
    },
  );

  testWidgets(
    'new diary uses AppFlowy and reopens its formatted saved document',
    (tester) async {
      await phone(tester);
      final db = MoodiaryDatabase.forTesting(NativeDatabase.memory());
      final repository = DiaryRepository(db);
      await tester.pumpWidget(app(RichDiaryPage(repository: repository)));
      await tester.pumpAndSettle();
      expect(find.byType(DailyNotesDocumentCanvas), findsOneWidget);
      expect(find.byType(MoodiaryEditor), findsNothing);
      final editor = tester
          .widget<af.AppFlowyEditor>(find.byType(af.AppFlowyEditor))
          .editorState;
      await editor.insertText(0, '日记正文', path: [0]);
      await insertHeading(tester, editor, path: [0], offset: 4, text: '日记标题');
      editor.selection = af.Selection.single(
        path: [0],
        startOffset: 0,
        endOffset: 4,
      );
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('rich-toolbar-bold')));
      await tester.pumpAndSettle();
      await applyInlineCode(tester);
      await tester.tap(find.byKey(const ValueKey('rich-toolbar-format')));
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('rich-format-panel')), findsOneWidget);
      await tester.tap(
        find.byKey(ValueKey('rich-format-${l10n.dailynotes.editorTextColor}')),
      );
      await tester.pumpAndSettle();
      await tester.tap(
        find.byKey(const ValueKey('rich-quick-color-text-0xffdb3636')),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('rich-color-done')));
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('rich-format-panel')), findsOneWidget);
      await applyAaLink(tester, text: '日记正文参考');
      await tester.binding.handlePopRoute();
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('rich-format-panel')), findsNothing);
      expect(find.byType(RichDiaryPage), findsOneWidget);
      await tester.pump(const Duration(milliseconds: 700));
      await tester.pumpAndSettle();
      final saved = (await repository.getAllDiaries()).single;
      expect(saved.contentText, contains('日记正文参考'));
      expect(saved.contentText, contains('日记标题'));
      expect(
        DailyNotesDocumentEnvelope.hasNativeDocument(saved.content),
        isTrue,
      );
      expect(
        jsonEncode(DailyNotesDocumentEnvelope.decode(saved.content).toJson()),
        contains('"bold":true'),
      );
      expect(
        jsonEncode(DailyNotesDocumentEnvelope.decode(saved.content).toJson()),
        contains('"code":true'),
      );
      expect(
        jsonEncode(DailyNotesDocumentEnvelope.decode(saved.content).toJson()),
        contains('0xffdb3636'),
      );
      expect(
        jsonEncode(DailyNotesDocumentEnvelope.decode(saved.content).toJson()),
        contains('"href":"https://example.com"'),
      );
      await tester.pumpWidget(const SizedBox());
      tester.view.viewInsets = FakeViewPadding.zero;
      await tester.pumpWidget(
        app(
          DailyNotesDiaryEntryGateway(
            repository: repository,
            diaryId: saved.id,
            legacy: (_) => const Text('legacy'),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.byType(DailyNotesDocumentCanvas), findsOneWidget);
      expect(find.text('legacy'), findsNothing);
      expect(
        tester
            .widget<af.AppFlowyEditor>(find.byType(af.AppFlowyEditor))
            .editable,
        isFalse,
      );
      await tester.pumpWidget(const SizedBox());
      await db.close();
    },
  );

  testWidgets('diary reconciles a committed write after readback fails', (
    tester,
  ) async {
    await phone(tester);
    final db = MoodiaryDatabase.forTesting(NativeDatabase.memory());
    final repository = _ReadbackFailureRepository(db);
    await tester.pumpWidget(app(RichDiaryPage(repository: repository)));
    await tester.pumpAndSettle();
    final editor = tester
        .widget<af.AppFlowyEditor>(find.byType(af.AppFlowyEditor))
        .editorState;
    await editor.insertText(0, '甲', path: [0]);
    await tester.pump(const Duration(milliseconds: 700));
    await tester.pumpAndSettle();
    expect(find.text(l10n.dailynotes.saveFailed), findsOneWidget);
    await editor.insertText(1, '乙', path: [0]);
    await tester.pump(const Duration(milliseconds: 700));
    await tester.pumpAndSettle();
    final diaries = await repository.getAllDiaries();
    expect(diaries, hasLength(1));
    expect(diaries.single.contentText, '甲乙');
    expect(find.text(l10n.dailynotes.saveFailed), findsNothing);
    await tester.pumpWidget(const SizedBox());
    await db.close();
  });

  testWidgets(
    'long-record append keeps a native draft until explicit submission',
    (tester) async {
      await phone(tester);
      final db = MoodiaryDatabase.forTesting(NativeDatabase.memory());
      final diaries = DiaryRepository(db);
      final topic = Diary.create(
        title: '工作',
        content:
            '{"type":"doc","attrs":{"v":2},"content":[{"type":"paragraph"}]}',
        contentText: '',
        imageName: [],
        audioName: [],
        videoName: [],
        tags: [ModDiary.topicTag],
        type: DiaryType.tiptap,
      );
      await diaries.insertADiary(topic);
      final repository = ModNativeMonthRepository(
        store: ModMonthStore(db),
        diaries: diaries,
      );
      final drafts = DailyNotesStore(db);
      await drafts.open();
      await tester.pumpWidget(
        app(
          Builder(
            builder: (context) => Scaffold(
              body: TextButton(
                onPressed: () => Navigator.of(context).push(
                  MaterialPageRoute<void>(
                    builder: (_) => ModMonthComposer(
                      repository: repository,
                      topicId: topic.id,
                      topicTitle: topic.title,
                      monthKey: '2026-11',
                      initialDayKey: '2026-11-17',
                      draftStore: drafts,
                      draftKey: 'unified-test',
                    ),
                  ),
                ),
                child: const Text('open'),
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();
      expect(find.byType(DailyNotesDocumentCanvas), findsOneWidget);
      expect(find.byType(MoodiaryEditor), findsNothing);
      final editor = tester
          .widget<af.AppFlowyEditor>(find.byType(af.AppFlowyEditor))
          .editorState;
      await editor.insertText(0, '追加内容', path: [0]);
      await insertHeading(tester, editor, path: [0], offset: 4, text: '追加标题');
      editor.selection = af.Selection.single(
        path: [0],
        startOffset: 0,
        endOffset: 4,
      );
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('rich-toolbar-bold')));
      await tester.pumpAndSettle();
      await applyInlineCode(tester);
      await tester.tap(find.byKey(const ValueKey('rich-toolbar-format')));
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('rich-format-panel')), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('rich-format-font')));
      await tester.pumpAndSettle();
      expect(
        find.byKey(const ValueKey('rich-format-font-page')),
        findsOneWidget,
      );
      await tester.tap(find.byKey(const ValueKey('rich-font-serif')));
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('rich-format-panel')), findsOneWidget);
      await applyAaLink(tester, text: '追加内容参考');
      await tester.binding.handlePopRoute();
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('rich-format-panel')), findsNothing);
      expect(find.byType(ModMonthComposer), findsOneWidget);
      tester.view.physicalSize = const Size(320, 700);
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      final heading = editor.document.root.children[1];
      final beforeOutline = jsonEncode(editor.document.toJson());
      await tester.tap(
        find.byKey(const ValueKey('long-document-outline-button')),
      );
      await tester.pumpAndSettle();
      expect(find.byKey(ValueKey('outline-${heading.id}')), findsOneWidget);
      await tester.binding.handlePopRoute();
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('long-document-more')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('long-document-outline')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(ValueKey('outline-${heading.id}')));
      await tester.pumpAndSettle();
      expect(jsonEncode(editor.document.toJson()), beforeOutline);
      expect((await repository.load(topic.id, '2026-11')).blocks, isEmpty);
      tester.view.physicalSize = const Size(430, 900);
      await tester.pumpAndSettle();
      await tester.pump(const Duration(milliseconds: 700));
      await tester.pumpAndSettle();
      final draft = drafts.draft('unified-test');
      expect(draft, isNotNull);
      expect(
        DailyNotesDocumentEnvelope.hasNativeDocument(draft!['body'] as String),
        isTrue,
      );
      expect(
        DailyNotesDocumentEnvelope.plainText(
          DailyNotesDocumentEnvelope.decode(draft['body'] as String),
        ),
        contains('追加内容参考'),
      );
      expect(
        DailyNotesDocumentEnvelope.plainText(
          DailyNotesDocumentEnvelope.decode(draft['body'] as String),
        ),
        contains('追加标题'),
      );
      expect(
        jsonEncode(
          DailyNotesDocumentEnvelope.decode(draft['body'] as String).toJson(),
        ),
        contains('"code":true'),
      );
      expect(
        jsonEncode(
          DailyNotesDocumentEnvelope.decode(draft['body'] as String).toJson(),
        ),
        contains('"font_family":"serif"'),
      );
      expect(
        jsonEncode(
          DailyNotesDocumentEnvelope.decode(draft['body'] as String).toJson(),
        ),
        contains('"href":"https://example.com"'),
      );
      expect((await repository.load(topic.id, '2026-11')).blocks, isEmpty);
      await tester.tap(find.widgetWithText(FilledButton, l10n.common.save));
      await tester.pumpAndSettle();
      final block = (await repository.load(topic.id, '2026-11')).blocks.single;
      expect(
        DailyNotesDocumentEnvelope.plainText(
          DailyNotesDocumentEnvelope.decode(block.tiptapJson),
        ),
        contains('追加标题'),
      );
      expect(
        DailyNotesDocumentEnvelope.hasNativeDocument(block.tiptapJson),
        isTrue,
      );
      expect(
        jsonEncode(
          DailyNotesDocumentEnvelope.decode(block.tiptapJson).toJson(),
        ),
        contains('"bold":true'),
      );
      expect(
        jsonEncode(
          DailyNotesDocumentEnvelope.decode(block.tiptapJson).toJson(),
        ),
        contains('"code":true'),
      );
      expect(
        jsonEncode(
          DailyNotesDocumentEnvelope.decode(block.tiptapJson).toJson(),
        ),
        contains('"href":"https://example.com"'),
      );
      expect(drafts.draft('unified-test'), isNull);
      await tester.pumpWidget(
        app(
          ModMonthComposer(
            repository: repository,
            topicId: topic.id,
            topicTitle: topic.title,
            monthKey: '2026-11',
            block: block,
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(
        tester
            .widget<af.AppFlowyEditor>(find.byType(af.AppFlowyEditor))
            .editable,
        isFalse,
      );
      expect(find.byTooltip(l10n.dailynotes.unlockEditing), findsOneWidget);
      await tester.tap(find.byTooltip(l10n.dailynotes.unlockEditing));
      await tester.pumpAndSettle();
      expect(
        tester
            .widget<af.AppFlowyEditor>(find.byType(af.AppFlowyEditor))
            .editable,
        isTrue,
      );
      await tester.pumpWidget(const SizedBox());
      drafts.dispose();
      await db.close();
    },
  );
}
