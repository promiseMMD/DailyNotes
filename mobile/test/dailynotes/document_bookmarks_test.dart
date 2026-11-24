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
import 'package:moodiary_mobile/app/dailynotes/editor/document_canvas.dart';
import 'package:moodiary_mobile/app/dailynotes/editor/document_envelope.dart';
import 'package:moodiary_mobile/app/dailynotes/notes/rich_note_editor_page.dart';
import 'package:moodiary_mobile/app/home/mod_continuous.dart';
import 'package:moodiary_mobile/app/home/mod_month_composer.dart';
import 'package:moodiary_mobile/app/home/mod_month_native.dart';
import 'package:moodiary_mobile/app/home/mod_month_store.dart';
import 'package:moodiary_models/moodiary_models.dart';
import 'package:moodiary_storage/moodiary_storage.dart';
import 'package:mui/mui.dart';

class _Storage extends IKVStorage {
  final data = <String, Object>{};
  bool failBookmarkWrite = false;
  bool failAfterBookmarkWrite = false;

  @override
  Future<void> init() async {}
  @override
  T? get<T extends Object>(String key) => data[key] as T?;
  @override
  void set<T extends Object>(String key, T value) {
    if (key.startsWith('dailynotes.bookmarks.') && failBookmarkWrite) {
      throw StateError('write failed');
    }
    data[key] = value;
    if (key.startsWith('dailynotes.bookmarks.') && failAfterBookmarkWrite) {
      throw StateError('result unknown');
    }
    super.set(key, value);
  }

  @override
  void remove(String key) {
    data.remove(key);
    super.remove(key);
  }

