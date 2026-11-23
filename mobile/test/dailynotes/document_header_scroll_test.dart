import 'dart:convert';

import 'package:appflowy_editor/appflowy_editor.dart' as af;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:moodiary_data/moodiary_data.dart';
import 'package:moodiary_di/moodiary_di.dart';
import 'package:moodiary_i18n/moodiary_i18n.dart';
import 'package:moodiary_mobile/app/dailynotes/data/daily_notes_store.dart';
import 'package:moodiary_mobile/app/dailynotes/diary/rich_diary_page.dart';
import 'package:moodiary_mobile/app/dailynotes/editor/document_canvas.dart';
import 'package:moodiary_mobile/app/dailynotes/editor/document_envelope.dart';
import 'package:moodiary_mobile/app/dailynotes/notes/rich_note_editor_page.dart';
import 'package:moodiary_mobile/app/home/mod_continuous.dart';
import 'package:moodiary_mobile/app/home/mod_month_composer.dart';
import 'package:moodiary_mobile/app/home/mod_month_native.dart';
import 'package:moodiary_mobile/app/home/mod_month_store.dart';
import 'package:moodiary_models/moodiary_models.dart';
import 'package:moodiary_storage/moodiary_storage.dart';
import 'package:moodiary_storage/testing.dart';
import 'package:mui/mui.dart';

