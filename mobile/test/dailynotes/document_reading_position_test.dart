// The application currently uses this bridge during its Material migration.
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

class _ReadingStorage extends IKVStorage {
  final data = <String, Object>{};
  bool failWrites = false;

  @override
  Future<void> init() async {}

  @override
  T? get<T extends Object>(String key) => data[key] as T?;

  @override
  void set<T extends Object>(String key, T value) {
    if (failWrites) throw StateError('storage unavailable');
    data[key] = value;
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
    ],
  ),
);

af.EditorScrollController _scroll(WidgetTester tester) => tester
    .widget<DailyNotesDocumentCanvas>(find.byType(DailyNotesDocumentCanvas))
    .scrollController;

double _position(WidgetTester tester, int index) =>
    _scroll(tester).itemPositionsListener.itemPositions.value
        .singleWhere((item) => item.index == index)
        .itemLeadingEdge;

Future<double> _moveAndSave(WidgetTester tester) async {
  _scroll(tester).itemScrollController.jumpTo(index: 25, alignment: 0.2);
  await tester.pumpAndSettle();
  final before = _position(tester, 25);
  await tester.pump(const Duration(milliseconds: 750));
  return before;
}

Future<void> _checkReopen(WidgetTester tester, Widget Function() page) async {
  await tester.pumpWidget(_app(page()));
  await tester.pumpAndSettle();
  final before = await _moveAndSave(tester);
  expect(before, closeTo(0.2, 0.03));
  await tester.pumpWidget(const SizedBox());
  await tester.pumpWidget(_app(page()));
  await tester.pumpAndSettle();
  expect(_position(tester, 25), closeTo(before, 0.03));
  final canvas = tester.widget<DailyNotesDocumentCanvas>(
    find.byType(DailyNotesDocumentCanvas),
  );
  expect(canvas.editable, isFalse);
  expect(canvas.editor.selection, isNull);
  expect(canvas.focusNode.hasFocus, isFalse);
}