  @override
  void clear() => data.clear();
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
      af.headingNode(level: 1, text: '末尾标题'),
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

Future<void> _add(WidgetTester tester, String name) async {
  await tester.tap(find.byKey(const ValueKey('bookmark-add')));
  await tester.pumpAndSettle();
  await tester.enterText(
    find.byKey(const ValueKey('bookmark-name-input')),
    name,
  );
  await tester.tap(find.byKey(const ValueKey('bookmark-name-save')));
  await tester.pumpAndSettle();
  expect(find.text(name), findsOneWidget);
}

Future<void> _action(WidgetTester tester, String name, String action) async {
  final item = find.ancestor(
    of: find.text(name),
    matching: find.byType(ListTile),
  );
  await tester.tap(
    find.descendant(
      of: item,
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
  late _Storage storage;
  setUpAll(() async {
    await setupPluralResolvers();
    await LocaleSettings.setLocale(AppLocale.zh);
  });
  setUp(() {
    storage = _Storage();
    getIt.registerSingleton<IKVStorage>(storage);
  });
  tearDown(() => getIt.reset());

  testWidgets('note bookmarks can be named, reopened, jumped to and undone', (
    tester,
  ) async {
    final db = MoodiaryDatabase.forTesting(NativeDatabase.memory());
    final store = DailyNotesStore(db);
    await store.open();
    final document = _document();
    final body = jsonEncode(document.toJson());
    document.dispose();
    final note = await store.saveRichNote(
      title: '笔记',
      plainText: '正文',
      documentJson: body,
      documentVersion: 1,
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
    final canvas = _canvas(tester);
    final editor = canvas.editor;
    final selection = af.Selection.single(
      path: [0],
      startOffset: 0,
      endOffset: 2,
    );
    editor.selection = selection;
    await tester.pumpAndSettle();
    canvas.scrollController.itemScrollController.jumpTo(
      index: 25,
      alignment: 0.2,
    );
    await tester.pumpAndSettle();
    final bookmarked = _leading(tester, 25);
    await _open(tester, 'note');
    expect(
      editor.selection,
      selection,
      reason: 'selection when bookmark dialog opens',
    );
    await _add(tester, '重点章节');
    expect(editor.selection, selection, reason: 'after adding bookmark');
    await _action(tester, '重点章节', l10n.dailynotes.rename);
    await tester.enterText(
      find.byKey(const ValueKey('bookmark-name-input')),
      '复习位置',
    );
    await tester.tap(find.byKey(const ValueKey('bookmark-name-save')));
    await tester.pumpAndSettle();
    expect(find.text('复习位置'), findsOneWidget);
    await tester.binding.handlePopRoute();
    await tester.pumpAndSettle();
    expect(editor.selection, selection);
    canvas.scrollController.itemScrollController.jumpTo(
      index: 3,
      alignment: 0.2,
    );
    await tester.pumpAndSettle();
    final previous = _leading(tester, 3);
    await _open(tester, 'note');
    await tester.tap(find.text('复习位置'));
    await tester.pumpAndSettle();
    expect(_leading(tester, 25), closeTo(bookmarked, 0.03));
    expect(editor.selection, selection);
    await tester.tap(
      find.byKey(const ValueKey('note-document-outline-button')),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('outline-return-previous')));
    await tester.pumpAndSettle();
    expect(_leading(tester, 3), closeTo(previous, 0.03));
    await _open(tester, 'note');
    await _action(tester, '复习位置', l10n.dailynotes.delete);
    expect(find.text('复习位置'), findsNothing);
    await tester.tap(find.byKey(const ValueKey('bookmark-undo')));
    await tester.pumpAndSettle();
    expect(find.text('复习位置'), findsOneWidget);
    await _action(tester, '复习位置', l10n.dailynotes.delete);
    await tester.binding.handlePopRoute();
    await tester.pumpAndSettle();
    await tester.pumpWidget(const SizedBox());
    await tester.pumpWidget(_app(RichNoteEditorPage(store: store, note: note)));
    await tester.pumpAndSettle();
    await _open(tester, 'note');
    expect(find.text(l10n.dailynotes.bookmarkEmpty), findsOneWidget);
    expect(store.notes.single.documentJson, body);
    expect(store.pendingOperationCount, pending);
  });

  testWidgets('changed documents retain old bookmarks without misdirecting', (
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
    await tester.binding.setSurfaceSize(const Size(430, 700));
    addTearDown(() async {
      await tester.pumpWidget(const SizedBox());
      store.dispose();
      await db.close();
      await tester.binding.setSurfaceSize(null);
    });
    await tester.pumpWidget(_app(RichNoteEditorPage(store: store, note: note)));
    await tester.pumpAndSettle();
    _canvas(tester).scrollController.itemScrollController.jumpTo(index: 25);
    await tester.pumpAndSettle();
    await _open(tester, 'note');
    await _add(tester, '原位置');
    await tester.binding.handlePopRoute();
    await tester.pumpAndSettle();
    await tester.pumpWidget(const SizedBox());
    final changed = _document('修改');
    final revised = await store.saveRichNote(
      id: note.id,
      expectedRevision: note.storageRevision,
      title: note.title,
      plainText: '修改',
      documentJson: jsonEncode(changed.toJson()),
      documentVersion: 1,
    );
    changed.dispose();
    await tester.pumpWidget(
      _app(RichNoteEditorPage(store: store, note: revised)),
    );
    await tester.pumpAndSettle();
    await _open(tester, 'note');
    expect(find.text('原位置'), findsOneWidget);
    expect(find.text(l10n.dailynotes.bookmarkUnavailable), findsOneWidget);
    final tile = tester.widget<ListTile>(
      find.ancestor(of: find.text('原位置'), matching: find.byType(ListTile)),
    );
    expect(tile.onTap, isNull);
  });

  testWidgets('diary bookmarks do not rewrite the saved diary', (tester) async {
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
    _canvas(tester).scrollController.itemScrollController
        .jumpTo(index: 25, alignment: 0.2);
    await tester.pumpAndSettle();
    final original = _leading(tester, 25);
    await _open(tester, 'diary');
    await _add(tester, '日记位置');
    await tester.binding.handlePopRoute();
    await tester.pumpAndSettle();
    await tester.pumpWidget(const SizedBox());
    await tester.pumpWidget(
      _app(RichDiaryPage(repository: repository, diary: diary)),
    );
    await tester.pumpAndSettle();
    _canvas(tester).scrollController.itemScrollController.jumpTo(index: 3);
    await tester.pumpAndSettle();
    await _open(tester, 'diary');
    await tester.tap(find.text('日记位置'));
    await tester.pumpAndSettle();
    expect(_leading(tester, 25), closeTo(original, 0.03));
    expect((await repository.getDiaryByBusinessId(diary.id))!.content, body);
  });

  testWidgets('long-record bookmarks do not submit another revision', (
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
        operationId: 'bookmark-operation-1',
        revisionId: 'bookmark-revision-1',
        blockId: 'bookmark-block-1',
        topicId: topic.id,
        monthKey: '2026-11',
        kind: 'entry',
        parentRevisionId: null,
        dayKey: '2026-11-17',
        occurredAtMs: DateTime(2026, 11, 17).millisecondsSinceEpoch,
        tiptapJson: body,
      ),
    );
    await tester.binding.setSurfaceSize(const Size(430, 700));
    addTearDown(() async {
      await tester.pumpWidget(const SizedBox());
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
          block: block,
        ),
      ),
    );
    await tester.pumpAndSettle();
    _canvas(tester).scrollController.itemScrollController
        .jumpTo(index: 25, alignment: 0.2);
    await tester.pumpAndSettle();
    final original = _leading(tester, 25);
    await _open(tester, 'long');
    await _add(tester, '长期位置');
    await tester.binding.handlePopRoute();
    await tester.pumpAndSettle();
    await tester.pumpWidget(const SizedBox());
    await tester.pumpWidget(
      _app(
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
    _canvas(tester).scrollController.itemScrollController.jumpTo(index: 3);
    await tester.pumpAndSettle();
    await _open(tester, 'long');
    await tester.tap(find.text('长期位置'));
    await tester.pumpAndSettle();
    expect(_leading(tester, 25), closeTo(original, 0.03));
    final blocks = (await repository.load(topic.id, '2026-11')).blocks;
    expect(blocks, hasLength(1));
    expect(blocks.single.revisionId, block.revisionId);
    expect(blocks.single.tiptapJson, body);
  });

  testWidgets(
    'unknown bookmark write outcome blocks further edits until reload',
    (tester) async {
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
      await _open(tester, 'note');
      storage.failAfterBookmarkWrite = true;
      await tester.tap(find.byKey(const ValueKey('bookmark-add')));
      await tester.pumpAndSettle();
      await tester.enterText(
        find.byKey(const ValueKey('bookmark-name-input')),
        '待确认',
      );
      await tester.tap(find.byKey(const ValueKey('bookmark-name-save')));
      await tester.pumpAndSettle();
      expect(find.text(l10n.dailynotes.bookmarkStorageError), findsOneWidget);
      expect(
        tester
            .widget<TextButton>(find.byKey(const ValueKey('bookmark-add')))
            .onPressed,
        isNull,
      );
      storage.failAfterBookmarkWrite = false;
      await tester.binding.handlePopRoute();
      await tester.pumpAndSettle();
      await _open(tester, 'note');
      expect(find.text('待确认'), findsOneWidget);
    },
  );

  testWidgets('unsaved document cannot create a durable bookmark', (
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
    failSave = true;
    final editor = _canvas(tester).editor;
    await editor.insertText(0, '未保存', path: [0]);
    await tester.pump(const Duration(milliseconds: 800));
    await tester.pumpAndSettle();
    expect(find.text(l10n.dailynotes.retry), findsOneWidget);
    await _open(tester, 'note');
    await tester.tap(find.byKey(const ValueKey('bookmark-add')));
    await tester.pumpAndSettle();
    expect(find.text(l10n.dailynotes.bookmarkSaveFirst), findsOneWidget);
    expect(find.byKey(const ValueKey('bookmark-name-input')), findsNothing);
    expect(
      storage.data.keys.any((key) => key.startsWith('dailynotes.bookmarks.')),
      isFalse,
    );
    expect(
      editor.document.root.children.first.delta!.toPlainText(),
      contains('未保存'),
    );
  });

  testWidgets('document edits while naming do not create a stale bookmark', (
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
    final editor = _canvas(tester).editor;
    await _open(tester, 'note');
    await tester.tap(find.byKey(const ValueKey('bookmark-add')));
    await tester.pumpAndSettle();
    await tester.enterText(
      find.byKey(const ValueKey('bookmark-name-input')),
      '旧位置',
    );
    await editor.insertText(0, '新内容', path: [0]);
    await tester.tap(find.byKey(const ValueKey('bookmark-name-save')));
    await tester.pumpAndSettle();
    expect(find.text(l10n.dailynotes.bookmarkChanged), findsOneWidget);
    expect(find.text('旧位置'), findsNothing);
    expect(
      storage.data.keys.any((key) => key.startsWith('dailynotes.bookmarks.')),
      isFalse,
    );
    expect(
      editor.document.root.children.first.delta!.toPlainText(),
      contains('新内容'),
    );
  });

  testWidgets('corrupt bookmark metadata remains intact and disables writes', (
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
    final encoded = base64Url.encode(utf8.encode('note:${note.id}'));
    final key = 'dailynotes.bookmarks.v1.$encoded';
    storage.data[key] = '{invalid';
    await tester.binding.setSurfaceSize(const Size(320, 550));
    addTearDown(() async {
      await tester.pumpWidget(const SizedBox());
      store.dispose();
      await db.close();
      await tester.binding.setSurfaceSize(null);
    });
    await tester.pumpWidget(_app(RichNoteEditorPage(store: store, note: note)));
    await tester.pumpAndSettle();
    await _open(tester, 'note');
    expect(find.text(l10n.dailynotes.bookmarkStorageError), findsOneWidget);
    expect(
      tester
          .widget<TextButton>(find.byKey(const ValueKey('bookmark-add')))
          .onPressed,
      isNull,
    );
    expect(storage.data[key], '{invalid');
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'document changes during a bookmark jump cannot target a replacement',
    (tester) async {
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
      _canvas(tester).scrollController.itemScrollController.jumpTo(index: 25);
      await tester.pumpAndSettle();
      await _open(tester, 'note');
      await _add(tester, '目标');
      await tester.binding.handlePopRoute();
      await tester.pumpAndSettle();
      await tester.tap(find.byTooltip(l10n.dailynotes.unlockEditing));
      await tester.pumpAndSettle();
      final editor = _canvas(tester).editor;
      _canvas(tester).scrollController.itemScrollController.jumpTo(index: 3);
      await tester.pumpAndSettle();
      await _open(tester, 'note');
      await tester.tap(find.text('目标'));
      await editor.insertText(0, '发生变化', path: [0]);
      await tester.pumpAndSettle();
      expect(find.text(l10n.dailynotes.bookmarkUnavailable), findsOneWidget);
      expect(
        editor.document.root.children.first.delta!.toPlainText(),
        contains('发生变化'),
      );
    },
  );

  testWidgets('a new long-record draft must be submitted before bookmarking', (
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
    await tester.binding.setSurfaceSize(const Size(430, 700));
    addTearDown(() async {
      await tester.pumpWidget(const SizedBox());
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
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('long-document-more')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('long-document-bookmarks')));
    await tester.pumpAndSettle();
    expect(find.text(l10n.dailynotes.bookmarkSaveFirst), findsOneWidget);
    expect(find.byKey(const ValueKey('bookmark-add')), findsNothing);
    expect((await repository.load(topic.id, '2026-11')).blocks, isEmpty);
    expect(
      storage.data.keys.any((key) => key.startsWith('dailynotes.bookmarks.')),
      isFalse,
    );
  });
}
