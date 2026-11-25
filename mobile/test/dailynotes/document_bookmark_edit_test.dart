// The app still uses this bridge during its Material migration.
// ignore_for_file: deprecated_member_use

import 'dart:convert';

import 'package:appflowy_editor/appflowy_editor.dart' as af;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:moodiary_data/moodiary_data.dart';
import 'package:moodiary_di/moodiary_di.dart';
import 'package:moodiary_i18n/moodiary_i18n.dart';
import 'package:moodiary_mobile/app/dailynotes/data/daily_notes_store.dart';
import 'package:moodiary_mobile/app/dailynotes/diary/rich_diary_page.dart';
import 'package:moodiary_mobile/app/dailynotes/editor/document_bookmark_store.dart';
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

class _UncertainLongRecordRepository extends ModNativeMonthRepository {
  _UncertainLongRecordRepository({
    required super.store,
    required super.diaries,
  });

  bool loseAcknowledgement = false;

  @override
  Future<ModStoredBlock> commit(ModMonthMutation operation) async {
    final saved = await super.commit(operation);
    if (loseAcknowledgement) throw StateError('acknowledgement lost');
    return saved;
  }
}

Widget _app(Widget page) => TranslationProvider(
  child: MaterialApp(
    theme: buildMuiTheme(brightness: Brightness.light),
    localizationsDelegates: const [
      af.AppFlowyEditorLocalizations.delegate,
      ...GlobalMaterialLocalizations.delegates,
      GlobalMuiLocalizations.delegate,
    ],
    builder: (context, child) => MaterialUiCompatibilityBridge(child: child!),
    home: page,
  ),
);

af.Document _document([String prefix = '正文']) => af.Document(
  root: af.pageNode(
    children: [
      for (var i = 0; i < 60; i++) af.paragraphNode(text: '$prefix $i'),
    ],
  ),
);

DailyNotesDocumentCanvas _canvas(WidgetTester tester) => tester
    .widget<DailyNotesDocumentCanvas>(find.byType(DailyNotesDocumentCanvas));

double _leading(WidgetTester tester, int index) =>
    _canvas(tester).scrollController.itemPositionsListener.itemPositions.value
        .singleWhere((item) => item.index == index)
        .itemLeadingEdge;

Future<void> _open(WidgetTester tester, String type) async {
  await tester.tap(find.byKey(ValueKey('$type-document-more')));
  await tester.pumpAndSettle();
  await tester.tap(find.byKey(ValueKey('$type-document-bookmarks')));
  await tester.pumpAndSettle();
}

Future<void> _add(WidgetTester tester, String type, String name) async {
  _canvas(tester).scrollController.itemScrollController
      .jumpTo(index: 25, alignment: 0.2);
  await tester.pumpAndSettle();
  await _open(tester, type);
  await tester.tap(find.byKey(const ValueKey('bookmark-add')));
  await tester.pumpAndSettle();
  await tester.enterText(
    find.byKey(const ValueKey('bookmark-name-input')),
    name,
  );
  await tester.tap(find.byKey(const ValueKey('bookmark-name-save')));
  await tester.pumpAndSettle();
  expect(find.text(name), findsOneWidget);
  await tester.binding.handlePopRoute();
  await tester.pumpAndSettle();
}

Future<void> _menu(WidgetTester tester, String name, String action) async {
  final row = find.ancestor(
    of: find.text(name),
    matching: find.byType(ListTile),
  );
  await tester.tap(
    find.descendant(
      of: row,
      matching: find.byWidgetPredicate(
        (widget) =>
            widget.key is ValueKey<String> &&
            (widget.key! as ValueKey<String>).value.startsWith(
              'bookmark-actions-',
            ),
      ),
    ),
  );
  await tester.pumpAndSettle();
  await tester.tap(find.text(action).last);
  await tester.pumpAndSettle();
}

