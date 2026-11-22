import 'dart:async';
import 'dart:convert';

import 'package:appflowy_editor/appflowy_editor.dart' as af;
import 'package:flutter_test/flutter_test.dart';
import 'package:moodiary_mobile/app/dailynotes/editor/plain_text_clipboard.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  af.EditorState document(af.Delta delta) => af.EditorState(
    document: af.Document(
      root: af.pageNode(children: [af.paragraphNode(delta: delta)]),
    ),
  );

  af.Selection select(af.EditorState editor, int start, int end) {
    final selection = af.Selection.single(
      path: [0],
      startOffset: start,
      endOffset: end,
    );
    editor.selection = selection;
    return selection;
  }

  String body(af.EditorState editor) =>
      editor.document.root.children.single.delta!.toPlainText();

  test(
    'cut copies before deleting and undo restores the selected text',
    () async {
      final editor = document(af.Delta()..insert('alpha beta'));
      final selection = select(editor, 0, 5);
      String? copied;
      final service = PlainTextClipboardEditor(
        readText: () async => null,
        writeText: (text) async => copied = text,
      );
      final result = await service.cut(
        editor: editor,
        selection: selection,
        canApply: () => true,
        contextRevision: () => 0,
      );
      expect(result, PlainTextClipboardResult.applied);
      expect(copied, 'alpha');
      expect(body(editor), ' beta');
      expect(editor.selection!.isCollapsed, isTrue);
      editor.undoManager.undo();
      await Future<void>.delayed(Duration.zero);
      expect(body(editor), 'alpha beta');
      editor.dispose();
    },
  );

  test(
    'cut refuses formatted text rather than losing its formatting',
    () async {
      final editor = document(
        af.Delta()
          ..insert('bold', attributes: {af.AppFlowyRichTextKeys.bold: true})
          ..insert(' plain'),
      );
      final original = jsonEncode(editor.document.toJson());
      final selection = select(editor, 0, 4);
      var writes = 0;
      final service = PlainTextClipboardEditor(
        readText: () async => null,
        writeText: (_) async => writes++,
      );
      final result = await service.cut(
        editor: editor,
        selection: selection,
        canApply: () => true,
        contextRevision: () => 0,
      );
      expect(result, PlainTextClipboardResult.unsupportedFormatting);
      expect(writes, 0);
      expect(jsonEncode(editor.document.toJson()), original);
      editor.dispose();
    },
  );

  test('clipboard write failure never deletes the selected text', () async {
    final editor = document(af.Delta()..insert('alpha beta'));
    final selection = select(editor, 0, 5);
    final service = PlainTextClipboardEditor(
      readText: () async => null,
      writeText: (_) async => throw StateError('clipboard'),
    );
    expect(
      await service.cut(
        editor: editor,
        selection: selection,
        canApply: () => true,
        contextRevision: () => 0,
      ),
      PlainTextClipboardResult.clipboardFailed,
    );
    expect(body(editor), 'alpha beta');
    expect(editor.undoManager.undoStack.isEmpty, isTrue);
    editor.dispose();
  });

  test(
    'cut expires when selection changes away and back during copying',
    () async {
      final editor = document(af.Delta()..insert('alpha beta'));
      final selection = select(editor, 0, 5);
      final write = Completer<void>();
      final service = PlainTextClipboardEditor(
        readText: () async => null,
        writeText: (_) => write.future,
      );
      final operation = service.cut(
        editor: editor,
        selection: selection,
        canApply: () => true,
        contextRevision: () => 0,
      );
      select(editor, 6, 10);
      editor.selection = selection;
      write.complete();
      expect(await operation, PlainTextClipboardResult.stale);
      expect(body(editor), 'alpha beta');
      editor.dispose();
    },
  );

  test(
    'cut expires when the editor is locked and unlocked while copying',
    () async {
      final editor = document(af.Delta()..insert('alpha beta'));
      final selection = select(editor, 0, 5);
      final write = Completer<void>();
      final service = PlainTextClipboardEditor(
        readText: () async => null,
        writeText: (_) => write.future,
      );
      final operation = service.cut(
        editor: editor,
        selection: selection,
        canApply: () => true,
        contextRevision: () => 0,
      );
      editor.editable = false;
      editor.editable = true;
      write.complete();
      expect(await operation, PlainTextClipboardResult.stale);
      expect(body(editor), 'alpha beta');
      editor.dispose();
    },
  );

  test(
    'paste replaces the selection as one independently undoable edit',
    () async {
      final editor = document(af.Delta()..insert('alpha beta'));
      final selection = select(editor, 0, 5);
      final service = PlainTextClipboardEditor(
        readText: () async => 'new',
        writeText: (_) async {},
      );
      final result = await service.paste(
        editor: editor,
        selection: selection,
        canApply: () => true,
        contextRevision: () => 0,
      );
      expect(result, PlainTextClipboardResult.applied);
      expect(body(editor), 'new beta');
      expect(editor.selection!.isCollapsed, isTrue);
      expect(editor.selection!.start.offset, 3);
      editor.undoManager.undo();
      await Future<void>.delayed(Duration.zero);
      expect(body(editor), 'alpha beta');
      editor.dispose();
    },
  );

  test('paste preserves untouched rich text on both sides and undo', () async {
    final editor = document(
      af.Delta()
        ..insert('ab', attributes: {af.AppFlowyRichTextKeys.bold: true})
        ..insert('cd')
        ..insert('ef', attributes: {af.AppFlowyRichTextKeys.italic: true}),
    );
    final original = jsonEncode(editor.document.toJson());
    final selection = select(editor, 2, 4);
    final service = PlainTextClipboardEditor(
      readText: () async => 'X',
      writeText: (_) async {},
    );
    expect(
      await service.paste(
        editor: editor,
        selection: selection,
        canApply: () => true,
        contextRevision: () => 0,
      ),
      PlainTextClipboardResult.applied,
    );
    expect(body(editor), 'abXef');
    final encoded = jsonEncode(editor.document.toJson());
    expect(encoded, contains('"bold":true'));
    expect(encoded, contains('"italic":true'));
    editor.undoManager.undo();
    await Future<void>.delayed(Duration.zero);
    expect(jsonEncode(editor.document.toJson()), original);
    editor.dispose();
  });

  test(
    'paste rejects empty or unsupported separators without deletion',
    () async {
      final editor = document(af.Delta()..insert('alpha beta'));
      final selection = select(editor, 0, 5);
      var clipboard = '';
      final service = PlainTextClipboardEditor(
        readText: () async => clipboard,
        writeText: (_) async {},
      );
      Future<PlainTextClipboardResult> paste() => service.paste(
        editor: editor,
        selection: selection,
        canApply: () => true,
        contextRevision: () => 0,
      );
      expect(await paste(), PlainTextClipboardResult.emptyClipboard);
      clipboard = 'one\u2028two';
      expect(await paste(), PlainTextClipboardResult.unsupportedText);
      expect(body(editor), 'alpha beta');
      expect(editor.undoManager.undoStack.isEmpty, isTrue);
      editor.dispose();
    },
  );

  test(
    'multi-line paste preserves rich suffix and undoes atomically',
    () async {
      final editor = document(
        af.Delta()
          ..insert('begin erase')
          ..insert('END', attributes: {af.AppFlowyRichTextKeys.italic: true}),
      );
      final original = jsonEncode(editor.document.toJson());
      final selection = select(editor, 6, 11);
      final service = PlainTextClipboardEditor(
        readText: () async => 'X\nY',
        writeText: (_) async {},
      );
      expect(
        await service.paste(
          editor: editor,
          selection: selection,
          canApply: () => true,
          contextRevision: () => 0,
        ),
        PlainTextClipboardResult.applied,
      );
      final nodes = editor.document.root.children.toList();
      expect(nodes.map((node) => node.delta!.toPlainText()), [
        'begin X',
        'YEND',
      ]);
      expect(jsonEncode(nodes.last.toJson()), contains('"italic":true'));
      expect(editor.selection!.isCollapsed, isTrue);
      expect(editor.selection!.start.path, [1]);
      expect(editor.selection!.start.offset, 1);
      final pasted = jsonEncode(editor.document.toJson());
      editor.undoManager.undo();
      await Future<void>.delayed(Duration.zero);
      expect(jsonEncode(editor.document.toJson()), original);
      editor.undoManager.redo();
      await Future<void>.delayed(Duration.zero);
      expect(jsonEncode(editor.document.toJson()), pasted);
      editor.dispose();
    },
  );

  test(
    'multi-line paste preserves blank lines, emoji and trailing spaces',
    () async {
      final editor = document(af.Delta()..insert('prefix suffix'));
      final selection = select(editor, 6, 6);
      final service = PlainTextClipboardEditor(
        readText: () async => '😄\r\n\r\n末 \r',
        writeText: (_) async {},
      );
      expect(
        await service.paste(
          editor: editor,
          selection: selection,
          canApply: () => true,
          contextRevision: () => 0,
        ),
        PlainTextClipboardResult.applied,
      );
      final nodes = editor.document.root.children.toList();
      expect(nodes.map((node) => node.delta!.toPlainText()).toList(), [
        'prefix😄',
        '',
        '末 ',
        ' suffix',
      ]);
      expect(editor.selection!.start.path, [3]);
      expect(editor.selection!.start.offset, 0);
      editor.dispose();
    },
  );

  test(
    'multi-line paste refuses blocks with children or extra metadata',
    () async {
      for (final node in [
        af.paragraphNode(
          text: 'alpha beta',
          children: [af.paragraphNode(text: 'nested')],
        ),
        af.paragraphNode(
          text: 'alpha beta',
          attributes: {'future': 'preserve'},
        ),
        af.headingNode(level: 1, text: 'alpha beta'),
      ]) {
        final editor = af.EditorState(
          document: af.Document(root: af.pageNode(children: [node])),
        );
        final original = jsonEncode(editor.document.toJson());
        final selection = select(editor, 0, 5);
        final service = PlainTextClipboardEditor(
          readText: () async => 'one\ntwo',
          writeText: (_) async {},
        );
        expect(
          await service.paste(
            editor: editor,
            selection: selection,
            canApply: () => true,
            contextRevision: () => 0,
          ),
          PlainTextClipboardResult.unsupportedText,
        );
        expect(jsonEncode(editor.document.toJson()), original);
        expect(editor.undoManager.undoStack.isEmpty, isTrue);
        editor.dispose();
      }
    },
  );

  test(
    'paste expires if the UI context changes away and back during reading',
    () async {
      final editor = document(af.Delta()..insert('alpha beta'));
      final selection = select(editor, 0, 5);
      final read = Completer<String?>();
      var contextRevision = 0;
      var canApply = true;
      final service = PlainTextClipboardEditor(
        readText: () => read.future,
        writeText: (_) async {},
      );
      final operation = service.paste(
        editor: editor,
        selection: selection,
        canApply: () => canApply,
        contextRevision: () => contextRevision,
      );
      canApply = false;
      contextRevision++;
      canApply = true;
      contextRevision++;
      read.complete('new');
      expect(await operation, PlainTextClipboardResult.stale);
      expect(body(editor), 'alpha beta');
      editor.dispose();
    },
  );

  test(
    'paste expires if document changes while clipboard reading is pending',
    () async {
      final editor = document(af.Delta()..insert('alpha beta'));
      final selection = select(editor, 0, 5);
      final read = Completer<String?>();
      final service = PlainTextClipboardEditor(
        readText: () => read.future,
        writeText: (_) async {},
      );
      final operation = service.paste(
        editor: editor,
        selection: selection,
        canApply: () => true,
        contextRevision: () => 0,
      );
      await editor.insertText(10, '!', path: [0]);
      editor.selection = selection;
      read.complete('new');
      expect(await operation, PlainTextClipboardResult.stale);
      expect(body(editor), 'alpha beta!');
      editor.dispose();
    },
  );

  test('a disposed editor cannot receive a late clipboard result', () async {
    final editor = document(af.Delta()..insert('alpha beta'));
    final selection = select(editor, 0, 5);
    final read = Completer<String?>();
    final service = PlainTextClipboardEditor(
      readText: () => read.future,
      writeText: (_) async {},
    );
    final operation = service.paste(
      editor: editor,
      selection: selection,
      canApply: () => true,
      contextRevision: () => 0,
    );
    editor.dispose();
    read.complete('new');
    expect(await operation, PlainTextClipboardResult.stale);
  });

  test(
    'paste will not read the clipboard while the input context is unsafe',
    () async {
      final editor = document(af.Delta()..insert('alpha beta'));
      final selection = select(editor, 0, 5);
      var reads = 0;
      final service = PlainTextClipboardEditor(
        readText: () async {
          reads++;
          return 'new';
        },
        writeText: (_) async {},
      );
      expect(
        await service.paste(
          editor: editor,
          selection: selection,
          canApply: () => false,
          contextRevision: () => 0,
        ),
        PlainTextClipboardResult.stale,
      );
      expect(reads, 0);
      expect(body(editor), 'alpha beta');
      editor.dispose();
    },
  );

  test('paste isolates undo from edits made immediately before it', () async {
    final editor = document(af.Delta()..insert('alpha'));
    await editor.insertText(5, '!', path: [0]);
    final selection = select(editor, 6, 6);
    final service = PlainTextClipboardEditor(
      readText: () async => 'X',
      writeText: (_) async {},
    );
    expect(
      await service.paste(
        editor: editor,
        selection: selection,
        canApply: () => true,
        contextRevision: () => 0,
      ),
      PlainTextClipboardResult.applied,
    );
    expect(body(editor), 'alpha!X');
    editor.undoManager.undo();
    await Future<void>.delayed(Duration.zero);
    expect(body(editor), 'alpha!');
    editor.undoManager.undo();
    await Future<void>.delayed(Duration.zero);
    expect(body(editor), 'alpha');
    editor.dispose();
  });

  test(
    'a timed-out clipboard write cannot later delete the source text',
    () async {
      final editor = document(af.Delta()..insert('alpha beta'));
      final selection = select(editor, 0, 5);
      final write = Completer<void>();
      final service = PlainTextClipboardEditor(
        readText: () async => null,
        writeText: (_) => write.future,
        timeout: const Duration(milliseconds: 10),
      );
      expect(
        await service.cut(
          editor: editor,
          selection: selection,
          canApply: () => true,
          contextRevision: () => 0,
        ),
        PlainTextClipboardResult.clipboardFailed,
      );
      write.complete();
      await Future<void>.delayed(Duration.zero);
      expect(body(editor), 'alpha beta');
      expect(editor.undoManager.undoStack.isEmpty, isTrue);
      editor.dispose();
    },
  );

  test(
    'multi-line paste preserves preceding and following sibling blocks',
    () async {
      final editor = af.EditorState(
        document: af.Document(
          root: af.pageNode(
            children: [
              af.paragraphNode(text: 'before'),
              af.paragraphNode(text: 'target'),
              af.paragraphNode(text: 'after'),
            ],
          ),
        ),
      );
      final original = jsonEncode(editor.document.toJson());
      final selection = af.Selection.single(
        path: [1],
        startOffset: 2,
        endOffset: 4,
      );
      editor.selection = selection;
      final service = PlainTextClipboardEditor(
        readText: () async => 'X\nY',
        writeText: (_) async {},
      );
      expect(
        await service.paste(
          editor: editor,
          selection: selection,
          canApply: () => true,
          contextRevision: () => 0,
        ),
        PlainTextClipboardResult.applied,
      );
      expect(
        editor.document.root.children
            .map((node) => node.delta!.toPlainText())
            .toList(),
        ['before', 'taX', 'Yet', 'after'],
      );
      expect(editor.selection!.start.path, [2]);
      expect(editor.selection!.start.offset, 1);
      editor.undoManager.undo();
      await Future<void>.delayed(Duration.zero);
      expect(jsonEncode(editor.document.toJson()), original);
      editor.dispose();
    },
  );

  test(
    'concurrent paste responses cannot both overwrite one selection',
    () async {
      final editor = document(af.Delta()..insert('alpha beta'));
      final selection = select(editor, 0, 5);
      final first = Completer<String?>();
      final second = Completer<String?>();
      var reads = 0;
      final service = PlainTextClipboardEditor(
        readText: () => reads++ == 0 ? first.future : second.future,
        writeText: (_) async {},
      );
      Future<PlainTextClipboardResult> paste() => service.paste(
        editor: editor,
        selection: selection,
        canApply: () => true,
        contextRevision: () => 0,
      );
      final firstResult = paste();
      final secondResult = paste();
      first.complete('one');
      expect(await firstResult, PlainTextClipboardResult.applied);
      second.complete('two');
      expect(await secondResult, PlainTextClipboardResult.stale);
      expect(body(editor), 'one beta');
      editor.dispose();
    },
  );

  test(
    'multi-line paste refuses nested paragraph without changing its parent',
    () async {
      final editor = af.EditorState(
        document: af.Document(
          root: af.pageNode(
            children: [
              af.bulletedListNode(
                text: 'parent',
                children: [af.paragraphNode(text: 'nested text')],
              ),
            ],
          ),
        ),
      );
      final original = jsonEncode(editor.document.toJson());
      final selection = af.Selection.single(
        path: [0, 0],
        startOffset: 0,
        endOffset: 6,
      );
      editor.selection = selection;
      final service = PlainTextClipboardEditor(
        readText: () async => 'one\ntwo',
        writeText: (_) async {},
      );
      expect(
        await service.paste(
          editor: editor,
          selection: selection,
          canApply: () => true,
          contextRevision: () => 0,
        ),
        PlainTextClipboardResult.unsupportedText,
      );
      expect(jsonEncode(editor.document.toJson()), original);
      editor.dispose();
    },
  );

  test(
    'paste stops when input becomes unsafe during clipboard reading',
    () async {
      final editor = document(af.Delta()..insert('alpha beta'));
      final selection = select(editor, 0, 5);
      final read = Completer<String?>();
      var safe = true;
      final service = PlainTextClipboardEditor(
        readText: () => read.future,
        writeText: (_) async {},
      );
      final operation = service.paste(
        editor: editor,
        selection: selection,
        canApply: () => safe,
        contextRevision: () => 0,
      );
      safe = false;
      read.complete('new');
      expect(await operation, PlainTextClipboardResult.stale);
      expect(body(editor), 'alpha beta');
      editor.dispose();
    },
  );

  test('multi-block selection is rejected before clipboard access', () async {
    final editor = af.EditorState(
      document: af.Document(
        root: af.pageNode(
          children: [
            af.paragraphNode(text: 'alpha'),
            af.paragraphNode(text: 'beta'),
          ],
        ),
      ),
    );
    final selection = af.Selection(
      start: af.Position(path: [0], offset: 0),
      end: af.Position(path: [1], offset: 4),
    );
    editor.selection = selection;
    final original = jsonEncode(editor.document.toJson());
    var accesses = 0;
    final service = PlainTextClipboardEditor(
      readText: () async {
        accesses++;
        return 'text';
      },
      writeText: (_) async => accesses++,
    );
    expect(
      await service.paste(
        editor: editor,
        selection: selection,
        canApply: () => true,
        contextRevision: () => 0,
      ),
      PlainTextClipboardResult.unsupportedSelection,
    );
    expect(
      await service.cut(
        editor: editor,
        selection: selection,
        canApply: () => true,
        contextRevision: () => 0,
      ),
      PlainTextClipboardResult.unsupportedSelection,
    );
    expect(accesses, 0);
    expect(jsonEncode(editor.document.toJson()), original);
    editor.dispose();
  });
}
