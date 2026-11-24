import 'dart:async';

import 'package:appflowy_editor/appflowy_editor.dart' as af;
import 'package:moodiary_di/moodiary_di.dart';
import 'package:moodiary_i18n/moodiary_i18n.dart';
import 'package:moodiary_storage/moodiary_storage.dart';
import 'package:moodiary_utils/moodiary_utils.dart';
import 'package:mui/mui.dart';

import '../editor/document_bookmark_store.dart';
import '../editor/document_outline_navigation.dart';
import 'rich_note_outline.dart';

/// Bookmarks are separate metadata; this flow never writes the document.
Future<void> openDocumentBookmarks({
  required BuildContext context,
  required af.EditorState editor,
  required af.EditorScrollController scroll,
  required FocusNode editorFocus,
  required String? identity,
  required bool Function() canStore,
  required bool Function() isAlive,
  required bool Function() isCurrent,
  required DocumentOutlineNavigation navigation,
}) async {
  void message(String text) =>
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(text)));

  if (identity == null) {
    message(context.l10n.dailynotes.bookmarkSaveFirst);
    return;
  }
  final storage = getIt.maybeGet<IKVStorage>();
  if (storage == null) {
    message(context.l10n.dailynotes.bookmarkStorageError);
    return;
  }
  final nameFocus = FocusNode(debugLabel: 'document-bookmark-name');
  final route = RawDialogRoute<DocumentBookmark>(
    requestFocus: false,
    barrierDismissible: true,
    barrierLabel: MaterialLocalizations.of(context).modalBarrierDismissLabel,
    barrierColor: context.theme.colors.scrim.withValues(alpha: 0.5),
    transitionDuration: const Duration(milliseconds: 200),
    pageBuilder: (_, _, _) => _DocumentBookmarksDialog(
      editor: editor,
      scroll: scroll,
      store: DocumentBookmarkStore(storage, identity),
      nameFocus: nameFocus,
      editorFocus: editorFocus,
      canStore: canStore,
      isAlive: isAlive,
    ),
  );
  try {
    final selected = await Navigator.of(
      context,
      rootNavigator: true,
    ).push(route);
    await route.completed;
    if (!context.mounted) return;
    if (selected == null || !isCurrent() || editor.isDisposed) return;
    final reached = await navigation.jumpToPosition(
      index: selected.index,
      alignment: selected.alignment,
      targetValid: () => documentBookmarkMatches(editor, selected),
      editor: editor,
      scroll: scroll,
      isCurrent: isCurrent,
    );
    if (reached == false && context.mounted) {
      message(context.l10n.dailynotes.bookmarkUnavailable);
    }
  } finally {
    nameFocus.dispose();
  }
}

enum _BookmarkAction { rename, delete }

class _DocumentBookmarksDialog extends StatefulWidget {
  const _DocumentBookmarksDialog({
    required this.editor,
    required this.scroll,
    required this.store,
    required this.nameFocus,
    required this.editorFocus,
    required this.canStore,
    required this.isAlive,
  });

  final af.EditorState editor;
  final af.EditorScrollController scroll;
  final DocumentBookmarkStore store;
  final FocusNode nameFocus;
  final FocusNode editorFocus;
  final bool Function() canStore;
  final bool Function() isAlive;

  @override
  State<_DocumentBookmarksDialog> createState() =>
      _DocumentBookmarksDialogState();
}

class _DocumentBookmarksDialogState extends State<_DocumentBookmarksDialog> {
  DocumentBookmarkSnapshot? _snapshot;
  StreamSubscription<dynamic>? _changes;
  String? _digest;
  String? _message;
  bool _blocked = false;
  bool _busy = false;
  DocumentBookmark? _deleted;
  int? _deletedAt;

  @override
  void initState() {
    super.initState();
    try {
      _snapshot = widget.store.load();
    } catch (_) {
      _blocked = true;
    }
    _changes = widget.editor.transactionStream.listen((event) {
      if (event.$1 == af.TransactionTime.after && mounted) {
        setState(() => _digest = null);
      }
    });
  }

  @override
  void dispose() {
    unawaited(_changes?.cancel());
    super.dispose();
  }

  String? get _currentDigest {
    if (!widget.isAlive() || widget.editor.isDisposed) return null;
    try {
      return _digest ??= documentBookmarkDigest(widget.editor);
    } catch (_) {
      return null;
    }
  }