void main() {
  late MemoryKVStorage storage;
  setUpAll(() async {
    await setupPluralResolvers();
    await LocaleSettings.setLocale(AppLocale.zh);
  });
  setUp(() {
    storage = MemoryKVStorage();
    getIt.registerSingleton<IKVStorage>(storage);
  });
  tearDown(() => getIt.reset());

  testWidgets('saved note edits follow the original bookmarked block', (
    tester,
  ) async {
    final db = MoodiaryDatabase.forTesting(NativeDatabase.memory());
    final store = DailyNotesStore(db);
    await store.open();
    final document = _document();
    final note = await store.saveRichNote(
      title: '笔记',
      plainText: '正文',
      documentJson: jsonEncode(document.toJson()),
      documentVersion: 1,
    );
    document.dispose();
    final bookmarks = DocumentBookmarkStore(storage, 'note:${note.id}');
    await tester.binding.setSurfaceSize(const Size(430, 700));
    addTearDown(() async {
      await tester.pumpWidget(const SizedBox());
      store.dispose();
      await db.close();
      await tester.binding.setSurfaceSize(null);
    });
    await tester.pumpWidget(_app(RichNoteEditorPage(store: store, note: note)));
    await tester.pumpAndSettle();
    await _add(tester, 'note', '章节');
    final original = bookmarks.load().items.single;
    final editor = _canvas(tester).editor;
    final target = editor.document.root.children[original.index - 1];
    await tester.tap(find.byTooltip(l10n.dailynotes.unlockEditing));
    await tester.pumpAndSettle();
    await editor.apply(
      editor.transaction..insertNode([0], af.paragraphNode(text: '新增')),
    );
    await tester.pump(const Duration(milliseconds: 800));
    await tester.pumpAndSettle();
    var updated = bookmarks.load().items.single;
    expect(updated.id, original.id);
    expect(updated.index, original.index + 1);
    expect(documentBookmarkMatches(editor, updated), isTrue);
    await editor.insertText(0, '修改', path: target.path);
    await tester.pump(const Duration(milliseconds: 800));
    await tester.pumpAndSettle();
    updated = bookmarks.load().items.single;
    expect(updated.id, original.id);
    expect(documentBookmarkMatches(editor, updated), isTrue);
    final saved = store.notes.single;
    await tester.pumpWidget(const SizedBox());
    await tester.pumpWidget(
      _app(RichNoteEditorPage(store: store, note: saved)),
    );
    await tester.pumpAndSettle();
    _canvas(tester).scrollController.itemScrollController.jumpTo(index: 3);
    await tester.pumpAndSettle();
    await _open(tester, 'note');
    expect(find.text(l10n.dailynotes.bookmarkUnavailable), findsNothing);
    await tester.tap(find.text('章节'));
    await tester.pumpAndSettle();
    expect(_leading(tester, updated.index), closeTo(updated.alignment, 0.03));
  });

  testWidgets('diary saves carry its original bookmark to the new position', (
    tester,
  ) async {
    final db = MoodiaryDatabase.forTesting(NativeDatabase.memory());
    final repository = DiaryRepository(db);
    final document = _document();
    final body = DailyNotesDocumentEnvelope.encode(document);
    document.dispose();
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
    final persisted = (await repository.getDiaryByBusinessId(diary.id))!;
    final bookmarks = DocumentBookmarkStore(storage, 'diary:${diary.id}');
    await tester.binding.setSurfaceSize(const Size(430, 700));
    addTearDown(() async {
      await tester.pumpWidget(const SizedBox());
      await db.close();
      await tester.binding.setSurfaceSize(null);
    });
    await tester.pumpWidget(
      _app(RichDiaryPage(repository: repository, diary: persisted)),
    );
    await tester.pumpAndSettle();
    await _add(tester, 'diary', '日记位置');
    final original = bookmarks.load().items.single;
    await tester.tap(find.byTooltip(l10n.dailynotes.unlockEditing));
    await tester.pumpAndSettle();
    final editor = _canvas(tester).editor;
    await editor.apply(
      editor.transaction..insertNode([0], af.paragraphNode(text: '新增')),
    );
    await tester.pump(const Duration(milliseconds: 800));
    await tester.pumpAndSettle();
    final updated = bookmarks.load().items.single;
    expect(updated.index, original.index + 1);
    expect(documentBookmarkMatches(editor, updated), isTrue);
    final saved = (await repository.getDiaryByBusinessId(diary.id))!;
    expect(saved.content, isNot(body));
    await tester.pumpWidget(const SizedBox());
    await tester.pumpWidget(
      _app(RichDiaryPage(repository: repository, diary: saved)),
    );
    await tester.pumpAndSettle();
    await _open(tester, 'diary');
    expect(find.text('日记位置'), findsOneWidget);
    expect(find.text(l10n.dailynotes.bookmarkUnavailable), findsNothing);
  });

  testWidgets('long-record bookmarks advance only after a formal commit', (
    tester,
  ) async {
    final db = MoodiaryDatabase.forTesting(NativeDatabase.memory());
    final diaries = DiaryRepository(db);
    final topic = Diary.create(
      title: '长期记录',
      content: '',
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
    final document = _document();
    final body = DailyNotesDocumentEnvelope.encode(document);
    document.dispose();
    final block = await repository.commit(
      ModMonthMutation(
        operationId: 'rebase-operation-1',
        revisionId: 'rebase-revision-1',
        blockId: 'rebase-block-1',
        topicId: topic.id,
        monthKey: '2026-11',
        kind: 'entry',
        parentRevisionId: null,
        dayKey: '2026-11-17',
        occurredAtMs: DateTime(2026, 11, 17).millisecondsSinceEpoch,
        tiptapJson: body,
      ),
    );
    final identity = 'long:${jsonEncode([topic.id, block.blockId])}';
    final bookmarks = DocumentBookmarkStore(storage, identity);
    await tester.binding.setSurfaceSize(const Size(430, 700));
    addTearDown(() async {
      await tester.pumpWidget(const SizedBox());
      await db.close();
      await tester.binding.setSurfaceSize(null);
    });
    await tester.pumpWidget(
      _app(
        Scaffold(
          body: Builder(
            builder: (context) => TextButton(
              onPressed: () => Navigator.of(context).push(
                MaterialPageRoute<void>(
                  builder: (_) => ModMonthComposer(
                    repository: repository,
                    topicId: topic.id,
                    topicTitle: topic.title,
                    monthKey: '2026-11',
                    block: block,
                  ),
                ),
              ),
              child: const Text('打开'),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('打开'));
    await tester.pumpAndSettle();
    await _add(tester, 'long', '长期位置');
    final original = bookmarks.load().items.single;
    await tester.tap(find.byTooltip(l10n.dailynotes.unlockEditing));
    await tester.pumpAndSettle();
    final editor = _canvas(tester).editor;
    await editor.apply(
      editor.transaction..insertNode([0], af.paragraphNode(text: '新增')),
    );
    await tester.pumpAndSettle();
    expect(bookmarks.load().items.single.digest, original.digest);
    expect(
      (await repository.load(topic.id, '2026-11')).blocks.single.revisionId,
      block.revisionId,
    );
    await tester.tap(find.widgetWithText(FilledButton, l10n.common.save));
    await tester.pumpAndSettle();
    final saved = (await repository.load(topic.id, '2026-11')).blocks.single;
    expect(saved.revisionId, isNot(block.revisionId));
    final reopened = af.EditorState(
      document: DailyNotesDocumentEnvelope.decode(saved.tiptapJson),
    );
    final updated = bookmarks.load().items.single;
    expect(updated.index, original.index + 1);
    expect(documentBookmarkMatches(reopened, updated), isTrue);
    reopened.dispose();
  });

  testWidgets('a stale bookmark is rebound only after explicit confirmation', (
    tester,
  ) async {
    final db = MoodiaryDatabase.forTesting(NativeDatabase.memory());
    final store = DailyNotesStore(db);
    await store.open();
    final document = _document();
    final note = await store.saveRichNote(
      title: '笔记',
      plainText: '正文',
      documentJson: jsonEncode(document.toJson()),
      documentVersion: 1,
    );
    document.dispose();
    final bookmarks = DocumentBookmarkStore(storage, 'note:${note.id}');
    await tester.binding.setSurfaceSize(const Size(430, 700));
    addTearDown(() async {
      await tester.pumpWidget(const SizedBox());
      store.dispose();
      await db.close();
      await tester.binding.setSurfaceSize(null);
    });
    await tester.pumpWidget(_app(RichNoteEditorPage(store: store, note: note)));
    await tester.pumpAndSettle();
    await _add(tester, 'note', '旧书签');
    final previous = bookmarks.load();
    await tester.pumpWidget(const SizedBox());
    final changed = _document('外部改动');
    final revised = await store.saveRichNote(
      id: note.id,
      expectedRevision: note.storageRevision,
      title: note.title,
      plainText: '外部改动',
      documentJson: jsonEncode(changed.toJson()),
      documentVersion: 1,
    );
    changed.dispose();
    await tester.pumpWidget(
      _app(RichNoteEditorPage(store: store, note: revised)),
    );
    await tester.pumpAndSettle();
    _canvas(tester).scrollController.itemScrollController
        .jumpTo(index: 35, alignment: 0.2);
    await tester.pumpAndSettle();
    final expected = _leading(tester, 35);
    await _open(tester, 'note');
    expect(find.text(l10n.dailynotes.bookmarkUnavailable), findsOneWidget);
    await _menu(tester, '旧书签', l10n.dailynotes.bookmarkRebind);
    await tester.tap(find.text(l10n.dailynotes.cancel).last);
    await tester.pumpAndSettle();
    expect(bookmarks.load().raw, previous.raw);
    await _menu(tester, '旧书签', l10n.dailynotes.bookmarkRebind);
    await tester.tap(find.byKey(const ValueKey('bookmark-rebind-confirm')));
    await tester.pumpAndSettle();
    final rebound = bookmarks.load().items.single;
    expect(rebound.id, previous.items.single.id);
    expect(rebound.name, '旧书签');
    expect(documentBookmarkMatches(_canvas(tester).editor, rebound), isTrue);
    await tester.binding.handlePopRoute();
    await tester.pumpAndSettle();
    _canvas(tester).scrollController.itemScrollController.jumpTo(index: 3);
    await tester.pumpAndSettle();
    await _open(tester, 'note');
    await tester.tap(find.text('旧书签'));
    await tester.pumpAndSettle();
    expect(_leading(tester, 35), closeTo(expected, 0.03));
    expect(store.notes.single.documentJson, revised.documentJson);
  });

  testWidgets('a failed note save does not advance a bookmark until retry', (
    tester,
  ) async {
    final db = MoodiaryDatabase.forTesting(NativeDatabase.memory());
    var failSave = false;
    final store = DailyNotesStore(
      db,
      beforeOutboxWrite: () async {
        if (failSave) throw StateError('disk failure');
      },
    );
    await store.open();
    final document = _document();
    final note = await store.saveRichNote(
      title: '笔记',
      plainText: '正文',
      documentJson: jsonEncode(document.toJson()),
      documentVersion: 1,
    );
    document.dispose();
    final bookmarks = DocumentBookmarkStore(storage, 'note:${note.id}');
    await tester.binding.setSurfaceSize(const Size(430, 700));
    addTearDown(() async {
      await tester.pumpWidget(const SizedBox());
      store.dispose();
      await db.close();
      await tester.binding.setSurfaceSize(null);
    });
    await tester.pumpWidget(_app(RichNoteEditorPage(store: store, note: note)));
    await tester.pumpAndSettle();
    await _add(tester, 'note', '保存位置');
    final previous = bookmarks.load();
    await tester.tap(find.byTooltip(l10n.dailynotes.unlockEditing));
    await tester.pumpAndSettle();
    failSave = true;
    final editor = _canvas(tester).editor;
    await editor.apply(
      editor.transaction..insertNode([0], af.paragraphNode(text: '未保存')),
    );
    await tester.pump(const Duration(milliseconds: 800));
    await tester.pumpAndSettle();
    expect(bookmarks.load().raw, previous.raw);
    expect(find.text(l10n.dailynotes.retry), findsOneWidget);
    await _open(tester, 'note');
    expect(find.text(l10n.dailynotes.bookmarkUnavailable), findsOneWidget);
    await _menu(tester, '保存位置', l10n.dailynotes.bookmarkRebind);
    expect(find.text(l10n.dailynotes.bookmarkSaveFirst), findsOneWidget);
    await tester.binding.handlePopRoute();
    await tester.pumpAndSettle();
    failSave = false;
    await tester.tap(find.text(l10n.dailynotes.retry));
    await tester.pumpAndSettle();
    final updated = bookmarks.load().items.single;
    expect(updated.index, previous.items.single.index + 1);
    expect(documentBookmarkMatches(editor, updated), isTrue);
    expect(store.notes.single.body, contains('未保存'));
  });

  testWidgets('replacing the target with identical text does not restore it', (
    tester,
  ) async {
    final db = MoodiaryDatabase.forTesting(NativeDatabase.memory());
    final store = DailyNotesStore(db);
    await store.open();
    final document = _document();
    final note = await store.saveRichNote(
      title: '笔记',
      plainText: '正文',
      documentJson: jsonEncode(document.toJson()),
      documentVersion: 1,
    );
    document.dispose();
    final bookmarks = DocumentBookmarkStore(storage, 'note:${note.id}');
    await tester.binding.setSurfaceSize(const Size(430, 700));
    addTearDown(() async {
      await tester.pumpWidget(const SizedBox());
      store.dispose();
      await db.close();
      await tester.binding.setSurfaceSize(null);
    });
    await tester.pumpWidget(_app(RichNoteEditorPage(store: store, note: note)));
    await tester.pumpAndSettle();
    await _add(tester, 'note', '原区块');
    final previous = bookmarks.load().items.single;
    final editor = _canvas(tester).editor;
    await tester.tap(find.byTooltip(l10n.dailynotes.unlockEditing));
    await tester.pumpAndSettle();
    final target = editor.document.root.children[previous.index - 1];
    final replacement = target.copyWith();
    await editor.apply(editor.transaction..deleteNode(target));
    await editor.apply(
      editor.transaction..insertNode([previous.index - 1], replacement),
    );
    expect(documentBookmarkDigest(editor), previous.digest);
    await tester.pump(const Duration(milliseconds: 800));
    await tester.pumpAndSettle();
    final invalidated = bookmarks.load().items.single;
    expect(invalidated.invalidated, isTrue);
    expect(documentBookmarkMatches(editor, invalidated), isFalse);
    await _open(tester, 'note');
    expect(find.text(l10n.dailynotes.bookmarkUnavailable), findsOneWidget);
    expect(find.text('原区块'), findsOneWidget);
  });

  testWidgets('an uncertain long-record commit leaves bookmarks until retry', (
    tester,
  ) async {
    final db = MoodiaryDatabase.forTesting(NativeDatabase.memory());
    final diaries = DiaryRepository(db);
    final topic = Diary.create(
      title: '长期记录',
      content: '',
      contentText: '',
      imageName: [],
      audioName: [],
      videoName: [],
      tags: [ModDiary.topicTag],
      type: DiaryType.tiptap,
    );
    await diaries.insertADiary(topic);
    final repository = _UncertainLongRecordRepository(
      store: ModMonthStore(db),
      diaries: diaries,
    );
    final document = _document();
    final body = DailyNotesDocumentEnvelope.encode(document);
    document.dispose();
    final block = await repository.commit(
      ModMonthMutation(
        operationId: 'uncertain-operation-1',
        revisionId: 'uncertain-revision-1',
        blockId: 'uncertain-block-1',
        topicId: topic.id,
        monthKey: '2026-11',
        kind: 'entry',
        parentRevisionId: null,
        dayKey: '2026-11-17',
        occurredAtMs: DateTime(2026, 11, 17).millisecondsSinceEpoch,
        tiptapJson: body,
      ),
    );
    final identity = 'long:${jsonEncode([topic.id, block.blockId])}';
    final bookmarks = DocumentBookmarkStore(storage, identity);
    await tester.binding.setSurfaceSize(const Size(430, 700));
    addTearDown(() async {
      await tester.pumpWidget(const SizedBox());
      await db.close();
      await tester.binding.setSurfaceSize(null);
    });
    await tester.pumpWidget(
      _app(
        Scaffold(
          body: Builder(
            builder: (context) => TextButton(
              onPressed: () => Navigator.of(context).push(
                MaterialPageRoute<void>(
                  builder: (_) => ModMonthComposer(
                    repository: repository,
                    topicId: topic.id,
                    topicTitle: topic.title,
                    monthKey: '2026-11',
                    block: block,
                  ),
                ),
              ),
              child: const Text('打开'),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('打开'));
    await tester.pumpAndSettle();
    await _add(tester, 'long', '未确认位置');
    final previous = bookmarks.load();
    await tester.tap(find.byTooltip(l10n.dailynotes.unlockEditing));
    await tester.pumpAndSettle();
    final editor = _canvas(tester).editor;
    await editor.apply(
      editor.transaction..insertNode([0], af.paragraphNode(text: '新增')),
    );
    await tester.pumpAndSettle();
    repository.loseAcknowledgement = true;
    await tester.tap(find.widgetWithText(FilledButton, l10n.common.save));
    await tester.pumpAndSettle();
    final committed = (await repository.load(
      topic.id,
      '2026-11',
    )).blocks.single;
    expect(committed.revisionId, isNot(block.revisionId));
    expect(bookmarks.load().raw, previous.raw);
    expect(find.text(l10n.month.uncertain), findsOneWidget);
    repository.loseAcknowledgement = false;
    await tester.tap(find.widgetWithText(FilledButton, l10n.month.retrySame));
    await tester.pumpAndSettle();
    final confirmed = (await repository.load(
      topic.id,
      '2026-11',
    )).blocks.single;
    expect(confirmed.revisionId, committed.revisionId);
    final reopened = af.EditorState(
      document: DailyNotesDocumentEnvelope.decode(confirmed.tiptapJson),
    );
    final updated = bookmarks.load().items.single;
    expect(updated.index, previous.items.single.index + 1);
    expect(documentBookmarkMatches(reopened, updated), isTrue);
    reopened.dispose();
  });
}
