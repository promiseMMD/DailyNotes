import 'dart:async';

import 'package:appflowy_editor/appflowy_editor.dart' as af;

/// Result of an editor operation, not a claim that the document was saved.
enum PlainTextClipboardResult {
  applied,
  stale,
  unsupportedSelection,
  unsupportedFormatting,
  unsupportedText,
  emptyClipboard,
  clipboardFailed,
  commitUncertain,
}

/// Guarded clipboard operations for a single selected text block.
///
/// This is a data-layer building block, not a UI entry point. The caller must
/// only permit mutation while its page, focus, lock and IME state are safe,
/// and must increment [contextRevision] whenever any of those change. In
/// particular, active or pending IME composition is not yet exposed safely by
/// the editor service: do not wire this into user-facing controls until it is.
class PlainTextClipboardEditor {
  const PlainTextClipboardEditor({
    required this.readText,
    required this.writeText,
    this.timeout = const Duration(seconds: 10),
  });

  final Future<String?> Function() readText;
  final Future<void> Function(String text) writeText;
  final Duration timeout;

  Future<PlainTextClipboardResult> cut({
    required af.EditorState editor,
    required af.Selection selection,
    required bool Function() canApply,
    required int Function() contextRevision,
  }) async {
    final guard = _ClipboardGuard.open(
      editor: editor,
      selection: selection,
      canApply: canApply,
      contextRevision: contextRevision,
    );
    if (guard == null) return PlainTextClipboardResult.stale;
    try {
      final selected = guard.selection.normalized;
      if (!selected.isSingle || selected.isCollapsed || !guard.isTextNode) {
        return PlainTextClipboardResult.unsupportedSelection;
      }
      final delta = guard.node.delta!;
      final selectedDelta = delta.slice(
        selected.start.offset,
        selected.end.offset,
      );
      // The existing system clipboard integration writes plain text only.
      // Do not delete formatting that cannot be faithfully copied.
      if (selectedDelta.any(
        (operation) =>
            operation is! af.TextInsert ||
            (operation.attributes?.isNotEmpty ?? false),
      )) {
        return PlainTextClipboardResult.unsupportedFormatting;
      }
      final text = selectedDelta.toPlainText();
      if (text.isEmpty) return PlainTextClipboardResult.unsupportedSelection;
      try {
        await writeText(text).timeout(timeout);
      } catch (_) {
        return PlainTextClipboardResult.clipboardFailed;
      }
      if (!guard.valid) return PlainTextClipboardResult.stale;
      final transaction = editor.transaction
        ..deleteText(guard.node, selected.start.offset, selected.length);
      return await _apply(editor, transaction);
    } finally {
      await guard.dispose();
    }
  }

  Future<PlainTextClipboardResult> paste({
    required af.EditorState editor,
    required af.Selection selection,
    required bool Function() canApply,
    required int Function() contextRevision,
  }) async {
    final guard = _ClipboardGuard.open(
      editor: editor,
      selection: selection,
      canApply: canApply,
      contextRevision: contextRevision,
    );
    if (guard == null) return PlainTextClipboardResult.stale;
    try {
      final selected = guard.selection.normalized;
      if (!selected.isSingle || !guard.isTextNode) {
        return PlainTextClipboardResult.unsupportedSelection;
      }
      String? text;
      try {
        text = await readText().timeout(timeout);
      } catch (_) {
        return PlainTextClipboardResult.clipboardFailed;
      }
      if (!guard.valid) return PlainTextClipboardResult.stale;
      if (text == null || text.isEmpty) {
        return PlainTextClipboardResult.emptyClipboard;
      }
      // Unicode paragraph separators require an explicit format adapter.
      if (RegExp(r'[\u2028\u2029]').hasMatch(text)) {
        return PlainTextClipboardResult.unsupportedText;
      }
      final lines = text
          .replaceAll('\r\n', '\n')
          .replaceAll('\r', '\n')
          .split('\n');
      final delta = guard.node.delta!;
      final attributes = <String, dynamic>{
        if (editor.sliceUpcomingAttributes)
          ...?delta.sliceAttributes(selected.start.offset),
        if (selected.isCollapsed) ...editor.toggledStyle,
      };
      final transaction = editor.transaction;
      if (lines.length == 1) {
        transaction.replaceText(
          guard.node,
          selected.start.offset,
          selected.length,
          lines.single,
          attributes: attributes,
        );
      } else {
        // Splitting a nested, styled or custom block may move children or
        // duplicate block metadata. Wait for a structure-aware adapter.
        if (guard.node.type != af.ParagraphBlockKeys.type ||
            !identical(guard.node.parent, editor.document.root) ||
            guard.node.children.isNotEmpty ||
            guard.node.attributes.keys.any(
              (key) => key != af.ParagraphBlockKeys.delta,
            )) {
          return PlainTextClipboardResult.unsupportedText;
        }
        // Keep the original node and its prefix; move the unchanged suffix,
        // including its rich-text attributes, into the final new paragraph.
        final suffix = af.Delta.fromJson(
          delta.slice(selected.end.offset).toJson(),
        );
        final nodes = <af.Node>[];
        for (var index = 1; index < lines.length; index++) {
          final next = af.Delta()
            ..insert(lines[index], attributes: {...attributes});
          if (index == lines.length - 1) next.addAll(suffix);
          nodes.add(af.paragraphNode(delta: next));
        }
        transaction
          ..replaceText(
            guard.node,
            selected.start.offset,
            delta.length - selected.start.offset,
            lines.first,
            attributes: attributes,
          )
          ..insertNodes(guard.node.path.next, nodes);
        final endPath = List<int>.of(guard.node.path);
        endPath[endPath.length - 1] += nodes.length;
        transaction.afterSelection = af.Selection.collapsed(
          af.Position(path: endPath, offset: lines.last.length),
        );
      }
      return await _apply(editor, transaction);
    } finally {
      await guard.dispose();
    }
  }

