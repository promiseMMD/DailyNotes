// The app still uses this bridge during its Material migration.
// ignore_for_file: deprecated_member_use

import 'dart:convert';

import 'package:appflowy_editor/appflowy_editor.dart' as af;
import 'package:drift/native.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:moodiary_data/moodiary_data.dart';
import 'package:moodiary_di/moodiary_di.dart';
import 'package:moodiary_i18n/moodiary_i18n.dart';
import 'package:moodiary_mobile/app/dailynotes/data/daily_notes_store.dart';
import 'package:moodiary_mobile/app/dailynotes/diary/rich_diary_page.dart';
import 'package:moodiary_mobile/app/dailynotes/editor/document_canvas.dart';
import 'package:moodiary_mobile/app/dailynotes/editor/document_envelope.dart';
import 'package:moodiary_mobile/app/dailynotes/editor/document_toggle_model.dart';
import 'package:moodiary_mobile/app/dailynotes/notes/rich_note_editor_page.dart';
import 'package:moodiary_mobile/app/home/mod_continuous.dart';
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
    builder: (context, child) => MaterialUiCompatibilityBridge(child: child!),
    home: page,
  ),
);

af.Document _document() => af.Document(
  root: af.pageNode(
    children: [
      documentToggleNode(
        level: 2,
        collapsed: true,
        delta: af.Delta()..insert('折叠标题'),
        children: [af.headingNode(level: 3, text: '已有内容')],
      ),
      documentToggleNode(
        delta: af.Delta()..insert('待嵌套'),
        children: [af.paragraphNode(text: '嵌套子内容')],
      ),
      af.paragraphNode(
        delta: af.Delta()..insert('带格式正文', attributes: {'bold': true}),
        children: [af.paragraphNode(text: '正文子内容')],
      ),
    ],
  ),
);

af.EditorState _editor(WidgetTester tester) => tester
    .widget<DailyNotesDocumentCanvas>(find.byType(DailyNotesDocumentCanvas))
    .editor;

Future<void> _jumpNested(WidgetTester tester, String kind) async {
  final nested = _editor(tester).document.root.children.first.children.single;
  expect(nested.key.currentContext, isNull);
  await tester.tap(find.byKey(ValueKey('$kind-document-outline-button')));
  await tester.pumpAndSettle();
  await tester.tap(find.byKey(ValueKey('outline-${nested.id}')));
  await tester.pumpAndSettle();
  expect(nested.key.currentContext, isNotNull);
  expect(find.text(l10n.dailynotes.outlineUnavailable), findsNothing);
}

Future<void> _edit(WidgetTester tester) async {
  await tester.tap(find.byTooltip(l10n.dailynotes.unlockEditing));
  await tester.pumpAndSettle();
  await _editor(tester).insertText(0, '修改', path: [0]);
  final canvas = tester.widget<DailyNotesDocumentCanvas>(
    find.byType(DailyNotesDocumentCanvas),
  );
  canvas.focusNode.requestFocus();
  canvas.editor.selection = af.Selection(
    start: af.Position(path: [1], offset: 1),
    end: af.Position(path: [2], offset: 2),
  );
  await tester.pumpAndSettle();
  await tester.sendKeyEvent(LogicalKeyboardKey.tab);
  await tester.pumpAndSettle();
  expect(canvas.editor.document.root.children, hasLength(1));
  expect(canvas.editor.document.root.children.first.children, hasLength(3));
  await tester.pump(const Duration(milliseconds: 800));
  await tester.pumpAndSettle();
}

void _checkDocument(af.Document document) {
  final toggle = document.root.children.first;
  expect(toggle.type, DocumentToggleKeys.type);
  expect(toggle.attributes[DocumentToggleKeys.level], 2);
  expect(toggle.delta!.toPlainText(), '修改折叠标题');
  expect(toggle.children, hasLength(3));
  expect(toggle.children.first.delta!.toPlainText(), '已有内容');
  final nested = toggle.children[1];
  expect(nested.type, DocumentToggleKeys.type);
  expect(nested.delta!.toPlainText(), '待嵌套');
  expect(nested.children.single.delta!.toPlainText(), '嵌套子内容');
  final paragraph = toggle.children.last;
  expect(paragraph.type, af.ParagraphBlockKeys.type);
  expect(paragraph.delta!.toJson(), [
    {
      'insert': '带格式正文',
      'attributes': {'bold': true},
    },
  ]);
  expect(paragraph.children.single.delta!.toPlainText(), '正文子内容');
}

