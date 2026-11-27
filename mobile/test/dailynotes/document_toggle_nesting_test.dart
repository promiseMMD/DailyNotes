import 'dart:convert';

import 'package:appflowy_editor/appflowy_editor.dart' as af;
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:moodiary_mobile/app/dailynotes/editor/document_envelope.dart';
import 'package:moodiary_mobile/app/dailynotes/editor/document_toggle_block.dart';
import 'package:moodiary_mobile/app/dailynotes/editor/document_toggle_model.dart';
import 'package:moodiary_mobile/app/dailynotes/editor/document_toggle_nesting.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  final movableBlocks = <String, af.Node Function(af.Delta)>{
    'paragraph': (delta) => af.paragraphNode(
      delta: delta,
      children: [af.paragraphNode(text: '子内容')],
    ),
    'heading': (delta) => af.headingNode(level: 3, delta: delta),
    'quote': (delta) => af.quoteNode(delta: delta),
    'bulleted list': (delta) => af.bulletedListNode(
      delta: delta,
      children: [af.paragraphNode(text: '子内容')],
    ),
    'numbered list': (delta) => af.numberedListNode(delta: delta, number: 7),
    'checked task': (delta) => af.todoListNode(checked: true, delta: delta),
  };

  for (final entry in movableBlocks.entries) {
    testWidgets('${entry.key} moves into and out of a toggle losslessly', (
      tester,
    ) async {
      final parent = documentToggleNode(
        collapsed: true,
        delta: af.Delta()..insert('父级'),
      );
      final moved = entry.value(
        af.Delta()..insert('内容', attributes: {'bold': true}),
      );
      final beforeNode = jsonEncode(moved.toJson());
      final editor = af.EditorState(
        document: af.Document(root: af.pageNode(children: [parent, moved])),
      );
      final folds = DocumentToggleController();
      final nesting = DocumentToggleNesting(folds);
      editor.selection = af.Selection.single(
        path: [1],
        startOffset: 2,
        endOffset: 0,
      );

      expect(nesting.canIndent(editor), isTrue);
      await nesting.indent(editor);
      expect(parent.children.single, same(moved));
      expect(folds.isCollapsed(parent), isFalse);
      expect(jsonEncode(moved.toJson()), beforeNode);
      expect(editor.selection!.start.path, [0, 0]);
      expect(editor.selection!.start.offset, 2);
      expect(editor.selection!.end.offset, 0);
      final saved = DailyNotesDocumentEnvelope.decode(
        DailyNotesDocumentEnvelope.encode(editor.document),
      );
      expect(
        jsonEncode(saved.root.children.single.children.single.toJson()),
        beforeNode,
      );
      saved.dispose();

      editor.undoManager.undo();
      await tester.pump();
      expect(editor.document.root.children.last, same(moved));
      editor.undoManager.redo();
      await tester.pump();
      expect(parent.children.single, same(moved));
      expect(nesting.canOutdent(editor), isTrue);
      await nesting.outdent(editor);
      expect(editor.document.root.children.last, same(moved));
      expect(jsonEncode(moved.toJson()), beforeNode);
      expect(editor.selection!.start.path, [1]);
      editor.undoManager.undo();
      await tester.pump();
      expect(parent.children.single, same(moved));

      folds.dispose();
      editor.dispose();
    });
  }

  testWidgets('ordinary paragraph indentation stays with the upstream editor', (
    tester,
  ) async {
    final editor = af.EditorState(
      document: af.Document(
        root: af.pageNode(
          children: [
            af.paragraphNode(text: '前文'),
            af.paragraphNode(text: '正文'),
          ],
        ),
      ),
    );
    final folds = DocumentToggleController();
    final nesting = DocumentToggleNesting(folds);
    editor.selection = af.Selection.single(path: [1], startOffset: 1);
    expect(nesting.canIndent(editor), isFalse);
    expect(nesting.shortcuts().first.handler(editor), KeyEventResult.ignored);
    expect(af.isIndentable(editor), isTrue);
    af.indentCommand.execute(editor);
    await tester.pump();
    expect(
      editor.document.root.children.first.children.single.delta!.toPlainText(),
      '正文',
    );
    expect(nesting.canOutdent(editor), isFalse);
    expect(nesting.shortcuts().last.handler(editor), KeyEventResult.ignored);
    expect(af.isOutdentable(editor), isTrue);
    af.outdentCommand.execute(editor);
    await tester.pump();
    expect(editor.document.root.children.last.delta!.toPlainText(), '正文');
    folds.dispose();
    editor.dispose();
  });

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
