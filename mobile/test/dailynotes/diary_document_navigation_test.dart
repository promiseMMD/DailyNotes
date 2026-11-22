import 'dart:convert';

import 'package:appflowy_editor/appflowy_editor.dart' as af;
import 'package:drift/native.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:moodiary_data/moodiary_data.dart';
import 'package:moodiary_di/moodiary_di.dart';
import 'package:moodiary_i18n/moodiary_i18n.dart';
import 'package:moodiary_mobile/app/dailynotes/diary/rich_diary_page.dart';
import 'package:moodiary_mobile/app/dailynotes/editor/document_canvas.dart';
import 'package:moodiary_mobile/app/dailynotes/editor/document_envelope.dart';
import 'package:moodiary_mobile/app/dailynotes/notes/rich_note_outline.dart';
import 'package:moodiary_models/moodiary_models.dart';
import 'package:moodiary_storage/moodiary_storage.dart';
import 'package:moodiary_storage/testing.dart';
import 'package:mui/mui.dart';

class _FailingDiaryRepository extends DiaryRepository {
  _FailingDiaryRepository(super.database);
  bool failWrites = true;

  @override
  Future<bool> insertADiaryIfAbsent(Diary diary) async {
    if (failWrites) throw StateError('injected write failure');
    return super.insertADiaryIfAbsent(diary);
  }
}

