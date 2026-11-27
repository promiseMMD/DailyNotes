// The app still uses this bridge during its Material migration.
// ignore_for_file: deprecated_member_use

import 'dart:convert';

import 'package:appflowy_editor/appflowy_editor.dart' as af;
// Exercise the same boundary handler used by the software keyboard.
// ignore: implementation_imports
import 'package:appflowy_editor/src/editor/editor_component/service/ime/delta_input_on_delete_impl.dart';
// ignore: implementation_imports
import 'package:appflowy_editor/src/editor/editor_component/service/ime/delta_input_on_insert_impl.dart';
// ignore: implementation_imports
import 'package:appflowy_editor/src/editor/editor_component/service/ime/delta_input_on_replace_impl.dart';
// ignore: implementation_imports
import 'package:appflowy_editor/src/editor/editor_component/service/ime/non_delta_input_service.dart';
// ignore: implementation_imports
import 'package:appflowy_editor/src/editor/editor_component/service/keyboard_service_widget.dart';
import 'package:drift/native.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:moodiary_data/moodiary_data.dart';
import 'package:moodiary_di/moodiary_di.dart';
import 'package:moodiary_i18n/moodiary_i18n.dart';
import 'package:moodiary_mobile/app/dailynotes/data/daily_notes_store.dart';
import 'package:moodiary_mobile/app/dailynotes/data/rich_document_guard.dart';
import 'package:moodiary_mobile/app/dailynotes/editor/document_canvas.dart';
import 'package:moodiary_mobile/app/dailynotes/editor/document_envelope.dart';
import 'package:moodiary_mobile/app/dailynotes/editor/document_toggle_block.dart';
import 'package:moodiary_mobile/app/dailynotes/editor/document_toggle_model.dart';
import 'package:moodiary_mobile/app/dailynotes/notes/rich_note_editor_page.dart';
import 'package:moodiary_storage/moodiary_storage.dart';
import 'package:moodiary_storage/testing.dart';
import 'package:mui/mui.dart';

Widget _app(Widget child) => TranslationProvider(
  child: MaterialApp(
    theme: buildMuiTheme(brightness: Brightness.light),
    localizationsDelegates: const [
      af.AppFlowyEditorLocalizations.delegate,
      ...GlobalMaterialLocalizations.delegates,
      GlobalMuiLocalizations.delegate,
    ],
    builder: (context, child) => MaterialUiCompatibilityBridge(child: child!),
    home: child,
  ),
);

