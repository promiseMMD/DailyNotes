import 'dart:async';

import 'package:appflowy_editor/appflowy_editor.dart' as af;
import 'package:moodiary_i18n/moodiary_i18n.dart';
import 'package:mui/mui.dart';

/// Top navigation controls for the live AppFlowy document. The owning page
/// remains responsible for persistence and determines when editing is safe.
class DocumentHistoryActions extends StatefulWidget {
  const DocumentHistoryActions({
    super.key,
    required this.editor,
    required this.editable,
    this.canEdit,
  });

  final af.EditorState? editor;
  final bool editable;

  /// Called again on activation to protect against a lock or pending submit
  /// occurring between a frame being built and the button being tapped.
  final bool Function()? canEdit;

  @override
  State<DocumentHistoryActions> createState() => _DocumentHistoryActionsState();
}

class _DocumentHistoryActionsState extends State<DocumentHistoryActions> {
  StreamSubscription<dynamic>? _changes;
  bool _busy = false;
  int _generation = 0;

  @override
  void initState() {
    super.initState();
    _listen(widget.editor);
  }

  void _listen(af.EditorState? editor) {
    _changes = editor?.transactionStream.listen((event) {
      if (event.$1 != af.TransactionTime.after) return;
      // The SDK records the history after broadcasting its transaction event.
      // Read the stacks on the next frame, after the update is complete.
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted && identical(widget.editor, editor)) setState(() {});
      });
      WidgetsBinding.instance.scheduleFrame();
    });
  }

  @override
  void didUpdateWidget(covariant DocumentHistoryActions oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!identical(oldWidget.editor, widget.editor)) {
      _generation++;
      _busy = false;
      unawaited(_changes?.cancel());
      _listen(widget.editor);
    }
    if (oldWidget.editable != widget.editable) {
      // The document canvas may apply its editable flag later in the same
      // build. Re-read it next frame after that update, without retaining a
      // stale document if navigation changed in between.
      final editor = widget.editor;
      final generation = _generation;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted &&
            generation == _generation &&
            identical(widget.editor, editor)) {
          setState(() {});
        }
      });
      WidgetsBinding.instance.scheduleFrame();
    }
  }

  @override
  void dispose() {
    _generation++;
    unawaited(_changes?.cancel());
    super.dispose();
  }

  bool _usable(af.EditorState? editor) =>
      mounted &&
      editor != null &&
      identical(widget.editor, editor) &&
      !editor.isDisposed &&
      widget.editable &&
      editor.editable &&
      (widget.canEdit?.call() ?? true) &&
      ModalRoute.of(context)?.isCurrent != false;

  void _run(af.EditorState editor, {required bool undo}) {
    if (_busy || !_usable(editor)) return;
    final stack = undo
        ? editor.undoManager.undoStack
        : editor.undoManager.redoStack;
    if (stack.isEmpty) return;
    final generation = _generation;
    setState(() => _busy = true);
    try {
      // UndoManager pops before apply() checks editable, so the last-moment
      // guard above must run before this call.
      if (undo) {
        editor.undoManager.undo();
      } else {
        editor.undoManager.redo();
      }
    } finally {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted && generation == _generation) setState(() => _busy = false);
      });
      WidgetsBinding.instance.scheduleFrame();
    }
  }

  @override
  Widget build(BuildContext context) {
    final editor = widget.editor;
    final enabled = !_busy && _usable(editor);
    return SizedBox(
      width: 80,
      child: Row(
        children: [
          Expanded(
            child: IconButton(
              key: const ValueKey('document-top-undo'),
              tooltip: context.l10n.editor.toolbar.undo,
              iconSize: 20,
              padding: EdgeInsets.zero,
              icon: const Icon(LucideIcons.undo2),
              onPressed: enabled && editor!.undoManager.undoStack.isNonEmpty
                  ? () => _run(editor, undo: true)
                  : null,
            ),
          ),
          Expanded(
            child: IconButton(
              key: const ValueKey('document-top-redo'),
              tooltip: context.l10n.editor.toolbar.redo,
              iconSize: 20,
              padding: EdgeInsets.zero,
              icon: const Icon(LucideIcons.redo2),
              onPressed: enabled && editor!.undoManager.redoStack.isNonEmpty
                  ? () => _run(editor, undo: false)
                  : null,
            ),
          ),
        ],
      ),
    );
  }
}