  bool _valid(DocumentBookmark item, String? digest) =>
      digest != null &&
      item.digest == digest &&
      item.index <= widget.editor.document.root.children.length;

  void _showMessage(String text) => setState(() => _message = text);

  bool _replace(List<DocumentBookmark> items) {
    final snapshot = _snapshot;
    if (_blocked || snapshot == null || !widget.isAlive()) return false;
    try {
      final next = widget.store.save(snapshot, items);
      setState(() {
        _snapshot = next;
        _message = null;
      });
      return true;
    } catch (_) {
      // The write may have committed before a readback error. Block further
      // mutations until the user reopens the dialog and reads the store again.
      setState(() {
        _blocked = true;
        _deleted = null;
        _deletedAt = null;
      });
      return false;
    }
  }

  Future<String?> _name(String initial) async {
    final guard = DocumentOverlaySelectionGuard(
      widget.editor,
      widget.editorFocus,
      widget.nameFocus,
    );
    final route = DialogRoute<String>(
      context: context,
      builder: (_) =>
          _BookmarkNameDialog(initial: initial, focusNode: widget.nameFocus),
    );
    try {
      final result = await Navigator.of(
        context,
        rootNavigator: true,
      ).push(route);
      await route.completed;
      if (mounted) {
        guard.restoreIfSafe(
          () => widget.isAlive() && ModalRoute.of(context)?.isCurrent == true,
        );
      }
      return result;
    } finally {
      guard.dispose();
    }
  }

  Future<void> _add() async {
    if (_busy || _blocked || !widget.isAlive()) return;
    final t = context.l10n.dailynotes;
    if (!widget.canStore()) {
      _showMessage(t.bookmarkSaveFirst);
      return;
    }
    final scroll = widget.scroll;
    if (scroll.shrinkWrap || !scroll.itemScrollController.isAttached) {
      _showMessage(t.bookmarkPositionUnavailable);
      return;
    }
    final positions =
        scroll.itemPositionsListener.itemPositions.value
            .where(
              (item) =>
                  item.itemLeadingEdge >= 0 &&
                  item.itemLeadingEdge < 1 &&
                  item.itemTrailingEdge > 0 &&
                  item.index >= 0 &&
                  item.index <= widget.editor.document.root.children.length,
            )
            .toList()
          ..sort((a, b) => a.itemLeadingEdge.compareTo(b.itemLeadingEdge));
    final digest = _currentDigest;
    if (positions.isEmpty || digest == null) {
      _showMessage(t.bookmarkPositionUnavailable);
      return;
    }
    final position = positions.first;
    setState(() => _busy = true);
    final name = await _name(t.bookmarkDefaultName);
    if (!mounted) return;
    setState(() => _busy = false);
    if (name == null) return;
    if (!widget.isAlive() || !widget.canStore() || _currentDigest != digest) {
      _showMessage(context.l10n.dailynotes.bookmarkChanged);
      return;
    }
    final item = DocumentBookmark(
      id: uuidV7(),
      name: name,
      digest: digest,
      index: position.index,
      alignment: position.itemLeadingEdge,
    );
    if (_replace([...?_snapshot?.items, item])) {
      _deleted = null;
      _deletedAt = null;
    }
  }

  Future<void> _rename(DocumentBookmark item) async {
    if (_busy || _blocked || !widget.isAlive()) return;
    setState(() => _busy = true);
    final name = await _name(item.name);
    if (!mounted) return;
    setState(() => _busy = false);
    if (name == null || !widget.isAlive()) return;
    final items = _snapshot?.items;
    if (items == null || !items.any((entry) => entry.id == item.id)) return;
    if (_replace([
      for (final entry in items)
        entry.id == item.id ? entry.rename(name) : entry,
    ])) {
      _deleted = null;
      _deletedAt = null;
    }
  }

  void _delete(DocumentBookmark item) {
    final items = _snapshot?.items;
    if (_busy || _blocked || items == null) return;
    final index = items.indexWhere((entry) => entry.id == item.id);
    if (index < 0) return;
    if (_replace([...items]..removeAt(index))) {
      setState(() {
        _deleted = item;
        _deletedAt = index;
      });
    }
  }

