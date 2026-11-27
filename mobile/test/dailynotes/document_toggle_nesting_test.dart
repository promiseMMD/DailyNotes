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

  testWidgets('move sibling blocks together and preserve order and selection', (
    tester,
  ) async {
    final existing = af.paragraphNode(text: '已有');
    final parent = documentToggleNode(
      collapsed: true,
      delta: af.Delta()..insert('父级'),
      children: [existing],
    );
    final child = af.paragraphNode(text: '段落子内容');
    final paragraph = af.paragraphNode(
      delta: af.Delta()..insert('段落', attributes: {'bold': true}),
      children: [child],
    );
    final heading = af.headingNode(level: 2, text: '小节');
    final toggle = documentToggleNode(
      delta: af.Delta()..insert('折叠块'),
      children: [af.paragraphNode(text: '折叠子内容')],
    );
    final tail = af.paragraphNode(text: '后文');
    final editor = af.EditorState(
      document: af.Document(
        root: af.pageNode(children: [parent, paragraph, heading, toggle, tail]),
      ),
    );
    final folds = DocumentToggleController();
    final nesting = DocumentToggleNesting(folds);
    final before = jsonEncode(editor.document.toJson());
    editor.selection = af.Selection(
      start: af.Position(path: [3], offset: 2),
      end: af.Position(path: [1], offset: 1),
    );

    expect(nesting.canIndent(editor), isTrue);
    await nesting.indent(editor);
    expect(editor.document.root.children, [parent, tail]);
    expect(parent.children, [existing, paragraph, heading, toggle]);
    expect(paragraph.children.single, same(child));
    expect(folds.isCollapsed(parent), isFalse);
    expect(editor.selection!.start.path, [0, 3]);
    expect(editor.selection!.start.offset, 2);
    expect(editor.selection!.end.path, [0, 1]);
    expect(editor.selection!.end.offset, 1);
    final saved = DailyNotesDocumentEnvelope.decode(
      DailyNotesDocumentEnvelope.encode(editor.document),
    );
    expect(jsonEncode(saved.toJson()), jsonEncode(editor.document.toJson()));
    saved.dispose();

    editor.undoManager.undo();
    await tester.pump();
    expect(jsonEncode(editor.document.toJson()), before);
    expect(editor.document.root.children, [
      parent,
      paragraph,
      heading,
      toggle,
      tail,
    ]);
    editor.undoManager.redo();
    await tester.pump();
    expect(parent.children, [existing, paragraph, heading, toggle]);
    expect(nesting.canOutdent(editor), isTrue);
    await nesting.outdent(editor);
    expect(editor.document.root.children, [
      parent,
      paragraph,
      heading,
      toggle,
      tail,
    ]);
    expect(parent.children, [existing]);
    expect(editor.selection!.start.path, [3]);
    expect(editor.selection!.end.path, [1]);
    expect(editor.selection!.start.offset, 2);
    expect(editor.selection!.end.offset, 1);
    editor.undoManager.undo();
    await tester.pump();
    expect(parent.children, [existing, paragraph, heading, toggle]);
    editor.undoManager.redo();
    await tester.pump();
    expect(editor.document.root.children, [
      parent,
      paragraph,
      heading,
      toggle,
      tail,
    ]);
    folds.dispose();
    editor.dispose();
  });

  testWidgets('batch moves preserve paths inside a nested container', (
    tester,
  ) async {
    final parent = documentToggleNode(delta: af.Delta()..insert('父级'));
    final first = af.paragraphNode(text: '第一');
    final second = af.todoListNode(checked: true, text: '第二');
    final outer = af.paragraphNode(
      text: '外层',
      children: [parent, first, second],
    );
    final editor = af.EditorState(
      document: af.Document(root: af.pageNode(children: [outer])),
    );
    final folds = DocumentToggleController();
    final nesting = DocumentToggleNesting(folds);
    editor.selection = af.Selection(
      start: af.Position(path: [0, 1], offset: 1),
      end: af.Position(path: [0, 2], offset: 2),
    );
    expect(nesting.canIndent(editor), isTrue);
    await nesting.indent(editor);
    expect(outer.children, [parent]);
    expect(parent.children, [first, second]);
    expect(editor.selection!.start.path, [0, 0, 0]);
    expect(editor.selection!.end.path, [0, 0, 1]);
    expect(nesting.canOutdent(editor), isTrue);
    await nesting.outdent(editor);
    expect(outer.children, [parent, first, second]);
    expect(editor.selection!.start.path, [0, 1]);
    expect(editor.selection!.end.path, [0, 2]);
    editor.undoManager.undo();
    await tester.pump();
    expect(parent.children, [first, second]);
    folds.dispose();
    editor.dispose();
  });

  test(
    'reject outdent of a middle range instead of reordering siblings',
    () async {
      final parent = documentToggleNode(
        delta: af.Delta()..insert('父级'),
        children: [
          af.paragraphNode(text: '之前'),
          documentToggleNode(delta: af.Delta()..insert('选中一')),
          af.paragraphNode(text: '选中二'),
          af.paragraphNode(text: '之后'),
        ],
      );
      final editor = af.EditorState(
        document: af.Document(root: af.pageNode(children: [parent])),
      );
      final folds = DocumentToggleController();
      final nesting = DocumentToggleNesting(folds);
      editor.selection = af.Selection(
        start: af.Position(path: [0, 1], offset: 1),
        end: af.Position(path: [0, 2], offset: 2),
      );
      final before = jsonEncode(editor.document.toJson());
      expect(nesting.canOutdent(editor), isFalse);
      expect(nesting.shortcuts().last.handler(editor), KeyEventResult.handled);
      await nesting.outdent(editor);
      expect(jsonEncode(editor.document.toJson()), before);
      folds.dispose();
      editor.dispose();
    },
  );

  test('cross-level selections touching a toggle cannot use SDK fallback', () {
    final parent = documentToggleNode(
      delta: af.Delta()..insert('父级'),
      children: [
        af.paragraphNode(text: '前一个子块'),
        af.paragraphNode(text: '选中子块'),
      ],
    );
    final editor = af.EditorState(
      document: af.Document(
        root: af.pageNode(
          children: [
            parent,
            af.paragraphNode(text: '后文'),
          ],
        ),
      ),
    );
    final folds = DocumentToggleController();
    final nesting = DocumentToggleNesting(folds);
    editor.selection = af.Selection(
      start: af.Position(path: [0, 1], offset: 1),
      end: af.Position(path: [1], offset: 1),
    );
    final before = jsonEncode(editor.document.toJson());
    expect(nesting.canIndent(editor), isFalse);
    expect(nesting.canOutdent(editor), isFalse);
    expect(nesting.blocksUnsafeFallback(editor), isTrue);
    expect(af.isIndentable(editor), isTrue);
    expect(nesting.shortcuts().first.handler(editor), KeyEventResult.handled);
    expect(nesting.shortcuts().last.handler(editor), KeyEventResult.handled);
    expect(jsonEncode(editor.document.toJson()), before);
    folds.dispose();
    editor.dispose();
  });

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

  test('one too-deep subtree prevents the whole batch from moving', () async {
    var foundBoundary = false;
    for (var count = 20; count < 35; count++) {
      af.Node child = af.paragraphNode(text: '末尾');
      for (var i = 0; i < count; i++) {
        child = af.paragraphNode(text: '层', children: [child]);
      }
      final parent = documentToggleNode(delta: af.Delta()..insert('父级'));
      final shallow = af.paragraphNode(text: '浅层');
      final deep = documentToggleNode(
        delta: af.Delta()..insert('深层'),
        children: [child],
      );
      final editor = af.EditorState(
        document: af.Document(
          root: af.pageNode(children: [parent, shallow, deep]),
        ),
      );
      final folds = DocumentToggleController();
      final nesting = DocumentToggleNesting(folds);
      editor.selection = af.Selection(
        start: af.Position(path: [1], offset: 1),
        end: af.Position(path: [2], offset: 1),
      );
      try {
        DailyNotesDocumentEnvelope.encode(editor.document);
        if (!nesting.canIndent(editor)) {
          final before = jsonEncode(editor.document.toJson());
          await nesting.indent(editor);
          expect(jsonEncode(editor.document.toJson()), before);
          foundBoundary = true;
        }
      } on FormatException {
        // The original document must still be serializable.
      }
      folds.dispose();
      editor.dispose();
      if (foundBoundary) break;
    }
    expect(foundBoundary, isTrue);
  });
}
