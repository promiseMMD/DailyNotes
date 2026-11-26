import 'dart:async';

import 'package:appflowy_editor/appflowy_editor.dart' as af;
// These tests exercise the vendored editor's actual IME handlers.
// ignore: implementation_imports
import 'package:appflowy_editor/src/editor/editor_component/service/ime/delta_input_on_delete_impl.dart';
// ignore: implementation_imports
import 'package:appflowy_editor/src/editor/editor_component/service/ime/delta_input_on_replace_impl.dart';
// ignore: implementation_imports
import 'package:appflowy_editor/src/editor/editor_component/service/ime/non_delta_input_service.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:moodiary_mobile/app/dailynotes/editor/plain_text_clipboard.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  NonDeltaTextInputService makeInput({
    Future<bool> Function(TextEditingDeltaInsertion)? insert,
    Duration duration = const Duration(milliseconds: 10),
  }) => NonDeltaTextInputService(
    debounceDuration: duration,
    onInsert: insert ?? (_) async => true,
    onDelete: (_) async => true,
    onReplace: (_) async => true,
    onNonTextUpdate: (_) async => true,
    onPerformAction: (_) async {},
  );

  void attach(NonDeltaTextInputService input) => input.attach(
    const TextEditingValue(selection: TextSelection.collapsed(offset: 0)),
    const TextInputConfiguration(),
  );

  TextEditingValue value(String text, {bool composing = false}) =>
      TextEditingValue(
        // The editor uses an invisible leading sentinel in the IME connection.
        text: ' $text',
        selection: TextSelection.collapsed(offset: text.length + 1),
        composing: composing
            ? TextRange(start: 1, end: text.length + 1)
            : TextRange.empty,
      );

  testWidgets('IME replacement does not run shortcuts during composition', (
    tester,
  ) async {
    final node = af.paragraphNode(text: 'ni');
    final editor = af.EditorState(
      document: af.Document(root: af.pageNode(children: [node])),
    );
    editor.selection = af.Selection.single(path: [0], startOffset: 2);
    var invoked = 0;
    final shortcut = af.CharacterShortcutEvent(
      key: 'test composition shortcut',
      character: '你',
      handler: (_) async {
        invoked++;
        return true;
      },
    );
    await onReplace(
      const TextEditingDeltaReplacement(
        oldText: 'ni',
        replacedRange: TextRange(start: 0, end: 2),
        replacementText: '你',
        selection: TextSelection.collapsed(offset: 1),
        composing: TextRange(start: 0, end: 1),
      ),
      editor,
      [shortcut],
    );
    expect(invoked, 0);
    expect(node.delta!.toPlainText(), '你');
    expect(editor.selection!.start.offset, 1);
    editor.dispose();
  });

  testWidgets('committed selection replacement can still invoke a shortcut', (
    tester,
  ) async {
    final node = af.paragraphNode(text: 'ni');
    final editor = af.EditorState(
      document: af.Document(root: af.pageNode(children: [node])),
    );
    editor.selection = af.Selection.single(
      path: [0],
      startOffset: 0,
      endOffset: 2,
    );
    var invoked = 0;
    final shortcut = af.CharacterShortcutEvent(
      key: 'test committed shortcut',
      character: '你',
      handler: (_) async {
        invoked++;
        return true;
      },
    );
    await onReplace(
      const TextEditingDeltaReplacement(
        oldText: 'ni',
        replacedRange: TextRange(start: 0, end: 2),
        replacementText: '你',
        selection: TextSelection.collapsed(offset: 1),
        composing: TextRange.empty,
      ),
      editor,
      [shortcut],
    );
    expect(invoked, 1);
    expect(node.delta!.toPlainText(), 'ni');
    editor.dispose();
  });

  testWidgets('IME commit behind the caret does not run shortcuts', (
    tester,
  ) async {
    final node = af.paragraphNode(text: 'ni');
    final editor = af.EditorState(
      document: af.Document(root: af.pageNode(children: [node])),
    );
    editor.selection = af.Selection.single(path: [0], startOffset: 2);
    var invoked = 0;
    final shortcut = af.CharacterShortcutEvent(
      key: 'test commit shortcut',
      character: '你',
      handler: (_) async {
        invoked++;
        return true;
      },
    );
    await onReplace(
      const TextEditingDeltaReplacement(
        oldText: 'ni',
        replacedRange: TextRange(start: 0, end: 2),
        replacementText: '你',
        selection: TextSelection.collapsed(offset: 1),
        composing: TextRange.empty,
      ),
      editor,
      [shortcut],
    );
    expect(invoked, 0);
    expect(node.delta!.toPlainText(), '你');
    expect(editor.selection!.start.offset, 1);
    editor.dispose();
  });

  testWidgets('IME boundary Backspace keeps the standard fallback', (
    tester,
  ) async {
    final heading = af.headingNode(level: 1, text: '标题');
    final editor = af.EditorState(
      document: af.Document(root: af.pageNode(children: [heading])),
    );
    editor.selection = af.Selection.single(path: [0], startOffset: 0);
    await onDelete(
      const TextEditingDeltaDeletion(
        oldText: '标题',
        deletedRange: TextRange(start: 0, end: 0),
        selection: TextSelection.collapsed(offset: 0),
        composing: TextRange.empty,
      ),
      editor,
      commandShortcutEvents: [],
    );
    await tester.pump();
    final converted = editor.document.root.children.single;
    expect(converted.type, af.ParagraphBlockKeys.type);
    expect(converted.delta!.toPlainText(), '标题');
    editor.dispose();
  });

  testWidgets('separate editors cannot cancel each other’s IME updates', (
    tester,
  ) async {
    final received = <String>[];
    final first = makeInput(
      insert: (delta) async {
        received.add(delta.textInserted);
        return true;
      },
    );
    final second = makeInput(
      insert: (delta) async {
        received.add(delta.textInserted);
        return true;
      },
    );
    attach(first);
    attach(second);
    first.updateEditingValue(value('你'));
    second.updateEditingValue(value('好'));
    expect(first.isInputSettled, isFalse);
    expect(second.isInputSettled, isFalse);
    await tester.pump(const Duration(milliseconds: 11));
    await tester.pump();
    expect(received, ['你', '好']);
    expect(first.isInputSettled, isTrue);
    expect(second.isInputSettled, isTrue);
    first.close();
    second.close();
  });

  testWidgets('pending and active composition are not settled', (tester) async {
    final input = makeInput();
    attach(input);
    final initialRevision = input.inputRevision;
    input.updateEditingValue(value('ni', composing: true));
    expect(input.isInputSettled, isFalse);
    await tester.pump(const Duration(milliseconds: 11));
    await tester.pump();
    expect(input.isInputSettled, isFalse);
    input.clearComposingTextRange();
    expect(input.isInputSettled, isFalse);
    input.updateEditingValue(value('ni'));
    expect(input.isInputSettled, isFalse);
    await tester.pump(const Duration(milliseconds: 11));
    await tester.pump();
    expect(input.isInputSettled, isTrue);
    expect(input.inputRevision, greaterThan(initialRevision));
    input.close();
  });

  testWidgets('in-flight updates remain unsafe until callback completion', (
    tester,
  ) async {
    final insert = Completer<bool>();
    final input = makeInput(insert: (_) => insert.future);
    attach(input);
    input.updateEditingValue(value('你'));
    await tester.pump(const Duration(milliseconds: 11));
    expect(input.isInputSettled, isFalse);
    insert.complete(true);
    await tester.pump();
    expect(input.isInputSettled, isTrue);
    input.close();
  });

  testWidgets('closing with queued input never reports a settled state', (
    tester,
  ) async {
    final input = makeInput();
    attach(input);
    input.updateEditingValue(value('你'));
    final revision = input.inputRevision;
    input.close();
    expect(input.inputRevision, greaterThan(revision));
    expect(input.isInputSettled, isFalse);
    await tester.pump(const Duration(milliseconds: 11));
    await tester.pump();
    expect(input.isInputSettled, isFalse);
  });

  test('invalid IME values cannot be reported as settled', () async {
    final input = makeInput(duration: Duration.zero);
    input.currentTextEditingValue = value('');
    input.updateEditingValue(
      const TextEditingValue(
        text: 'abc',
        selection: TextSelection.collapsed(offset: 99),
      ),
    );
    await Future<void>.delayed(Duration.zero);
    expect(input.isInputSettled, isFalse);
    input.close();
  });

  testWidgets('cancelled, overlapping or rejected input stays uncertain', (
    tester,
  ) async {
    var inserted = 0;
    final cancelled = makeInput(
      insert: (_) async {
        inserted++;
        return true;
      },
    );
    attach(cancelled);
    cancelled.updateEditingValue(value('你'));
    cancelled.attach(
      const TextEditingValue(
        text: 'other',
        selection: TextSelection.collapsed(offset: 5),
      ),
      const TextInputConfiguration(),
    );
    await tester.pump(const Duration(milliseconds: 11));
    expect(inserted, 0);
    expect(cancelled.isInputSettled, isFalse);
    cancelled.close();

    final inFlight = Completer<bool>();
    final overlapping = makeInput(insert: (_) => inFlight.future);
    attach(overlapping);
    overlapping.updateEditingValue(value('你'));
    await tester.pump(const Duration(milliseconds: 11));
    overlapping.updateEditingValue(value('你好'));
    inFlight.complete(true);
    await tester.pump(const Duration(milliseconds: 11));
    await tester.pump();
    expect(overlapping.isInputSettled, isFalse);
    overlapping.close();

    final rejected = makeInput(insert: (_) async => false);
    attach(rejected);
    rejected.updateEditingValue(value('你'));
    await tester.pump(const Duration(milliseconds: 11));
    await tester.pump();
    expect(rejected.isInputSettled, isFalse);
    rejected.close();
  });

  test(
    'a pending clipboard read expires after IME changes and settles',
    () async {
      final input = makeInput(duration: Duration.zero);
      input.currentTextEditingValue = value('');
      final editor = af.EditorState(
        document: af.Document(
          root: af.pageNode(children: [af.paragraphNode(text: 'original')]),
        ),
      );
      final selection = af.Selection.single(
        path: [0],
        startOffset: 0,
        endOffset: 8,
      );
      editor.selection = selection;
      final read = Completer<String?>();
      final clipboard = PlainTextClipboardEditor(
        readText: () => read.future,
        writeText: (_) async {},
      );
      final operation = clipboard.paste(
        editor: editor,
        selection: selection,
        canApply: () => input.isInputSettled,
        contextRevision: () => input.inputRevision,
      );
      input.updateEditingValue(value('ni', composing: true));
      await Future<void>.delayed(Duration.zero);
      input.updateEditingValue(value('ni'));
      await Future<void>.delayed(Duration.zero);
      expect(input.isInputSettled, isTrue);
      read.complete('replacement');
      expect(await operation, PlainTextClipboardResult.stale);
      expect(
        editor.document.root.children.single.delta!.toPlainText(),
        'original',
      );
      input.close();
      editor.dispose();
    },
  );
}
