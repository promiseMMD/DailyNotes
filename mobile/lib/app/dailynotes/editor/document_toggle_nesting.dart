import 'dart:async';

import 'package:appflowy_editor/appflowy_editor.dart' as af;
import 'package:mui/mui.dart';

import 'document_envelope.dart';
import 'document_toggle_block.dart';
import 'document_toggle_model.dart';

/// Moves selected sibling text blocks and their live subtrees to or from a
/// toggle in one undoable transaction.
///
/// Toggle blocks can also move among the editor's supported containers. Other
/// blocks remain on the upstream indent path unless a toggle is involved.
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

  static const _movable = {
    DocumentToggleKeys.type,
    af.ParagraphBlockKeys.type,
    af.HeadingBlockKeys.type,
    af.QuoteBlockKeys.type,
    af.BulletedListBlockKeys.type,
    af.NumberedListBlockKeys.type,
    af.TodoListBlockKeys.type,
  };

  _SelectedSiblings? _selected(af.EditorState editor) {
    final selection = editor.selection;
    if (editor.isDisposed ||
        !editor.editable ||
        editor.selectionType == af.SelectionType.block ||
        selection == null ||
        selection.start.path.isEmpty ||
        selection.end.path.isEmpty) {
      return null;
    }
    final keyboard = editor.service.keyboardService;
    if (keyboard != null && !keyboard.isInputSettled) return null;
    final normalized = selection.normalized;
    final first = editor.document.nodeAtPath(normalized.start.path);
    final last = editor.document.nodeAtPath(normalized.end.path);
    final parent = first?.parent;
    if (first == null ||
        last == null ||
        parent == null ||
        !identical(parent, last.parent) ||
        first.delta == null ||
        last.delta == null ||
        normalized.start.offset < 0 ||
        normalized.end.offset < 0 ||
        normalized.end.offset > last.delta!.length ||
        normalized.start.offset > first.delta!.length) {
      return null;
    }
    final start = normalized.start.path.last;
    final end = normalized.end.path.last;
    if (start < 0 || end < start || end >= parent.children.length) return null;
    final nodes = parent.children.sublist(start, end + 1);
    if (!identical(nodes.first, first) ||
        !identical(nodes.last, last) ||
        nodes.any(
          (node) => !_movable.contains(node.type) || node.delta == null,
        )) {
      return null;
    }
    return _SelectedSiblings(parent, nodes, start);
  }

  /// The upstream command filters selected descendants by depth. Avoid that
  /// fallback when an unsupported multi-level range touches a toggle.
  bool blocksUnsafeFallback(af.EditorState editor) {
    final selection = editor.selection;
    if (selection == null || selection.isSingle) return false;
    if (_selected(editor) != null) return false;
    try {
      for (final node in editor.getNodesInSelection(selection)) {
        af.Node? current = node;
        while (current != null) {
          if (current.type == DocumentToggleKeys.type) return true;
          current = current.parent;
        }
      }
      return false;
    } catch (_) {
      return true;
    }
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
    final selected = _selected(editor);
    final previous = selected?.nodes.first.previous;
    return selected != null &&
        previous != null &&
        _containers.contains(previous.type) &&
        (selected.includesToggle || previous.type == DocumentToggleKeys.type) &&
        selected.nodes.every(
          (node) => _fitsAtDepth(node, node.path.length + 1),
        );
  }

  bool canOutdent(af.EditorState editor) {
    final selected = _selected(editor);
    final parent = selected?.parent;
    final grandparent = parent?.parent;
    return selected != null &&
        parent != null &&
        parent.path.isNotEmpty &&
        _containers.contains(parent.type) &&
        (selected.includesToggle || parent.type == DocumentToggleKeys.type) &&
        // Moving an intermediate range past its parent would put unselected
        // following siblings before it. Do not silently reorder those blocks.
        (selected.nodes.length == 1 ||
            selected.start + selected.nodes.length == parent.children.length) &&
        grandparent != null &&
        (identical(grandparent, editor.document.root) ||
            _containers.contains(grandparent.type));
  }

  Future<void> indent(af.EditorState editor) async {
    if (!canIndent(editor)) return;
    final selected = _selected(editor)!;
    final previous = selected.nodes.first.previous!;
    final target = [...previous.path, previous.children.length];
    // The selected block must remain visible after it becomes a child.
    if (previous.type == DocumentToggleKeys.type) {
      folds.trackParent(previous);
      folds.setCollapsed(previous, false);
    }
    await _move(editor, selected, target);
    folds.reconcileTrackedParents();
  }

  Future<void> outdent(af.EditorState editor) async {
    if (!canOutdent(editor)) return;
    final selected = _selected(editor)!;
    final parent = selected.parent;
    final target = [...parent.path]..last += 1;
    if (parent.type == DocumentToggleKeys.type) folds.trackParent(parent);
    await _move(editor, selected, target);
    folds.reconcileTrackedParents();
  }

  Future<void> _move(
    af.EditorState editor,
    _SelectedSiblings selected,
    af.Path path,
  ) async {
    final selection = editor.selection!;
    af.Position movedPosition(af.Position original) => original.copyWith(
      path: [
        ...path.sublist(0, path.length - 1),
        path.last + original.path.last - selected.start,
      ],
    );
    final transaction = editor.transaction
      ..deleteNodesAtPath(selected.nodes.first.path, selected.nodes.length)
      ..insertNodes(path, selected.nodes, deepCopy: false)
      ..afterSelection = af.Selection(
        start: movedPosition(selection.start),
        end: movedPosition(selection.end),
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
      final selected = _selected(editor);
      if (selected == null) {
        return blocksUnsafeFallback(editor)
            ? KeyEventResult.handled
            : KeyEventResult.ignored;
      }
      if (canMove(editor)) {
        unawaited(move(editor));
        return KeyEventResult.handled;
      }
      // Leave ordinary list/paragraph shortcuts to the upstream editor.
      return selected.includesToggle
          ? KeyEventResult.handled
          : KeyEventResult.ignored;
    },
  );
}

class _SelectedSiblings {
  const _SelectedSiblings(this.parent, this.nodes, this.start);

  final af.Node parent;
  final List<af.Node> nodes;
  final int start;

  bool get includesToggle =>
      nodes.any((node) => node.type == DocumentToggleKeys.type);
}
