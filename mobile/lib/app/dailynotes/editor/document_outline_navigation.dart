import 'package:appflowy_editor/appflowy_editor.dart' as af;
import 'package:mui/mui.dart';

import 'document_toggle_block.dart';

class _ReadingAnchor {
  const _ReadingAnchor(this.editor, this.node, this.alignment);

  final af.EditorState editor;
  // Null represents the shared document header at item zero.
  final af.Node? node;
  final double alignment;
}

/// Navigates live document nodes without replacing the editor or its selection.
/// A new request invalidates any earlier jump that is still waiting on a frame.
class DocumentOutlineNavigation {
  int _generation = 0;
  bool _disposed = false;
  _ReadingAnchor? _previous;
  af.EditorState? _foldEditor;
  DocumentToggleController? _folds;

  void attachFolds(af.EditorState editor, DocumentToggleController folds) {
    if (_disposed) return;
    _foldEditor = editor;
    _folds = folds;
  }

  void detachFolds(af.EditorState editor, DocumentToggleController folds) {
    if (identical(_foldEditor, editor) && identical(_folds, folds)) {
      _foldEditor = null;
      _folds = null;
    }
  }

  /// A temporary point from this editor session, not a persistent bookmark.
  bool hasPrevious(af.EditorState editor) =>
      !_disposed && identical(_previous?.editor, editor);

  void dispose() {
    _disposed = true;
    _generation++;
    _previous = null;
    _foldEditor = null;
    _folds = null;
  }

  _ReadingAnchor? _capture(
    af.EditorState editor,
    af.EditorScrollController scroll,
  ) {
    final positions =
        scroll.itemPositionsListener.itemPositions.value
            .where(
              (item) =>
                  item.itemLeadingEdge >= 0 &&
                  item.itemLeadingEdge < 1 &&
                  item.itemTrailingEdge > 0 &&
                  item.index >= 0 &&
                  item.index <= editor.document.root.children.length,
            )
            .toList()
          ..sort((a, b) => a.itemLeadingEdge.compareTo(b.itemLeadingEdge));
    if (positions.isEmpty) return null;
    final first = positions.first;
    final node = first.index == 0
        ? null
        : editor.document.root.children[first.index - 1];
    return _ReadingAnchor(editor, node, first.itemLeadingEdge);
  }

  int? _anchorIndex(_ReadingAnchor anchor, af.EditorState editor) {
    if (!identical(anchor.editor, editor) || editor.isDisposed) return null;
    final node = anchor.node;
    if (node == null) return 0;
    try {
      final path = node.path;
      if (path.length != 1 ||
          !identical(editor.document.nodeAtPath(path), node)) {
        return null;
      }
      return path.first + 1;
    } catch (_) {
      return null;
    }
  }

  /// Returns null if the owning page is no longer current, false if the
  /// requested node cannot be reached, and true when scrolling was requested.
  Future<bool?> jump({
    required af.Node target,
    required af.EditorState editor,
    required af.EditorScrollController scroll,
    required bool Function() isCurrent,
  }) async {
    final generation = ++_generation;
    bool current() =>
        !_disposed &&
        generation == _generation &&
        !editor.isDisposed &&
        isCurrent();
    bool targetIsCurrent() {
      try {
        final path = target.path;
        return path.isNotEmpty &&
            identical(editor.document.nodeAtPath(path), target);
      } catch (_) {
        return false;
      }
    }

    await WidgetsBinding.instance.endOfFrame;
    if (!current()) return null;
    if (!targetIsCurrent() ||
        scroll.shrinkWrap ||
        !scroll.itemScrollController.isAttached) {
      return false;
    }
    final previous = _capture(editor, scroll);
    if (identical(_foldEditor, editor) &&
        (_folds?.expandAncestors(target) ?? false)) {
      await WidgetsBinding.instance.endOfFrame;
      if (!current()) return null;
      if (!targetIsCurrent()) return false;
    }
    var targetContext = target.key.currentContext;
    if (targetContext == null || !targetContext.mounted) {
      // The document header is item zero; root document blocks start at one.
      scroll.itemScrollController.jumpTo(index: target.path.first + 1);
      await WidgetsBinding.instance.endOfFrame;
      if (!current()) return null;
      if (!targetIsCurrent()) return false;
      targetContext = target.key.currentContext;
    }
    if (targetContext == null || !targetContext.mounted) return false;
    try {
      await Scrollable.ensureVisible(
        targetContext,
        alignment: 0.08,
        duration: const Duration(milliseconds: 180),
      );
    } catch (_) {
      return current() ? false : null;
    }
    if (!current()) return null;
    if (!targetIsCurrent()) return false;
    _previous = previous;
    return true;
  }

  /// Jump to a previously verified viewport location and retain the current
  /// position as the same-session return point. The caller must revalidate
  /// the saved document snapshot, including after the frame boundary.
  Future<bool?> jumpToPosition({
    required int index,
    required double alignment,
    required bool Function() targetValid,
    required af.EditorState editor,
    required af.EditorScrollController scroll,
    required bool Function() isCurrent,
  }) async {
    final generation = ++_generation;
    bool current() =>
        !_disposed &&
        generation == _generation &&
        !editor.isDisposed &&
        isCurrent();
    bool valid() {
      try {
        return index >= 0 &&
            index <= editor.document.root.children.length &&
            alignment.isFinite &&
            alignment >= 0 &&
            alignment < 1 &&
            targetValid();
      } catch (_) {
        return false;
      }
    }

    await WidgetsBinding.instance.endOfFrame;
    if (!current()) return null;
    if (!valid() ||
        scroll.shrinkWrap ||
        !scroll.itemScrollController.isAttached) {
      return false;
    }
    final previous = _capture(editor, scroll);
    final target = index == 0 ? null : editor.document.root.children[index - 1];
    scroll.itemScrollController.jumpTo(index: index, alignment: alignment);
    await WidgetsBinding.instance.endOfFrame;
    if (!current()) return null;
    if (!valid() ||
        (target != null &&
            !identical(editor.document.nodeAtPath([index - 1]), target))) {
      return false;
    }
    _previous = previous;
    return true;
  }

  /// Restores the last in-session viewport anchor without changing selection.
  /// Deleted anchors are rejected instead of navigating to a replacement.
  Future<bool?> returnToPrevious({
    required af.EditorState editor,
    required af.EditorScrollController scroll,
    required bool Function() isCurrent,
  }) async {
    final generation = ++_generation;
    bool current() =>
        !_disposed &&
        generation == _generation &&
        !editor.isDisposed &&
        isCurrent();
    if (!current()) return null;
    final anchor = _previous;
    if (anchor == null || !identical(anchor.editor, editor)) return false;
    final index = _anchorIndex(anchor, editor);
    if (index == null) {
      _previous = null;
      return false;
    }
    if (scroll.shrinkWrap || !scroll.itemScrollController.isAttached) {
      return false;
    }
    scroll.itemScrollController.jumpTo(
      index: index,
      alignment: anchor.alignment,
    );
    await WidgetsBinding.instance.endOfFrame;
    if (!current()) return null;
    if (_anchorIndex(anchor, editor) == null) {
      _previous = null;
      return false;
    }
    _previous = null;
    return true;
  }
}