  Future<PlainTextClipboardResult> _apply(
    af.EditorState editor,
    af.Transaction transaction,
  ) async {
    try {
      // A clipboard operation should undo independently of earlier typing.
      if (editor.undoManager.undoStack.isNonEmpty) {
        editor.undoManager.undoStack.last.seal();
      }
      await editor.apply(transaction, skipHistoryDebounce: true);
      return PlainTextClipboardResult.applied;
    } catch (_) {
      // Applying a transaction is not a persistence receipt; if an exception
      // arrives after the write starts, do not claim the content is unchanged.
      return PlainTextClipboardResult.commitUncertain;
    }
  }
}

class _ClipboardGuard {
  _ClipboardGuard._({
    required this.editor,
    required this.selection,
    required this.node,
    required this.canApply,
    required this.contextRevision,
    required this.initialContextRevision,
  }) {
    editor.selectionNotifier.addListener(_selectionChanged);
    editor.editableNotifier.addListener(_editableChanged);
    _transactions = editor.transactionStream.listen((event) {
      if (event.$1 == af.TransactionTime.after) _changed = true;
    });
  }

  static _ClipboardGuard? open({
    required af.EditorState editor,
    required af.Selection selection,
    required bool Function() canApply,
    required int Function() contextRevision,
  }) {
    if (editor.isDisposed ||
        !editor.editable ||
        editor.selection != selection) {
      return null;
    }
    try {
      if (!canApply()) return null;
      final node = editor.document.nodeAtPath(selection.start.path);
      if (node == null) return null;
      final snapshot = af.Selection(
        start: af.Position(
          path: List.of(selection.start.path),
          offset: selection.start.offset,
        ),
        end: af.Position(
          path: List.of(selection.end.path),
          offset: selection.end.offset,
        ),
      );
      return _ClipboardGuard._(
        editor: editor,
        selection: snapshot,
        node: node,
        canApply: canApply,
        contextRevision: contextRevision,
        initialContextRevision: contextRevision(),
      );
    } catch (_) {
      return null;
    }
  }

  final af.EditorState editor;
  final af.Selection selection;
  final af.Node node;
  final bool Function() canApply;
  final int Function() contextRevision;
  final int initialContextRevision;
  late final StreamSubscription<dynamic> _transactions;
  bool _changed = false;

  bool get isTextNode {
    final delta = node.delta;
    if (delta == null || !selection.isSingle) return false;
    final selected = selection.normalized;
    return selected.start.offset >= 0 &&
        selected.end.offset <= delta.length &&
        delta.every((operation) => operation is af.TextInsert);
  }

  void _selectionChanged() {
    if (editor.selection != selection) _changed = true;
  }

  void _editableChanged() {
    if (!editor.editable) _changed = true;
  }

  bool get valid {
    if (_changed ||
        editor.isDisposed ||
        !editor.editable ||
        editor.selection != selection ||
        !identical(editor.document.nodeAtPath(selection.start.path), node) ||
        !isTextNode) {
      return false;
    }
    try {
      return contextRevision() == initialContextRevision && canApply();
    } catch (_) {
      return false;
    }
  }

  Future<void> dispose() async {
    editor.selectionNotifier.removeListener(_selectionChanged);
    editor.editableNotifier.removeListener(_editableChanged);
    await _transactions.cancel();
  }
}