  void _undoDelete() {
    final items = _snapshot?.items;
    final item = _deleted;
    final index = _deletedAt;
    if (_busy || _blocked || items == null || item == null || index == null) {
      return;
    }
    if (_replace([...items]..insert(index.clamp(0, items.length), item))) {
      setState(() {
        _deleted = null;
        _deletedAt = null;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final t = context.l10n.dailynotes;
    final items = _snapshot?.items ?? const <DocumentBookmark>[];
    // Opening an empty list should not serialize a long document until the
    // user actually chooses to add a bookmark.
    final digest = items.isEmpty ? null : _currentDigest;
    return AlertDialog(
      title: Text(t.documentBookmarks),
      content: SizedBox(
        width: 360,
        height: (MediaQuery.sizeOf(context).height * 0.45).clamp(80.0, 300.0),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (_blocked || _message != null)
              Padding(
                padding: const EdgeInsets.only(bottom: 8),
                child: Text(_blocked ? t.bookmarkStorageError : _message!),
              ),
            if (_deleted != null && !_blocked)
              Align(
                alignment: Alignment.centerRight,
                child: TextButton(
                  key: const ValueKey('bookmark-undo'),
                  onPressed: _undoDelete,
                  child: Text(t.bookmarkUndoDelete),
                ),
              ),
            Expanded(
              child: items.isEmpty
                  ? Center(child: Text(_blocked ? '' : t.bookmarkEmpty))
                  : ListView.builder(
                      itemCount: items.length,
                      itemBuilder: (context, index) {
                        final item = items[index];
                        final valid = _valid(item, digest);
                        return ListTile(
                          key: ValueKey('bookmark-entry-${item.id}'),
                          title: Text(
                            item.name,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                          isThreeLine: !valid,
                          subtitle: valid
                              ? null
                              : Text(
                                  t.bookmarkUnavailable,
                                  maxLines: 2,
                                  overflow: TextOverflow.ellipsis,
                                ),
                          onTap: valid && !_busy && !_blocked
                              ? () => Navigator.of(context).pop(item)
                              : null,
                          trailing: PopupMenuButton<_BookmarkAction>(
                            key: ValueKey('bookmark-actions-${item.id}'),
                            requestFocus: false,
                            enabled: !_busy && !_blocked,
                            onSelected: (action) {
                              switch (action) {
                                case _BookmarkAction.rename:
                                  unawaited(_rename(item));
                                case _BookmarkAction.delete:
                                  _delete(item);
                              }
                            },
                            itemBuilder: (context) => [
                              PopupMenuItem(
                                value: _BookmarkAction.rename,
                                child: Text(t.rename),
                              ),
                              PopupMenuItem(
                                value: _BookmarkAction.delete,
                                child: Text(t.delete),
                              ),
                            ],
                          ),
                        );
                      },
                    ),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: Text(context.l10n.common.close),
        ),
        TextButton(
          key: const ValueKey('bookmark-add'),
          onPressed: _busy || _blocked ? null : _add,
          child: Text(t.bookmarkAdd),
        ),
      ],
    );
  }
}

class _BookmarkNameDialog extends StatefulWidget {
  const _BookmarkNameDialog({required this.initial, required this.focusNode});
  final String initial;
  final FocusNode focusNode;

  @override
  State<_BookmarkNameDialog> createState() => _BookmarkNameDialogState();
}

class _BookmarkNameDialogState extends State<_BookmarkNameDialog> {
  late final _controller = TextEditingController(text: widget.initial);
  bool _invalid = false;

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final t = context.l10n.dailynotes;
    return AlertDialog(
      title: Text(t.bookmarkName),
      content: TextField(
        key: const ValueKey('bookmark-name-input'),
        controller: _controller,
        focusNode: widget.focusNode,
        autofocus: true,
        maxLength: 80,
        decoration: InputDecoration(
          labelText: t.bookmarkName,
          errorText: _invalid ? t.bookmarkNameRequired : null,
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: Text(t.cancel),
        ),
        TextButton(
          key: const ValueKey('bookmark-name-save'),
          onPressed: () {
            final name = _controller.text.trim();
            if (name.isEmpty) {
              setState(() => _invalid = true);
            } else {
              Navigator.of(context).pop(name);
            }
          },
          child: Text(t.save),
        ),
      ],
    );
  }
}