void main() {
  setUpAll(() async {
    await setupPluralResolvers();
    await LocaleSettings.setLocale(AppLocale.zh);
  });
  setUp(() => getIt.registerSingleton<IKVStorage>(MemoryKVStorage()));
  tearDown(() => getIt.reset());

  testWidgets('note autosaves and reopens a nested toggle subtree', (
    tester,
  ) async {
    final db = MoodiaryDatabase.forTesting(NativeDatabase.memory());
    final store = DailyNotesStore(db);
    await store.open();
    final document = _document();
    final note = await store.saveRichNote(
      title: '笔记',
      plainText: '折叠标题\n已有内容\n待嵌套\n嵌套子内容\n带格式正文\n正文子内容',
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
    await _jumpNested(tester, 'note');
    expect(store.notes.single.documentJson, note.documentJson);
    await _edit(tester);
    final saved = store.notes.single;
    final reopened = af.Document.fromJson(
      jsonDecode(saved.documentJson!) as Map<String, dynamic>,
    );
    _checkDocument(reopened);
    reopened.dispose();
    await tester.pumpWidget(const SizedBox());
    await tester.pumpWidget(
      _app(RichNoteEditorPage(store: store, note: saved)),
    );
    await tester.pumpAndSettle();
    _checkDocument(_editor(tester).document);
  });

  testWidgets('diary autosaves and reopens a nested toggle subtree', (
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
      contentText: '折叠标题',
      imageName: [],
      audioName: [],
      videoName: [],
      tags: [],
      type: DiaryType.tiptap,
    );
    await repository.insertADiary(diary);
    final initial = (await repository.getDiaryByBusinessId(diary.id))!;
    await tester.binding.setSurfaceSize(const Size(430, 700));
    addTearDown(() async {
      await tester.pumpWidget(const SizedBox());
      await db.close();
      await tester.binding.setSurfaceSize(null);
    });
    await tester.pumpWidget(
      _app(RichDiaryPage(repository: repository, diary: initial)),
    );
    await tester.pumpAndSettle();
    await _jumpNested(tester, 'diary');
    expect((await repository.getDiaryByBusinessId(diary.id))!.content, body);
    await _edit(tester);
    final saved = (await repository.getDiaryByBusinessId(diary.id))!;
    final reopened = DailyNotesDocumentEnvelope.decode(saved.content);
    _checkDocument(reopened);
    reopened.dispose();
    await tester.pumpWidget(const SizedBox());
    await tester.pumpWidget(
      _app(RichDiaryPage(repository: repository, diary: saved)),
    );
    await tester.pumpAndSettle();
    _checkDocument(_editor(tester).document);
  });

  testWidgets('long-record nested toggle commits only after explicit save', (
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
        operationId: 'toggle-operation-1',
        revisionId: 'toggle-revision-1',
        blockId: 'toggle-block-1',
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
    await _jumpNested(tester, 'long');
    expect(
      (await repository.load(topic.id, '2026-11')).blocks.single.revisionId,
      block.revisionId,
    );
    await _edit(tester);
    expect(
      (await repository.load(topic.id, '2026-11')).blocks.single.revisionId,
      block.revisionId,
    );
    await tester.tap(find.widgetWithText(FilledButton, l10n.common.save));
    await tester.pumpAndSettle();
    final saved = (await repository.load(topic.id, '2026-11')).blocks.single;
    expect(saved.revisionId, isNot(block.revisionId));
    final reopened = DailyNotesDocumentEnvelope.decode(saved.tiptapJson);
    _checkDocument(reopened);
    reopened.dispose();
  });
}
