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
import 'package:moodiary_mobile/app/home/mod_month_composer.dart';
import 'package:moodiary_mobile/app/home/mod_month_native.dart';
import 'package:moodiary_mobile/app/home/mod_month_store.dart';
import 'package:moodiary_models/moodiary_models.dart';
import 'package:moodiary_storage/moodiary_storage.dart';
import 'package:moodiary_storage/testing.dart';
import 'package:mui/mui.dart';

Widget _app(Widget page) => TranslationProvider(
  child: MaterialApp(
    theme: buildMuiTheme(brightness: Brightness.light),
    localizationsDelegates: const [
      af.AppFlowyEditorLocalizations.delegate,
      ...GlobalMaterialLocalizations.delegates,
      GlobalMuiLocalizations.delegate,
    ],
    // Match the application's compatibility wrapper.
    // ignore: deprecated_member_use
    builder: (context, child) => MaterialUiCompatibilityBridge(child: child!),
    home: page,
  ),
);

af.Document _document() => af.Document(
  root: af.pageNode(
    children: [
      for (var i = 0; i < 32; i++) af.paragraphNode(text: '正文 $i'),
      af.headingNode(level: 2, text: '远处标题'),
      for (var i = 33; i < 45; i++) af.paragraphNode(text: '正文 $i'),
    ],
  ),
);

Future<void> _exerciseReturn(WidgetTester tester, String buttonKey) async {
  final canvas = tester.widget<DailyNotesDocumentCanvas>(
    find.byType(DailyNotesDocumentCanvas),
  );
  final editor = canvas.editor;
  final scroll = canvas.scrollController;
  final heading = editor.document.root.children[32];
  final original = jsonEncode(editor.document.toJson());
  editor.selection = af.Selection.single(
    path: [0],
    startOffset: 0,
    endOffset: 2,
  );
  final selection = editor.selection;
  expect(selection, isNotNull);
  await tester.pumpAndSettle();
  scroll.itemScrollController.jumpTo(index: 8, alignment: 0.2);
  await tester.pumpAndSettle();
  final before = scroll.itemPositionsListener.itemPositions.value
      .singleWhere((position) => position.index == 8)
      .itemLeadingEdge;
  expect(before, closeTo(0.2, 0.03));
  await tester.tap(find.byKey(ValueKey(buttonKey)));
  await tester.pumpAndSettle();
  expect(find.byKey(const ValueKey('outline-return-previous')), findsNothing);
  await tester.tap(find.byKey(ValueKey('outline-${heading.id}')));
  await tester.pumpAndSettle();
  expect(heading.key.currentContext, isNotNull);
  await tester.tap(find.byKey(ValueKey(buttonKey)));
  await tester.pumpAndSettle();
  expect(find.byKey(const ValueKey('outline-return-previous')), findsOneWidget);
  await tester.tap(find.byKey(const ValueKey('outline-return-previous')));
  await tester.pumpAndSettle();
  final after = scroll.itemPositionsListener.itemPositions.value
      .singleWhere((position) => position.index == 8)
      .itemLeadingEdge;
  expect(after, closeTo(before, 0.03));
  expect(editor.selection, selection);
  expect(jsonEncode(editor.document.toJson()), original);
  await tester.tap(find.byKey(ValueKey(buttonKey)));
  await tester.pumpAndSettle();
  expect(find.byKey(const ValueKey('outline-return-previous')), findsNothing);
  await tester.binding.handlePopRoute();
  await tester.pumpAndSettle();
}

