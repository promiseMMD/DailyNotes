import 'dart:async';

import 'package:appflowy_editor/appflowy_editor.dart' as af;
import 'package:mui/mui.dart';

import 'document_envelope.dart';
import 'document_toggle_block.dart';
import 'document_toggle_model.dart';

/// Moves one toggle and its live subtree in a single undoable transaction.
class DocumentToggleNesting {
  const DocumentToggleNesting(this.folds);

  final DocumentToggleController folds;

  static const _containers = {
    DocumentToggleKeys.type,
    af.ParagraphBlockKeys.type,
    af.BulletedListBlockKeys.type,
    af.NumberedListBlockKeys.type,
    af.TodoListBlockKeys.type,
  };

  af.Node? _selected(af.EditorState editor) {
    final selection = editor.selection;
    if (editor.isDisposed ||
        !editor.editable ||
        editor.selectionType == af.SelectionType.block ||
        selection == null ||
        !selection.isSingle ||
        selection.start.path.isEmpty) {
      return null;
    }
    final keyboard = editor.service.keyboardService;
    if (keyboard != null && !keyboard.isInputSettled) return null;
    final node = editor.document.nodeAtPath(selection.start.path);
    final delta = node?.delta;
    final normalized = selection.normalized;
    if (node == null ||
        node.type != DocumentToggleKeys.type ||
        delta == null ||
        normalized.start.offset < 0 ||
        normalized.end.offset > delta.length) {
      return null;
    }
    return node;
  }

  // The saved envelope has a JSON depth limit. A move must not produce a
  // document that can be edited in memory but no longer persisted.
  bool _fitsAtDepth(af.Node node, int pathLength) {
    try {
      int depth(Object? value) {
        if (value is Map) {
          return value.isEmpty
              ? 0
              : 1 + value.values.map(depth).reduce((a, b) => a > b ? a : b);
        }
        if (value is List) {
          return value.isEmpty
              ? 0
              : 1 + value.map(depth).reduce((a, b) => a > b ? a : b);
        }
        return 0;
      }

      return 1 + 2 * pathLength + depth(node.toJson()) <=
          DailyNotesDocumentEnvelope.maxDepth;
    } catch (_) {
      return false;
    }
  }

  bool canIndent(af.EditorState editor) {
    final node = _selected(editor);
    final previous = node?.previous;
    return node != null &&
        previous != null &&
        _containers.contains(previous.type) &&
        _fitsAtDepth(node, node.path.length + 1);
  }

  bool canOutdent(af.EditorState editor) {
    final node = _selected(editor);
    final parent = node?.parent;
    final grandparent = parent?.parent;
    return node != null &&
        parent != null &&
        parent.path.isNotEmpty &&
        _containers.contains(parent.type) &&
        grandparent != null &&
        (identical(grandparent, editor.document.root) ||
            _containers.contains(grandparent.type));
  }

  Future<void> indent(af.EditorState editor) async {
    if (!canIndent(editor)) return;
    final node = _selected(editor)!;
    final previous = node.previous!;
    final target = [...previous.path, previous.children.length];
    // The selected block must remain visible after it becomes a child.
    if (previous.type == DocumentToggleKeys.type) {
      folds.trackParent(previous);
      folds.setCollapsed(previous, false);
    }
    await _move(editor, node, target);
    folds.reconcileTrackedParents();
  }

  Future<void> outdent(af.EditorState editor) async {
    if (!canOutdent(editor)) return;
    final node = _selected(editor)!;
    final parent = node.parent!;
    final target = [...parent.path]..last += 1;
    if (parent.type == DocumentToggleKeys.type) folds.trackParent(parent);
    await _move(editor, node, target);
    folds.reconcileTrackedParents();
  }

  Future<void> _move(af.EditorState editor, af.Node node, af.Path path) async {
    final selection = editor.selection!;
    final transaction = editor.transaction
      ..moveNode(path, node)
      ..afterSelection = af.Selection(
        start: selection.start.copyWith(path: path),
        end: selection.end.copyWith(path: path),
      );
    if (editor.undoManager.undoStack.isNonEmpty) {
      editor.undoManager.undoStack.last.seal();
    }
    await editor.apply(transaction, skipHistoryDebounce: true);
  }

  List<af.CommandShortcutEvent> shortcuts() => [
    _shortcut('tab', indent, canIndent),
    _shortcut('shift+tab', outdent, canOutdent),
  ];

  af.CommandShortcutEvent _shortcut(
    String key,
    Future<void> Function(af.EditorState) move,
    bool Function(af.EditorState) canMove,
  ) => af.CommandShortcutEvent(
    key: 'dailynotes toggle $key',
    command: key,
    getDescription: null,
    handler: (editor) {
      if (_selected(editor) == null) return KeyEventResult.ignored;
      if (canMove(editor)) unawaited(move(editor));
      return KeyEventResult.handled;
    },
  );
}