void main() {
  setUpAll(() async {
    await setupPluralResolvers();
    await LocaleSettings.setLocale(AppLocale.zh);
  });
  setUp(() => getIt.registerSingleton<IKVStorage>(MemoryKVStorage()));
  tearDown(() => getIt.reset());

  test('toggle blocks preserve their rich content and reject invalid data', () {
    final document = af.Document(
      root: af.pageNode(
        children: [
          documentToggleNode(
            level: 2,
            collapsed: true,
            delta: af.Delta()..insert('标题', attributes: {'bold': true}),
            children: [af.paragraphNode(text: '子内容')],
          ),
        ],
      ),
    );
    final json = jsonEncode(document.toJson());
    expect(validateRichDocument(json), jsonDecode(json));
    final envelope = DailyNotesDocumentEnvelope.encode(document);
    final reopened = DailyNotesDocumentEnvelope.decode(envelope);
    expect(jsonEncode(reopened.toJson()), json);
    expect(DailyNotesDocumentEnvelope.plainText(reopened), '标题\n子内容');
    reopened.dispose();
    document.dispose();

    for (final bad in <Map<String, Object>>[
      {'delta': [], 'collapsed': 'no'},
      {'delta': [], 'level': 7},
      {'delta': [], 'level': '2'},
      {'collapsed': false},
    ]) {
      expect(
        () => validateRichDocument(
          jsonEncode({
            'document': {
              'type': 'page',
              'children': [
                {'type': DocumentToggleKeys.type, 'data': bad},
              ],
            },
          }),
        ),
        throwsFormatException,
      );
    }
  });

  testWidgets('greater-space converts a paragraph and preserves rich suffix', (
    tester,
  ) async {
    final paragraph = af.paragraphNode(
      delta: af.Delta()
        ..insert('>')
        ..insert('正文', attributes: {'bold': true}),
      attributes: {af.blockComponentTextDirection: 'rtl'},
    );
    final editor = af.EditorState(
      document: af.Document(root: af.pageNode(children: [paragraph])),
    );
    final before = jsonEncode(editor.document.toJson());
    editor.selection = af.Selection.single(path: [0], startOffset: 1);
    expect(await documentToggleFromMarker.execute(editor), isTrue);
    final result = editor.document.root.children.single;
    expect(result.type, DocumentToggleKeys.type);
    expect(result.attributes[DocumentToggleKeys.level], isNull);
    expect(result.attributes[af.blockComponentTextDirection], 'rtl');
    expect(result.delta!.toPlainText(), '正文');
    expect(jsonEncode(result.delta!.toJson()), contains('"bold":true'));
    expect(editor.selection!.start.offset, 0);
    editor.undoManager.undo();
    await tester.pump();
    expect(jsonEncode(editor.document.toJson()), before);
    editor.undoManager.redo();
    await tester.pump();
    expect(editor.document.root.children.single.type, DocumentToggleKeys.type);
    editor.dispose();
  });

  testWidgets('greater-space keeps heading level inside a nested toggle', (
    tester,
  ) async {
    final heading = af.headingNode(level: 2, text: '>小节');
    final parent = documentToggleNode(
      delta: af.Delta()..insert('父级'),
      children: [
        heading,
        af.paragraphNode(text: '兄弟内容'),
      ],
    );
    final editor = af.EditorState(
      document: af.Document(root: af.pageNode(children: [parent])),
    );
    final before = jsonEncode(editor.document.toJson());
    editor.selection = af.Selection.single(path: [0, 0], startOffset: 1);
    expect(await documentToggleFromMarker.execute(editor), isTrue);
    expect(parent.children.first.type, DocumentToggleKeys.type);
    expect(parent.children.first.attributes[DocumentToggleKeys.level], 2);
    expect(parent.children.first.delta!.toPlainText(), '小节');
    expect(parent.children.last.delta!.toPlainText(), '兄弟内容');
    expect(editor.selection!.start.path, [0, 0]);
    editor.undoManager.undo();
    await tester.pump();
    expect(jsonEncode(editor.document.toJson()), before);
    editor.dispose();
  });

  testWidgets('greater-space keeps complex parents and inserts a space', (
    tester,
  ) async {
    final paragraph = af.paragraphNode(
      text: '>正文',
      children: [af.paragraphNode(text: '原子内容')],
    );
    final child = paragraph.children.single;
    final editor = af.EditorState(
      document: af.Document(root: af.pageNode(children: [paragraph])),
    );
    editor.selection = af.Selection.single(path: [0], startOffset: 1);
    await onInsert(
      const TextEditingDeltaInsertion(
        oldText: '>正文',
        textInserted: ' ',
        insertionOffset: 1,
        selection: TextSelection.collapsed(offset: 2),
        composing: TextRange.empty,
      ),
      editor,
      [documentToggleFromMarker, ...af.standardCharacterShortcutEvents],
    );
    expect(editor.document.root.children.single, same(paragraph));
    expect(paragraph.delta!.toPlainText(), '> 正文');
    expect(paragraph.children.single, same(child));
    editor.dispose();
  });

  testWidgets('greater-space does not convert while the IME is composing', (
    tester,
  ) async {
    final paragraph = af.paragraphNode(text: '>');
    final editor = af.EditorState(
      document: af.Document(root: af.pageNode(children: [paragraph])),
    );
    editor.selection = af.Selection.single(path: [0], startOffset: 1);
    await onInsert(
      const TextEditingDeltaInsertion(
        oldText: '>',
        textInserted: ' ',
        insertionOffset: 1,
        selection: TextSelection.collapsed(offset: 2),
        composing: TextRange(start: 0, end: 2),
      ),
      editor,
      [documentToggleFromMarker],
    );
    expect(editor.document.root.children.single, same(paragraph));
    expect(paragraph.delta!.toPlainText(), '> ');
    editor.dispose();
  });

  test(
    'greater-space rejects ambiguous metadata and locked documents',
    () async {
      final candidates = [
        af.paragraphNode(
          text: '>原文',
          attributes: {DocumentToggleKeys.level: 2},
        ),
        af.paragraphNode(
          text: '>原文',
          attributes: {DocumentToggleKeys.collapsed: true},
        ),
        af.quoteNode(delta: af.Delta()..insert('>原文')),
        af.paragraphNode(text: 'x原文'),
      ];
      for (final node in candidates) {
        final editor = af.EditorState(
          document: af.Document(root: af.pageNode(children: [node])),
        );
        final before = jsonEncode(editor.document.toJson());
        editor.selection = af.Selection.single(path: [0], startOffset: 1);
        expect(await documentToggleFromMarker.execute(editor), isFalse);
        expect(jsonEncode(editor.document.toJson()), before);
        editor.dispose();
      }
      final editor = af.EditorState(
        document: af.Document(
          root: af.pageNode(children: [af.paragraphNode(text: '>原文')]),
        ),
      );
      final before = jsonEncode(editor.document.toJson());
      editor.selection = af.Selection.single(path: [0], startOffset: 1);
      editor.editable = false;
      expect(await documentToggleFromMarker.execute(editor), isFalse);
      expect(jsonEncode(editor.document.toJson()), before);
      editor.dispose();
    },
  );

  testWidgets('greater-space shortcut accepts actual canvas keyboard input', (
    tester,
  ) async {
    final editor = af.EditorState(
      document: af.Document(root: af.pageNode(children: [af.paragraphNode()])),
    );
    final focus = FocusNode();
    final scroll = af.EditorScrollController(editorState: editor);
    addTearDown(() async {
      await tester.pumpWidget(const SizedBox());
      scroll.dispose();
      editor.dispose();
      focus.dispose();
    });
    await tester.pumpWidget(
      _app(
        Scaffold(
          body: DailyNotesDocumentCanvas(
            editor: editor,
            focusNode: focus,
            scrollController: scroll,
            editable: true,
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    focus.requestFocus();
    editor.selection = af.Selection.single(path: [0], startOffset: 0);
    await tester.pumpAndSettle();
    tester.testTextInput.updateEditingValue(
      const TextEditingValue(
        text: ' >',
        selection: TextSelection.collapsed(offset: 2),
      ),
    );
    await tester.pump(const Duration(milliseconds: 50));
    await tester.pumpAndSettle();
    expect(editor.document.root.children.single.delta!.toPlainText(), '>');
    tester.testTextInput.updateEditingValue(
      const TextEditingValue(
        text: ' > ',
        selection: TextSelection.collapsed(offset: 3),
      ),
    );
    await tester.pump(const Duration(milliseconds: 50));
    await tester.pumpAndSettle();
    final toggle = editor.document.root.children.single;
    expect(toggle.type, DocumentToggleKeys.type);
    expect(editor.selection!.start.offset, 0);
    tester.testTextInput.updateEditingValue(
      const TextEditingValue(
        text: ' 新',
        selection: TextSelection.collapsed(offset: 2),
      ),
    );
    await tester.pump(const Duration(milliseconds: 50));
    await tester.pumpAndSettle();
    expect(toggle.delta!.toPlainText(), '新');
    expect(tester.takeException(), isNull);
  });

  testWidgets('Aa indents and outdents a toggle without losing its children', (
    tester,
  ) async {
    final first = documentToggleNode(
      collapsed: true,
      delta: af.Delta()..insert('父级'),
    );
    final second = documentToggleNode(
      level: 2,
      delta: af.Delta()..insert('章节'),
      children: [af.paragraphNode(text: '子内容')],
    );
    final editor = af.EditorState(
      document: af.Document(root: af.pageNode(children: [first, second])),
    );
    final focus = FocusNode();
    final scroll = af.EditorScrollController(editorState: editor);
    tester.view.physicalSize = const Size(430, 900);
    tester.view.devicePixelRatio = 1;
    tester.view.viewInsets = const FakeViewPadding(bottom: 300);
    addTearDown(() async {
      await tester.pumpWidget(const SizedBox());
      scroll.dispose();
      editor.dispose();
      focus.dispose();
      tester.view.resetPhysicalSize();
      tester.view.resetDevicePixelRatio();
      tester.view.resetViewInsets();
    });
    await tester.pumpWidget(
      _app(
        Scaffold(
          body: DailyNotesDocumentCanvas(
            editor: editor,
            focusNode: focus,
            scrollController: scroll,
            editable: true,
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    focus.requestFocus();
    editor.selection = af.Selection.single(path: [1], startOffset: 1);
    await tester.pumpAndSettle();
    tester.testTextInput.updateEditingValue(
      const TextEditingValue(
        text: ' 章节',
        selection: TextSelection.collapsed(offset: 2),
        composing: TextRange(start: 1, end: 2),
      ),
    );
    await tester.pump(const Duration(milliseconds: 50));
    await tester.pumpAndSettle();
    expect(editor.service.keyboardService!.isInputSettled, isFalse);
    await tester.sendKeyEvent(LogicalKeyboardKey.tab);
    await tester.pumpAndSettle();
    expect(editor.document.root.children.last, same(second));
    tester.testTextInput.updateEditingValue(
      const TextEditingValue(
        text: ' 章节',
        selection: TextSelection.collapsed(offset: 2),
      ),
    );
    await tester.pump(const Duration(milliseconds: 50));
    await tester.pumpAndSettle();
    expect(editor.service.keyboardService!.isInputSettled, isTrue);
    await tester.tap(find.byKey(const ValueKey('rich-toolbar-format')));
    await tester.pumpAndSettle();
    final indent = find.byKey(
      ValueKey('rich-format-${l10n.editor.toolbar.indent}'),
    );
    await tester.ensureVisible(indent);
    await tester.tap(indent);
    await tester.pumpAndSettle();
    expect(first.children.single, same(second));
    expect(second.children.single.delta!.toPlainText(), '子内容');
    expect(editor.selection!.start.path, [0, 0]);
    expect(find.byKey(ValueKey('toggle-block-${second.id}')), findsOneWidget);
    final outdent = find.byKey(
      ValueKey('rich-format-${l10n.editor.toolbar.outdent}'),
    );
    await tester.ensureVisible(outdent);
    await tester.tap(outdent);
    await tester.pump();
    await tester.pumpAndSettle(
      const Duration(milliseconds: 100),
      EnginePhase.sendSemanticsUpdate,
      const Duration(seconds: 2),
    );
    expect(editor.document.root.children.last, same(second));
    expect(second.children.single.delta!.toPlainText(), '子内容');
    expect(editor.selection!.start.path, [1]);
    expect(find.text(l10n.dailynotes.editorSelectionChanged), findsNothing);
    await tester.tap(find.byKey(const ValueKey('rich-format-done')));
    await tester.pumpAndSettle();
    editor.undoManager.undo();
    await tester.pumpAndSettle();
    expect(first.children.single, same(second));
    expect(editor.selection!.start.path, [0, 0]);
    expect(find.byKey(ValueKey('toggle-block-${second.id}')), findsOneWidget);
    editor.undoManager.redo();
    await tester.pumpAndSettle();
    expect(editor.document.root.children.last, same(second));
    expect(editor.selection!.start.path, [1]);
    focus.requestFocus();
    await tester.pumpAndSettle();
    await tester.sendKeyEvent(LogicalKeyboardKey.tab);
    await tester.pumpAndSettle();
    expect(first.children.single, same(second));
    await tester.sendKeyDownEvent(LogicalKeyboardKey.shiftLeft);
    await tester.sendKeyEvent(LogicalKeyboardKey.tab);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.shiftLeft);
    await tester.pumpAndSettle();
    expect(editor.document.root.children.last, same(second));
    expect(second.children.single.delta!.toPlainText(), '子内容');
    expect(tester.takeException(), isNull);
  });

  testWidgets('heading Backspace keeps the toggle subtree and can undo', (
    tester,
  ) async {
    final root = documentToggleNode(
      level: 2,
      delta: af.Delta()..insert('标题', attributes: {'bold': true}),
      children: [af.paragraphNode(text: '子内容')],
    );
    final child = root.children.single;
    final editor = af.EditorState(
      document: af.Document(root: af.pageNode(children: [root])),
    );
    final before = jsonEncode(editor.document.toJson());
    editor.selection = af.Selection.single(path: [0], startOffset: 0);
    expect(
      documentToggleHeadingBackspace.execute(editor),
      KeyEventResult.handled,
    );
    await tester.pump();
    expect(root.attributes[DocumentToggleKeys.level], isNull);
    expect(root.children.single, same(child));
    expect(root.delta!.toPlainText(), '标题');
    editor.undoManager.undo();
    await tester.pump();
    expect(jsonEncode(editor.document.toJson()), before);
    editor.selectionType = af.SelectionType.block;
    expect(
      documentToggleHeadingBackspace.execute(editor),
      KeyEventResult.ignored,
    );
    editor.selectionType = null;
    editor.editable = false;
    expect(
      documentToggleHeadingBackspace.execute(editor),
      KeyEventResult.ignored,
    );
    expect(jsonEncode(editor.document.toJson()), before);
    editor.dispose();
  });

  testWidgets('IME Backspace uses heading shortcut only at the boundary', (
    tester,
  ) async {
    final root = documentToggleNode(
      level: 1,
      delta: af.Delta()..insert('abc'),
      children: [af.paragraphNode(text: '子内容')],
    );
    final editor = af.EditorState(
      document: af.Document(root: af.pageNode(children: [root])),
    );
    final shortcuts = [
      documentToggleHeadingBackspace,
      ...af.standardCommandShortcutEvents,
    ];
    editor.selection = af.Selection.single(path: [0], startOffset: 1);
    await onDelete(
      const TextEditingDeltaDeletion(
        oldText: 'abc',
        deletedRange: TextRange(start: 0, end: 1),
        selection: TextSelection.collapsed(offset: 0),
        composing: TextRange.empty,
      ),
      editor,
      commandShortcutEvents: shortcuts,
    );
    expect(root.delta!.toPlainText(), 'bc');
    expect(root.attributes[DocumentToggleKeys.level], 1);
    await onDelete(
      const TextEditingDeltaDeletion(
        oldText: 'bc',
        deletedRange: TextRange(start: 0, end: 0),
        selection: TextSelection.collapsed(offset: 0),
        composing: TextRange.empty,
      ),
      editor,
      commandShortcutEvents: shortcuts,
    );
    await tester.pump();
    expect(root.attributes[DocumentToggleKeys.level], isNull);
    expect(root.delta!.toPlainText(), 'bc');
    expect(root.children.single.delta!.toPlainText(), '子内容');
    editor.dispose();
  });

  testWidgets('canvas routes software and hardware Backspace to the heading', (
    tester,
  ) async {
    final software = documentToggleNode(
      level: 1,
      delta: af.Delta()..insert('软件键盘'),
      children: [af.paragraphNode(text: '软件子内容')],
    );
    final hardware = documentToggleNode(
      level: 2,
      delta: af.Delta()..insert('外接键盘'),
      children: [af.paragraphNode(text: '外接子内容')],
    );
    final editor = af.EditorState(
      document: af.Document(root: af.pageNode(children: [software, hardware])),
    );
    final focus = FocusNode();
    final scroll = af.EditorScrollController(editorState: editor);
    addTearDown(() async {
      await tester.pumpWidget(const SizedBox());
      scroll.dispose();
      editor.dispose();
      focus.dispose();
    });
    await tester.pumpWidget(
      _app(
        Scaffold(
          body: DailyNotesDocumentCanvas(
            editor: editor,
            focusNode: focus,
            scrollController: scroll,
            editable: true,
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    focus.requestFocus();
    editor.selection = af.Selection.single(path: [0], startOffset: 0);
    await tester.pumpAndSettle();
    expect(tester.testTextInput.editingState?['text'], ' 软件键盘');
    tester.testTextInput.updateEditingValue(
      const TextEditingValue(
        text: '软件键盘',
        selection: TextSelection.collapsed(offset: 0),
      ),
    );
    await tester.pump(const Duration(milliseconds: 50));
    await tester.pumpAndSettle();
    expect(software.attributes[DocumentToggleKeys.level], isNull);
    expect(software.children.single.delta!.toPlainText(), '软件子内容');
    final keyboard =
        editor.service.keyboardServiceKey.currentState!
            as KeyboardServiceWidgetState;
    final input = keyboard.textInputService as NonDeltaTextInputService;
    expect(input.currentTextEditingValue?.text, ' 软件键盘');
    tester.testTextInput.updateEditingValue(
      const TextEditingValue(
        text: ' 新软件键盘',
        selection: TextSelection.collapsed(offset: 2),
      ),
    );
    await tester.pump(const Duration(milliseconds: 50));
    await tester.pumpAndSettle();
    expect(software.delta!.toPlainText(), '新软件键盘');
    editor.selection = af.Selection.single(path: [1], startOffset: 0);
    focus.requestFocus();
    await tester.pumpAndSettle();
    await tester.sendKeyEvent(LogicalKeyboardKey.backspace);
    await tester.pumpAndSettle();
    expect(hardware.attributes[DocumentToggleKeys.level], isNull);
    expect(hardware.children.single.delta!.toPlainText(), '外接子内容');
    expect(tester.takeException(), isNull);
  });

  testWidgets('replacing selected toggle text with Enter keeps its children', (
    tester,
  ) async {
    final root = documentToggleNode(
      delta: af.Delta()..insert('abcd'),
      children: [af.paragraphNode(text: '子内容')],
    );
    final editor = af.EditorState(
      document: af.Document(root: af.pageNode(children: [root])),
    );
    final folds = DocumentToggleController();
    editor.selection = af.Selection.single(
      path: [0],
      startOffset: 1,
      endOffset: 3,
    );
    await onReplace(
      const TextEditingDeltaReplacement(
        oldText: 'abcd',
        replacedRange: TextRange(start: 1, end: 3),
        replacementText: '\n',
        selection: TextSelection.collapsed(offset: 2),
        composing: TextRange.empty,
      ),
      editor,
      [documentToggleEnter(folds)],
    );
    expect(root.delta!.toPlainText(), 'a');
    expect(root.children.map((child) => child.delta!.toPlainText()), [
      'd',
      '子内容',
    ]);
    folds.dispose();
    editor.dispose();
  });

  testWidgets(
    'Enter inside an expanded toggle preserves its subtree and undo',
    (tester) async {
      final root = documentToggleNode(
        delta: af.Delta()
          ..insert('前文')
          ..insert('后文', attributes: {'bold': true}),
        children: [af.paragraphNode(text: '原子内容')],
      );
      final editor = af.EditorState(
        document: af.Document(root: af.pageNode(children: [root])),
      );
      final folds = DocumentToggleController();
      final before = jsonEncode(editor.document.toJson());
      editor.selection = af.Selection.single(path: [0], startOffset: 2);
      expect(await documentToggleEnter(folds).execute(editor), isTrue);
      expect(root.delta!.toPlainText(), '前文');
      expect(root.children.map((child) => child.delta!.toPlainText()), [
        '后文',
        '原子内容',
      ]);
      expect(
        jsonEncode(root.children.first.delta!.toJson()),
        contains('"bold":true'),
      );
      expect(editor.selection!.start.path, [0, 0]);
      editor.undoManager.undo();
      await tester.pump();
      expect(jsonEncode(editor.document.toJson()), before);
      folds.dispose();
      editor.dispose();
    },
  );

  testWidgets('Enter on a collapsed toggle keeps its existing children', (
    tester,
  ) async {
    final root = documentToggleNode(
      level: 2,
      collapsed: true,
      delta: af.Delta()..insert('标题尾部'),
      children: [af.paragraphNode(text: '保留内容')],
    );
    final editor = af.EditorState(
      document: af.Document(root: af.pageNode(children: [root])),
    );
    final folds = DocumentToggleController();
    final before = jsonEncode(editor.document.toJson());
    editor.selection = af.Selection.single(path: [0], startOffset: 2);
    expect(await documentToggleEnter(folds).execute(editor), isTrue);
    expect(root.delta!.toPlainText(), '标题');
    expect(root.children.single.delta!.toPlainText(), '保留内容');
    final next = editor.document.root.children.last;
    expect(next.delta!.toPlainText(), '尾部');
    expect(next.attributes[DocumentToggleKeys.level], 2);
    expect(next.attributes[DocumentToggleKeys.collapsed], isTrue);
    editor.undoManager.undo();
    await tester.pump();
    expect(jsonEncode(editor.document.toJson()), before);
    folds.dispose();
    editor.dispose();
  });

  testWidgets(
    'Enter replaces selected toggle text without moving its subtree',
    (tester) async {
      final root = documentToggleNode(
        delta: af.Delta()
          ..insert('ab', attributes: {'bold': true})
          ..insert('cd')
          ..insert('ef', attributes: {'italic': true}),
        children: [af.paragraphNode(text: '原子内容')],
      );
      final editor = af.EditorState(
        document: af.Document(root: af.pageNode(children: [root])),
      );
      final folds = DocumentToggleController();
      final before = jsonEncode(editor.document.toJson());
      editor.selection = af.Selection.single(
        path: [0],
        startOffset: 2,
        endOffset: 4,
      );
      expect(await documentToggleEnter(folds).execute(editor), isTrue);
      expect(root.delta!.toPlainText(), 'ab');
      expect(root.children.map((child) => child.delta!.toPlainText()), [
        'ef',
        '原子内容',
      ]);
      expect(
        jsonEncode(root.children.first.delta!.toJson()),
        contains('"italic":true'),
      );
      editor.undoManager.undo();
      await tester.pump();
      expect(jsonEncode(editor.document.toJson()), before);
      folds.dispose();
      editor.dispose();
    },
  );

  testWidgets('Enter before an empty folded title never deletes its children', (
    tester,
  ) async {
    final root = documentToggleNode(
      collapsed: true,
      children: [af.paragraphNode(text: '保留内容')],
    );
    final editor = af.EditorState(
      document: af.Document(root: af.pageNode(children: [root])),
    );
    final folds = DocumentToggleController();
    final before = jsonEncode(editor.document.toJson());
    editor.selection = af.Selection.single(path: [0], startOffset: 0);
    expect(await documentToggleEnter(folds).execute(editor), isTrue);
    expect(editor.document.root.children, hasLength(2));
    expect(root.children.single.delta!.toPlainText(), '保留内容');
    expect(editor.selection!.start.path, [1]);
    expect(editor.selection!.start.offset, 0);
    editor.undoManager.undo();
    await tester.pump();
    expect(jsonEncode(editor.document.toJson()), before);
    folds.dispose();
    editor.dispose();
  });

  testWidgets('Enter at folded title start keeps focus on the moved toggle', (
    tester,
  ) async {
    final inner = documentToggleNode(
      collapsed: true,
      delta: af.Delta()..insert('折叠标题'),
      children: [af.paragraphNode(text: '保留子内容')],
    );
    final parent = documentToggleNode(children: [inner]);
    final editor = af.EditorState(
      document: af.Document(root: af.pageNode(children: [parent])),
    );
    final folds = DocumentToggleController();
    final before = jsonEncode(editor.document.toJson());
    editor.selection = af.Selection.single(path: [0, 0], startOffset: 0);
    expect(await documentToggleEnter(folds).execute(editor), isTrue);
    expect(parent.children.first.type, af.ParagraphBlockKeys.type);
    expect(parent.children.last, same(inner));
    expect(inner.children.single.delta!.toPlainText(), '保留子内容');
    expect(editor.selection!.start.path, [0, 1]);
    editor.undoManager.undo();
    await tester.pump();
    expect(jsonEncode(editor.document.toJson()), before);
    folds.dispose();
    editor.dispose();
  });

  test(
    'cross-toggle Enter is stopped before changing document contents',
    () async {
      final root = documentToggleNode(
        delta: af.Delta()..insert('标题'),
        children: [af.paragraphNode(text: '子内容')],
      );
      final editor = af.EditorState(
        document: af.Document(
          root: af.pageNode(
            children: [
              root,
              af.paragraphNode(text: '后文'),
            ],
          ),
        ),
      );
      final folds = DocumentToggleController();
      final before = jsonEncode(editor.document.toJson());
      editor.selection = af.Selection(
        start: af.Position(path: [0], offset: 1),
        end: af.Position(path: [1], offset: 1),
      );
      expect(await documentToggleEnter(folds).execute(editor), isTrue);
      expect(jsonEncode(editor.document.toJson()), before);
      expect(editor.undoManager.undoStack.isEmpty, isTrue);
      folds.dispose();
      editor.dispose();
    },
  );

  testWidgets('IME cross-toggle replacement is stopped before deletion', (
    tester,
  ) async {
    final root = documentToggleNode(
      delta: af.Delta()..insert('标题'),
      children: [af.paragraphNode(text: '子内容')],
    );
    final editor = af.EditorState(
      document: af.Document(
        root: af.pageNode(
          children: [
            root,
            af.paragraphNode(text: '后文'),
          ],
        ),
      ),
    );
    final folds = DocumentToggleController();
    final before = jsonEncode(editor.document.toJson());
    editor.selection = af.Selection(
      start: af.Position(path: [0], offset: 1),
      end: af.Position(path: [1], offset: 1),
    );
    var selectionRefreshes = 0;
    editor.selectionNotifier.addListener(() => selectionRefreshes++);
    await onReplace(
      const TextEditingDeltaReplacement(
        oldText: '标题\n后文',
        replacedRange: TextRange(start: 1, end: 4),
        replacementText: '\n',
        selection: TextSelection.collapsed(offset: 2),
        composing: TextRange.empty,
      ),
      editor,
      [documentToggleEnter(folds), ...af.standardCharacterShortcutEvents],
    );
    expect(jsonEncode(editor.document.toJson()), before);
    expect(editor.undoManager.undoStack, isEmpty);
    expect(selectionRefreshes, 1);
    folds.dispose();
    editor.dispose();
  });

  testWidgets('rejected cross-toggle Enter restores the IME buffer', (
    tester,
  ) async {
    final root = documentToggleNode(
      delta: af.Delta()..insert('标题'),
      children: [af.paragraphNode(text: '子内容')],
    );
    final editor = af.EditorState(
      document: af.Document(
        root: af.pageNode(
          children: [
            root,
            af.paragraphNode(text: '后文'),
          ],
        ),
      ),
    );
    final focus = FocusNode();
    final scroll = af.EditorScrollController(editorState: editor);
    addTearDown(() async {
      await tester.pumpWidget(const SizedBox());
      scroll.dispose();
      editor.dispose();
      focus.dispose();
    });
    await tester.pumpWidget(
      _app(
        Scaffold(
          body: DailyNotesDocumentCanvas(
            editor: editor,
            focusNode: focus,
            scrollController: scroll,
            editable: true,
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    final original = jsonEncode(editor.document.toJson());
    focus.requestFocus();
    editor.selection = af.Selection(
      start: af.Position(path: [0], offset: 1),
      end: af.Position(path: [1], offset: 1),
    );
    await tester.pumpAndSettle();
    final keyboard =
        editor.service.keyboardServiceKey.currentState!
            as KeyboardServiceWidgetState;
    final input = keyboard.textInputService as NonDeltaTextInputService;
    final before = input.currentTextEditingValue!;
    final index = before.text.indexOf(RegExp(r'[^\s]'));
    expect(index, greaterThan(0));
    tester.testTextInput.updateEditingValue(
      TextEditingValue(
        text: before.text.replaceRange(index, index + 1, '\n'),
        selection: TextSelection.collapsed(offset: index + 1),
      ),
    );
    await tester.pump(const Duration(milliseconds: 50));
    await tester.pumpAndSettle();
    expect(jsonEncode(editor.document.toJson()), original);
    expect(input.currentTextEditingValue?.text, before.text);
    expect(input.currentTextEditingValue?.selection, before.selection);
    expect(tester.takeException(), isNull);
  });

  testWidgets('plus menu creates toggle lists and three heading levels', (
    tester,
  ) async {
    final editor = af.EditorState(
      document: af.Document(
        root: af.pageNode(children: [af.paragraphNode(text: '前文')]),
      ),
    );
    final focus = FocusNode();
    final scroll = af.EditorScrollController(editorState: editor);
    tester.view.physicalSize = const Size(430, 900);
    tester.view.devicePixelRatio = 1;
    tester.view.viewInsets = const FakeViewPadding(bottom: 300);
    addTearDown(() async {
      await tester.pumpWidget(const SizedBox());
      scroll.dispose();
      editor.dispose();
      focus.dispose();
      tester.view.resetPhysicalSize();
      tester.view.resetDevicePixelRatio();
      tester.view.resetViewInsets();
    });
    await tester.pumpWidget(
      _app(
        Scaffold(
          body: DailyNotesDocumentCanvas(
            editor: editor,
            focusNode: focus,
            scrollController: scroll,
            editable: true,
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    focus.requestFocus();
    editor.selection = af.Selection.single(path: [0], startOffset: 2);
    await tester.pumpAndSettle();
    for (final kind in ['toggle', 'toggleH1', 'toggleH2', 'toggleH3']) {
      await tester.tap(find.byKey(const ValueKey('rich-toolbar-insert')));
      await tester.pumpAndSettle();
      expect(
        find.byType(ListView),
        findsWidgets,
        reason: 'opening $kind with selection ${editor.selection}',
      );
      final item = find.byKey(ValueKey('rich-insert-$kind'));
      final list = find.byType(ListView).last;
      await tester.scrollUntilVisible(
        item,
        160,
        scrollable: find.descendant(
          of: list,
          matching: find.byType(Scrollable),
        ),
      );
      await tester.ensureVisible(item);
      await tester.pumpAndSettle();
      await tester.tap(item);
      await tester.pumpAndSettle();
    }
    final nodes = editor.document.root.children;
    expect(nodes.first.delta!.toPlainText(), '前文');
    expect(
      nodes.skip(1).map((node) => node.type),
      everyElement(DocumentToggleKeys.type),
    );
    expect(
      nodes.skip(1).map((node) => node.attributes[DocumentToggleKeys.level]),
      [null, 1, 2, 3],
    );
    final last = nodes.last;
    await tester.tap(find.byKey(ValueKey('toggle-add-child-${last.id}')));
    await tester.pumpAndSettle();
    expect(last.children, hasLength(1));
    expect(editor.selection!.start.path, [...last.path, 0]);
    expect(tester.takeException(), isNull);
  });

  testWidgets('outline opens hidden headings without changing a locked note', (
    tester,
  ) async {
    final db = MoodiaryDatabase.forTesting(NativeDatabase.memory());
    final store = DailyNotesStore(db);
    await store.open();
    final document = af.Document(
      root: af.pageNode(
        children: [
          documentToggleNode(
            collapsed: true,
            delta: af.Delta()..insert('折叠父级'),
            children: [
              af.headingNode(level: 2, text: '隐藏标题'),
              documentToggleNode(
                level: 3,
                delta: af.Delta()
                  ..insert(
                    '折叠标题',
                    attributes: {
                      af.AppFlowyRichTextKeys.textColor: '0xffdb3636',
                    },
                  ),
              ),
              af.paragraphNode(text: '隐藏内容'),
            ],
          ),
          af.paragraphNode(text: '结尾'),
        ],
      ),
    );
    final body = jsonEncode(document.toJson());
    final note = await store.saveRichNote(
      title: '测试',
      plainText: '折叠父级\n隐藏标题\n折叠标题\n隐藏内容\n结尾',
      documentJson: body,
      documentVersion: 1,
    );
    document.dispose();
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
    final canvas = tester.widget<DailyNotesDocumentCanvas>(
      find.byType(DailyNotesDocumentCanvas),
    );
    final root = canvas.editor.document.root.children.first;
    final hidden = root.children.first;
    final toggleHeading = root.children[1];
    expect(hidden.key.currentContext, isNull);
    await tester.tap(
      find.byKey(const ValueKey('note-document-outline-button')),
    );
    await tester.pumpAndSettle();
    expect(find.byKey(ValueKey('outline-${root.id}')), findsNothing);
    expect(find.byKey(ValueKey('outline-${hidden.id}')), findsOneWidget);
    expect(find.byKey(ValueKey('outline-${toggleHeading.id}')), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('outline-show-toggles')));
    await tester.pumpAndSettle();
    expect(find.byKey(ValueKey('outline-${root.id}')), findsOneWidget);
    await tester.tap(find.byKey(ValueKey('outline-${hidden.id}')));
    await tester.pumpAndSettle();
    expect(hidden.key.currentContext, isNotNull);
    expect(find.text(l10n.dailynotes.outlineUnavailable), findsNothing);
    bool redTitle(InlineSpan span) {
      if (span is! TextSpan) return false;
      return ((span.text?.contains('折叠标题') ?? false) &&
              span.style?.color == const Color(0xffdb3636)) ||
          (span.children?.any(redTitle) ?? false);
    }

    expect(
      tester
          .widgetList<RichText>(
            find.descendant(
              of: find.byKey(toggleHeading.key),
              matching: find.byType(RichText),
            ),
          )
          .any((widget) => redTitle(widget.text)),
      isTrue,
    );
    await tester.tap(find.byKey(ValueKey('toggle-block-${root.id}')));
    await tester.pumpAndSettle();
    expect(hidden.key.currentContext, isNull);
    await tester.tap(find.byKey(ValueKey('toggle-block-${root.id}')));
    await tester.pumpAndSettle();
    expect(hidden.key.currentContext, isNotNull);
    canvas.editor.selection = af.Selection.single(path: [0, 0], startOffset: 1);
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(ValueKey('toggle-block-${root.id}')));
    await tester.pumpAndSettle();
    expect(hidden.key.currentContext, isNotNull);
    expect(find.text(l10n.dailynotes.toggleSelectionInside), findsOneWidget);
    expect(canvas.editable, isFalse);
    expect(store.notes.single.documentJson, body);
    expect(store.pendingOperationCount, pending);
  });
}
