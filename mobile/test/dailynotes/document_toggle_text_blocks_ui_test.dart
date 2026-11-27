// The app still uses this bridge during its Material migration.
// ignore_for_file: deprecated_member_use

import 'dart:convert';

import 'package:appflowy_editor/appflowy_editor.dart' as af;
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:moodiary_di/moodiary_di.dart';
import 'package:moodiary_i18n/moodiary_i18n.dart';
import 'package:moodiary_mobile/app/dailynotes/editor/document_canvas.dart';
import 'package:moodiary_mobile/app/dailynotes/editor/document_toggle_model.dart';
import 'package:moodiary_storage/moodiary_storage.dart';
import 'package:moodiary_storage/testing.dart';
import 'package:mui/mui.dart';

void main() {
  setUpAll(() async {
    await setupPluralResolvers();
    await LocaleSettings.setLocale(AppLocale.zh);
  });
  setUp(() => getIt.registerSingleton<IKVStorage>(MemoryKVStorage()));
  tearDown(() => getIt.reset());

  final factories = <String, af.Node Function()>{
    'heading': () => af.headingNode(level: 2, text: '正文'),
    'quote': () => af.quoteNode(delta: af.Delta()..insert('正文')),
    'bulleted list': () => af.bulletedListNode(text: '正文'),
    'numbered list': () =>
        af.numberedListNode(delta: af.Delta()..insert('正文'), number: 2),
    'checked task': () => af.todoListNode(checked: true, text: '正文'),
  };

  for (final entry in factories.entries) {
    testWidgets('${entry.key} renders across toggle moves and undo', (
      tester,
    ) async {
      final parent = documentToggleNode(
        collapsed: true,
        delta: af.Delta()..insert('父级'),
      );
      final moved = entry.value();
      final before = jsonEncode(moved.toJson());
      final editor = af.EditorState(
        document: af.Document(root: af.pageNode(children: [parent, moved])),
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
              body: DailyNotesDocumentCanvas(
                editor: editor,
                focusNode: focus,
                scrollController: scroll,
                editable: true,
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      focus.requestFocus();
      editor.selection = af.Selection.single(path: [1], startOffset: 1);
      await tester.pumpAndSettle();
      await tester.sendKeyEvent(LogicalKeyboardKey.tab);
      await tester.pumpAndSettle();
      expect(parent.children.single, same(moved));
      expect(moved.key.currentContext, isNotNull);
      expect(jsonEncode(moved.toJson()), before);

      await tester.sendKeyDownEvent(LogicalKeyboardKey.shiftLeft);
      await tester.sendKeyEvent(LogicalKeyboardKey.tab);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.shiftLeft);
      await tester.pumpAndSettle();
      expect(editor.document.root.children.last, same(moved));
      expect(moved.key.currentContext, isNotNull);
      expect(jsonEncode(moved.toJson()), before);
      editor.undoManager.undo();
      await tester.pumpAndSettle();
      expect(parent.children.single, same(moved));
      expect(moved.key.currentContext, isNotNull);
      editor.undoManager.redo();
      await tester.pumpAndSettle();
      expect(editor.document.root.children.last, same(moved));
      expect(moved.key.currentContext, isNotNull);
      expect(tester.takeException(), isNull);
    });
  }
}
