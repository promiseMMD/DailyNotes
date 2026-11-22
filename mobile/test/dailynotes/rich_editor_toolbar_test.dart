import 'dart:async';
import 'dart:convert';
import 'dart:ui' show Tristate;

import 'package:appflowy_editor/appflowy_editor.dart' as af;
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:moodiary_di/moodiary_di.dart';
import 'package:moodiary_i18n/moodiary_i18n.dart';
import 'package:moodiary_mobile/app/dailynotes/editor/document_editor_back_controller.dart';
import 'package:moodiary_mobile/app/dailynotes/notes/rich_editor_toolbar.dart';
import 'package:moodiary_storage/moodiary_storage.dart';
import 'package:moodiary_storage/testing.dart';
import 'package:mui/mui.dart';

void main() {
  setUpAll(() async {
    getIt.registerSingleton<IKVStorage>(MemoryKVStorage());
    await setupPluralResolvers();
    await LocaleSettings.setLocale(AppLocale.zh);
  });
  tearDownAll(() => getIt.reset());

  Future<void> mount(
    WidgetTester tester,
    af.EditorState editor, {
    bool editable = true,
    af.EditorScrollController? scrollController,
    DocumentEditorBackController? backController,
    Future<({List<String> families, bool hasUnavailable})> Function()?
    loadFonts,
  }) async {
    final focus = FocusNode();
    addTearDown(focus.dispose);
    tester.view.physicalSize = const Size(430, 900);
    tester.view.devicePixelRatio = 1;
    tester.view.viewInsets = const FakeViewPadding(bottom: 300);
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    addTearDown(tester.view.resetViewInsets);
    await tester.pumpWidget(
      TranslationProvider(
        child: MaterialApp(
          theme: buildMuiTheme(brightness: Brightness.light),
          localizationsDelegates: const [
            af.AppFlowyEditorLocalizations.delegate,
            ...GlobalMaterialLocalizations.delegates,
            GlobalMuiLocalizations.delegate,
          ],
          builder: (context, child) =>
              MaterialUiCompatibilityBridge(child: child!),
          home: Scaffold(
            body: RichEditorToolbar(
              editor: editor,
              focusNode: focus,
              editable: editable,
              backController: backController,
              loadFonts: loadFonts,
              scrollController: scrollController,
              child: af.AppFlowyEditor(
                editorState: editor,
                editable: editable,
                focusNode: focus,
                editorScrollController: scrollController,
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    if (editable) {
      focus.requestFocus();
      await tester.pump();
    }
  }

  af.EditorState document(String text) => af.EditorState(
    document: af.Document(
      root: af.pageNode(children: [af.paragraphNode(text: text)]),
    ),
  );

  Future<void> tapOverflow(WidgetTester tester, String action) async {
    await tester.tap(find.byKey(const ValueKey('rich-toolbar-more')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(ValueKey('rich-overflow-$action')));
    await tester.pumpAndSettle();
  }

  Future<void> openInlineCodeMenu(WidgetTester tester) async {
    final arrow = find.byKey(const ValueKey('rich-format-code-more'));
    await tester.ensureVisible(arrow);
    await tester.tap(arrow);
    await tester.pumpAndSettle();
  }

  testWidgets('quick color applies text and highlight to the same selection', (
    tester,
  ) async {
    final editor = document('alpha beta');
    await mount(tester, editor);
    final selection = af.Selection.single(
      path: [0],
      startOffset: 0,
      endOffset: 5,
    );
    editor.selection = selection;
    await tester.pumpAndSettle();
    await tapOverflow(tester, 'color');
    await tester.pumpAndSettle();
    await tester.tap(
      find.byKey(const ValueKey('rich-quick-color-text-0xffd32f2f')),
    );
    await tester.pumpAndSettle();
    await tester.tap(
      find.byKey(const ValueKey('rich-quick-color-background-0xff1976d2')),
    );
    await tester.pumpAndSettle();
    final serialized = jsonEncode(editor.document.toJson());
    expect(serialized, contains('0xffd32f2f'));
    expect(serialized, contains('0x4d1976d2'));
    expect(editor.selection, selection);
    expect(find.text(l10n.dailynotes.editorSelectionChanged), findsNothing);
    await tester.pumpWidget(const SizedBox());
    editor.dispose();
  });

  testWidgets('toolbar changes with selection without rebuilding the editor', (
    tester,
  ) async {
    final editor = document('alpha beta');
    await mount(tester, editor);
    final before = tester.state(find.byType(af.AppFlowyEditor));
    expect(find.byKey(const ValueKey('rich-toolbar-insert')), findsNothing);
    tester.view.viewInsets = FakeViewPadding.zero;
    editor.selection = af.Selection.single(path: [0], startOffset: 0);
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('rich-toolbar-insert')), findsNothing);
    expect(
      identical(before, tester.state(find.byType(af.AppFlowyEditor))),
      isTrue,
    );
    tester.view.viewInsets = const FakeViewPadding(bottom: 300);
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('rich-toolbar-insert')), findsOneWidget);
    expect(find.byKey(const ValueKey('rich-toolbar-format')), findsOneWidget);
    expect(
      identical(before, tester.state(find.byType(af.AppFlowyEditor))),
      isTrue,
    );
    editor.selection = af.Selection.single(
      path: [0],
      startOffset: 0,
      endOffset: 5,
    );
    await tester.pumpAndSettle();
    expect(
      tester
          .widget<IconButton>(find.byKey(const ValueKey('rich-toolbar-insert')))
          .onPressed,
      isNull,
    );
    expect(find.byKey(const ValueKey('rich-toolbar-bold')), findsOneWidget);
    expect(
      identical(before, tester.state(find.byType(af.AppFlowyEditor))),
      isTrue,
    );
    tester
        .widget<RichEditorToolbar>(find.byType(RichEditorToolbar))
        .focusNode
        .unfocus();
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('rich-toolbar-format')), findsNothing);
    await tester.pumpWidget(const SizedBox());
    editor.dispose();
  });

  testWidgets('plus menu inserts a real heading after nonempty text', (
    tester,
  ) async {
    final editor = document('keep this');
    await mount(tester, editor);
    editor.selection = af.Selection.single(path: [0], startOffset: 4);
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('rich-toolbar-insert')));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('rich-insert-h1')), findsOneWidget);
    expect(find.byKey(const ValueKey('rich-insert-h2')), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('rich-insert-h1')));
    await tester.pumpAndSettle();
    expect(editor.document.root.children, hasLength(2));
    expect(
      editor.document.root.children.first.delta!.toPlainText(),
      'keep this',
    );
    expect(editor.document.root.children.last.type, af.HeadingBlockKeys.type);
    expect(
      editor.document.root.children.last.attributes[af.HeadingBlockKeys.level],
      1,
    );
    final encoded = jsonEncode(editor.document.toJson());
    expect(
      jsonEncode(af.Document.fromJson(jsonDecode(encoded)).toJson()),
      encoded,
    );
    await tester.pumpWidget(const SizedBox());
    editor.dispose();
  });

  testWidgets(
    'Aa applies consecutive formatting to the original selected text',
    (tester) async {
      final editor = document('alpha beta');
      await mount(tester, editor);
      final selection = af.Selection.single(
        path: [0],
        startOffset: 0,
        endOffset: 5,
      );
      editor.selection = selection;
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('rich-toolbar-format')));
      await tester.pumpAndSettle();
      final sheet = find.byKey(const ValueKey('rich-format-panel'));
      await tester.tap(
        find.descendant(
          of: sheet,
          matching: find.byTooltip(l10n.editor.toolbar.bold),
        ),
      );
      await tester.pumpAndSettle();
      expect(editor.selection, selection);
      expect(jsonEncode(editor.document.toJson()), contains('"bold":true'));
      expect(
        tester
            .widget<IconButton>(
              find.byKey(ValueKey('rich-format-${l10n.editor.toolbar.bold}')),
            )
            .isSelected,
        isTrue,
      );
      await tester.tap(
        find.byKey(ValueKey('rich-format-${l10n.dailynotes.editorTextColor}')),
      );
      await tester.pumpAndSettle();
      await tester.tap(
        find.byKey(const ValueKey('rich-quick-color-text-0xffd32f2f')),
      );
      await tester.pumpAndSettle();
      expect(editor.selection, selection);
      expect(jsonEncode(editor.document.toJson()), contains('0xffd32f2f'));
      expect(
        find.descendant(
          of: find.byKey(const ValueKey('rich-quick-color-text-0xffd32f2f')),
          matching: find.byKey(
            const ValueKey('rich-quick-color-selected-text'),
          ),
        ),
        findsOneWidget,
      );
      await tester.tap(
        find.byKey(const ValueKey('rich-quick-color-background-0xffd32f2f')),
      );
      await tester.pumpAndSettle();
      expect(jsonEncode(editor.document.toJson()), contains('0x4dd32f2f'));
      expect(editor.selection, selection);
      expect(
        find.descendant(
          of: find.byKey(
            const ValueKey('rich-quick-color-background-0xffd32f2f'),
          ),
          matching: find.byKey(
            const ValueKey('rich-quick-color-selected-background'),
          ),
        ),
        findsOneWidget,
      );
      await tester.tap(find.byKey(const ValueKey('rich-color-done')));
      await tester.pumpAndSettle();
      await tester.tap(
        find.descendant(
          of: sheet,
          matching: find.byTooltip(l10n.editor.toolbar.italic),
        ),
      );
      await tester.pumpAndSettle();
      expect(jsonEncode(editor.document.toJson()), contains('"italic":true'));
      expect(
        editor.document.root.children.single.delta!.toPlainText(),
        'alpha beta',
      );
      await tester.tap(find.text(l10n.dailynotes.editorFormatDone));
      await tester.pumpAndSettle();
      await tester.pumpWidget(const SizedBox());
      editor.dispose();
    },
  );

  testWidgets('Aa refuses an old selection after the user changes it', (
    tester,
  ) async {
    final editor = document('alpha beta');
    await mount(tester, editor);
    editor.selection = af.Selection.single(
      path: [0],
      startOffset: 0,
      endOffset: 5,
    );
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('rich-toolbar-format')));
    await tester.pumpAndSettle();
    final original = jsonEncode(editor.document.toJson());
    editor.selection = af.Selection.single(
      path: [0],
      startOffset: 6,
      endOffset: 10,
    );
    // Returning to the same coordinates must not revive the old session.
    editor.selection = af.Selection.single(
      path: [0],
      startOffset: 0,
      endOffset: 5,
    );
    await tester.pump();
    final button = find.byKey(
      ValueKey('rich-format-${l10n.editor.toolbar.bold}'),
    );
    expect(tester.widget<IconButton>(button).onPressed, isNull);
    expect(jsonEncode(editor.document.toJson()), original);
    expect(find.text(l10n.dailynotes.editorSelectionChanged), findsOneWidget);
    await tester.pumpWidget(const SizedBox());
    editor.dispose();
  });

  testWidgets('Aa shows ordered headings and selected block and alignment', (
    tester,
  ) async {
    final semantics = tester.ensureSemantics();
    final editor = document('alpha beta');
    await mount(tester, editor);
    editor.selection = af.Selection.single(
      path: [0],
      startOffset: 0,
      endOffset: 5,
    );
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('rich-toolbar-format')));
    await tester.pumpAndSettle();
    final h1 = find.byKey(const ValueKey('rich-format-heading-1'));
    final h2 = find.byKey(const ValueKey('rich-format-heading-2'));
    final h3 = find.byKey(const ValueKey('rich-format-heading-3'));
    final paragraph = find.byKey(const ValueKey('rich-format-paragraph'));
    expect(tester.getTopLeft(h1).dx, lessThan(tester.getTopLeft(h2).dx));
    expect(tester.getTopLeft(h2).dx, lessThan(tester.getTopLeft(h3).dx));
    expect(tester.getTopLeft(h3).dx, lessThan(tester.getTopLeft(paragraph).dx));
    expect(
      tester.getSemantics(paragraph).flagsCollection.isSelected ==
          Tristate.isTrue,
      isTrue,
    );
    final left = find.byKey(
      ValueKey('rich-format-${l10n.dailynotes.editorAlignLeft}'),
    );
    expect(tester.widget<IconButton>(left).isSelected, isTrue);
    await tester.tap(h2);
    await tester.pumpAndSettle();
    expect(tester.getSemantics(h2).flagsCollection.isSelected, Tristate.isTrue);
    expect(
      tester.getSemantics(paragraph).flagsCollection.isSelected ==
          Tristate.isTrue,
      isFalse,
    );
    final right = find.byKey(
      ValueKey('rich-format-${l10n.dailynotes.editorAlignRight}'),
    );
    await tester.ensureVisible(right);
    await tester.tap(right);
    await tester.pumpAndSettle();
    expect(tester.widget<IconButton>(right).isSelected, isTrue);
    expect(tester.widget<IconButton>(left).isSelected, isFalse);
    expect(editor.selection?.start.path, [0]);
    semantics.dispose();
    await tester.pumpWidget(const SizedBox());
    editor.dispose();
  });

  testWidgets('Aa mixed block selection does not claim one heading type', (
    tester,
  ) async {
    final semantics = tester.ensureSemantics();
    final editor = af.EditorState(
      document: af.Document(
        root: af.pageNode(
          children: [
            af.headingNode(level: 1, text: 'first'),
            af.paragraphNode(text: 'second'),
          ],
        ),
      ),
    );
    await mount(tester, editor);
    editor.selection = af.Selection(
      start: af.Position(path: [0], offset: 0),
      end: af.Position(path: [1], offset: 3),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('rich-toolbar-format')));
    await tester.pumpAndSettle();
    for (final key in ['heading-1', 'heading-2', 'heading-3', 'paragraph']) {
      expect(
        tester
                .getSemantics(find.byKey(ValueKey('rich-format-$key')))
                .flagsCollection
                .isSelected ==
            Tristate.isTrue,
        isFalse,
      );
    }
    semantics.dispose();
    await tester.pumpWidget(const SizedBox());
    editor.dispose();
  });

  testWidgets('Aa long press on link group toggles inline code', (
    tester,
  ) async {
    final editor = document('alpha beta');
    await mount(tester, editor);
    final selection = af.Selection.single(
      path: [0],
      startOffset: 0,
      endOffset: 5,
    );
    editor.selection = selection;
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('rich-toolbar-format')));
    await tester.pumpAndSettle();
    final group = find.byKey(const ValueKey('rich-format-link-code'));
    await tester.ensureVisible(group);
    await tester.longPress(group);
    await tester.pumpAndSettle();
    expect(jsonEncode(editor.document.toJson()), contains('"code":true'));
    expect(editor.selection, selection);
    expect(find.byKey(const ValueKey('rich-format-panel')), findsOneWidget);
    await tester.pumpWidget(const SizedBox());
    editor.dispose();
  });

  testWidgets('dragging away from the Aa code popup cancels the long press', (
    tester,
  ) async {
    final editor = document('alpha beta');
    await mount(tester, editor);
    editor.selection = af.Selection.single(
      path: [0],
      startOffset: 0,
      endOffset: 5,
    );
    await tester.pumpAndSettle();
    final original = jsonEncode(editor.document.toJson());
    await tester.tap(find.byKey(const ValueKey('rich-toolbar-format')));
    await tester.pumpAndSettle();
    final group = find.byKey(const ValueKey('rich-format-link-code'));
    await tester.ensureVisible(group);
    final gesture = await tester.startGesture(tester.getCenter(group));
    await tester.pump(const Duration(milliseconds: 600));
    await gesture.moveBy(const Offset(300, 0));
    await tester.pump();
    await gesture.up();
    await tester.pumpAndSettle();
    expect(jsonEncode(editor.document.toJson()), original);
    expect(
      find.byKey(ValueKey('rich-format-${l10n.editor.toolbar.inlineCode}')),
      findsNothing,
    );
    await tester.pumpWidget(const SizedBox());
    editor.dispose();
  });

  testWidgets('Aa code menu remains reachable on a narrow screen', (
    tester,
  ) async {
    final editor = document('alpha beta');
    await mount(tester, editor);
    tester.view.physicalSize = const Size(192, 600);
    tester.view.viewInsets = FakeViewPadding.zero;
    editor.selection = af.Selection.single(
      path: [0],
      startOffset: 0,
      endOffset: 5,
    );
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('rich-floating-format')));
    await tester.pumpAndSettle();
    await openInlineCodeMenu(tester);
    final code = find.byKey(
      ValueKey('rich-format-${l10n.editor.toolbar.inlineCode}'),
    );
    final bounds = tester.getRect(code);
    expect(bounds.left, greaterThanOrEqualTo(0));
    expect(bounds.right, lessThanOrEqualTo(192));
    await tester.tap(code);
    await tester.pumpAndSettle();
    expect(jsonEncode(editor.document.toJson()), contains('"code":true'));
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
    editor.dispose();
  });

  testWidgets(
    'Aa code menu returns before closing Aa and rejects old actions',
    (tester) async {
      final editor = document('alpha beta');
      await mount(tester, editor);
      editor.selection = af.Selection.single(
        path: [0],
        startOffset: 0,
        endOffset: 5,
      );
      await tester.pumpAndSettle();
      final original = jsonEncode(editor.document.toJson());
      await tester.tap(find.byKey(const ValueKey('rich-toolbar-format')));
      await tester.pumpAndSettle();
      await openInlineCodeMenu(tester);
      final code = find.byKey(
        ValueKey('rich-format-${l10n.editor.toolbar.inlineCode}'),
      );
      expect(code, findsOneWidget);
      tester.testTextInput.log.clear();
      await tester.binding.handlePopRoute();
      await tester.pumpAndSettle();
      expect(code, findsNothing);
      expect(find.byKey(const ValueKey('rich-format-panel')), findsOneWidget);
      expect(
        tester.testTextInput.log.map((call) => call.method),
        isNot(contains('TextInput.show')),
      );
      await openInlineCodeMenu(tester);
      final oldAction = tester.widget<MenuItemButton>(code).onPressed!;
      editor.selection = af.Selection.single(
        path: [0],
        startOffset: 6,
        endOffset: 10,
      );
      oldAction();
      await tester.pumpAndSettle();
      expect(jsonEncode(editor.document.toJson()), original);
      await tester.pumpWidget(const SizedBox());
      editor.dispose();
    },
  );

  testWidgets(
    'Aa link sheet applies a link and returns to the same selection',
    (tester) async {
      final editor = document('alpha beta');
      await mount(tester, editor);
      final selection = af.Selection.single(
        path: [0],
        startOffset: 0,
        endOffset: 5,
      );
      editor.selection = selection;
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('rich-toolbar-format')));
      await tester.pumpAndSettle();
      final link = find.byKey(const ValueKey('rich-format-link'));
      await tester.ensureVisible(link);
      await tester.tap(link);
      await tester.pumpAndSettle();
      expect(
        find.byKey(const ValueKey('rich-format-link-sheet')),
        findsOneWidget,
      );
      expect(find.byType(BottomSheet), findsOneWidget);
      await tester.enterText(
        find.byKey(const ValueKey('rich-link-address')),
        'javascript:alert(1)',
      );
      await tester.tap(find.byKey(const ValueKey('rich-link-save')));
      await tester.pumpAndSettle();
      expect(find.text(l10n.dailynotes.editorLinkInvalid), findsOneWidget);
      await tester.enterText(
        find.byKey(const ValueKey('rich-link-address')),
        'example.com',
      );
      tester.testTextInput.log.clear();
      await tester.tap(find.byKey(const ValueKey('rich-link-save')));
      await tester.pumpAndSettle();
      expect(
        find.byKey(const ValueKey('rich-format-link-sheet')),
        findsNothing,
      );
      expect(find.byKey(const ValueKey('rich-format-panel')), findsOneWidget);
      expect(editor.selection, selection);
      expect(
        jsonEncode(editor.document.toJson()),
        contains('"href":"https://example.com"'),
      );
      expect(
        tester.testTextInput.log.map((call) => call.method),
        isNot(contains('TextInput.show')),
      );
      final italic = find.byKey(
        ValueKey('rich-format-${l10n.editor.toolbar.italic}'),
      );
      await tester.tap(italic);
      await tester.pumpAndSettle();
      expect(jsonEncode(editor.document.toJson()), contains('"italic":true'));
      tester.testTextInput.log.clear();
      await tester.tap(find.byKey(const ValueKey('rich-format-done')));
      await tester.pumpAndSettle();
      expect(
        tester.testTextInput.log.map((call) => call.method),
        contains('TextInput.show'),
      );
      await tester.pumpWidget(const SizedBox());
      editor.dispose();
    },
  );

  testWidgets('Aa inserts a link at the caret and undoes it atomically', (
    tester,
  ) async {
    final editor = document('A😀B');
    await mount(tester, editor);
    final original = jsonEncode(editor.document.toJson());
    editor.selection = af.Selection.collapsed(
      af.Position(path: [0], offset: 3),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('rich-toolbar-format')));
    await tester.pumpAndSettle();
    final link = find.byKey(const ValueKey('rich-format-link'));
    await tester.ensureVisible(link);
    await tester.tap(link);
    await tester.pumpAndSettle();
    expect(
      tester
          .widget<TextField>(find.byKey(const ValueKey('rich-link-text')))
          .controller!
          .text,
      isEmpty,
    );
    await tester.enterText(
      find.byKey(const ValueKey('rich-link-address')),
      'example.com',
    );
    await tester.tap(find.byKey(const ValueKey('rich-link-save')));
    await tester.pumpAndSettle();
    expect(
      editor.document.root.children.single.delta!.toPlainText(),
      'A😀https://example.comB',
    );
    expect(
      editor.selection,
      af.Selection.collapsed(af.Position(path: [0], offset: 22)),
    );
    expect(
      jsonEncode(editor.document.toJson()),
      contains('"href":"https://example.com"'),
    );
    final inserted = jsonEncode(editor.document.toJson());
    editor.undoManager.undo();
    await tester.pumpAndSettle();
    expect(jsonEncode(editor.document.toJson()), original);
    editor.undoManager.redo();
    await tester.pumpAndSettle();
    expect(jsonEncode(editor.document.toJson()), inserted);
    await tester.pumpWidget(const SizedBox());
    editor.dispose();
  });

  testWidgets('editing link text preserves unaffected rich styles and undo', (
    tester,
  ) async {
    final editor = document('前alpha😀beta后');
    await mount(tester, editor);
    await editor.formatDelta(
      af.Selection.single(path: [0], startOffset: 1, endOffset: 6),
      {af.AppFlowyRichTextKeys.bold: true},
    );
    await editor.formatDelta(
      af.Selection.single(path: [0], startOffset: 6, endOffset: 12),
      {af.AppFlowyRichTextKeys.italic: true},
    );
    final selected = af.Selection.single(
      path: [0],
      startOffset: 1,
      endOffset: 12,
    );
    editor.selection = selected;
    await tester.pumpAndSettle();
    final original = jsonEncode(editor.document.toJson());
    await tester.tap(find.byKey(const ValueKey('rich-toolbar-format')));
    await tester.pumpAndSettle();
    final link = find.byKey(const ValueKey('rich-format-link'));
    await tester.ensureVisible(link);
    await tester.tap(link);
    await tester.pumpAndSettle();
    expect(
      tester
          .widget<TextField>(find.byKey(const ValueKey('rich-link-text')))
          .controller!
          .text,
      'alpha😀beta',
    );
    await tester.enterText(
      find.byKey(const ValueKey('rich-link-text')),
      'alpha😀BETA',
    );
    await tester.enterText(
      find.byKey(const ValueKey('rich-link-address')),
      'example.com',
    );
    await tester.tap(find.byKey(const ValueKey('rich-link-save')));
    await tester.pumpAndSettle();
    final delta = editor.document.root.children.single.delta!;
    expect(delta.toPlainText(), '前alpha😀BETA后');
    expect(
      delta.slice(1, 6).first.attributes?[af.AppFlowyRichTextKeys.bold],
      true,
    );
    expect(
      delta.slice(6, 12).first.attributes?[af.AppFlowyRichTextKeys.italic],
      true,
    );
    expect(
      delta
          .slice(1, 12)
          .every(
            (op) =>
                op.attributes?[af.AppFlowyRichTextKeys.href] ==
                'https://example.com',
          ),
      isTrue,
    );
    expect(editor.selection, selected);
    final edited = jsonEncode(editor.document.toJson());
    editor.undoManager.undo();
    await tester.pumpAndSettle();
    expect(jsonEncode(editor.document.toJson()), original);
    editor.undoManager.redo();
    await tester.pumpAndSettle();
    expect(jsonEncode(editor.document.toJson()), edited);
    await tester.pumpWidget(const SizedBox());
    editor.dispose();
  });

  testWidgets('toolbar link inserts custom text and rejects multiline text', (
    tester,
  ) async {
    final editor = document('hello');
    await mount(tester, editor);
    editor.selection = af.Selection.collapsed(
      af.Position(path: [0], offset: 5),
    );
    await tester.pumpAndSettle();
    await tapOverflow(tester, 'link');
    final textField = tester.widget<TextField>(
      find.byKey(const ValueKey('rich-link-text')),
    );
    textField.controller!.text = 'invalid\ntext';
    await tester.enterText(
      find.byKey(const ValueKey('rich-link-address')),
      'example.com',
    );
    await tester.tap(find.byKey(const ValueKey('rich-link-save')));
    await tester.pumpAndSettle();
    expect(find.text(l10n.dailynotes.editorLinkTextInvalid), findsOneWidget);
    expect(editor.document.root.children.single.delta!.toPlainText(), 'hello');
    await tester.enterText(find.byKey(const ValueKey('rich-link-text')), '参考');
    await tester.tap(find.byKey(const ValueKey('rich-link-save')));
    await tester.pumpAndSettle();
    expect(
      editor.document.root.children.single.delta!.toPlainText(),
      'hello参考',
    );
    expect(
      jsonEncode(editor.document.toJson()),
      contains('"href":"https://example.com"'),
    );
    await tester.pumpWidget(const SizedBox());
    editor.dispose();
  });

  testWidgets('link label insertion preserves styled emoji suffix and undo', (
    tester,
  ) async {
    final editor = document('ab😀cd');
    await mount(tester, editor);
    await editor.formatDelta(
      af.Selection.single(path: [0], startOffset: 0, endOffset: 2),
      {af.AppFlowyRichTextKeys.bold: true},
    );
    await editor.formatDelta(
      af.Selection.single(path: [0], startOffset: 2, endOffset: 6),
      {af.AppFlowyRichTextKeys.italic: true},
    );
    editor.selection = af.Selection.single(
      path: [0],
      startOffset: 0,
      endOffset: 6,
    );
    await tester.pumpAndSettle();
    final original = jsonEncode(editor.document.toJson());
    await tester.tap(find.byKey(const ValueKey('rich-toolbar-format')));
    await tester.pumpAndSettle();
    final link = find.byKey(const ValueKey('rich-format-link'));
    await tester.ensureVisible(link);
    await tester.tap(link);
    await tester.pumpAndSettle();
    await tester.enterText(
      find.byKey(const ValueKey('rich-link-text')),
      'abX😀cd',
    );
    await tester.enterText(
      find.byKey(const ValueKey('rich-link-address')),
      'example.com',
    );
    await tester.tap(find.byKey(const ValueKey('rich-link-save')));
    await tester.pumpAndSettle();
    final delta = editor.document.root.children.single.delta!;
    expect(delta.toPlainText(), 'abX😀cd');
    expect(
      delta.slice(0, 2).first.attributes?[af.AppFlowyRichTextKeys.bold],
      true,
    );
    expect(
      delta.slice(3, 7).first.attributes?[af.AppFlowyRichTextKeys.italic],
      true,
    );
    expect(
      editor.selection,
      af.Selection.single(path: [0], startOffset: 0, endOffset: 7),
    );
    editor.undoManager.undo();
    await tester.pumpAndSettle();
    expect(jsonEncode(editor.document.toJson()), original);
    await tester.pumpWidget(const SizedBox());
    editor.dispose();
  });

  testWidgets('link editor remains usable on a short narrow phone', (
    tester,
  ) async {
    final editor = document('短文');
    await mount(tester, editor);
    tester.view.physicalSize = const Size(320, 600);
    tester.view.viewInsets = const FakeViewPadding(bottom: 280);
    editor.selection = af.Selection.collapsed(
      af.Position(path: [0], offset: 2),
    );
    await tester.pumpAndSettle();
    await tapOverflow(tester, 'link');
    expect(tester.takeException(), isNull);
    final text = find.byKey(const ValueKey('rich-link-text'));
    final address = find.byKey(const ValueKey('rich-link-address'));
    await tester.ensureVisible(text);
    await tester.enterText(text, '参考');
    await tester.ensureVisible(address);
    await tester.enterText(address, 'example.com');
    final save = find.byKey(const ValueKey('rich-link-save'));
    await tester.ensureVisible(save);
    await tester.tap(save);
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    expect(editor.document.root.children.single.delta!.toPlainText(), '短文参考');
    await tester.pumpWidget(const SizedBox());
    editor.dispose();
  });

  testWidgets('Aa link sheet rejects a selection changed while editing', (
    tester,
  ) async {
    final editor = document('alpha beta');
    await mount(tester, editor);
    editor.selection = af.Selection.single(
      path: [0],
      startOffset: 0,
      endOffset: 5,
    );
    await tester.pumpAndSettle();
    final original = jsonEncode(editor.document.toJson());
    await tester.tap(find.byKey(const ValueKey('rich-toolbar-format')));
    await tester.pumpAndSettle();
    final link = find.byKey(const ValueKey('rich-format-link'));
    await tester.ensureVisible(link);
    await tester.tap(link);
    await tester.pumpAndSettle();
    editor.selection = af.Selection.single(
      path: [0],
      startOffset: 6,
      endOffset: 10,
    );
    tester
            .widget<TextField>(find.byKey(const ValueKey('rich-link-address')))
            .controller!
            .text =
        'example.com';
    await tester.pump();
    await tester.tap(find.byKey(const ValueKey('rich-link-save')));
    await tester.pumpAndSettle();
    expect(jsonEncode(editor.document.toJson()), original);
    expect(find.byKey(const ValueKey('rich-format-panel')), findsNothing);
    expect(find.text(l10n.dailynotes.editorSelectionChanged), findsOneWidget);
    await tester.pumpWidget(const SizedBox());
    editor.dispose();
  });

  testWidgets('Aa reopens and removes a link with undo support', (
    tester,
  ) async {
    final editor = document('alpha beta');
    await mount(tester, editor);
    final selection = af.Selection.single(
      path: [0],
      startOffset: 0,
      endOffset: 5,
    );
    editor.selection = selection;
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('rich-toolbar-format')));
    await tester.pumpAndSettle();
    final link = find.byKey(const ValueKey('rich-format-link'));
    await tester.ensureVisible(link);
    await tester.tap(link);
    await tester.pumpAndSettle();
    await tester.enterText(
      find.byKey(const ValueKey('rich-link-address')),
      'example.com',
    );
    await tester.tap(find.byKey(const ValueKey('rich-link-save')));
    await tester.pumpAndSettle();
    await tester.ensureVisible(link);
    await tester.tap(link);
    await tester.pumpAndSettle();
    expect(
      tester
          .widget<TextField>(find.byKey(const ValueKey('rich-link-address')))
          .controller!
          .text,
      'https://example.com',
    );
    await tester.tap(find.byKey(const ValueKey('rich-link-remove')));
    await tester.pumpAndSettle();
    expect(jsonEncode(editor.document.toJson()), isNot(contains('"href"')));
    expect(editor.selection, selection);
    editor.undoManager.undo();
    await tester.pumpAndSettle();
    expect(
      jsonEncode(editor.document.toJson()),
      contains('"href":"https://example.com"'),
    );
    await tester.pumpWidget(const SizedBox());
    editor.dispose();
  });

  testWidgets('cancelling an Aa link returns without reopening the keyboard', (
    tester,
  ) async {
    final editor = document('alpha beta');
    await mount(tester, editor);
    tester.view.viewInsets = FakeViewPadding.zero;
    final selection = af.Selection.single(
      path: [0],
      startOffset: 0,
      endOffset: 5,
    );
    editor.selection = selection;
    await tester.pumpAndSettle();
    final original = jsonEncode(editor.document.toJson());
    await tester.tap(find.byKey(const ValueKey('rich-floating-format')));
    await tester.pumpAndSettle();
    final link = find.byKey(const ValueKey('rich-format-link'));
    await tester.ensureVisible(link);
    await tester.tap(link);
    await tester.pumpAndSettle();
    tester.testTextInput.log.clear();
    await tester.binding.handlePopRoute();
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('rich-format-link-sheet')), findsNothing);
    expect(find.byKey(const ValueKey('rich-format-panel')), findsOneWidget);
    expect(editor.selection, selection);
    expect(jsonEncode(editor.document.toJson()), original);
    await tester.tap(find.byKey(const ValueKey('rich-format-done')));
    await tester.pumpAndSettle();
    expect(
      tester.testTextInput.log.map((call) => call.method),
      isNot(contains('TextInput.show')),
    );
    await tester.pumpWidget(const SizedBox());
    editor.dispose();
  });

  testWidgets('locking and unlocking invalidates an Aa link result', (
    tester,
  ) async {
    final editor = document('alpha beta');
    await mount(tester, editor);
    editor.selection = af.Selection.single(
      path: [0],
      startOffset: 0,
      endOffset: 5,
    );
    await tester.pumpAndSettle();
    final original = jsonEncode(editor.document.toJson());
    await tester.tap(find.byKey(const ValueKey('rich-toolbar-format')));
    await tester.pumpAndSettle();
    final link = find.byKey(const ValueKey('rich-format-link'));
    await tester.ensureVisible(link);
    await tester.tap(link);
    await tester.pumpAndSettle();
    tester
            .widget<TextField>(find.byKey(const ValueKey('rich-link-address')))
            .controller!
            .text =
        'example.com';
    final save = tester
        .widget<TextButton>(find.byKey(const ValueKey('rich-link-save')))
        .onPressed!;
    tester.testTextInput.log.clear();
    editor.editable = false;
    editor.editable = true;
    save();
    await tester.pumpAndSettle();
    expect(jsonEncode(editor.document.toJson()), original);
    expect(find.byKey(const ValueKey('rich-format-panel')), findsNothing);
    expect(find.byKey(const ValueKey('rich-format-link-sheet')), findsNothing);
    expect(
      tester.testTextInput.log.map((call) => call.method),
      isNot(contains('TextInput.show')),
    );
    await tester.pumpWidget(const SizedBox());
    editor.dispose();
  });

  testWidgets('another route invalidates an Aa link before it can be saved', (
    tester,
  ) async {
    final editor = document('alpha beta');
    await mount(tester, editor);
    editor.selection = af.Selection.single(
      path: [0],
      startOffset: 0,
      endOffset: 5,
    );
    await tester.pumpAndSettle();
    final original = jsonEncode(editor.document.toJson());
    await tester.tap(find.byKey(const ValueKey('rich-toolbar-format')));
    await tester.pumpAndSettle();
    final link = find.byKey(const ValueKey('rich-format-link'));
    await tester.ensureVisible(link);
    await tester.tap(link);
    await tester.pumpAndSettle();
    final navigator = Navigator.of(
      tester.element(find.byKey(const ValueKey('rich-format-link-sheet'))),
    );
    unawaited(
      navigator.push<void>(
        MaterialPageRoute<void>(
          builder: (_) => const Scaffold(body: Text('other document')),
        ),
      ),
    );
    await tester.pumpAndSettle();
    navigator.pop();
    await tester.pumpAndSettle();
    tester
            .widget<TextField>(find.byKey(const ValueKey('rich-link-address')))
            .controller!
            .text =
        'example.com';
    await tester.pump();
    await tester.tap(find.byKey(const ValueKey('rich-link-save')));
    await tester.pumpAndSettle();
    expect(jsonEncode(editor.document.toJson()), original);
    expect(find.byKey(const ValueKey('rich-format-panel')), findsNothing);
    await tester.pumpWidget(const SizedBox());
    editor.dispose();
  });

  testWidgets('backgrounding invalidates an Aa link result', (tester) async {
    final editor = document('alpha beta');
    await mount(tester, editor);
    editor.selection = af.Selection.single(
      path: [0],
      startOffset: 0,
      endOffset: 5,
    );
    await tester.pumpAndSettle();
    final original = jsonEncode(editor.document.toJson());
    await tester.tap(find.byKey(const ValueKey('rich-toolbar-format')));
    await tester.pumpAndSettle();
    final link = find.byKey(const ValueKey('rich-format-link'));
    await tester.ensureVisible(link);
    await tester.tap(link);
    await tester.pumpAndSettle();
    tester
            .widget<TextField>(find.byKey(const ValueKey('rich-link-address')))
            .controller!
            .text =
        'example.com';
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await tester.pump();
    await tester.tap(find.byKey(const ValueKey('rich-link-save')));
    await tester.pumpAndSettle();
    expect(jsonEncode(editor.document.toJson()), original);
    expect(find.byKey(const ValueKey('rich-format-panel')), findsNothing);
    await tester.pumpWidget(const SizedBox());
    editor.dispose();
  });

  testWidgets('late keyboard hide cannot apply a link to a changed selection', (
    tester,
  ) async {
    final editor = document('alpha beta');
    await mount(tester, editor);
    editor.selection = af.Selection.single(
      path: [0],
      startOffset: 0,
      endOffset: 5,
    );
    await tester.pumpAndSettle();
    final original = jsonEncode(editor.document.toJson());
    await tester.tap(find.byKey(const ValueKey('rich-toolbar-format')));
    await tester.pumpAndSettle();
    final link = find.byKey(const ValueKey('rich-format-link'));
    await tester.ensureVisible(link);
    await tester.tap(link);
    await tester.pumpAndSettle();
    tester
            .widget<TextField>(find.byKey(const ValueKey('rich-link-address')))
            .controller!
            .text =
        'example.com';
    final hide = Completer<void>();
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      SystemChannels.textInput,
      (call) async {
        if (call.method == 'TextInput.hide') await hide.future;
        return null;
      },
    );
    addTearDown(tester.testTextInput.register);
    await tester.tap(find.byKey(const ValueKey('rich-link-save')));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    editor.selection = af.Selection.single(
      path: [0],
      startOffset: 6,
      endOffset: 10,
    );
    hide.complete();
    await tester.pumpAndSettle();
    expect(jsonEncode(editor.document.toJson()), original);
    expect(find.byKey(const ValueKey('rich-format-panel')), findsNothing);
    tester.testTextInput.register();
    await tester.pumpWidget(const SizedBox());
    editor.dispose();
  });

  testWidgets('back can cancel an Aa link while keyboard hide is pending', (
    tester,
  ) async {
    final editor = document('alpha beta');
    final back = DocumentEditorBackController();
    await mount(tester, editor, backController: back);
    editor.selection = af.Selection.single(
      path: [0],
      startOffset: 0,
      endOffset: 5,
    );
    await tester.pumpAndSettle();
    final original = jsonEncode(editor.document.toJson());
    await tester.tap(find.byKey(const ValueKey('rich-toolbar-format')));
    await tester.pumpAndSettle();
    final link = find.byKey(const ValueKey('rich-format-link'));
    await tester.ensureVisible(link);
    await tester.tap(link);
    await tester.pumpAndSettle();
    tester
            .widget<TextField>(find.byKey(const ValueKey('rich-link-address')))
            .controller!
            .text =
        'example.com';
    final hide = Completer<void>();
    var hideRequested = false;
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      SystemChannels.textInput,
      (call) async {
        if (call.method == 'TextInput.hide') {
          hideRequested = true;
          await hide.future;
        }
        return null;
      },
    );
    addTearDown(tester.testTextInput.register);
    await tester.tap(find.byKey(const ValueKey('rich-link-save')));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    expect(hideRequested, isTrue);
    expect(back.handleBack(), isTrue);
    await tester.pump();
    hide.complete();
    await tester.pumpAndSettle();
    expect(jsonEncode(editor.document.toJson()), original);
    expect(find.byKey(const ValueKey('rich-format-panel')), findsNothing);
    tester.testTextInput.register();
    await tester.pumpWidget(const SizedBox());
    editor.dispose();
  });

  testWidgets('Aa link does not steal focus after another field is focused', (
    tester,
  ) async {
    final editor = document('alpha beta');
    await mount(tester, editor);
    final otherFocus = FocusNode();
    final attachment = otherFocus.attach(
      tester.element(find.byType(RichEditorToolbar)),
    );
    attachment.reparent();
    addTearDown(() {
      attachment.detach();
      otherFocus.dispose();
    });
    editor.selection = af.Selection.single(
      path: [0],
      startOffset: 0,
      endOffset: 5,
    );
    await tester.pumpAndSettle();
    final original = jsonEncode(editor.document.toJson());
    await tester.tap(find.byKey(const ValueKey('rich-toolbar-format')));
    await tester.pumpAndSettle();
    final link = find.byKey(const ValueKey('rich-format-link'));
    await tester.ensureVisible(link);
    await tester.tap(link);
    await tester.pumpAndSettle();
    tester
            .widget<TextField>(find.byKey(const ValueKey('rich-link-address')))
            .controller!
            .text =
        'example.com';
    await tester.tap(find.byKey(const ValueKey('rich-link-save')));
    otherFocus.requestFocus();
    await tester.pumpAndSettle();
    expect(otherFocus.hasFocus, isTrue);
    expect(jsonEncode(editor.document.toJson()), original);
    expect(find.byKey(const ValueKey('rich-format-panel')), findsNothing);
    await tester.pumpWidget(const SizedBox());
    editor.dispose();
  });

  testWidgets('failed keyboard hide reports that the Aa link was not applied', (
    tester,
  ) async {
    final editor = document('alpha beta');
    await mount(tester, editor);
    editor.selection = af.Selection.single(
      path: [0],
      startOffset: 0,
      endOffset: 5,
    );
    await tester.pumpAndSettle();
    final original = jsonEncode(editor.document.toJson());
    await tester.tap(find.byKey(const ValueKey('rich-toolbar-format')));
    await tester.pumpAndSettle();
    final link = find.byKey(const ValueKey('rich-format-link'));
    await tester.ensureVisible(link);
    await tester.tap(link);
    await tester.pumpAndSettle();
    tester
            .widget<TextField>(find.byKey(const ValueKey('rich-link-address')))
            .controller!
            .text =
        'example.com';
    var hideCalls = 0;
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      SystemChannels.textInput,
      (call) async {
        if (call.method == 'TextInput.hide') {
          hideCalls++;
          // The first hide is the framework closing the sheet's text field;
          // fail the editor's subsequent explicit restoration request.
          if (hideCalls == 2) throw PlatformException(code: 'hide_failed');
        }
        return null;
      },
    );
    addTearDown(tester.testTextInput.register);
    await tester.tap(find.byKey(const ValueKey('rich-link-save')));
    await tester.pumpAndSettle();
    expect(hideCalls, greaterThanOrEqualTo(2));
    expect(jsonEncode(editor.document.toJson()), original);
    expect(find.byKey(const ValueKey('rich-format-panel')), findsNothing);
    expect(find.text(l10n.dailynotes.editorLinkApplyFailed), findsOneWidget);
    tester.testTextInput.register();
    await tester.pumpWidget(const SizedBox());
    editor.dispose();
  });

  testWidgets('mixed color selection does not claim a uniform color', (
    tester,
  ) async {
    final editor = document('alpha beta');
    await mount(tester, editor);
    final first = af.Selection.single(path: [0], startOffset: 0, endOffset: 5);
    await editor.formatDelta(first, {
      af.AppFlowyRichTextKeys.textColor: '0xffd32f2f',
    });
    editor.selection = af.Selection.single(
      path: [0],
      startOffset: 0,
      endOffset: 10,
    );
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('rich-toolbar-format')));
    await tester.pumpAndSettle();
    await tester.tap(
      find.byKey(ValueKey('rich-format-${l10n.dailynotes.editorTextColor}')),
    );
    await tester.pumpAndSettle();
    expect(
      find.byKey(const ValueKey('rich-quick-color-selected-text')),
      findsNothing,
    );
    expect(
      find.byKey(const ValueKey('rich-quick-color-selected-background')),
      findsOneWidget,
    );
    await tester.pumpWidget(const SizedBox());
    editor.dispose();
  });

  testWidgets('Aa inline code formats only the selection and supports undo', (
    tester,
  ) async {
    final editor = af.EditorState(
      document: af.Document(
        root: af.pageNode(
          children: [
            af.paragraphNode(
              delta: af.Delta()
                ..insert(
                  'alpha',
                  attributes: {af.AppFlowyRichTextKeys.bold: true},
                )
                ..insert(' beta'),
            ),
          ],
        ),
      ),
    );
    await mount(tester, editor);
    final selection = af.Selection.single(
      path: [0],
      startOffset: 1,
      endOffset: 7,
    );
    editor.selection = selection;
    await tester.pumpAndSettle();
    final original = jsonEncode(editor.document.toJson());
    await tester.tap(find.byKey(const ValueKey('rich-toolbar-format')));
    await tester.pumpAndSettle();
    final code = find.byKey(
      ValueKey('rich-format-${l10n.editor.toolbar.inlineCode}'),
    );
    await openInlineCodeMenu(tester);
    await tester.tap(code);
    await tester.pumpAndSettle();
    final delta = editor.document.root.children.single.delta!;
    expect(delta.toPlainText(), 'alpha beta');
    expect(
      delta
          .slice(1, 7)
          .toJson()
          .every((op) => op['attributes']?['code'] == true),
      isTrue,
    );
    expect(
      delta
          .slice(0, 1)
          .toJson()
          .every((op) => op['attributes']?['code'] != true),
      isTrue,
    );
    expect(
      delta.slice(7).toJson().every((op) => op['attributes']?['code'] != true),
      isTrue,
    );
    expect(
      delta
          .slice(0, 5)
          .toJson()
          .every((op) => op['attributes']?['bold'] == true),
      isTrue,
    );
    await openInlineCodeMenu(tester);
    expect(
      find.descendant(of: code, matching: find.byIcon(LucideIcons.check)),
      findsOneWidget,
    );
    await tester.binding.handlePopRoute();
    await tester.pumpAndSettle();
    expect(editor.selection, selection);
    final formatted = jsonEncode(editor.document.toJson());
    editor.undoManager.undo();
    await tester.pumpAndSettle();
    expect(jsonEncode(editor.document.toJson()), original);
    editor.undoManager.redo();
    await tester.pumpAndSettle();
    expect(jsonEncode(editor.document.toJson()), formatted);
    await tester.pumpWidget(const SizedBox());
    editor.dispose();
  });

  testWidgets('inline code at a caret applies to subsequent keyboard input', (
    tester,
  ) async {
    final editor = document('alpha');
    await mount(tester, editor);
    editor.selection = af.Selection.single(path: [0], startOffset: 5);
    await tester.pumpAndSettle();
    final original = jsonEncode(editor.document.toJson());
    await tester.tap(find.byKey(const ValueKey('rich-toolbar-format')));
    await tester.pumpAndSettle();
    final code = find.byKey(
      ValueKey('rich-format-${l10n.editor.toolbar.inlineCode}'),
    );
    await openInlineCodeMenu(tester);
    await tester.tap(code);
    await tester.pumpAndSettle();
    expect(editor.toggledStyle[af.AppFlowyRichTextKeys.code], isTrue);
    expect(jsonEncode(editor.document.toJson()), original);
    await tester.tap(find.text(l10n.dailynotes.editorFormatDone));
    await tester.pumpAndSettle();
    tester.testTextInput.enterText(' alphaX');
    await tester.pumpAndSettle();
    final delta = editor.document.root.children.single.delta!;
    expect(delta.toPlainText(), 'alphaX');
    expect(delta.slice(5, 6).toJson().single['attributes']?['code'], isTrue);
    expect(
      delta
          .slice(0, 5)
          .toJson()
          .every((op) => op['attributes']?['code'] != true),
      isTrue,
    );
    await tester.pumpWidget(const SizedBox());
    editor.dispose();
  });

  testWidgets('inline code from more rejects a stale selection', (
    tester,
  ) async {
    final editor = document('alpha beta');
    await mount(tester, editor);
    editor.selection = af.Selection.single(
      path: [0],
      startOffset: 0,
      endOffset: 5,
    );
    await tester.pumpAndSettle();
    final original = jsonEncode(editor.document.toJson());
    await tester.tap(find.byKey(const ValueKey('rich-toolbar-more')));
    await tester.pumpAndSettle();
    editor.selection = af.Selection.single(
      path: [0],
      startOffset: 6,
      endOffset: 10,
    );
    await tester.pump();
    final code = find.byKey(const ValueKey('rich-overflow-code'));
    await tester.ensureVisible(code);
    await tester.tap(code);
    await tester.pumpAndSettle();
    expect(jsonEncode(editor.document.toJson()), original);
    await tester.pumpWidget(const SizedBox());
    editor.dispose();
  });

  testWidgets('inline code supports first input with Chinese and emoji', (
    tester,
  ) async {
    final editor = document('');
    await mount(tester, editor);
    editor.selection = af.Selection.single(path: [0], startOffset: 0);
    await tester.pumpAndSettle();
    await tapOverflow(tester, 'code');
    expect(editor.toggledStyle[af.AppFlowyRichTextKeys.code], isTrue);
    tester.testTextInput.enterText(' 中🙂');
    await tester.pumpAndSettle();
    final delta = editor.document.root.children.single.delta!;
    expect(delta.toPlainText(), '中🙂');
    expect(delta.toJson().single['attributes']?['code'], isTrue);
    expect(editor.selection!.start.offset, '中🙂'.length);
    await tester.pumpWidget(const SizedBox());
    editor.dispose();
  });

  testWidgets(
    'inline code can be toggled across paragraphs without touching neighbors',
    (tester) async {
      final editor = af.EditorState(
        document: af.Document(
          root: af.pageNode(
            children: [
              af.paragraphNode(text: 'alpha'),
              af.paragraphNode(text: 'beta'),
              af.paragraphNode(text: 'outside'),
            ],
          ),
        ),
      );
      await mount(tester, editor);
      final selection = af.Selection(
        start: af.Position(path: [0], offset: 2),
        end: af.Position(path: [1], offset: 2),
      );
      editor.selection = selection;
      await tester.pumpAndSettle();
      await tapOverflow(tester, 'code');
      final first = editor.document.root.children[0].delta!;
      final second = editor.document.root.children[1].delta!;
      expect(
        first
            .slice(0, 2)
            .toJson()
            .every((op) => op['attributes']?['code'] != true),
        isTrue,
      );
      expect(
        first
            .slice(2)
            .toJson()
            .every((op) => op['attributes']?['code'] == true),
        isTrue,
      );
      expect(
        second
            .slice(0, 2)
            .toJson()
            .every((op) => op['attributes']?['code'] == true),
        isTrue,
      );
      expect(
        second
            .slice(2)
            .toJson()
            .every((op) => op['attributes']?['code'] != true),
        isTrue,
      );
      expect(editor.document.root.children[2].delta!.toPlainText(), 'outside');
      expect(editor.selection, selection);
      await tester.tap(find.byKey(const ValueKey('rich-toolbar-more')));
      await tester.pumpAndSettle();
      final code = find.byKey(const ValueKey('rich-overflow-code'));
      expect(
        find.descendant(of: code, matching: find.byIcon(LucideIcons.check)),
        findsOneWidget,
      );
      await tester.ensureVisible(code);
      await tester.tap(code);
      await tester.pumpAndSettle();
      final toggledOff = editor.document.root.children
          .take(2)
          .expand((node) => node.delta!.toJson());
      expect(
        toggledOff.every((op) => op['attributes']?['code'] != true),
        isTrue,
      );
      expect(
        editor.document.root.children.map((node) => node.delta!.toPlainText()),
        ['alpha', 'beta', 'outside'],
      );
      expect(editor.selection, selection);
      await tester.tap(find.byKey(const ValueKey('rich-toolbar-more')));
      await tester.pumpAndSettle();
      expect(
        find.descendant(
          of: find.byKey(const ValueKey('rich-overflow-code')),
          matching: find.byIcon(LucideIcons.check),
        ),
        findsNothing,
      );
      await tester.binding.handlePopRoute();
      await tester.pumpAndSettle();
      await tester.pumpWidget(const SizedBox());
      editor.dispose();
    },
  );

  testWidgets(
    'Aa color with a caret sets upcoming style without altering existing text',
    (tester) async {
      final editor = document('alpha beta');
      await mount(tester, editor);
      editor.selection = af.Selection.single(path: [0], startOffset: 5);
      await tester.pumpAndSettle();
      final original = jsonEncode(editor.document.toJson());
      await tester.tap(find.byKey(const ValueKey('rich-toolbar-format')));
      await tester.pumpAndSettle();
      await tester.tap(
        find.byKey(ValueKey('rich-format-${l10n.dailynotes.editorTextColor}')),
      );
      await tester.pumpAndSettle();
      await tester.tap(
        find.byKey(const ValueKey('rich-quick-color-text-0xffd32f2f')),
      );
      await tester.pumpAndSettle();
      expect(jsonEncode(editor.document.toJson()), original);
      expect(
        editor.toggledStyle[af.AppFlowyRichTextKeys.textColor],
        '0xffd32f2f',
      );
      await tester.pumpWidget(const SizedBox());
      editor.dispose();
    },
  );

  testWidgets('plus replaces an empty paragraph and preserves undo and redo', (
    tester,
  ) async {
    final editor = document('');
    await mount(tester, editor);
    editor.selection = af.Selection.single(path: [0], startOffset: 0);
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('rich-toolbar-insert')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('rich-insert-h2')));
    await tester.pumpAndSettle();
    expect(editor.document.root.children, hasLength(1));
    expect(editor.document.root.children.single.type, af.HeadingBlockKeys.type);
    expect(
      editor.document.root.children.single.attributes[af
          .HeadingBlockKeys
          .level],
      2,
    );
    await tapOverflow(tester, 'undo');
    await tester.pumpAndSettle();
    expect(
      editor.document.root.children.single.type,
      af.ParagraphBlockKeys.type,
    );
    await tapOverflow(tester, 'redo');
    await tester.pumpAndSettle();
    expect(editor.document.root.children.single.type, af.HeadingBlockKeys.type);
    await tester.pumpWidget(const SizedBox());
    editor.dispose();
  });

  testWidgets(
    'Aa changes a text block into a heading without losing its content',
    (tester) async {
      final editor = document('alpha beta');
      await mount(tester, editor);
      editor.selection = af.Selection.single(path: [0], startOffset: 2);
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('rich-toolbar-format')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('H1'));
      await tester.pumpAndSettle();
      final node = editor.document.root.children.single;
      expect(node.type, af.HeadingBlockKeys.type);
      expect(node.attributes[af.HeadingBlockKeys.level], 1);
      expect(node.delta!.toPlainText(), 'alpha beta');
      expect(find.text(l10n.dailynotes.editorSelectionChanged), findsNothing);
      await tester.pumpWidget(const SizedBox());
      editor.dispose();
    },
  );

  testWidgets('Aa aligns text and keeps the selection usable', (tester) async {
    final editor = document('alpha beta');
    await mount(tester, editor);
    editor.selection = af.Selection.single(path: [0], startOffset: 2);
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('rich-toolbar-format')));
    await tester.pumpAndSettle();
    final center = find.byTooltip(l10n.dailynotes.editorAlignCenter);
    await tester.ensureVisible(center);
    await tester.tap(center);
    await tester.pumpAndSettle();
    expect(
      editor.document.root.children.single.attributes[af.blockComponentAlign],
      'center',
    );
    expect(
      editor.document.root.children.single.delta!.toPlainText(),
      'alpha beta',
    );
    expect(find.text(l10n.dailynotes.editorSelectionChanged), findsNothing);
    await tester.pumpWidget(const SizedBox());
    editor.dispose();
  });

  testWidgets('Aa can indent and outdent list blocks consecutively', (
    tester,
  ) async {
    final editor = af.EditorState(
      document: af.Document(
        root: af.pageNode(
          children: [
            af.bulletedListNode(text: 'first'),
            af.bulletedListNode(text: 'second'),
          ],
        ),
      ),
    );
    await mount(tester, editor);
    editor.selection = af.Selection.single(path: [1], startOffset: 2);
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('rich-toolbar-format')));
    await tester.pumpAndSettle();
    final indent = find.byKey(
      ValueKey('rich-format-${l10n.editor.toolbar.indent}'),
    );
    await tester.ensureVisible(indent);
    await tester.tap(indent);
    await tester.pumpAndSettle();
    expect(editor.document.root.children, hasLength(1));
    expect(
      editor.document.root.children.first.children.single.delta!.toPlainText(),
      'second',
    );
    expect(find.text(l10n.dailynotes.editorSelectionChanged), findsNothing);
    final outdent = find.byKey(
      ValueKey('rich-format-${l10n.editor.toolbar.outdent}'),
    );
    await tester.ensureVisible(outdent);
    await tester.tap(outdent);
    await tester.pumpAndSettle();
    expect(editor.document.root.children, hasLength(2));
    expect(editor.document.root.children.last.delta!.toPlainText(), 'second');
    expect(find.text(l10n.dailynotes.editorSelectionChanged), findsNothing);
    await tester.pumpWidget(const SizedBox());
    editor.dispose();
  });

  testWidgets('quick checklist conversion and reversal retain the text', (
    tester,
  ) async {
    final editor = document('alpha beta');
    await mount(tester, editor);
    editor.selection = af.Selection.single(path: [0], startOffset: 2);
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('rich-toolbar-todo')));
    await tester.pumpAndSettle();
    expect(
      editor.document.root.children.single.type,
      af.TodoListBlockKeys.type,
    );
    expect(
      editor.document.root.children.single.attributes[af
          .TodoListBlockKeys
          .checked],
      isFalse,
    );
    await tester.tap(find.byKey(const ValueKey('rich-toolbar-todo')));
    await tester.pumpAndSettle();
    expect(
      editor.document.root.children.single.type,
      af.ParagraphBlockKeys.type,
    );
    expect(
      editor.document.root.children.single.delta!.toPlainText(),
      'alpha beta',
    );
    await tester.pumpWidget(const SizedBox());
    editor.dispose();
  });

  testWidgets('plus inserts a divider with an editable following paragraph', (
    tester,
  ) async {
    final editor = document('alpha');
    await mount(tester, editor);
    editor.selection = af.Selection.single(path: [0], startOffset: 2);
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('rich-toolbar-insert')));
    await tester.pumpAndSettle();
    final divider = find.byKey(const ValueKey('rich-insert-divider'));
    await tester.scrollUntilVisible(
      divider,
      200,
      scrollable: find
          .descendant(
            of: find.byType(BottomSheet),
            matching: find.byType(Scrollable),
          )
          .first,
    );
    await tester.tap(divider);
    await tester.pumpAndSettle();
    expect(editor.document.root.children.map((node) => node.type), [
      af.ParagraphBlockKeys.type,
      af.DividerBlockKeys.type,
      af.ParagraphBlockKeys.type,
    ]);
    expect(editor.document.root.children.first.delta!.toPlainText(), 'alpha');
    await tester.pumpWidget(const SizedBox());
    editor.dispose();
  });

  testWidgets(
    'divider reuses the following empty paragraph and can be undone',
    (tester) async {
      final editor = af.EditorState(
        document: af.Document(
          root: af.pageNode(
            children: [
              af.paragraphNode(text: 'alpha'),
              af.paragraphNode(),
            ],
          ),
        ),
      );
      await mount(tester, editor);
      editor.selection = af.Selection.single(path: [0], startOffset: 2);
      await tester.pumpAndSettle();
      final original = jsonEncode(editor.document.toJson());
      await tester.tap(find.byKey(const ValueKey('rich-toolbar-insert')));
      await tester.pumpAndSettle();
      final divider = find.byKey(const ValueKey('rich-insert-divider'));
      await tester.scrollUntilVisible(
        divider,
        200,
        scrollable: find
            .descendant(
              of: find.byType(BottomSheet),
              matching: find.byType(Scrollable),
            )
            .first,
      );
      await tester.tap(divider);
      await tester.pumpAndSettle();
      expect(editor.document.root.children.map((n) => n.type), [
        af.ParagraphBlockKeys.type,
        af.DividerBlockKeys.type,
        af.ParagraphBlockKeys.type,
      ]);
      expect(editor.selection?.start.path, [2]);
      editor.undoManager.undo();
      await tester.pumpAndSettle();
      expect(jsonEncode(editor.document.toJson()), original);
      await tester.pumpWidget(const SizedBox());
      editor.dispose();
    },
  );

  testWidgets('locked editor never exposes editing controls', (tester) async {
    final editor = document('read only');
    await mount(tester, editor, editable: false);
    editor.selection = af.Selection.single(
      path: [0],
      startOffset: 0,
      endOffset: 4,
    );
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('rich-toolbar-format')), findsNothing);
    expect(find.byKey(const ValueKey('rich-toolbar-insert')), findsNothing);
    expect(
      editor.document.root.children.single.delta!.toPlainText(),
      'read only',
    );
    await tester.pumpWidget(const SizedBox());
    editor.dispose();
  });

  testWidgets('system back returns from color to Aa before closing the panel', (
    tester,
  ) async {
    final editor = document('alpha beta');
    await mount(tester, editor);
    final selection = af.Selection.single(
      path: [0],
      startOffset: 0,
      endOffset: 5,
    );
    editor.selection = selection;
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('rich-toolbar-format')));
    await tester.pumpAndSettle();
    await tester.tap(
      find.byKey(ValueKey('rich-format-${l10n.dailynotes.editorTextColor}')),
    );
    await tester.pumpAndSettle();
    expect(
      find.byKey(const ValueKey('rich-format-color-sheet')),
      findsOneWidget,
    );
    expect(find.byType(BottomSheet), findsOneWidget);
    final sheetContext = tester.element(
      find.byKey(const ValueKey('rich-format-color-sheet')),
    );
    final route = ModalRoute.of(sheetContext)! as ModalBottomSheetRoute<bool>;
    expect(route.capturedThemes, isNotNull);
    expect(
      route.barrierLabel,
      MaterialLocalizations.of(sheetContext).scrimLabel,
    );
    expect(route.barrierOnTapHint, isNotNull);
    tester.testTextInput.log.clear();
    await tester.binding.handlePopRoute();
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('rich-format-panel')), findsOneWidget);
    expect(find.byKey(const ValueKey('rich-format-color-sheet')), findsNothing);
    expect(find.text('H1'), findsOneWidget);
    await tester.binding.handlePopRoute();
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('rich-format-panel')), findsNothing);
    expect(editor.selection, selection);
    expect(
      tester.testTextInput.log.map((call) => call.method),
      isNot(contains('TextInput.show')),
    );
    await tester.pumpWidget(const SizedBox());
    editor.dispose();
  });

  testWidgets('format panel remains scrollable on a short landscape screen', (
    tester,
  ) async {
    final editor = document('alpha beta');
    await mount(tester, editor);
    tester.view.physicalSize = const Size(700, 320);
    tester.view.viewInsets = FakeViewPadding.zero;
    editor.selection = af.Selection.single(
      path: [0],
      startOffset: 0,
      endOffset: 5,
    );
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('rich-floating-format')));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    final sheet = find.byKey(const ValueKey('rich-format-panel'));
    final list = find
        .descendant(of: sheet, matching: find.byType(ListView))
        .first;
    await tester.drag(list, const Offset(0, -240));
    await tester.pumpAndSettle();
    await tester.drag(list, const Offset(0, -240));
    await tester.pumpAndSettle();
    expect(
      find.descendant(
        of: sheet,
        matching: find.byTooltip(l10n.editor.toolbar.indent),
      ),
      findsOneWidget,
    );
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
    editor.dispose();
  });

  testWidgets('Aa fonts apply to selection and survive serialization', (
    tester,
  ) async {
    final editor = document('alpha beta');
    await mount(
      tester,
      editor,
      loadFonts: () async =>
          (families: ['Imported Font'], hasUnavailable: false),
    );
    final selection = af.Selection.single(
      path: [0],
      startOffset: 0,
      endOffset: 5,
    );
    editor.selection = selection;
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('rich-toolbar-format')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('rich-format-font')));
    await tester.pumpAndSettle();
    final fontPage = find.byKey(const ValueKey('rich-format-font-page'));
    expect(fontPage, findsOneWidget);
    expect(ModalRoute.of(tester.element(fontPage)), isA<PageRoute<void>>());
    await tester.scrollUntilVisible(
      find.byKey(const ValueKey('rich-font-Imported Font')),
      100,
      scrollable: find
          .descendant(
            of: find.byKey(const ValueKey('rich-format-font-page')),
            matching: find.byType(Scrollable),
          )
          .first,
    );
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('rich-font-Imported Font')));
    await tester.pumpAndSettle();
    final serialized = jsonEncode(editor.document.toJson());
    expect(serialized, contains('"font_family":"Imported Font"'));
    expect(
      jsonEncode(af.Document.fromJson(jsonDecode(serialized)).toJson()),
      serialized,
    );
    expect(editor.selection, selection);
    expect(find.byKey(const ValueKey('rich-format-font')), findsOneWidget);
    await tester.pumpWidget(const SizedBox());
    editor.dispose();
  });

  testWidgets('font picker sets typing style for a caret and returns to Aa', (
    tester,
  ) async {
    final editor = document('alpha');
    await mount(tester, editor);
    editor.selection = af.Selection.single(path: [0], startOffset: 2);
    await tester.pumpAndSettle();
    final original = jsonEncode(editor.document.toJson());
    await tester.tap(find.byKey(const ValueKey('rich-toolbar-format')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('rich-format-font')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('rich-font-serif')));
    await tester.pumpAndSettle();
    expect(editor.toggledStyle[af.AppFlowyRichTextKeys.fontFamily], 'serif');
    expect(jsonEncode(editor.document.toJson()), original);
    expect(find.byKey(const ValueKey('rich-format-font')), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('rich-format-font')));
    await tester.pumpAndSettle();
    expect(
      tester
          .widget<ListTile>(find.byKey(const ValueKey('rich-font-serif')))
          .selected,
      isTrue,
    );
    await tester.tap(find.text(l10n.dailynotes.editorFormatDone));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('rich-format-font')), findsOneWidget);
    await tester.pumpWidget(const SizedBox());
    editor.dispose();
  });

  testWidgets(
    'font picker indicates a uniform font but not a mixed selection',
    (tester) async {
      final editor = document('alpha beta');
      await mount(tester, editor);
      final first = af.Selection.single(
        path: [0],
        startOffset: 0,
        endOffset: 5,
      );
      editor.selection = first;
      await editor.formatDelta(first, {
        af.AppFlowyRichTextKeys.fontFamily: 'serif',
      });
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('rich-toolbar-format')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('rich-format-font')));
      await tester.pumpAndSettle();
      expect(
        tester
            .widget<ListTile>(find.byKey(const ValueKey('rich-font-serif')))
            .selected,
        isTrue,
      );
      expect(
        tester
            .widget<ListTile>(find.byKey(const ValueKey('rich-font-default')))
            .selected,
        isFalse,
      );
      await tester.tap(find.text(l10n.dailynotes.editorFormatDone));
      await tester.pumpAndSettle();
      await tester.tap(find.text(l10n.dailynotes.editorFormatDone));
      await tester.pumpAndSettle();
      editor.selection = af.Selection.single(
        path: [0],
        startOffset: 0,
        endOffset: 10,
      );
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('rich-toolbar-format')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('rich-format-font')));
      await tester.pumpAndSettle();
      expect(
        tester
            .widget<ListTile>(find.byKey(const ValueKey('rich-font-serif')))
            .selected,
        isFalse,
      );
      expect(
        tester
            .widget<ListTile>(find.byKey(const ValueKey('rich-font-default')))
            .selected,
        isFalse,
      );
      await tester.pumpWidget(const SizedBox());
      editor.dispose();
    },
  );

  testWidgets('font load completion cannot revive a changed selection', (
    tester,
  ) async {
    final pending = Completer<({List<String> families, bool hasUnavailable})>();
    final editor = document('alpha beta');
    await mount(tester, editor, loadFonts: () => pending.future);
    editor.selection = af.Selection.single(
      path: [0],
      startOffset: 0,
      endOffset: 5,
    );
    await tester.pumpAndSettle();
    final original = jsonEncode(editor.document.toJson());
    await tester.tap(find.byKey(const ValueKey('rich-toolbar-format')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('rich-format-font')));
    await tester.pump();
    editor.selection = af.Selection.single(
      path: [0],
      startOffset: 6,
      endOffset: 10,
    );
    pending.complete((families: ['Imported Font'], hasUnavailable: false));
    await tester.pumpAndSettle();
    await tester.scrollUntilVisible(
      find.byKey(const ValueKey('rich-font-Imported Font')),
      120,
      scrollable: find
          .descendant(
            of: find.byKey(const ValueKey('rich-format-font-page')),
            matching: find.byType(Scrollable),
          )
          .first,
    );
    final tile = tester.widget<ListTile>(
      find.byKey(const ValueKey('rich-font-Imported Font')),
    );
    expect(tile.onTap, isNull);
    expect(jsonEncode(editor.document.toJson()), original);
    await tester.pumpWidget(const SizedBox());
    editor.dispose();
  });

  testWidgets('a closed font page cannot replace a later font catalog', (
    tester,
  ) async {
    final pending = Completer<({List<String> families, bool hasUnavailable})>();
    var loads = 0;
    final editor = document('alpha beta');
    await mount(
      tester,
      editor,
      loadFonts: () {
        loads++;
        return loads == 1
            ? pending.future
            : Future.value((families: ['New Font'], hasUnavailable: false));
      },
    );
    editor.selection = af.Selection.single(
      path: [0],
      startOffset: 0,
      endOffset: 5,
    );
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('rich-toolbar-format')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('rich-format-font')));
    await tester.pump();
    await tester.binding.handlePopRoute();
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('rich-format-font')));
    await tester.pumpAndSettle();
    pending.complete((families: ['Old Font'], hasUnavailable: false));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('rich-font-New Font')), findsOneWidget);
    expect(find.byKey(const ValueKey('rich-font-Old Font')), findsNothing);
    await tester.pumpWidget(const SizedBox());
    editor.dispose();
  });

  testWidgets('locking invalidates a font page and its pending actions', (
    tester,
  ) async {
    final pending = Completer<({List<String> families, bool hasUnavailable})>();
    final editor = document('alpha beta');
    await mount(tester, editor, loadFonts: () => pending.future);
    editor.selection = af.Selection.single(
      path: [0],
      startOffset: 0,
      endOffset: 5,
    );
    await tester.pumpAndSettle();
    final original = jsonEncode(editor.document.toJson());
    await tester.tap(find.byKey(const ValueKey('rich-toolbar-format')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('rich-format-font')));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    final oldFont = tester
        .widget<ListTile>(find.byKey(const ValueKey('rich-font-serif')))
        .onTap!;
    tester.testTextInput.log.clear();
    editor.editable = false;
    editor.editable = true;
    oldFont();
    pending.complete((families: ['Late Font'], hasUnavailable: false));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('rich-format-font-page')), findsNothing);
    expect(find.byKey(const ValueKey('rich-format-panel')), findsNothing);
    expect(jsonEncode(editor.document.toJson()), original);
    expect(
      tester.testTextInput.log.map((call) => call.method),
      isNot(contains('TextInput.show')),
    );
    await tester.pumpWidget(const SizedBox());
    editor.dispose();
  });

  testWidgets('locking invalidates an open color sheet and its old actions', (
    tester,
  ) async {
    final editor = document('alpha beta');
    await mount(tester, editor);
    editor.selection = af.Selection.single(
      path: [0],
      startOffset: 0,
      endOffset: 5,
    );
    await tester.pumpAndSettle();
    final original = jsonEncode(editor.document.toJson());
    await tester.tap(find.byKey(const ValueKey('rich-toolbar-format')));
    await tester.pumpAndSettle();
    await tester.tap(
      find.byKey(ValueKey('rich-format-${l10n.dailynotes.editorTextColor}')),
    );
    await tester.pumpAndSettle();
    final oldColor = tester
        .widget<InkWell>(
          find.byKey(const ValueKey('rich-quick-color-text-0xffd32f2f')),
        )
        .onTap!;
    tester.testTextInput.log.clear();
    editor.editable = false;
    editor.editable = true;
    oldColor();
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('rich-format-color-sheet')), findsNothing);
    expect(find.byKey(const ValueKey('rich-format-panel')), findsNothing);
    expect(jsonEncode(editor.document.toJson()), original);
    expect(
      tester.testTextInput.log.map((call) => call.method),
      isNot(contains('TextInput.show')),
    );
    await tester.pumpWidget(const SizedBox());
    editor.dispose();
  });

  for (final child in ['font', 'color']) {
    testWidgets('covering the Aa $child route invalidates the old session', (
      tester,
    ) async {
      final editor = document('alpha beta');
      await mount(tester, editor);
      editor.selection = af.Selection.single(
        path: [0],
        startOffset: 0,
        endOffset: 5,
      );
      await tester.pumpAndSettle();
      final original = jsonEncode(editor.document.toJson());
      await tester.tap(find.byKey(const ValueKey('rich-toolbar-format')));
      await tester.pumpAndSettle();
      final opener = child == 'font'
          ? find.byKey(const ValueKey('rich-format-font'))
          : find.byKey(
              ValueKey('rich-format-${l10n.dailynotes.editorTextColor}'),
            );
      await tester.tap(opener);
      await tester.pumpAndSettle();
      final childView = find.byKey(
        ValueKey(
          child == 'font' ? 'rich-format-font-page' : 'rich-format-color-sheet',
        ),
      );
      final oldAction = child == 'font'
          ? tester
                .widget<ListTile>(find.byKey(const ValueKey('rich-font-serif')))
                .onTap!
          : tester
                .widget<InkWell>(
                  find.byKey(
                    const ValueKey('rich-quick-color-text-0xffd32f2f'),
                  ),
                )
                .onTap!;
      final navigator = Navigator.of(tester.element(childView));
      unawaited(
        navigator.push<void>(
          MaterialPageRoute<void>(
            builder: (_) => const Scaffold(body: Text('another record')),
          ),
        ),
      );
      await tester.pumpAndSettle();
      navigator.pop();
      await tester.pumpAndSettle();
      if (child == 'font') {
        expect(
          tester
              .widget<ListTile>(find.byKey(const ValueKey('rich-font-serif')))
              .onTap,
          isNull,
        );
      } else {
        expect(
          tester
              .widget<InkWell>(
                find.byKey(const ValueKey('rich-quick-color-text-0xffd32f2f')),
              )
              .onTap,
          isNull,
        );
      }
      tester.testTextInput.log.clear();
      await tester.binding.handlePopRoute();
      await tester.pumpAndSettle();
      final bold = tester.widget<IconButton>(
        find.byKey(ValueKey('rich-format-${l10n.editor.toolbar.bold}')),
      );
      expect(bold.onPressed, isNull);
      await tester.tap(find.byKey(const ValueKey('rich-format-done')));
      await tester.pumpAndSettle();
      oldAction();
      await tester.pump();
      expect(jsonEncode(editor.document.toJson()), original);
      expect(tester.takeException(), isNull);
      expect(
        tester.testTextInput.log.map((call) => call.method),
        isNot(contains('TextInput.show')),
      );
      await tester.pumpWidget(const SizedBox());
      editor.dispose();
    });
  }

  testWidgets('selection link validates and writes the AppFlowy href', (
    tester,
  ) async {
    final editor = document('alpha beta');
    await mount(tester, editor);
    editor.selection = af.Selection.single(
      path: [0],
      startOffset: 0,
      endOffset: 5,
    );
    await tester.pumpAndSettle();
    await tester.ensureVisible(find.byKey(const ValueKey('rich-toolbar-link')));
    await tester.tap(find.byKey(const ValueKey('rich-toolbar-link')));
    await tester.pumpAndSettle();
    await tester.enterText(
      find.byKey(const ValueKey('rich-link-address')),
      'javascript:alert(1)',
    );
    await tester.tap(find.byKey(const ValueKey('rich-link-save')));
    await tester.pumpAndSettle();
    expect(find.text(l10n.dailynotes.editorLinkInvalid), findsOneWidget);
    await tester.enterText(
      find.byKey(const ValueKey('rich-link-address')),
      'example.com',
    );
    await tester.tap(find.byKey(const ValueKey('rich-link-save')));
    await tester.pumpAndSettle();
    final serialized = jsonEncode(editor.document.toJson());
    expect(serialized, contains('"href":"https://example.com"'));
    expect(
      editor.document.root.children.single.delta!.toPlainText(),
      'alpha beta',
    );
    expect(
      jsonEncode(af.Document.fromJson(jsonDecode(serialized)).toJson()),
      serialized,
    );
    await tester.ensureVisible(find.byKey(const ValueKey('rich-toolbar-link')));
    await tester.tap(find.byKey(const ValueKey('rich-toolbar-link')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('rich-link-remove')));
    await tester.pumpAndSettle();
    expect(jsonEncode(editor.document.toJson()), isNot(contains('"href"')));
    expect(
      editor.document.root.children.single.delta!.toPlainText(),
      'alpha beta',
    );
    await tester.pumpWidget(const SizedBox());
    editor.dispose();
  });

  testWidgets('link dialog rejects selection changes while it is open', (
    tester,
  ) async {
    final editor = document('alpha beta');
    await mount(tester, editor);
    editor.selection = af.Selection.single(
      path: [0],
      startOffset: 0,
      endOffset: 5,
    );
    await tester.pumpAndSettle();
    final original = jsonEncode(editor.document.toJson());
    await tester.ensureVisible(find.byKey(const ValueKey('rich-toolbar-link')));
    await tester.tap(find.byKey(const ValueKey('rich-toolbar-link')));
    await tester.pumpAndSettle();
    editor.selection = af.Selection.single(
      path: [0],
      startOffset: 6,
      endOffset: 10,
    );
    // Simulate a remote selection change without depending on which text
    // input client the test binding currently considers focused.
    tester
            .widget<TextField>(find.byKey(const ValueKey('rich-link-address')))
            .controller!
            .text =
        'https://example.com';
    await tester.pump();
    await tester.tap(find.byKey(const ValueKey('rich-link-save')));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 250));
    expect(jsonEncode(editor.document.toJson()), original);
    expect(find.text(l10n.dailynotes.editorSelectionChanged), findsOneWidget);
    await tester.pumpWidget(const SizedBox());
    editor.dispose();
  });

  testWidgets('Aa scrolls only when it covers the selected text', (
    tester,
  ) async {
    final editor = af.EditorState(
      document: af.Document(
        root: af.pageNode(
          children: [
            for (var i = 0; i < 80; i++) af.paragraphNode(text: 'Line $i text'),
          ],
        ),
      ),
    );
    final scroll = af.EditorScrollController(editorState: editor);
    await mount(tester, editor, scrollController: scroll);
    tester.view.viewInsets = FakeViewPadding.zero;
    scroll.itemScrollController.jumpTo(index: 30, alignment: .65);
    await tester.pumpAndSettle();
    editor.selection = af.Selection.single(
      path: [30],
      startOffset: 0,
      endOffset: 4,
    );
    await tester.pumpAndSettle();
    final before = editor.selectionRects().single;
    expect(before.bottom, greaterThan(450));
    await tester.tap(find.byKey(const ValueKey('rich-floating-format')));
    await tester.pumpAndSettle();
    final after = editor.selectionRects().single;
    final sheetHeader = tester
        .getTopLeft(find.text(l10n.dailynotes.editorFormatDone))
        .dy;
    expect(after.bottom, lessThan(sheetHeader));
    expect(after.bottom, lessThan(before.bottom));
    await tester.pumpWidget(const SizedBox());
    scroll.dispose();
    editor.dispose();
  });

  testWidgets('Aa keeps the scroll anchor when selection is already visible', (
    tester,
  ) async {
    final editor = af.EditorState(
      document: af.Document(
        root: af.pageNode(
          children: [
            for (var i = 0; i < 80; i++) af.paragraphNode(text: 'Line $i text'),
          ],
        ),
      ),
    );
    final scroll = af.EditorScrollController(editorState: editor);
    await mount(tester, editor, scrollController: scroll);
    tester.view.viewInsets = FakeViewPadding.zero;
    scroll.itemScrollController.jumpTo(index: 30, alignment: .15);
    await tester.pumpAndSettle();
    editor.selection = af.Selection.single(
      path: [30],
      startOffset: 0,
      endOffset: 4,
    );
    await tester.pumpAndSettle();
    final before = editor.selectionRects().single;
    expect(before.bottom, lessThan(450));
    await tester.tap(find.byKey(const ValueKey('rich-floating-format')));
    await tester.pumpAndSettle();
    expect(editor.selectionRects().single.top, closeTo(before.top, .1));
    await tester.pumpWidget(const SizedBox());
    scroll.dispose();
    editor.dispose();
  });

  testWidgets('resizing Aa scrolls only when the selection becomes covered', (
    tester,
  ) async {
    final editor = af.EditorState(
      document: af.Document(
        root: af.pageNode(
          children: [
            for (var i = 0; i < 80; i++) af.paragraphNode(text: 'Line $i text'),
          ],
        ),
      ),
    );
    final scroll = af.EditorScrollController(editorState: editor);
    await mount(tester, editor, scrollController: scroll);
    tester.view.viewInsets = FakeViewPadding.zero;
    scroll.itemScrollController.jumpTo(index: 30, alignment: .25);
    await tester.pumpAndSettle();
    final selection = af.Selection.single(
      path: [30],
      startOffset: 0,
      endOffset: 4,
    );
    editor.selection = selection;
    await tester.pumpAndSettle();
    final before = editor.selectionRects().single;
    await tester.tap(find.byKey(const ValueKey('rich-floating-format')));
    await tester.pumpAndSettle();
    expect(editor.selectionRects().single.top, closeTo(before.top, .5));
    final handle = find.byKey(const ValueKey('rich-format-drag-handle'));
    await tester.drag(handle, const Offset(0, -250));
    await tester.pumpAndSettle();
    final expanded = editor.selectionRects().single;
    final toolbarTop = tester
        .getTopLeft(find.byKey(const ValueKey('rich-keyboard-toolbar')))
        .dy;
    expect(expanded.bottom, lessThanOrEqualTo(toolbarTop));
    expect(expanded.top, lessThan(before.top));
    await tester.drag(handle, const Offset(0, 150));
    await tester.pumpAndSettle();
    expect(editor.selectionRects().single.top, closeTo(expanded.top, .5));
    expect(editor.selection, selection);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
    scroll.dispose();
    editor.dispose();
  });

  testWidgets('Aa starts at half height, resizes, and Done restores keyboard', (
    tester,
  ) async {
    final editor = document('alpha beta');
    await mount(tester, editor);
    final beforeState = tester.state(find.byType(af.AppFlowyEditor));
    final selection = af.Selection.single(
      path: [0],
      startOffset: 0,
      endOffset: 5,
    );
    editor.selection = selection;
    await tester.pumpAndSettle();
    tester.testTextInput.log.clear();
    await tester.tap(find.byKey(const ValueKey('rich-toolbar-format')));
    await tester.pumpAndSettle();
    expect(
      tester.testTextInput.log.map((call) => call.method),
      contains('TextInput.hide'),
    );
    expect(
      tester.getSize(find.byType(af.AppFlowyEditor)).height,
      greaterThanOrEqualTo(150),
    );
    tester.view.viewInsets = FakeViewPadding.zero;
    await tester.pumpAndSettle();
    final panel = find.byKey(const ValueKey('rich-format-panel'));
    final toolbar = find.byKey(const ValueKey('rich-keyboard-toolbar'));
    expect(panel, findsOneWidget);
    expect(find.byType(BottomSheet), findsNothing);
    expect(tester.getSize(panel).height, 450);
    expect(tester.getBottomLeft(toolbar).dy, tester.getTopLeft(panel).dy);
    expect(editor.selection, selection);
    expect(
      identical(beforeState, tester.state(find.byType(af.AppFlowyEditor))),
      isTrue,
    );
    final handle = find.byKey(const ValueKey('rich-format-drag-handle'));
    await tester.drag(handle, const Offset(0, -100));
    await tester.pumpAndSettle();
    expect(tester.getSize(panel).height, greaterThan(450));
    await tester.drag(handle, const Offset(0, 200));
    await tester.pumpAndSettle();
    expect(tester.getSize(panel).height, lessThan(450));
    expect(editor.selection, selection);
    tester.testTextInput.log.clear();
    await tester.tap(find.byKey(const ValueKey('rich-format-done')));
    await tester.pumpAndSettle();
    expect(panel, findsNothing);
    expect(
      tester.testTextInput.log.map((call) => call.method),
      contains('TextInput.show'),
    );
    expect(editor.selection, selection);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
    editor.dispose();
  });
  testWidgets('closing Aa does not summon a previously hidden keyboard', (
    tester,
  ) async {
    final editor = document('alpha beta');
    await mount(tester, editor);
    tester.view.viewInsets = FakeViewPadding.zero;
    final selection = af.Selection.single(
      path: [0],
      startOffset: 0,
      endOffset: 5,
    );
    editor.selection = selection;
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('rich-floating-format')));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('rich-format-panel')), findsOneWidget);
    tester.testTextInput.log.clear();
    await tester.tap(find.text(l10n.dailynotes.editorFormatDone));
    await tester.pumpAndSettle();
    expect(
      tester.testTextInput.log.map((call) => call.method),
      isNot(contains('TextInput.show')),
    );
    expect(editor.selection, selection);
    await tester.pumpWidget(const SizedBox());
    editor.dispose();
  });

  testWidgets('after system back, tapping the caret reopens the keyboard', (
    tester,
  ) async {
    final editor = document('alpha beta');
    await mount(tester, editor);
    editor.selection = af.Selection.single(path: [0], startOffset: 3);
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('rich-toolbar-format')));
    await tester.pumpAndSettle();
    tester.view.viewInsets = FakeViewPadding.zero;
    await tester.pumpAndSettle();
    tester.testTextInput.log.clear();
    await tester.binding.handlePopRoute();
    await tester.pumpAndSettle();
    expect(
      tester.testTextInput.log.map((call) => call.method),
      isNot(contains('TextInput.show')),
    );
    final caret = editor.selectionRects().single;
    await tester.tapAt(caret.center);
    await tester.pumpAndSettle();
    expect(
      tester.testTextInput.log.map((call) => call.method),
      contains('TextInput.show'),
    );
    await tester.pumpWidget(const SizedBox());
    editor.dispose();
  });

  testWidgets(
    'Aa preserves the selection anchor while keyboard insets change',
    (tester) async {
      final editor = af.EditorState(
        document: af.Document(
          root: af.pageNode(
            children: [
              for (var i = 0; i < 80; i++)
                af.paragraphNode(text: 'Line $i text'),
            ],
          ),
        ),
      );
      final scroll = af.EditorScrollController(editorState: editor);
      await mount(tester, editor, scrollController: scroll);
      scroll.itemScrollController.jumpTo(index: 30, alignment: .15);
      await tester.pumpAndSettle();
      final selection = af.Selection.single(
        path: [30],
        startOffset: 0,
        endOffset: 4,
      );
      editor.selection = selection;
      await tester.pumpAndSettle();
      final before = editor.selectionRects().single;
      await tester.tap(find.byKey(const ValueKey('rich-toolbar-format')));
      await tester.pumpAndSettle();
      tester.view.viewInsets = FakeViewPadding.zero;
      await tester.pumpAndSettle();
      expect(editor.selectionRects().single.top, closeTo(before.top, .5));
      expect(editor.selection, selection);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
      scroll.dispose();
      editor.dispose();
    },
  );

  testWidgets('Aa remains usable when the screen rotates after opening', (
    tester,
  ) async {
    final editor = document('alpha beta');
    await mount(tester, editor);
    final selection = af.Selection.single(
      path: [0],
      startOffset: 0,
      endOffset: 5,
    );
    editor.selection = selection;
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('rich-toolbar-format')));
    await tester.pumpAndSettle();
    tester.view.viewInsets = FakeViewPadding.zero;
    tester.view.physicalSize = const Size(700, 320);
    await tester.pumpAndSettle();
    final panel = find.byKey(const ValueKey('rich-format-panel'));
    expect(panel, findsOneWidget);
    expect(tester.getRect(panel).bottom, lessThanOrEqualTo(320));
    expect(editor.selection, selection);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
    editor.dispose();
  });

  testWidgets('locking and unlocking invalidates an open Aa session', (
    tester,
  ) async {
    final editor = document('alpha beta');
    var fontLoads = 0;
    await mount(
      tester,
      editor,
      loadFonts: () async {
        fontLoads++;
        return (families: <String>[], hasUnavailable: false);
      },
    );
    editor.selection = af.Selection.single(
      path: [0],
      startOffset: 0,
      endOffset: 5,
    );
    await tester.pumpAndSettle();
    final original = jsonEncode(editor.document.toJson());
    await tester.tap(find.byKey(const ValueKey('rich-toolbar-format')));
    await tester.pumpAndSettle();
    final oldBold = tester
        .widget<IconButton>(
          find.byKey(ValueKey('rich-format-${l10n.editor.toolbar.bold}')),
        )
        .onPressed!;
    final oldFont = tester
        .widget<TextButton>(find.byKey(const ValueKey('rich-format-font')))
        .onPressed!;
    final oldMore = tester
        .widget<IconButton>(find.byKey(const ValueKey('rich-toolbar-more')))
        .onPressed!;
    final menuController = tester
        .widget<MenuAnchor>(
          find.ancestor(
            of: find.byKey(const ValueKey('rich-toolbar-more')),
            matching: find.byType(MenuAnchor),
          ),
        )
        .controller!;
    tester.testTextInput.log.clear();
    editor.editable = false;
    editor.editable = true;
    oldBold();
    oldFont();
    oldMore();
    expect(fontLoads, 0);
    expect(menuController.isOpen, isFalse);
    await tester.pumpAndSettle();
    expect(jsonEncode(editor.document.toJson()), original);
    expect(find.byKey(const ValueKey('rich-format-panel')), findsNothing);
    expect(find.byKey(const ValueKey('rich-overflow-code')), findsNothing);
    expect(
      tester.testTextInput.log.map((call) => call.method),
      isNot(contains('TextInput.show')),
    );
    await tester.pumpWidget(const SizedBox());
    editor.dispose();
  });

  testWidgets('late keyboard hide cannot open Aa for an old selection', (
    tester,
  ) async {
    final editor = document('alpha beta');
    await mount(tester, editor);
    final originalSelection = af.Selection.single(
      path: [0],
      startOffset: 0,
      endOffset: 5,
    );
    editor.selection = originalSelection;
    await tester.pumpAndSettle();
    final original = jsonEncode(editor.document.toJson());
    final hide = Completer<void>();
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      SystemChannels.textInput,
      (call) async {
        if (call.method == 'TextInput.hide') await hide.future;
        return null;
      },
    );
    addTearDown(tester.testTextInput.register);
    await tester.tap(find.byKey(const ValueKey('rich-toolbar-format')));
    await tester.pump();
    editor.selection = af.Selection.single(
      path: [0],
      startOffset: 6,
      endOffset: 10,
    );
    editor.selection = originalSelection;
    hide.complete();
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('rich-format-panel')), findsNothing);
    expect(jsonEncode(editor.document.toJson()), original);
    tester.testTextInput.register();
    await tester.pumpWidget(const SizedBox());
    editor.dispose();
  });

  testWidgets(
    'returning from another route cannot reactivate an old Aa session',
    (tester) async {
      final editor = document('alpha beta');
      await mount(tester, editor);
      editor.selection = af.Selection.single(
        path: [0],
        startOffset: 0,
        endOffset: 5,
      );
      await tester.pumpAndSettle();
      final original = jsonEncode(editor.document.toJson());
      await tester.tap(find.byKey(const ValueKey('rich-toolbar-format')));
      await tester.pumpAndSettle();
      final navigator = Navigator.of(
        tester.element(find.byType(RichEditorToolbar)),
      );
      unawaited(
        navigator.push<void>(
          MaterialPageRoute<void>(
            builder: (_) => const Scaffold(body: Text('other record')),
          ),
        ),
      );
      await tester.pumpAndSettle();
      navigator.pop();
      await tester.pumpAndSettle();
      final bold = find.byKey(
        ValueKey('rich-format-${l10n.editor.toolbar.bold}'),
      );
      expect(tester.widget<IconButton>(bold).onPressed, isNull);
      tester.testTextInput.log.clear();
      await tester.tap(find.text(l10n.dailynotes.editorFormatDone));
      await tester.pumpAndSettle();
      expect(
        tester.testTextInput.log.map((call) => call.method),
        isNot(contains('TextInput.show')),
      );
      expect(jsonEncode(editor.document.toJson()), original);
      await tester.pumpWidget(const SizedBox());
      editor.dispose();
    },
  );

  testWidgets('Aa stays usable after applying a toolbar more action', (
    tester,
  ) async {
    final editor = document('alpha beta');
    await mount(tester, editor);
    final selection = af.Selection.single(
      path: [0],
      startOffset: 0,
      endOffset: 5,
    );
    editor.selection = selection;
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('rich-toolbar-format')));
    await tester.pumpAndSettle();
    await tapOverflow(tester, 'code');
    expect(jsonEncode(editor.document.toJson()), contains('"code":true'));
    expect(find.byKey(const ValueKey('rich-format-panel')), findsOneWidget);
    final bold = find.byKey(
      ValueKey('rich-format-${l10n.editor.toolbar.bold}'),
    );
    expect(tester.widget<IconButton>(bold).onPressed, isNotNull);
    await tester.tap(bold);
    await tester.pumpAndSettle();
    expect(jsonEncode(editor.document.toJson()), contains('"bold":true'));
    expect(editor.selection, selection);
    await tester.pumpWidget(const SizedBox());
    editor.dispose();
  });

  testWidgets('Aa more survives a width change without losing its selection', (
    tester,
  ) async {
    final editor = document('alpha beta');
    await mount(tester, editor);
    final selection = af.Selection.single(
      path: [0],
      startOffset: 0,
      endOffset: 5,
    );
    editor.selection = selection;
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('rich-toolbar-format')));
    await tester.pumpAndSettle();
    tester.view.viewInsets = FakeViewPadding.zero;
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('rich-toolbar-more')));
    await tester.pumpAndSettle();
    tester.view.physicalSize = const Size(320, 900);
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('rich-format-panel')), findsOneWidget);
    expect(editor.selection, selection);
    expect(find.byKey(const ValueKey('rich-overflow-code')), findsNothing);
    await tester.tap(find.byKey(const ValueKey('rich-toolbar-more')));
    await tester.pumpAndSettle();
    final code = find.byKey(const ValueKey('rich-overflow-code'));
    await tester.ensureVisible(code);
    await tester.pumpAndSettle();
    await tester.tap(code);
    await tester.pumpAndSettle();
    expect(jsonEncode(editor.document.toJson()), contains('"code":true'));
    expect(editor.selection, selection);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
    editor.dispose();
  });

  testWidgets('system back dismisses Aa more before closing Aa', (
    tester,
  ) async {
    final editor = document('alpha beta');
    await mount(tester, editor);
    editor.selection = af.Selection.single(
      path: [0],
      startOffset: 0,
      endOffset: 5,
    );
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('rich-toolbar-format')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('rich-toolbar-more')));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('rich-overflow-code')), findsOneWidget);
    tester.testTextInput.log.clear();
    await tester.binding.handlePopRoute();
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('rich-overflow-code')), findsNothing);
    expect(find.byKey(const ValueKey('rich-format-panel')), findsOneWidget);
    expect(
      tester.testTextInput.log.map((call) => call.method),
      isNot(contains('TextInput.show')),
    );
    await tester.binding.handlePopRoute();
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('rich-format-panel')), findsNothing);
    await tester.pumpWidget(const SizedBox());
    editor.dispose();
  });

  testWidgets('old Aa more actions cannot undo after locking and unlocking', (
    tester,
  ) async {
    final editor = document('alpha beta');
    await mount(tester, editor);
    await editor.insertText(0, 'new ', path: [0]);
    editor.selection = af.Selection.single(
      path: [0],
      startOffset: 0,
      endOffset: 3,
    );
    await tester.pumpAndSettle();
    expect(editor.undoManager.undoStack.isNonEmpty, isTrue);
    final original = jsonEncode(editor.document.toJson());
    await tester.tap(find.byKey(const ValueKey('rich-toolbar-format')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('rich-toolbar-more')));
    await tester.pumpAndSettle();
    final oldUndo = tester
        .widget<MenuItemButton>(
          find.byKey(const ValueKey('rich-overflow-undo')),
        )
        .onPressed!;
    editor.editable = false;
    editor.editable = true;
    oldUndo();
    await tester.pumpAndSettle();
    expect(jsonEncode(editor.document.toJson()), original);
    expect(editor.undoManager.undoStack.isNonEmpty, isTrue);
    await tester.pumpWidget(const SizedBox());
    editor.dispose();
  });

  testWidgets('Aa toolbar color returns to the same panel and selection', (
    tester,
  ) async {
    final editor = document('alpha beta');
    await mount(tester, editor);
    final selection = af.Selection.single(
      path: [0],
      startOffset: 0,
      endOffset: 5,
    );
    editor.selection = selection;
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('rich-toolbar-format')));
    await tester.pumpAndSettle();
    tester.testTextInput.log.clear();
    await tapOverflow(tester, 'color');
    await tester.tap(
      find.byKey(const ValueKey('rich-quick-color-text-0xffd32f2f')),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('rich-color-done')));
    await tester.pumpAndSettle();
    expect(jsonEncode(editor.document.toJson()), contains('0xffd32f2f'));
    expect(find.byKey(const ValueKey('rich-format-font')), findsOneWidget);
    expect(editor.selection, selection);
    expect(
      tester.testTextInput.log.map((call) => call.method),
      isNot(contains('TextInput.show')),
    );
    await tester.pumpWidget(const SizedBox());
    editor.dispose();
  });

  testWidgets('navigation while Aa more is open invalidates its selection', (
    tester,
  ) async {
    final editor = document('alpha beta');
    await mount(tester, editor);
    editor.selection = af.Selection.single(
      path: [0],
      startOffset: 0,
      endOffset: 5,
    );
    await tester.pumpAndSettle();
    final original = jsonEncode(editor.document.toJson());
    await tester.tap(find.byKey(const ValueKey('rich-toolbar-format')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('rich-toolbar-more')));
    await tester.pumpAndSettle();
    final navigator = Navigator.of(
      tester.element(find.byType(RichEditorToolbar)),
    );
    unawaited(
      navigator.push<void>(
        MaterialPageRoute<void>(
          builder: (_) => const Scaffold(body: Text('another document')),
        ),
      ),
    );
    await tester.pumpAndSettle();
    navigator.pop();
    await tester.pumpAndSettle();
    final bold = find.byKey(
      ValueKey('rich-format-${l10n.editor.toolbar.bold}'),
    );
    expect(tester.widget<IconButton>(bold).onPressed, isNull);
    expect(jsonEncode(editor.document.toJson()), original);
    await tester.pumpWidget(const SizedBox());
    editor.dispose();
  });

  testWidgets(
    'Aa converts selected sibling blocks together and undo restores them',
    (tester) async {
      final editor = af.EditorState(
        document: af.Document(
          root: af.pageNode(
            children: [
              af.paragraphNode(text: 'first'),
              af.headingNode(level: 2, text: 'second'),
              af.paragraphNode(text: 'outside'),
            ],
          ),
        ),
      );
      await mount(tester, editor);
      final selection = af.Selection(
        start: af.Position(path: [0], offset: 1),
        end: af.Position(path: [1], offset: 4),
      );
      editor.selection = selection;
      await tester.pumpAndSettle();
      final before = jsonEncode(editor.document.toJson());
      await tester.tap(find.byKey(const ValueKey('rich-toolbar-format')));
      await tester.pumpAndSettle();
      await tester.tap(
        find.byKey(ValueKey('rich-format-${l10n.editor.toolbar.bulletList}')),
      );
      await tester.pumpAndSettle();
      final nodes = editor.document.root.children.toList();
      expect(nodes.map((n) => n.type).toList(), [
        af.BulletedListBlockKeys.type,
        af.BulletedListBlockKeys.type,
        af.ParagraphBlockKeys.type,
      ]);
      expect(nodes.map((n) => n.delta!.toPlainText()).toList(), [
        'first',
        'second',
        'outside',
      ]);
      expect(editor.selection, selection);
      final encoded = jsonEncode(editor.document.toJson());
      expect(
        jsonEncode(af.Document.fromJson(jsonDecode(encoded)).toJson()),
        encoded,
      );
      editor.undoManager.undo();
      await tester.pumpAndSettle();
      expect(jsonEncode(editor.document.toJson()), before);
      await tester.pumpWidget(const SizedBox());
      editor.dispose();
    },
  );

  testWidgets('Aa refuses cross-level block conversion', (tester) async {
    final editor = af.EditorState(
      document: af.Document(
        root: af.pageNode(
          children: [
            af.bulletedListNode(
              text: 'parent',
              children: [af.paragraphNode(text: 'child')],
            ),
            af.paragraphNode(text: 'next'),
          ],
        ),
      ),
    );
    await mount(tester, editor);
    editor.selection = af.Selection(
      start: af.Position(path: [0], offset: 0),
      end: af.Position(path: [1], offset: 2),
    );
    await tester.pumpAndSettle();
    final before = jsonEncode(editor.document.toJson());
    await tester.tap(find.byKey(const ValueKey('rich-toolbar-format')));
    await tester.pumpAndSettle();
    final button = tester.widget<IconButton>(
      find.byKey(ValueKey('rich-format-${l10n.editor.toolbar.bulletList}')),
    );
    expect(button.onPressed, isNull);
    expect(jsonEncode(editor.document.toJson()), before);
    await tester.pumpWidget(const SizedBox());
    editor.dispose();
  });
  testWidgets('more menu never applies an action to a changed selection', (
    tester,
  ) async {
    final editor = document('alpha beta');
    await mount(tester, editor);
    editor.selection = af.Selection.single(
      path: [0],
      startOffset: 0,
      endOffset: 5,
    );
    await tester.pumpAndSettle();
    final original = jsonEncode(editor.document.toJson());
    await tester.tap(find.byKey(const ValueKey('rich-toolbar-more')));
    await tester.pumpAndSettle();
    editor.selection = af.Selection.single(
      path: [0],
      startOffset: 6,
      endOffset: 10,
    );
    await tester.pump();
    await tester.tap(find.byKey(const ValueKey('rich-overflow-color')));
    await tester.pumpAndSettle();
    expect(jsonEncode(editor.document.toJson()), original);
    expect(
      find.byKey(const ValueKey('rich-quick-color-text-0xffd32f2f')),
      findsNothing,
    );
    await tester.pumpWidget(const SizedBox());
    editor.dispose();
  });

  testWidgets('narrow toolbar fits without horizontal scrolling', (
    tester,
  ) async {
    final editor = document('alpha beta');
    await mount(tester, editor);
    tester.view.physicalSize = const Size(320, 700);
    editor.selection = af.Selection.single(path: [0], startOffset: 2);
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('rich-toolbar-insert')), findsOneWidget);
    expect(find.byKey(const ValueKey('rich-toolbar-format')), findsOneWidget);
    expect(find.byKey(const ValueKey('rich-toolbar-more')), findsOneWidget);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
    editor.dispose();
  });

  testWidgets('toolbar keeps usable widths and moves shortcuts into more', (
    tester,
  ) async {
    final editor = document('alpha beta');
    await mount(tester, editor);
    final selection = af.Selection.single(path: [0], startOffset: 2);
    editor.selection = selection;
    await tester.pumpAndSettle();
    final originalState = tester.state(find.byType(af.AppFlowyEditor));
    final shortcuts = ['todo', 'bullet', 'numbered', 'bold'];
    double? toolbarTop;
    for (final (width, count) in [
      (430.0, 4),
      (320.0, 2),
      (240.0, 1),
      (192.0, 0),
    ]) {
      tester.view.physicalSize = Size(width, 900);
      await tester.pumpAndSettle();
      final toolbar = find.byKey(const ValueKey('rich-keyboard-toolbar'));
      final top = tester.getTopLeft(toolbar).dy;
      toolbarTop ??= top;
      expect(top, toolbarTop);
      for (var index = 0; index < shortcuts.length; index++) {
        expect(
          find.byKey(ValueKey('rich-toolbar-${shortcuts[index]}')),
          index < count ? findsOneWidget : findsNothing,
        );
      }
      for (final id in [
        'insert',
        'format',
        'more',
        'close',
        ...shortcuts.take(count),
      ]) {
        expect(
          tester.getSize(find.byKey(ValueKey('rich-toolbar-$id'))).width,
          greaterThanOrEqualTo(48),
          reason: '$id is too narrow at $width logical pixels',
        );
      }
      expect(editor.selection, selection);
      expect(
        identical(tester.state(find.byType(af.AppFlowyEditor)), originalState),
        isTrue,
      );
      expect(tester.takeException(), isNull);
    }
    await tester.tap(find.byKey(const ValueKey('rich-toolbar-more')));
    await tester.pumpAndSettle();
    for (final id in shortcuts) {
      final item = tester.widget<PopupMenuItem<String>>(
        find.byKey(ValueKey('rich-overflow-$id')),
      );
      expect(item.enabled, isTrue);
    }
    await tester.tap(find.byKey(const ValueKey('rich-overflow-numbered')));
    await tester.pumpAndSettle();
    expect(
      editor.document.root.children.single.type,
      af.NumberedListBlockKeys.type,
    );
    expect(
      editor.document.root.children.single.delta!.toPlainText(),
      'alpha beta',
    );
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
    editor.dispose();
  });

  testWidgets('an open more menu keeps its action after a width change', (
    tester,
  ) async {
    final editor = document('alpha beta');
    await mount(tester, editor);
    tester.view.physicalSize = const Size(240, 900);
    editor.selection = af.Selection.single(path: [0], startOffset: 2);
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('rich-toolbar-more')));
    await tester.pumpAndSettle();
    expect(
      find.byKey(const ValueKey('rich-overflow-numbered')),
      findsOneWidget,
    );
    tester.view.physicalSize = const Size(430, 900);
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('rich-overflow-numbered')));
    await tester.pumpAndSettle();
    expect(
      editor.document.root.children.single.type,
      af.NumberedListBlockKeys.type,
    );
    expect(
      editor.document.root.children.single.delta!.toPlainText(),
      'alpha beta',
    );
    expect(find.text(l10n.dailynotes.editorSelectionChanged), findsNothing);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
    editor.dispose();
  });

  testWidgets('very narrow toolbar keeps the keyboard action in more', (
    tester,
  ) async {
    final editor = document('alpha beta');
    await mount(tester, editor);
    tester.view.physicalSize = const Size(160, 900);
    final selection = af.Selection.single(path: [0], startOffset: 2);
    editor.selection = selection;
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('rich-toolbar-insert')), findsOneWidget);
    expect(find.byKey(const ValueKey('rich-toolbar-format')), findsOneWidget);
    expect(find.byKey(const ValueKey('rich-toolbar-close')), findsNothing);
    expect(
      tester.getSize(find.byKey(const ValueKey('rich-toolbar-more'))).width,
      greaterThanOrEqualTo(48),
    );
    tester.testTextInput.log.clear();
    await tester.tap(find.byKey(const ValueKey('rich-toolbar-more')));
    await tester.pumpAndSettle();
    final close = find.byKey(const ValueKey('rich-overflow-close'));
    await tester.ensureVisible(close);
    await tester.tap(close);
    await tester.pumpAndSettle();
    expect(
      tester.testTextInput.log.map((call) => call.method),
      contains('TextInput.hide'),
    );
    expect(editor.selection, selection);
    expect(
      editor.document.root.children.single.delta!.toPlainText(),
      'alpha beta',
    );
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
    editor.dispose();
  });

  testWidgets('selection menu and keyboard toolbar coexist without overlap', (
    tester,
  ) async {
    final editor = document('alpha beta');
    await mount(tester, editor);
    final beforeState = tester.state(find.byType(af.AppFlowyEditor));
    final selection = af.Selection.single(
      path: [0],
      startOffset: 0,
      endOffset: 5,
    );
    editor.selection = selection;
    await tester.pumpAndSettle();

    final menu = find.byKey(const ValueKey('rich-selection-menu'));
    final toolbar = find.byKey(const ValueKey('rich-keyboard-toolbar'));
    expect(menu, findsOneWidget);
    expect(toolbar, findsOneWidget);
    expect(tester.getRect(menu).overlaps(tester.getRect(toolbar)), isFalse);
    expect(
      editor.selectionRects().any(
        (rect) => rect.overlaps(tester.getRect(menu)),
      ),
      isFalse,
    );
    await tester.tap(find.byKey(const ValueKey('rich-floating-bold')));
    await tester.pumpAndSettle();
    expect(jsonEncode(editor.document.toJson()), contains('"bold":true'));
    expect(editor.selection, selection);

    tester.view.viewInsets = FakeViewPadding.zero;
    await tester.pumpAndSettle();
    expect(toolbar, findsNothing);
    expect(menu, findsOneWidget);
    expect(
      identical(beforeState, tester.state(find.byType(af.AppFlowyEditor))),
      isTrue,
    );
    await tester.pumpWidget(const SizedBox());
    editor.dispose();
  });

  testWidgets('narrow selection menu keeps every action usable and visible', (
    tester,
  ) async {
    final editor = document('alpha beta');
    await mount(tester, editor);
    tester.view.physicalSize = const Size(240, 900);
    final selection = af.Selection.single(
      path: [0],
      startOffset: 0,
      endOffset: 5,
    );
    editor.selection = selection;
    await tester.pumpAndSettle();
    final menu = find.byKey(const ValueKey('rich-selection-menu'));
    final toolbar = find.byKey(const ValueKey('rich-keyboard-toolbar'));
    expect(tester.getSize(menu), const Size(126, 88));
    expect(tester.getRect(menu).overlaps(tester.getRect(toolbar)), isFalse);
    expect(
      editor.selectionRects().any(
        (rect) => rect.overlaps(tester.getRect(menu)),
      ),
      isFalse,
    );
    final rectangles = <Rect>[];
    for (final id in [
      'format',
      'bold',
      'italic',
      'link',
      'copy',
      'select-all',
    ]) {
      final action = find.byKey(ValueKey('rich-floating-$id'));
      expect(action, findsOneWidget);
      final rect = tester.getRect(action);
      expect(rect.width, greaterThanOrEqualTo(42));
      expect(tester.getRect(menu).contains(rect.topLeft), isTrue);
      expect(rectangles.any((other) => other.overlaps(rect)), isFalse);
      rectangles.add(rect);
    }
    tester.view.physicalSize = const Size(430, 900);
    await tester.pumpAndSettle();
    expect(tester.getSize(menu), const Size(252, 44));
    expect(editor.selection, selection);
    tester.view.physicalSize = const Size(240, 900);
    await tester.pumpAndSettle();
    expect(tester.getSize(menu), const Size(126, 88));
    await tester.tap(find.byKey(const ValueKey('rich-floating-bold')));
    await tester.pumpAndSettle();
    expect(jsonEncode(editor.document.toJson()), contains('"bold":true'));
    expect(editor.selection, selection);
    tester.view.viewInsets = FakeViewPadding.zero;
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('rich-keyboard-toolbar')), findsNothing);
    expect(tester.getSize(menu), const Size(126, 88));
    await tester.tap(find.byKey(const ValueKey('rich-floating-select-all')));
    await tester.pumpAndSettle();
    expect(editor.selection!.normalized.end.offset, 10);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
    editor.dispose();
  });

  testWidgets(
    'hidden keyboard uses a selection menu without rebuilding editor',
    (tester) async {
      final editor = document('alpha beta');
      await mount(tester, editor);
      final beforeState = tester.state(find.byType(af.AppFlowyEditor));
      tester.view.viewInsets = FakeViewPadding.zero;
      final selection = af.Selection.single(
        path: [0],
        startOffset: 0,
        endOffset: 5,
      );
      editor.selection = selection;
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('rich-toolbar-format')), findsNothing);
      expect(find.byKey(const ValueKey('rich-selection-menu')), findsOneWidget);
      expect(find.byKey(const ValueKey('rich-floating-link')), findsOneWidget);
      expect(find.byKey(const ValueKey('rich-floating-copy')), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('rich-floating-bold')));
      await tester.pumpAndSettle();
      expect(jsonEncode(editor.document.toJson()), contains('"bold":true'));
      expect(editor.selection, selection);
      expect(
        identical(beforeState, tester.state(find.byType(af.AppFlowyEditor))),
        isTrue,
      );
      await tester.tap(find.byKey(const ValueKey('rich-floating-format')));
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('rich-format-panel')), findsOneWidget);
      await tester.pumpWidget(const SizedBox());
      editor.dispose();
    },
  );

  testWidgets(
    'floating select all expands the selection without changing text',
    (tester) async {
      final editor = document('alpha beta');
      await mount(tester, editor);
      editor.selection = af.Selection.single(
        path: [0],
        startOffset: 0,
        endOffset: 5,
      );
      await tester.pumpAndSettle();
      final original = jsonEncode(editor.document.toJson());
      await tester.tap(find.byKey(const ValueKey('rich-floating-select-all')));
      await tester.pumpAndSettle();
      expect(editor.selection!.normalized.start.offset, 0);
      expect(editor.selection!.normalized.end.offset, 10);
      expect(jsonEncode(editor.document.toJson()), original);
      await tester.pumpWidget(const SizedBox());
      editor.dispose();
    },
  );

  testWidgets(
    'read-only selection offers copy and select all without editing',
    (tester) async {
      final editor = document('alpha beta');
      await mount(tester, editor, editable: false);
      tester.view.viewInsets = FakeViewPadding.zero;
      final original = jsonEncode(editor.document.toJson());
      af.AppFlowyClipboard.lastText = null;
      unawaited(
        editor.updateSelectionWithReason(
          af.Selection.single(path: [0], startOffset: 0, endOffset: 5),
          reason: af.SelectionUpdateReason.uiEvent,
        ),
      );
      await tester.pumpAndSettle();
      expect(tester.testTextInput.isVisible, isFalse);
      expect(find.byKey(const ValueKey('rich-selection-menu')), findsOneWidget);
      expect(find.byKey(const ValueKey('rich-floating-format')), findsNothing);
      expect(find.byKey(const ValueKey('rich-floating-bold')), findsNothing);
      expect(find.byKey(const ValueKey('rich-floating-link')), findsNothing);
      expect(find.byKey(const ValueKey('rich-keyboard-toolbar')), findsNothing);
      await tester.tap(find.byKey(const ValueKey('rich-floating-copy')));
      await tester.pumpAndSettle();
      expect(af.AppFlowyClipboard.lastText, 'alpha');
      await tester.tap(find.byKey(const ValueKey('rich-floating-select-all')));
      await tester.pumpAndSettle();
      expect(editor.selection!.normalized.end.offset, 10);
      expect(jsonEncode(editor.document.toJson()), original);
      expect(tester.testTextInput.isVisible, isFalse);
      await tester.pumpWidget(const SizedBox());
      editor.dispose();
    },
  );

  testWidgets('stale read-only copy never copies another selection', (
    tester,
  ) async {
    final editor = document('alpha beta');
    await mount(tester, editor, editable: false);
    tester.view.viewInsets = FakeViewPadding.zero;
    unawaited(
      editor.updateSelectionWithReason(
        af.Selection.single(path: [0], startOffset: 0, endOffset: 5),
        reason: af.SelectionUpdateReason.uiEvent,
      ),
    );
    await tester.pumpAndSettle();
    final action = tester
        .widget<IconButton>(find.byKey(const ValueKey('rich-floating-copy')))
        .onPressed!;
    af.AppFlowyClipboard.lastText = null;
    editor.selection = af.Selection.single(
      path: [0],
      startOffset: 6,
      endOffset: 10,
    );
    action();
    await tester.pump();
    expect(af.AppFlowyClipboard.lastText, isNull);
    await tester.pumpWidget(const SizedBox());
    editor.dispose();
  });

  testWidgets('selection menu hides while the platform is dragging handles', (
    tester,
  ) async {
    final editor = document('alpha beta');
    await mount(tester, editor);
    tester.view.viewInsets = FakeViewPadding.zero;
    final selection = af.Selection.single(
      path: [0],
      startOffset: 0,
      endOffset: 5,
    );
    editor.selection = selection;
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('rich-selection-menu')), findsOneWidget);
    unawaited(
      editor.updateSelectionWithReason(
        selection,
        reason: af.SelectionUpdateReason.uiEvent,
        extraInfo: {af.selectionExtraInfoDisableFloatingToolbar: true},
      ),
    );
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('rich-selection-menu')), findsNothing);
    unawaited(
      editor.updateSelectionWithReason(
        selection,
        reason: af.SelectionUpdateReason.uiEvent,
        extraInfo: {},
      ),
    );
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('rich-selection-menu')), findsOneWidget);
    await tester.pumpWidget(const SizedBox());
    editor.dispose();
  });

  testWidgets('selection menu updates safely when the document lock changes', (
    tester,
  ) async {
    final editor = document('alpha beta');
    await mount(tester, editor);
    tester.view.viewInsets = FakeViewPadding.zero;
    editor.selection = af.Selection.single(
      path: [0],
      startOffset: 0,
      endOffset: 5,
    );
    await tester.pumpAndSettle();
    final oldBold = tester
        .widget<IconButton>(find.byKey(const ValueKey('rich-floating-bold')))
        .onPressed!;
    final original = jsonEncode(editor.document.toJson());
    editor.editable = false;
    oldBold();
    await tester.pump();
    expect(tester.takeException(), isNull);
    await tester.pumpAndSettle();
    expect(jsonEncode(editor.document.toJson()), original);
    expect(find.byKey(const ValueKey('rich-floating-bold')), findsNothing);
    expect(find.byKey(const ValueKey('rich-floating-copy')), findsOneWidget);
    expect(
      tester.getSize(find.byKey(const ValueKey('rich-selection-menu'))).width,
      84,
    );
    editor.editable = true;
    await tester.pump();
    expect(tester.takeException(), isNull);
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('rich-floating-bold')), findsOneWidget);
    expect(
      tester.getSize(find.byKey(const ValueKey('rich-selection-menu'))).width,
      252,
    );
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
    editor.dispose();
  });

  testWidgets('locking closes the active text input connection', (
    tester,
  ) async {
    final editor = document('alpha beta');
    await mount(tester, editor);
    unawaited(
      editor.updateSelectionWithReason(
        af.Selection.single(path: [0], startOffset: 2),
        reason: af.SelectionUpdateReason.uiEvent,
      ),
    );
    await tester.pumpAndSettle();
    expect(tester.testTextInput.isVisible, isTrue);
    editor.editable = false;
    await tester.pumpAndSettle();
    expect(tester.testTextInput.isVisible, isFalse);
    editor.service.keyboardService!.enableKeyBoard(editor.selection!);
    await tester.pump();
    expect(tester.testTextInput.isVisible, isFalse);
    editor.editable = true;
    await tester.pump();
    expect(tester.testTextInput.isVisible, isFalse);
    unawaited(
      editor.updateSelectionWithReason(
        editor.selection,
        reason: af.SelectionUpdateReason.uiEvent,
      ),
    );
    await tester.pumpAndSettle();
    expect(tester.testTextInput.isVisible, isTrue);
    await tester.pumpWidget(const SizedBox());
    editor.dispose();
  });

  testWidgets('read-only keyboard shortcuts preserve undo and allow copy', (
    tester,
  ) async {
    final editor = document('alpha');
    await mount(tester, editor);
    await editor.insertText(5, ' beta', path: [0]);
    await tester.pumpAndSettle();
    expect(editor.undoManager.undoStack.isNonEmpty, isTrue);
    final undoItem = editor.undoManager.undoStack.last;
    final original = jsonEncode(editor.document.toJson());
    editor.editable = false;
    unawaited(
      editor.updateSelectionWithReason(
        af.Selection.single(path: [0], startOffset: 0, endOffset: 5),
        reason: af.SelectionUpdateReason.uiEvent,
      ),
    );
    await tester.pumpAndSettle();
    await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
    await tester.sendKeyEvent(LogicalKeyboardKey.keyZ);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
    await tester.pumpAndSettle();
    expect(editor.undoManager.undoStack.isNonEmpty, isTrue);
    expect(identical(editor.undoManager.undoStack.last, undoItem), isTrue);
    expect(jsonEncode(editor.document.toJson()), original);
    af.AppFlowyClipboard.lastText = null;
    await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
    await tester.sendKeyEvent(LogicalKeyboardKey.keyC);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
    await tester.pumpAndSettle();
    expect(af.AppFlowyClipboard.lastText, 'alpha');
    await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
    await tester.sendKeyEvent(LogicalKeyboardKey.keyA);
    await tester.sendKeyEvent(LogicalKeyboardKey.keyX);
    await tester.sendKeyEvent(LogicalKeyboardKey.keyV);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
    await tester.pumpAndSettle();
    expect(editor.selection!.normalized.end.offset, 10);
    expect(af.AppFlowyClipboard.lastText, 'alpha');
    expect(identical(editor.undoManager.undoStack.last, undoItem), isTrue);
    expect(jsonEncode(editor.document.toJson()), original);
    await tester.pumpWidget(const SizedBox());
    editor.dispose();
  });

  testWidgets('a stale floating command never writes to another selection', (
    tester,
  ) async {
    final editor = document('alpha beta');
    await mount(tester, editor);
    tester.view.viewInsets = FakeViewPadding.zero;
    editor.selection = af.Selection.single(
      path: [0],
      startOffset: 0,
      endOffset: 5,
    );
    await tester.pumpAndSettle();
    final action = tester
        .widget<IconButton>(find.byKey(const ValueKey('rich-floating-bold')))
        .onPressed!;
    final original = jsonEncode(editor.document.toJson());
    editor.selection = af.Selection.single(
      path: [0],
      startOffset: 6,
      endOffset: 10,
    );
    action();
    await tester.pump();
    expect(jsonEncode(editor.document.toJson()), original);
    await tester.pumpWidget(const SizedBox());
    editor.dispose();
  });

  testWidgets(
    'locking while a floating command is pending cannot modify text',
    (tester) async {
      final editor = document('alpha beta');
      await mount(tester, editor);
      tester.view.viewInsets = FakeViewPadding.zero;
      editor.selection = af.Selection.single(
        path: [0],
        startOffset: 0,
        endOffset: 5,
      );
      await tester.pumpAndSettle();
      final action = tester
          .widget<IconButton>(find.byKey(const ValueKey('rich-floating-bold')))
          .onPressed!;
      final original = jsonEncode(editor.document.toJson());
      editor.editable = false;
      action();
      await tester.pump();
      expect(jsonEncode(editor.document.toJson()), original);
      await tester.pumpWidget(const SizedBox());
      editor.dispose();
    },
  );

  testWidgets(
    'floating menu hides on focus loss and with a collapsed selection',
    (tester) async {
      final editor = document('alpha beta');
      await mount(tester, editor);
      tester.view.viewInsets = FakeViewPadding.zero;
      editor.selection = af.Selection.single(
        path: [0],
        startOffset: 0,
        endOffset: 5,
      );
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('rich-selection-menu')), findsOneWidget);
      editor.selection = af.Selection.single(path: [0], startOffset: 2);
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('rich-selection-menu')), findsNothing);
      editor.selection = af.Selection.single(
        path: [0],
        startOffset: 0,
        endOffset: 5,
      );
      await tester.pumpAndSettle();
      tester
          .widget<RichEditorToolbar>(find.byType(RichEditorToolbar))
          .focusNode
          .unfocus();
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('rich-selection-menu')), findsNothing);
      await tester.pumpWidget(const SizedBox());
      editor.dispose();
    },
  );
}