void main() {
  setUpAll(() async {
    getIt.registerSingleton<IKVStorage>(MemoryKVStorage());
    await setupPluralResolvers();
    await LocaleSettings.setLocale(AppLocale.zh);
  });
  tearDownAll(() => getIt.reset());

  testWidgets('note outline returns to the earlier reading position', (
    tester,
  ) async {
    final db = MoodiaryDatabase.forTesting(NativeDatabase.memory());
    final store = DailyNotesStore(db);
    await store.open();
    final doc = _document();
    final note = await store.saveRichNote(
      title: '长笔记',
      plainText: '正文',
      documentJson: jsonEncode(doc.toJson()),
      documentVersion: 1,
    );
    doc.dispose();
    final events = store.pendingOperationCount;
    await tester.binding.setSurfaceSize(const Size(430, 700));
    addTearDown(() async {
      await tester.pumpWidget(const SizedBox());
      store.dispose();
      await db.close();
      await tester.binding.setSurfaceSize(null);
    });
    await tester.pumpWidget(_app(RichNoteEditorPage(store: store, note: note)));
    await tester.pumpAndSettle();
    await _exerciseReturn(tester, 'note-document-outline-button');
    expect(store.pendingOperationCount, events);
  });

  testWidgets('diary outline returns without changing the saved document', (
    tester,
  ) async {
    final db = MoodiaryDatabase.forTesting(NativeDatabase.memory());
    final repository = DiaryRepository(db);
    final doc = _document();
    final body = DailyNotesDocumentEnvelope.encode(doc);
    doc.dispose();
    final diary = Diary.create(
      title: '日记',
      content: body,
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
    await _exerciseReturn(tester, 'diary-document-outline-button');
    expect((await repository.getDiaryByBusinessId(diary.id))!.content, body);
  });

  testWidgets('long-record outline returns without submitting the draft', (
    tester,
  ) async {
    final db = MoodiaryDatabase.forTesting(NativeDatabase.memory());
    final drafts = DailyNotesStore(db);
    await drafts.open();
    final store = ModMonthStore(db);
    final repository = ModNativeMonthRepository(
      store: store,
      diaries: DiaryRepository(db),
    );
    final doc = _document();
    final body = DailyNotesDocumentEnvelope.encode(doc);
    doc.dispose();
    final time = DateTime(2026, 11, 17, 12).millisecondsSinceEpoch;
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
          topicId: 'topic-1',
          topicTitle: '长期记录',
          monthKey: '2026-11',
          initialDayKey: '2026-11-17',
          draftStore: drafts,
          draftKey: 'outline-draft',
          initialDraft: {
            'schemaVersion': 1,
            'blockId': 'block-12345',
            'body': body,
            'dayKey': '2026-11-17',
            'occurredAtMs': time,
            'baselineBody': body,
            'baselineDay': '2026-11-17',
            'baselineEventMs': time,
          },
        ),
      ),
    );
    await tester.pumpAndSettle();
    await _exerciseReturn(tester, 'long-document-outline-button');
    expect(await store.monthKeysForTopic('topic-1'), isEmpty);
    expect(drafts.draft('outline-draft'), isNull);
  });

  testWidgets('outline reaches a heading nested in an offscreen list', (
    tester,
  ) async {
    final db = MoodiaryDatabase.forTesting(NativeDatabase.memory());
    final store = DailyNotesStore(db);
    await store.open();
    final doc = af.Document(
      root: af.pageNode(
        children: [
          for (var i = 0; i < 25; i++) af.paragraphNode(text: '正文 $i'),
          af.bulletedListNode(
            text: '列表容器',
            children: [af.headingNode(level: 2, text: '嵌套标题')],
          ),
          af.paragraphNode(text: '结尾'),
        ],
      ),
    );
    final note = await store.saveRichNote(
      title: '笔记',
      plainText: '正文',
      documentJson: jsonEncode(doc.toJson()),
      documentVersion: 1,
    );
    doc.dispose();
    final events = store.pendingOperationCount;
    await tester.binding.setSurfaceSize(const Size(430, 700));
    addTearDown(() async {
      await tester.pumpWidget(const SizedBox());
      store.dispose();
      await db.close();
      await tester.binding.setSurfaceSize(null);
    });
    await tester.pumpWidget(_app(RichNoteEditorPage(store: store, note: note)));
    await tester.pumpAndSettle();
    final canvas = tester.widget<DailyNotesDocumentCanvas>(
      find.byType(DailyNotesDocumentCanvas),
    );
    final editor = canvas.editor;
    final nested = editor.document.root.children[25].children.single;
    final before = jsonEncode(editor.document.toJson());
    await tester.tap(
      find.byKey(const ValueKey('note-document-outline-button')),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(ValueKey('outline-${nested.id}')));
    await tester.pumpAndSettle();
    expect(nested.key.currentContext, isNotNull);
    final box = nested.key.currentContext!.findRenderObject()! as RenderBox;
    expect(box.localToGlobal(Offset.zero).dy, inInclusiveRange(0, 700));
    expect(jsonEncode(editor.document.toJson()), before);
    expect(store.pendingOperationCount, events);
    expect(find.text(l10n.dailynotes.outlineUnavailable), findsNothing);
  });

  testWidgets(
    'return follows the original block after earlier content is inserted',
    (tester) async {
      final db = MoodiaryDatabase.forTesting(NativeDatabase.memory());
      final store = DailyNotesStore(db);
      await store.open();
      final doc = _document();
      final note = await store.saveRichNote(
        title: '笔记',
        plainText: '正文',
        documentJson: jsonEncode(doc.toJson()),
        documentVersion: 1,
      );
      doc.dispose();
      await tester.binding.setSurfaceSize(const Size(430, 700));
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
      await tester.tap(find.byTooltip(l10n.dailynotes.unlockEditing));
      await tester.pumpAndSettle();
      final canvas = tester.widget<DailyNotesDocumentCanvas>(
        find.byType(DailyNotesDocumentCanvas),
      );
      final editor = canvas.editor;
      final scroll = canvas.scrollController;
      scroll.itemScrollController.jumpTo(index: 8, alignment: 0.2);
      await tester.pumpAndSettle();
      final candidates =
          scroll.itemPositionsListener.itemPositions.value
              .where(
                (p) =>
                    p.itemLeadingEdge >= 0 &&
                    p.itemLeadingEdge < 1 &&
                    p.index > 0,
              )
              .toList()
            ..sort((a, b) => a.itemLeadingEdge.compareTo(b.itemLeadingEdge));
      final anchor = editor.document.root.children[candidates.first.index - 1];
      final originalAnchorIndex = anchor.path.first;
      final alignment = candidates.first.itemLeadingEdge;
      final heading = editor.document.root.children[32];
      await tester.tap(
        find.byKey(const ValueKey('note-document-outline-button')),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(ValueKey('outline-${heading.id}')));
      await tester.pumpAndSettle();
      await editor.apply(
        editor.transaction..insertNode([0], af.paragraphNode(text: '新内容')),
      );
      await tester.pumpAndSettle();
      expect(anchor.path.first, originalAnchorIndex + 1);
      final afterEdit = jsonEncode(editor.document.toJson());
      await tester.tap(
        find.byKey(const ValueKey('note-document-outline-button')),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('outline-return-previous')));
      await tester.pumpAndSettle();
      final anchorPosition = scroll.itemPositionsListener.itemPositions.value
          .singleWhere((position) => position.index == anchor.path.first + 1);
      expect(anchorPosition.itemLeadingEdge, closeTo(alignment, 0.03));
      expect(jsonEncode(editor.document.toJson()), afterEdit);
      expect(
        find.text(l10n.dailynotes.outlinePreviousUnavailable),
        findsNothing,
      );
    },
  );

  testWidgets('a deleted return anchor is not replaced by a nearby block', (
    tester,
  ) async {
    final db = MoodiaryDatabase.forTesting(NativeDatabase.memory());
    final store = DailyNotesStore(db);
    await store.open();
    final doc = _document();
    final note = await store.saveRichNote(
      title: '笔记',
      plainText: '正文',
      documentJson: jsonEncode(doc.toJson()),
      documentVersion: 1,
    );
    doc.dispose();
    await tester.binding.setSurfaceSize(const Size(430, 700));
    addTearDown(() async {
      await tester.pumpWidget(const SizedBox());
      store.dispose();
      await db.close();
      await tester.binding.setSurfaceSize(null);
    });
    await tester.pumpWidget(_app(RichNoteEditorPage(store: store, note: note)));
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip(l10n.dailynotes.unlockEditing));
    await tester.pumpAndSettle();
    final canvas = tester.widget<DailyNotesDocumentCanvas>(
      find.byType(DailyNotesDocumentCanvas),
    );
    final editor = canvas.editor;
    final scroll = canvas.scrollController;
    final heading = editor.document.root.children[32];
    scroll.itemScrollController.jumpTo(index: 8, alignment: 0.2);
    await tester.pumpAndSettle();
    // Remove the whole region around the initial viewport so the test covers
    // whichever fully visible block was captured after closing the outline.
    final removedBlocks = editor.document.root.children.take(26).toList();
    await tester.tap(
      find.byKey(const ValueKey('note-document-outline-button')),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(ValueKey('outline-${heading.id}')));
    await tester.pumpAndSettle();
    for (final node in removedBlocks.reversed) {
      await editor.apply(editor.transaction..deleteNode(node));
    }
    await tester.pumpAndSettle();
    expect(editor.document.root.children.length, 45 - removedBlocks.length);
    final afterDeletion = jsonEncode(editor.document.toJson());
    await tester.tap(
      find.byKey(const ValueKey('note-document-outline-button')),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('outline-return-previous')));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    await tester.pump();
    expect(
      find.text(l10n.dailynotes.outlinePreviousUnavailable),
      findsOneWidget,
    );
    expect(jsonEncode(editor.document.toJson()), afterDeletion);
    expect(heading.key.currentContext, isNotNull);
    await tester.tap(
      find.byKey(const ValueKey('note-document-outline-button')),
    );
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('outline-return-previous')), findsNothing);
  });
}
