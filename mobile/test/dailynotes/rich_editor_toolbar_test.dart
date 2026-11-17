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
              child: af.AppFlowyEditor(
                editorState: editor,
                editable: editable,
                focusNode: focus,
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
    await tester.tap(find.byKey(const ValueKey('rich-toolbar-color')));
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
    expect(find.byKey(const ValueKey('rich-toolbar-insert')), findsNothing);
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
    await tester.ensureVisible(find.byKey(const ValueKey('rich-toolbar-undo')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('rich-toolbar-undo')));
    await tester.pumpAndSettle();
    expect(
      editor.document.root.children.single.type,
      af.ParagraphBlockKeys.type,
    );
    await tester.ensureVisible(find.byKey(const ValueKey('rich-toolbar-redo')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('rich-toolbar-redo')));
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
    await tester.tap(find.byKey(const ValueKey('rich-toolbar-format')));
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
}
