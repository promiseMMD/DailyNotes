import 'package:appflowy_editor/appflowy_editor.dart' as af;
import 'package:flutter_test/flutter_test.dart';
import 'package:moodiary_di/moodiary_di.dart';
import 'package:moodiary_i18n/moodiary_i18n.dart';
import 'package:moodiary_mobile/app/dailynotes/editor/document_history_actions.dart';
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

  af.EditorState document() => af.EditorState(
    document: af.Document(root: af.pageNode(children: [af.paragraphNode()])),
  );

  Widget app(
    af.EditorState editor, {
    bool editable = true,
    bool Function()? canEdit,
  }) => TranslationProvider(
    child: MaterialApp(
      theme: buildMuiTheme(brightness: Brightness.light),
      localizationsDelegates: const [
        af.AppFlowyEditorLocalizations.delegate,
        ...GlobalMaterialLocalizations.delegates,
        GlobalMuiLocalizations.delegate,
      ],
      builder: (context, child) => MaterialUiCompatibilityBridge(child: child!),
      home: Scaffold(
        appBar: AppBar(
          actions: [
            DocumentHistoryActions(
              editor: editor,
              editable: editable,
              canEdit: canEdit,
            ),
          ],
        ),
      ),
    ),
  );

  testWidgets('top actions undo and redo and react to history updates', (
    tester,
  ) async {
    final editor = document();
    await tester.pumpWidget(app(editor));
    expect(
      tester
          .widget<IconButton>(find.byKey(const ValueKey('document-top-undo')))
          .onPressed,
      isNull,
    );
    await editor.insertText(0, 'text', path: [0]);
    await tester.pumpAndSettle();
    expect(
      tester
          .widget<IconButton>(find.byKey(const ValueKey('document-top-undo')))
          .onPressed,
      isNotNull,
    );
    await tester.tap(find.byKey(const ValueKey('document-top-undo')));
    await tester.pumpAndSettle();
    expect(editor.document.root.children.single.delta!.toPlainText(), isEmpty);
    expect(
      tester
          .widget<IconButton>(find.byKey(const ValueKey('document-top-redo')))
          .onPressed,
      isNotNull,
    );
    await tester.tap(find.byKey(const ValueKey('document-top-redo')));
    await tester.pumpAndSettle();
    expect(editor.document.root.children.single.delta!.toPlainText(), 'text');
    await tester.pumpWidget(const SizedBox());
    editor.dispose();
  });

  testWidgets('a lock after build never consumes undo history', (tester) async {
    final editor = document();
    var allow = true;
    await tester.pumpWidget(app(editor, canEdit: () => allow));
    await editor.insertText(0, 'saved', path: [0]);
    await tester.pumpAndSettle();
    final callback = tester
        .widget<IconButton>(find.byKey(const ValueKey('document-top-undo')))
        .onPressed!;
    allow = false;
    callback();
    await tester.pump();
    expect(editor.undoManager.undoStack.isNonEmpty, isTrue);
    expect(editor.document.root.children.single.delta!.toPlainText(), 'saved');
    allow = true;
    await tester.pumpWidget(app(editor, editable: false, canEdit: () => allow));
    expect(
      tester
          .widget<IconButton>(find.byKey(const ValueKey('document-top-undo')))
          .onPressed,
      isNull,
    );
    await tester.pumpWidget(const SizedBox());
    editor.dispose();
  });

  testWidgets(
    'switching editors cancels stale callbacks and follows new history',
    (tester) async {
      final first = document();
      final second = document();
      await tester.pumpWidget(app(first));
      await first.insertText(0, 'first', path: [0]);
      await tester.pumpAndSettle();
      final stale = tester
          .widget<IconButton>(find.byKey(const ValueKey('document-top-undo')))
          .onPressed!;
      await tester.pumpWidget(app(second));
      stale();
      await tester.pumpAndSettle();
      expect(first.document.root.children.single.delta!.toPlainText(), 'first');
      expect(first.undoManager.undoStack.isNonEmpty, isTrue);
      expect(
        tester
            .widget<IconButton>(find.byKey(const ValueKey('document-top-undo')))
            .onPressed,
        isNull,
      );
      await second.insertText(0, 'second', path: [0]);
      await tester.pumpAndSettle();
      expect(
        tester
            .widget<IconButton>(find.byKey(const ValueKey('document-top-undo')))
            .onPressed,
        isNotNull,
      );
      await tester.pumpWidget(const SizedBox());
      first.dispose();
      second.dispose();
    },
  );

  testWidgets('unlock refreshes after editor becomes editable later in frame', (
    tester,
  ) async {
    final editor = document();
    await editor.insertText(0, 'text', path: [0]);
    editor.editable = false;
    await tester.pumpWidget(app(editor, editable: false));
    expect(
      tester
          .widget<IconButton>(find.byKey(const ValueKey('document-top-undo')))
          .onPressed,
      isNull,
    );
    // The history actions rebuild first; the editor canvas applies its flag
    // later. No transaction or further parent state change occurs.
    await tester.pumpWidget(app(editor, editable: true));
    editor.editable = true;
    await tester.pump();
    expect(
      tester
          .widget<IconButton>(find.byKey(const ValueKey('document-top-undo')))
          .onPressed,
      isNotNull,
    );
    await tester.pumpWidget(const SizedBox());
    editor.dispose();
  });
}