void main() {
  setUpAll(() async {
    getIt.registerSingleton<IKVStorage>(MemoryKVStorage());
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

  testWidgets('locked diary opens its document menu and navigates headings', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(320, 700);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final db = MoodiaryDatabase.forTesting(NativeDatabase.memory());
    final repository = DiaryRepository(db);
    final document = af.Document(
      root: af.pageNode(
        children: [
          af.headingNode(level: 1, text: '开始'),
          for (var i = 0; i < 25; i++) af.paragraphNode(text: '正文 $i'),
          af.headingNode(level: 2, text: '目标标题'),
          af.paragraphNode(text: '尾段'),
        ],
      ),
    );
    final diary = Diary.create(
      title: '测试日记',
      content: DailyNotesDocumentEnvelope.encode(document),
      contentText: DailyNotesDocumentEnvelope.plainText(document),
      imageName: [],
      audioName: [],
      videoName: [],
      tags: [],
      type: DiaryType.tiptap,
    );
    document.dispose();
    await repository.insertADiary(diary);
    await tester.pumpWidget(
      app(RichDiaryPage(repository: repository, diary: diary)),
    );
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    final editor = tester
        .widget<af.AppFlowyEditor>(find.byType(af.AppFlowyEditor))
        .editorState;
    expect(editor.editable, isFalse);
    final before = jsonEncode(editor.document.toJson());
    final target = editor.document.root.children[26];

    tester.testTextInput.log.clear();
    await tester.tap(find.byKey(const ValueKey('diary-document-more')));
    await tester.pumpAndSettle();
    expect(find.byType(SimpleDialog), findsOneWidget);
    expect(
      find.byKey(const ValueKey('diary-document-outline')),
      findsOneWidget,
    );
    expect(find.byKey(const ValueKey('rich-overflow-code')), findsNothing);
    await tester.binding.handlePopRoute();
    await tester.pumpAndSettle();
    expect(find.byType(RichDiaryPage), findsOneWidget);
    expect(editor.editable, isFalse);
    expect(jsonEncode(editor.document.toJson()), before);
    expect(
      tester.testTextInput.log.map((call) => call.method),
      isNot(contains('TextInput.show')),
    );

    await tester.tap(find.byKey(const ValueKey('diary-document-more')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('diary-document-outline')));
    await tester.pumpAndSettle();
    expect(find.byType(RichNoteOutline), findsOneWidget);
    await tester.enterText(find.byType(TextField).last, '目标');
    await tester.pumpAndSettle();
    expect(find.byKey(ValueKey('outline-${target.id}')), findsOneWidget);
    await tester.tap(find.byKey(ValueKey('outline-${target.id}')));
    await tester.pumpAndSettle();
    expect(find.byType(RichNoteOutline), findsNothing);
    expect(target.key.currentContext, isNotNull);
    expect(find.text(l10n.dailynotes.outlineUnavailable), findsNothing);
    expect(jsonEncode(editor.document.toJson()), before);
    expect(editor.editable, isFalse);
    expect(
      (await repository.getDiaryByBusinessId(diary.id))!.content,
      diary.content,
    );

    await tester.tap(
      find.byKey(const ValueKey('diary-document-outline-button')),
    );
    await tester.pumpAndSettle();
    expect(find.byType(RichNoteOutline), findsOneWidget);
    await tester.binding.handlePopRoute();
    await tester.pumpAndSettle();
    expect(find.byType(RichNoteOutline), findsNothing);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
    await db.close();
  });

  testWidgets('diary outline preserves failed unsaved edits and retry', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(430, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final db = MoodiaryDatabase.forTesting(NativeDatabase.memory());
    final repository = _FailingDiaryRepository(db);
    await tester.pumpWidget(app(RichDiaryPage(repository: repository)));
    await tester.pumpAndSettle();
    final editor = tester
        .widget<af.AppFlowyEditor>(find.byType(af.AppFlowyEditor))
        .editorState;
    await editor.apply(
      editor.transaction
        ..insertNode([0], af.headingNode(level: 1, text: '未保存标题')),
    );
    await tester.pump(const Duration(milliseconds: 700));
    await tester.pumpAndSettle();
    expect(find.text(l10n.dailynotes.saveFailed), findsOneWidget);
    final before = jsonEncode(editor.document.toJson());
    final heading = editor.document.root.children.first;
    await tester.tap(
      find.byKey(const ValueKey('diary-document-outline-button')),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(ValueKey('outline-${heading.id}')));
    await tester.pumpAndSettle();
    expect(jsonEncode(editor.document.toJson()), before);
    expect(find.text(l10n.dailynotes.saveFailed), findsOneWidget);
    expect(await repository.getAllDiaries(), isEmpty);
    repository.failWrites = false;
    await tester.tap(find.text(l10n.dailynotes.retry));
    await tester.pumpAndSettle();
    final saved = (await repository.getAllDiaries()).single;
    expect(saved.contentText, contains('未保存标题'));
    expect(
      jsonEncode(DailyNotesDocumentEnvelope.decode(saved.content).toJson()),
      before,
    );
    await tester.pumpWidget(const SizedBox());
    await db.close();
  });

  testWidgets('holding a link in a locked diary cannot open a writing dialog', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(430, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final db = MoodiaryDatabase.forTesting(NativeDatabase.memory());
    final repository = DiaryRepository(db);
    final document = af.Document(
      root: af.pageNode(
        children: [
          af.paragraphNode(
            delta: af.Delta()
              ..insert(
                '安全链接',
                attributes: {
                  af.AppFlowyRichTextKeys.href: 'https://example.com',
                },
              ),
          ),
        ],
      ),
    );
    final diary = Diary.create(
      title: '只读日记',
      content: DailyNotesDocumentEnvelope.encode(document),
      contentText: '安全链接',
      imageName: [],
      audioName: [],
      videoName: [],
      tags: [],
      type: DiaryType.tiptap,
    );
    document.dispose();
    await repository.insertADiary(diary);
    await tester.pumpWidget(
      app(RichDiaryPage(repository: repository, diary: diary)),
    );
    await tester.pumpAndSettle();
    final editor = tester
        .widget<af.AppFlowyEditor>(find.byType(af.AppFlowyEditor))
        .editorState;
    final before = jsonEncode(editor.document.toJson());
    final link = find.text('安全链接', findRichText: true);
    expect(link, findsOneWidget);
    expect(tester.testTextInput.isVisible, isFalse);
    tester.testTextInput.log.clear();
    await tester.longPress(link);
    await tester.pump(const Duration(milliseconds: 700));
    await tester.pumpAndSettle();
    expect(find.byType(AlertDialog), findsNothing);
    expect(tester.testTextInput.isVisible, isFalse);
    expect(
      tester.testTextInput.log.map((call) => call.method),
      isNot(contains('TextInput.show')),
    );
    expect(editor.editable, isFalse);
    expect(jsonEncode(editor.document.toJson()), before);

    const channel = MethodChannel('plugins.flutter.io/url_launcher');
    final calls = <MethodCall>[];
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(channel, (
      call,
    ) async {
      calls.add(call);
      return true;
    });
    addTearDown(
      () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        channel,
        null,
      ),
    );
    await tester.tap(link);
    await tester.pumpAndSettle();
    expect(calls.map((call) => call.method), contains('launch'));
    expect(calls.last.arguments['url'], 'https://example.com');
    expect(tester.testTextInput.isVisible, isFalse);
    expect(jsonEncode(editor.document.toJson()), before);

    await tester.tap(find.byTooltip(l10n.dailynotes.unlockEditing));
    await tester.pumpAndSettle();
    final gesture = await tester.startGesture(tester.getCenter(link));
    await tester.pump(const Duration(milliseconds: 120));
    editor.editable = false;
    editor.editable = true;
    await tester.pump(const Duration(milliseconds: 600));
    await gesture.up();
    await tester.pumpAndSettle();
    expect(find.byType(AlertDialog), findsNothing);
    expect(jsonEncode(editor.document.toJson()), before);
    await tester.pumpWidget(const SizedBox());
    await db.close();
  });

  testWidgets('diary document controls keep the active editing selection', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(430, 900);
    tester.view.devicePixelRatio = 1;
    tester.view.viewInsets = const FakeViewPadding(bottom: 300);
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    addTearDown(tester.view.resetViewInsets);
    final db = MoodiaryDatabase.forTesting(NativeDatabase.memory());
    final repository = DiaryRepository(db);
    await tester.pumpWidget(app(RichDiaryPage(repository: repository)));
    await tester.pumpAndSettle();
    final canvas = tester.widget<DailyNotesDocumentCanvas>(
      find.byType(DailyNotesDocumentCanvas),
    );
    final editor = canvas.editor;
    await editor.insertText(0, '选择内容', path: [0]);
    final selected = af.Selection.single(
      path: [0],
      startOffset: 0,
      endOffset: 2,
    );
    editor.selection = selected;
    canvas.focusNode.requestFocus();
    await tester.pumpAndSettle();
    expect(canvas.focusNode.hasFocus, isTrue);
    tester.testTextInput.log.clear();

    await tester.tap(find.byKey(const ValueKey('diary-document-more')));
    await tester.pumpAndSettle();
    expect(editor.selection, selected);
    expect(canvas.focusNode.hasFocus, isTrue);
    await tester.binding.handlePopRoute();
    await tester.pumpAndSettle();
    expect(editor.selection, selected);
    expect(canvas.focusNode.hasFocus, isTrue);
    expect(
      tester.testTextInput.log.map((call) => call.method),
      isNot(contains('TextInput.hide')),
    );

    await tester.tap(
      find.byKey(const ValueKey('diary-document-outline-button')),
    );
    await tester.pumpAndSettle();
    expect(editor.selection, selected);
    expect(canvas.focusNode.hasFocus, isTrue);
    await tester.binding.handlePopRoute();
    await tester.pumpAndSettle();
    expect(editor.selection, selected);
    expect(canvas.focusNode.hasFocus, isTrue);
    expect(
      tester.testTextInput.log.map((call) => call.method),
      isNot(contains('TextInput.hide')),
    );
    expect(find.byType(RichDiaryPage), findsOneWidget);
    await tester.tap(
      find.byKey(const ValueKey('diary-document-outline-button')),
    );
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField).last, '搜索');
    await tester.pumpAndSettle();
    await tester.binding.handlePopRoute();
    await tester.pumpAndSettle();
    expect(editor.selection, selected);

    // A document change while search owns focus invalidates the old offsets.
    canvas.focusNode.requestFocus();
    await tester.pumpAndSettle();
    editor.selection = selected;
    await tester.pumpAndSettle();
    await tester.tap(
      find.byKey(const ValueKey('diary-document-outline-button')),
    );
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField).last, '搜索');
    await tester.pumpAndSettle();
    expect(editor.selection, isNull);
    await editor.insertText(0, '新', path: [0]);
    await tester.pumpAndSettle();
    final selectionAfterEdit = editor.selection;
    expect(selectionAfterEdit, isNot(selected));
    await tester.binding.handlePopRoute();
    await tester.pumpAndSettle();
    expect(editor.selection, selectionAfterEdit);
    expect(editor.document.root.children.first.delta!.toPlainText(), '新选择内容');

    // Re-locking and unlocking also invalidates a captured selection.
    canvas.focusNode.requestFocus();
    await tester.pumpAndSettle();
    editor.selection = selected;
    await tester.pumpAndSettle();
    await tester.tap(
      find.byKey(const ValueKey('diary-document-outline-button')),
    );
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField).last, '搜索');
    await tester.pumpAndSettle();
    expect(editor.selection, isNull);
    editor.editable = false;
    await tester.pump();
    editor.editable = true;
    await tester.pump();
    await tester.binding.handlePopRoute();
    await tester.pumpAndSettle();
    expect(editor.selection, isNull);
    await tester.pumpWidget(const SizedBox());
    await db.close();
  });
}
