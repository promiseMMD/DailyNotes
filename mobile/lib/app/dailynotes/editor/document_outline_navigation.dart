import 'package:appflowy_editor/appflowy_editor.dart' as af;
import 'package:mui/mui.dart';

/// Navigates live document nodes without replacing the editor or its selection.
/// A new request invalidates any earlier jump that is still waiting on a frame.
class DocumentOutlineNavigation {
  int _generation = 0;

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
        generation == _generation && !editor.isDisposed && isCurrent();
    bool targetIsCurrent() {
      final path = target.path;
      return path.isNotEmpty &&
          identical(editor.document.nodeAtPath(path), target);
    }

    await WidgetsBinding.instance.endOfFrame;
    if (!current()) return null;
    if (!targetIsCurrent() || !scroll.itemScrollController.isAttached) {
      return false;
    }
    // The document header is item zero; root document blocks start at one.
    scroll.itemScrollController.jumpTo(index: target.path.first + 1);
    await WidgetsBinding.instance.endOfFrame;
    if (!current()) return null;
    if (!targetIsCurrent()) return false;
    final targetContext = target.key.currentContext;
    if (targetContext == null || !targetContext.mounted) return false;
    await Scrollable.ensureVisible(
      targetContext,
      alignment: 0.08,
      duration: const Duration(milliseconds: 180),
    );
    return current() ? true : null;
  }
}
