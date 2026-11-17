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
      await tester.pump(const Duration(milliseconds: 700));
      await tester.pumpAndSettle();
      final saved = store.notes.singleWhere((value) => value.id == note.id);
      expect(saved.body, '第一行\n\n第三行续');
      expect(saved.documentJson, isNotNull);
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
      editor.selection = af.Selection.single(
        path: [0],
        startOffset: 0,
        endOffset: 4,
      );
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('rich-toolbar-bold')));
      await tester.pump(const Duration(milliseconds: 700));
      await tester.pumpAndSettle();
      final saved = (await repository.getAllDiaries()).single;
      expect(saved.contentText, contains('日记正文'));
      expect(
        DailyNotesDocumentEnvelope.hasNativeDocument(saved.content),
        isTrue,
      );
      expect(
        jsonEncode(DailyNotesDocumentEnvelope.decode(saved.content).toJson()),
        contains('"bold":true'),
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
      editor.selection = af.Selection.single(
        path: [0],
        startOffset: 0,
        endOffset: 4,
      );
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('rich-toolbar-bold')));
      await tester.pump(const Duration(milliseconds: 700));
      await tester.pumpAndSettle();
      final draft = drafts.draft('unified-test');
      expect(draft, isNotNull);
      expect(
        DailyNotesDocumentEnvelope.hasNativeDocument(draft!['body'] as String),
        isTrue,
      );
      expect((await repository.load(topic.id, '2026-11')).blocks, isEmpty);
      await tester.tap(find.widgetWithText(FilledButton, l10n.common.save));
      await tester.pumpAndSettle();
      final block = (await repository.load(topic.id, '2026-11')).blocks.single;
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