Widget _app(Widget home) => TranslationProvider(
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

af.Document _longDocument() => af.Document(
  root: af.pageNode(
    children: [
      for (var i = 0; i < 40; i++) af.paragraphNode(text: '第 $i 行正文内容'),
    ],
  ),
);

Future<void> _checkHeaderScroll(WidgetTester tester, String key) async {
  final canvas = tester.widget<DailyNotesDocumentCanvas>(
    find.byType(DailyNotesDocumentCanvas),
  );
  final scroll = canvas.scrollController;
  expect(find.byKey(ValueKey(key)), findsOneWidget);
  expect(scroll.itemScrollController.isAttached, isTrue);
  bool headerVisible() => scroll.itemPositionsListener.itemPositions.value.any(
    (item) =>
        item.index == 0 &&
        item.itemTrailingEdge > 0 &&
        item.itemLeadingEdge < 1,
  );
  expect(headerVisible(), isTrue);
  scroll.itemScrollController.jumpTo(index: 25);
  await tester.pumpAndSettle();
  expect(headerVisible(), isFalse);
  scroll.itemScrollController.jumpTo(index: 0);
  await tester.pumpAndSettle();
  expect(headerVisible(), isTrue);
  expect(find.byKey(ValueKey(key)), findsOneWidget);
}

void main() {
  setUpAll(() async {
    getIt.registerSingleton<IKVStorage>(MemoryKVStorage());
    await setupPluralResolvers();
    await LocaleSettings.setLocale(AppLocale.zh);
  });
  tearDownAll(() => getIt.reset());

  testWidgets('note title, folder and tags scroll with its document', (
    tester,
  ) async {
    final db = MoodiaryDatabase.forTesting(NativeDatabase.memory());
    final store = DailyNotesStore(db);
    await store.open();
    final folder = await store.createFolder('项目资料');
    final document = jsonEncode(_longDocument().toJson());
    final note = await store.saveRichNote(
      title: '独立笔记标题',
      plainText: '正文',
      documentJson: document,
      documentVersion: 1,
      folderId: folder.id,
      tags: ['重要'],
    );
    final pending = store.pendingOperationCount;
    await tester.binding.setSurfaceSize(const Size(430, 700));
    addTearDown(() async {
      await tester.pumpWidget(const SizedBox());
      store.dispose();
      await db.close();
      await tester.binding.setSurfaceSize(null);
    });
    await tester.pumpWidget(_app(RichNoteEditorPage(store: store, note: note)));
    await tester.pumpAndSettle();
    expect(find.text('项目资料'), findsOneWidget);
    expect(find.text('#重要'), findsOneWidget);
    expect(
      tester.widget<TextField>(find.byType(TextField).first).controller!.text,
      '独立笔记标题',
    );
    await _checkHeaderScroll(tester, 'note-document-header');
    expect(find.text('项目资料'), findsOneWidget);
    expect(find.text('#重要'), findsOneWidget);
    expect(
      tester.widget<TextField>(find.byType(TextField).first).controller!.text,
      '独立笔记标题',
    );
    expect(store.notes.single.documentJson, document);
    expect(store.notes.single.folderId, folder.id);
    expect(store.pendingOperationCount, pending);
    await tester.tap(find.byTooltip(l10n.dailynotes.unlockEditing));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField).first, '滚动时输入的标题');
    await tester.pump();
    final scroll = tester
        .widget<DailyNotesDocumentCanvas>(find.byType(DailyNotesDocumentCanvas))
        .scrollController;
    scroll.itemScrollController.jumpTo(index: 25);
    await tester.pump(const Duration(milliseconds: 32));
    scroll.itemScrollController.jumpTo(index: 0);
    await tester.pump(const Duration(milliseconds: 32));
    expect(
      tester.widget<TextField>(find.byType(TextField).first).controller!.text,
      '滚动时输入的标题',
    );
    await tester.pump(const Duration(milliseconds: 700));
    await tester.pumpAndSettle();
    expect(store.notes.single.title, '滚动时输入的标题');
    expect(store.notes.single.documentJson, document);
  });

  testWidgets('diary date and title scroll with the same document', (
    tester,
  ) async {
    final db = MoodiaryDatabase.forTesting(NativeDatabase.memory());
    final repository = DiaryRepository(db);
    final document = DailyNotesDocumentEnvelope.encode(_longDocument());
    final diary = Diary.create(
      title: '日记业务标题',
      content: document,
      contentText: '正文',
      imageName: [],
      audioName: [],
      videoName: [],
      tags: [],
      type: DiaryType.tiptap,
    );
    await repository.insertADiary(diary);
    await tester.binding.setSurfaceSize(const Size(430, 700));
    addTearDown(() async {
      await tester.pumpWidget(const SizedBox());
      await db.close();
      await tester.binding.setSurfaceSize(null);
    });
    await tester.pumpWidget(
      _app(RichDiaryPage(repository: repository, diary: diary)),
    );
    await tester.pumpAndSettle();
    expect(
      tester.widget<TextField>(find.byType(TextField).first).controller!.text,
      '日记业务标题',
    );
    await _checkHeaderScroll(tester, 'diary-document-header');
    expect(
      tester.widget<TextField>(find.byType(TextField).first).controller!.text,
      '日记业务标题',
    );
    expect(
      (await repository.getDiaryByBusinessId(diary.id))!.content,
      document,
    );
  });

  testWidgets('long-record header scrolls while the draft stays unsubmitted', (
    tester,
  ) async {
    final db = MoodiaryDatabase.forTesting(NativeDatabase.memory());
    final diaries = DiaryRepository(db);
    final topic = Diary.create(
      title: '长期项目',
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
    await tester.binding.setSurfaceSize(const Size(430, 700));
    addTearDown(() async {
      await tester.pumpWidget(const SizedBox());
      drafts.dispose();
      await db.close();
      await tester.binding.setSurfaceSize(null);
    });
    await tester.pumpWidget(
      _app(
        ModMonthComposer(
          repository: repository,
          topicId: topic.id,
          topicTitle: topic.title,
          monthKey: '2026-11',
          initialDayKey: '2026-11-17',
          draftStore: drafts,
          draftKey: 'header-scroll-test',
        ),
      ),
    );
    await tester.pumpAndSettle();
    final editor = tester
        .widget<af.AppFlowyEditor>(find.byType(af.AppFlowyEditor))
        .editorState;
    await editor.apply(
      editor.transaction..insertNodes(
        [1],
        [for (var i = 0; i < 40; i++) af.paragraphNode(text: '追加 $i')],
      ),
    );
    await tester.pump(const Duration(milliseconds: 700));
    await tester.pumpAndSettle();
    final before = jsonEncode(editor.document.toJson());
    expect(find.text('长期项目'), findsOneWidget);
    await _checkHeaderScroll(tester, 'long-document-header');
    expect(find.text('长期项目'), findsOneWidget);
    expect(jsonEncode(editor.document.toJson()), before);
    expect(drafts.draft('header-scroll-test'), isNotNull);
    expect((await repository.load(topic.id, '2026-11')).blocks, isEmpty);
  });
}
