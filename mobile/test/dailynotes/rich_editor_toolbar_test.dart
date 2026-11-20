import 'dart:async';
import 'dart:convert';

import 'package:appflowy_editor/appflowy_editor.dart' as af;
import 'package:flutter_test/flutter_test.dart';
import 'package:moodiary_di/moodiary_di.dart';
import 'package:moodiary_i18n/moodiary_i18n.dart';
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
      final sheet = find.byType(DraggableScrollableSheet);
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
      await tester.tap(find.byKey(const ValueKey('rich-color-0xffd32f2f')));
      await tester.pumpAndSettle();
      expect(editor.selection, selection);
      expect(jsonEncode(editor.document.toJson()), contains('0xffd32f2f'));
      await tester.tap(find.byTooltip(l10n.dailynotes.editorHighlightColor));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('rich-color-0xffd32f2f')));
      await tester.pumpAndSettle();
      expect(jsonEncode(editor.document.toJson()), contains('0x4dd32f2f'));
      expect(editor.selection, selection);
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
      await tester.tap(find.byKey(const ValueKey('rich-color-0xffd32f2f')));
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
    expect(find.byKey(const ValueKey('rich-color-0xffd32f2f')), findsOneWidget);
    await tester.binding.handlePopRoute();
    await tester.pumpAndSettle();
    expect(find.byType(DraggableScrollableSheet), findsOneWidget);
    expect(find.byKey(const ValueKey('rich-color-0xffd32f2f')), findsNothing);
    expect(find.text('H1'), findsOneWidget);
    await tester.binding.handlePopRoute();
    await tester.pumpAndSettle();
    expect(find.byType(DraggableScrollableSheet), findsNothing);
    expect(editor.selection, selection);
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
    final sheet = find.byType(DraggableScrollableSheet);
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
    final tile = tester.widget<ListTile>(
      find.byKey(const ValueKey('rich-font-Imported Font')),
    );
    expect(tile.onTap, isNull);
    expect(jsonEncode(editor.document.toJson()), original);
    await tester.pumpWidget(const SizedBox());
    editor.dispose();
  });

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

  testWidgets(
    'dragging the Aa handle expands the sheet and reveals covered text',
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
      tester.view.viewInsets = FakeViewPadding.zero;
      scroll.itemScrollController.jumpTo(index: 30, alignment: .4);
      await tester.pumpAndSettle();
      editor.selection = af.Selection.single(
        path: [30],
        startOffset: 0,
        endOffset: 4,
      );
      await tester.pumpAndSettle();
      final before = editor.selectionRects().single;
      await tester.tap(find.byKey(const ValueKey('rich-floating-format')));
      await tester.pumpAndSettle();
      expect(editor.selectionRects().single.top, closeTo(before.top, .1));
      final handle = find.byKey(const ValueKey('rich-format-drag-handle'));
      final sheetTop = tester.getTopLeft(handle).dy;
      await tester.drag(handle, const Offset(0, -220));
      await tester.pumpAndSettle();
      final expandedTop = tester.getTopLeft(handle).dy;
      final after = editor.selectionRects().single;
      expect(expandedTop, lessThan(sheetTop - 100));
      expect(after.bottom, lessThan(expandedTop));
      await tester.drag(handle, const Offset(0, 140));
      await tester.pumpAndSettle();
      expect(tester.getTopLeft(handle).dy, greaterThan(expandedTop + 70));
      expect(editor.selectionRects().single.top, closeTo(after.top, .1));
      await tester.pumpWidget(const SizedBox());
      scroll.dispose();
      editor.dispose();
    },
  );
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
      editor.selectionRects().any((rect) => rect.overlaps(tester.getRect(menu))),
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
      expect(find.byType(DraggableScrollableSheet), findsOneWidget);
      await tester.pumpWidget(const SizedBox());
      editor.dispose();
    },
  );

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
