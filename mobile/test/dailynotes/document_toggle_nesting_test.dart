import 'dart:convert';

import 'package:appflowy_editor/appflowy_editor.dart' as af;
import 'package:flutter_test/flutter_test.dart';
import 'package:moodiary_mobile/app/dailynotes/editor/document_envelope.dart';
import 'package:moodiary_mobile/app/dailynotes/editor/document_toggle_block.dart';
import 'package:moodiary_mobile/app/dailynotes/editor/document_toggle_model.dart';
import 'package:moodiary_mobile/app/dailynotes/editor/document_toggle_nesting.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  testWidgets(
    'indent and outdent preserve the live subtree, selection and undo',
    (tester) async {
      final first = documentToggleNode(
        collapsed: true,
        delta: af.Delta()..insert('父级'),
        children: [af.paragraphNode(text: '已有内容')],
      );
      final child = af.paragraphNode(text: '保留子内容');
      final second = documentToggleNode(
        level: 2,
        delta: af.Delta()..insert('待移动'),
        children: [child],
      );
      final editor = af.EditorState(
        document: af.Document(root: af.pageNode(children: [first, second])),
      );
      final folds = DocumentToggleController();
      final nesting = DocumentToggleNesting(folds);
      final before = jsonEncode(editor.document.toJson());
      folds.setCollapsed(second, true);
      editor.selection = af.Selection.single(
        path: [1],
        startOffset: 3,
        endOffset: 1,
      );
      expect(nesting.canIndent(editor), isTrue);
      await nesting.indent(editor);
      expect(editor.document.root.children, hasLength(1));
      expect(first.children.last, same(second));
      expect(second.children.single, same(child));
      expect(folds.isCollapsed(first), isFalse);
      expect(folds.isCollapsed(second), isTrue);
      expect(editor.selection!.start.path, [0, 1]);
      expect(editor.selection!.start.offset, 3);
      expect(editor.selection!.end.offset, 1);
      expect(nesting.canOutdent(editor), isTrue);
      editor.undoManager.undo();
      await tester.pump();
      expect(jsonEncode(editor.document.toJson()), before);
      expect(editor.document.root.children.last, same(second));
      editor.undoManager.redo();
      await tester.pump();
      expect(first.children.last, same(second));
      await nesting.outdent(editor);
      expect(editor.document.root.children.last, same(second));
      expect(second.children.single, same(child));
      expect(editor.selection!.start.path, [1]);
      editor.undoManager.undo();
      await tester.pump();
      expect(first.children.last, same(second));
      folds.dispose();
      editor.dispose();
    },
  );

  test(
    'invalid, locked and cross-block selections never move a toggle',
    () async {
      final first = af.headingNode(level: 1, text: '非容器');
      final second = documentToggleNode(delta: af.Delta()..insert('标题'));
      final editor = af.EditorState(
        document: af.Document(root: af.pageNode(children: [first, second])),
      );
      final folds = DocumentToggleController();
      final nesting = DocumentToggleNesting(folds);
      final before = jsonEncode(editor.document.toJson());
      editor.selection = af.Selection.single(path: [1], startOffset: 0);
      expect(nesting.canIndent(editor), isFalse);
      expect(nesting.canOutdent(editor), isFalse);
      await nesting.indent(editor);
      editor.editable = false;
      expect(nesting.canOutdent(editor), isFalse);
      editor.editable = true;
      editor.selection = af.Selection(
        start: af.Position(path: [0], offset: 0),
        end: af.Position(path: [1], offset: 0),
      );
      expect(nesting.canIndent(editor), isFalse);
      await nesting.outdent(editor);
      expect(jsonEncode(editor.document.toJson()), before);
      folds.dispose();
      editor.dispose();
    },
  );

  test('indent stops before exceeding the document serialization depth', () {
    var foundBoundary = false;
    for (var count = 20; count < 35; count++) {
      af.Node child = af.paragraphNode(text: '末尾');
      for (var i = 0; i < count; i++) {
        child = af.paragraphNode(text: '层', children: [child]);
      }
      final target = documentToggleNode(
        delta: af.Delta()..insert('章节'),
        children: [child],
      );
      final editor = af.EditorState(
        document: af.Document(
          root: af.pageNode(
            children: [
              af.paragraphNode(text: '前文'),
              target,
            ],
          ),
        ),
      );
      final folds = DocumentToggleController();
      final nesting = DocumentToggleNesting(folds);
      editor.selection = af.Selection.single(path: [1], startOffset: 0);
      try {
        DailyNotesDocumentEnvelope.encode(editor.document);
        if (!nesting.canIndent(editor)) foundBoundary = true;
      } on FormatException {
        // Only test documents that can already be saved.
      }
      folds.dispose();
      editor.dispose();
      if (foundBoundary) break;
    }
    expect(foundBoundary, isTrue);
  });
}