void main() {
  late _ReadingStorage storage;
  setUpAll(() async {
    await setupPluralResolvers();
    await LocaleSettings.setLocale(AppLocale.zh);
  });
  setUp(() {
    storage = _ReadingStorage();
    getIt.registerSingleton<IKVStorage>(storage);
  });
  tearDown(() => getIt.reset());

  testWidgets('note reopens at its last reading position', (tester) async {
    final db = MoodiaryDatabase.forTesting(NativeDatabase.memory());
    final store = DailyNotesStore(db);
    await store.open();
    final document = _document();
    final json = jsonEncode(document.toJson());
    document.dispose();
    final note = await store.saveRichNote(
      title: '笔记',
      plainText: '正文',
      documentJson: json,
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
    await _checkReopen(
      tester,
      () => RichNoteEditorPage(store: store, note: note),
    );
    expect(store.pendingOperationCount, pending);
    expect(store.notes.single.documentJson, json);
  });

  testWidgets('diary reopens without editing or rewriting its content', (
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
    await tester.binding.setSurfaceSize(const Size(430, 700));
    addTearDown(() async {
      await tester.pumpWidget(const SizedBox());
      await db.close();
      await tester.binding.setSurfaceSize(null);
    });
    await _checkReopen(
      tester,
      () => RichDiaryPage(repository: repository, diary: diary),
    );
    expect((await repository.getDiaryByBusinessId(diary.id))!.content, body);
  });

  testWidgets('an existing long record reopens without another submission', (
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
        operationId: 'reading-operation-1',
        revisionId: 'reading-revision-1',
        blockId: 'reading-block-1',
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
    await _checkReopen(
      tester,
      () => ModMonthComposer(
        repository: repository,
        topicId: topic.id,
        topicTitle: topic.title,
        monthKey: '2026-11',
        block: block,
      ),
    );
    final blocks = (await repository.load(topic.id, '2026-11')).blocks;
    expect(blocks, hasLength(1));
    expect(blocks.single.revisionId, block.revisionId);
    expect(blocks.single.tiptapJson, body);
  });

  testWidgets('changed content never reuses a stale document position', (
    tester,
  ) async {
    final db = MoodiaryDatabase.forTesting(NativeDatabase.memory());
    final store = DailyNotesStore(db);
    await store.open();
    final original = _document();
    final note = await store.saveRichNote(
      title: '笔记',
      plainText: '正文',
      documentJson: jsonEncode(original.toJson()),
      documentVersion: 1,
    );
    original.dispose();
    await tester.binding.setSurfaceSize(const Size(430, 700));
    addTearDown(() async {
      await tester.pumpWidget(const SizedBox());
      store.dispose();
      await db.close();
      await tester.binding.setSurfaceSize(null);
    });
    await tester.pumpWidget(_app(RichNoteEditorPage(store: store, note: note)));
    await tester.pumpAndSettle();
    await _moveAndSave(tester);
    final saved = Map<String, Object>.of(storage.data);
    expect(saved, isNotEmpty);
    await tester.pumpWidget(const SizedBox());
    final changed = _document('已变化');
    final revised = await store.saveRichNote(
      id: note.id,
      expectedRevision: note.storageRevision,
      title: note.title,
      plainText: '已变化',
      documentJson: jsonEncode(changed.toJson()),
      documentVersion: 1,
    );
    changed.dispose();
    await tester.pumpWidget(
      _app(RichNoteEditorPage(store: store, note: revised)),
    );
    await tester.pumpAndSettle();
    expect(
      _scroll(tester).itemPositionsListener.itemPositions.value
          .any((item) => item.index == 0 && item.itemTrailingEdge > 0),
      isTrue,
    );
    expect(storage.data, saved);
  });

  testWidgets('failed position writes preserve the last stored position', (
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
    await _moveAndSave(tester);
    final saved = Map<String, Object>.of(storage.data);
    expect(saved, isNotEmpty);
    storage.failWrites = true;
    _scroll(tester).itemScrollController.jumpTo(index: 40);
    await tester.pumpAndSettle();
    await tester.pump(const Duration(milliseconds: 750));
    await tester.pumpWidget(const SizedBox());
    expect(storage.data, saved);
    storage.failWrites = false;
    await tester.pumpWidget(_app(RichNoteEditorPage(store: store, note: note)));
    await tester.pumpAndSettle();
    expect(_position(tester, 25), closeTo(0.2, 0.03));
  });

  testWidgets('unsaved edits cannot replace a confirmed reading position', (
    tester,
  ) async {
    final db = MoodiaryDatabase.forTesting(NativeDatabase.memory());
    var failSave = false;
    final store = DailyNotesStore(
      db,
      beforeOutboxWrite: () async {
        if (failSave) throw StateError('disk full');
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
    await _moveAndSave(tester);
    final saved = Map<String, Object>.of(storage.data);
    expect(saved, isNotEmpty);
    failSave = true;
    await tester.tap(find.byTooltip(l10n.dailynotes.unlockEditing));
    await tester.pumpAndSettle();
    final editor = tester
        .widget<DailyNotesDocumentCanvas>(find.byType(DailyNotesDocumentCanvas))
        .editor;
    await editor.insertText(0, '未保存', path: [0]);
    await tester.pump(const Duration(milliseconds: 800));
    await tester.pumpAndSettle();
    expect(find.text(l10n.dailynotes.retry), findsOneWidget);
    _scroll(tester).itemScrollController.jumpTo(index: 40, alignment: 0.2);
    await tester.pumpAndSettle();
    final newPosition = _position(tester, 40);
    await tester.pump(const Duration(milliseconds: 800));
    expect(storage.data, saved);
    failSave = false;
    await tester.tap(find.text(l10n.dailynotes.retry));
    await tester.pumpAndSettle();
    expect(storage.data, isNot(saved));
    final persisted = store.notes.single;
    expect(persisted.body, contains('未保存'));
    await tester.pumpWidget(const SizedBox());
    await tester.pumpWidget(
      _app(RichNoteEditorPage(store: store, note: persisted)),
    );
    await tester.pumpAndSettle();
    expect(_position(tester, 40), closeTo(newPosition, 0.03));
  });

  testWidgets('identical documents keep independent reading positions', (
    tester,
  ) async {
    final db = MoodiaryDatabase.forTesting(NativeDatabase.memory());
    final store = DailyNotesStore(db);
    await store.open();
    final document = _document();
    final body = jsonEncode(document.toJson());
    document.dispose();
    Future<DailyNote> create(String title) => store.saveRichNote(
      title: title,
      plainText: '正文',
      documentJson: body,
      documentVersion: 1,
    );

    final first = await create('第一篇');
    final second = await create('第二篇');
    await tester.binding.setSurfaceSize(const Size(430, 700));
    addTearDown(() async {
      await tester.pumpWidget(const SizedBox());
      store.dispose();
      await db.close();
      await tester.binding.setSurfaceSize(null);
    });
    await tester.pumpWidget(
      _app(RichNoteEditorPage(store: store, note: first)),
    );
    await tester.pumpAndSettle();
    await _moveAndSave(tester);
    await tester.pumpWidget(const SizedBox());
    await tester.pumpWidget(
      _app(RichNoteEditorPage(store: store, note: second)),
    );
    await tester.pumpAndSettle();
    expect(
      _scroll(tester).itemPositionsListener.itemPositions.value
          .any((item) => item.index == 0 && item.itemTrailingEdge > 0),
      isTrue,
    );
    expect(store.notes, hasLength(2));
    expect(store.notes.every((note) => note.documentJson == body), isTrue);
  });

  testWidgets('backgrounding flushes a pending reading position', (
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
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      await tester.pumpWidget(const SizedBox());
      store.dispose();
      await db.close();
      await tester.binding.setSurfaceSize(null);
    });
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await tester.pumpWidget(_app(RichNoteEditorPage(store: store, note: note)));
    await tester.pumpAndSettle();
    _scroll(tester).itemScrollController.jumpTo(index: 25, alignment: 0.2);
    await tester.pump();
    final before = _position(tester, 25);
    expect(storage.data, isEmpty);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
    expect(storage.data, isNotEmpty);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await tester.pumpWidget(const SizedBox());
    await tester.pumpWidget(_app(RichNoteEditorPage(store: store, note: note)));
    await tester.pumpAndSettle();
    expect(_position(tester, 25), closeTo(before, 0.03));
    _scroll(tester).itemScrollController.jumpTo(index: 40, alignment: 0.2);
    await tester.pump();
    final beforeExit = _position(tester, 40);
    await tester.pumpWidget(const SizedBox());
    await tester.pumpWidget(_app(RichNoteEditorPage(store: store, note: note)));
    await tester.pumpAndSettle();
    expect(_position(tester, 40), closeTo(beforeExit, 0.03));
  });

  testWidgets('damaged position metadata cannot prevent opening a note', (
    tester,
  ) async {
    final db = MoodiaryDatabase.forTesting(NativeDatabase.memory());
    final store = DailyNotesStore(db);
    await store.open();
    final document = _document();
    final body = jsonEncode(document.toJson());
    final note = await store.saveRichNote(
      title: '笔记',
      plainText: '正文',
      documentJson: body,
      documentVersion: 1,
    );
    document.dispose();
    final encodedId = base64Url.encode(utf8.encode('note:${note.id}'));
    final key = 'dailynotes.reading.v1.$encodedId';
    await tester.binding.setSurfaceSize(const Size(430, 700));
    addTearDown(() async {
      await tester.pumpWidget(const SizedBox());
      store.dispose();
      await db.close();
      await tester.binding.setSurfaceSize(null);
    });
    for (final damaged in <Object>[
      '{invalid json',
      42,
      '{"v":1,"digest":"unknown","index":9999,"alignment":0.2}',
      '{"v":1,"digest":"unknown","index":3,"alignment":-1}',
    ]) {
      storage.data[key] = damaged;
      await tester.pumpWidget(
        _app(RichNoteEditorPage(store: store, note: note)),
      );
      await tester.pumpAndSettle();
      expect(
        _scroll(tester).itemPositionsListener.itemPositions.value
            .any((item) => item.index == 0 && item.itemTrailingEdge > 0),
        isTrue,
      );
      expect(storage.data[key], damaged);
      expect(store.notes.single.documentJson, body);
      await tester.pumpWidget(const SizedBox());
    }
  });
}
