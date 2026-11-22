import 'dart:async';

import 'package:appflowy_editor/appflowy_editor.dart';
import 'package:moodiary_i18n/moodiary_i18n.dart';
import 'package:mui/mui.dart';

/// Presents the outline on the right without taking focus from the document.
/// Search may request focus when the user explicitly taps the search field.
Future<Node?> showDocumentOutline({
  required BuildContext context,
  required EditorState editor,
  required FocusNode editorFocus,
  required bool Function() isCurrent,
}) async {
  final searchFocus = FocusNode(debugLabel: 'document-outline-search');
  final guard = _OutlineSelectionGuard(editor, editorFocus, searchFocus);
  final route = RawDialogRoute<Node>(
    requestFocus: false,
    barrierDismissible: true,
    barrierLabel: MaterialLocalizations.of(context).modalBarrierDismissLabel,
    barrierColor: context.theme.colors.scrim.withValues(alpha: 0.5),
    transitionDuration: const Duration(milliseconds: 200),
    pageBuilder: (dialog, animation, secondaryAnimation) => Align(
      alignment: Alignment.centerRight,
      child: RichNoteOutline(
        editor: editor,
        searchFocusNode: searchFocus,
        onSelect: (node) => Navigator.of(dialog).pop(node),
      ),
    ),
    transitionBuilder: (context, animation, secondaryAnimation, child) =>
        SlideTransition(
          position: Tween<Offset>(
            begin: const Offset(1, 0),
            end: Offset.zero,
          ).animate(CurvedAnimation(parent: animation, curve: Curves.easeOut)),
          child: child,
        ),
  );
  try {
    final target = await Navigator.of(context, rootNavigator: true).push(route);
    await route.completed;
    if (context.mounted) guard.restoreIfSafe(isCurrent);
    return target;
  } finally {
    guard.dispose();
    searchFocus.dispose();
  }
}

/// Restores only the single selection-clear caused by focusing outline search.
/// Any document, lock, lifecycle, selection or unrelated focus change makes
/// the captured selection stale. It never requests the keyboard or focus.
class _OutlineSelectionGuard with WidgetsBindingObserver {
  _OutlineSelectionGuard(this.editor, this.editorFocus, this.searchFocus)
    : selection = editor.selection,
      wasEditable = editor.editable {
    final selected = selection;
    if (selected != null) {
      startNode = editor.document.nodeAtPath(selected.start.path);
      endNode = editor.document.nodeAtPath(selected.end.path);
    }
    editor.selectionNotifier.addListener(_selectionChanged);
    editor.editableNotifier.addListener(_invalidate);
    searchFocus.addListener(_searchFocusChanged);
    FocusManager.instance.addListener(_focusChanged);
    _transactions = editor.transactionStream.listen((event) {
      if (event.$1 == TransactionTime.after) _invalid = true;
    });
    WidgetsBinding.instance.addObserver(this);
  }

  final EditorState editor;
  final FocusNode editorFocus;
  final FocusNode searchFocus;
  final Selection? selection;
  final bool wasEditable;
  Node? startNode;
  Node? endNode;
  late final StreamSubscription<dynamic> _transactions;
  bool _invalid = false;
  bool _searchWasFocused = false;
  bool _selectionCleared = false;

  void _invalidate() => _invalid = true;

  void _searchFocusChanged() {
    if (searchFocus.hasFocus) _searchWasFocused = true;
  }

  void _focusChanged() {
    final focus = FocusManager.instance.primaryFocus;
    if (focus != null &&
        focus is! FocusScopeNode &&
        !identical(focus, editorFocus) &&
        !identical(focus, searchFocus)) {
      _invalid = true;
    }
  }

  void _selectionChanged() {
    if (selection != null && !_selectionCleared && editor.selection == null) {
      _selectionCleared = true;
    } else {
      _invalid = true;
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state != AppLifecycleState.resumed) _invalid = true;
  }

  void restoreIfSafe(bool Function() isCurrent) {
    final selected = selection;
    if (_invalid ||
        !_searchWasFocused ||
        !_selectionCleared ||
        selected == null ||
        editor.isDisposed ||
        editor.editable != wasEditable ||
        editor.selection != null ||
        !isCurrent() ||
        startNode == null ||
        endNode == null ||
        !identical(
          editor.document.nodeAtPath(selected.start.path),
          startNode,
        ) ||
        !identical(editor.document.nodeAtPath(selected.end.path), endNode)) {
      return;
    }
    // The SDK's transaction-reason future does not complete; the notifier is
    // updated synchronously. Do not reattach an input service or show an IME.
    unawaited(
      editor.updateSelectionWithReason(
        selected,
        extraInfo: {
          selectionExtraInfoDoNotAttachTextService: true,
          selectionExtraInfoDisableFloatingToolbar: true,
        },
      ),
    );
  }

  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    FocusManager.instance.removeListener(_focusChanged);
    searchFocus.removeListener(_searchFocusChanged);
    editor.selectionNotifier.removeListener(_selectionChanged);
    editor.editableNotifier.removeListener(_invalidate);
    unawaited(_transactions.cancel());
  }
}

/// This view refers to live nodes only. The editor's node IDs are not stored
/// in its document JSON, so they must not be presented as durable bookmarks.
class RichNoteOutline extends StatefulWidget {
  const RichNoteOutline({
    super.key,
    required this.editor,
    required this.onSelect,
    this.searchFocusNode,
  });

  final EditorState editor;
  final ValueChanged<Node> onSelect;
  final FocusNode? searchFocusNode;

  @override
  State<RichNoteOutline> createState() => _RichNoteOutlineState();
}

class _RichNoteOutlineState extends State<RichNoteOutline> {
  late StreamSubscription<dynamic> _changes;
  String _query = '';
  final Set<String> _collapsed = {};

  @override
  void initState() {
    super.initState();
    _listen(widget.editor);
  }

  void _listen(EditorState editor) {
    _changes = editor.transactionStream.listen((event) {
      if (event.$1 == TransactionTime.after &&
          mounted &&
          identical(editor, widget.editor)) {
        setState(() {
          final current = NodeIterator(
            document: editor.document,
            startNode: editor.document.root,
          ).toList().map((node) => node.id).toSet();
          _collapsed.removeWhere((id) => !current.contains(id));
        });
      }
    });
  }

  @override
  void didUpdateWidget(covariant RichNoteOutline oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!identical(oldWidget.editor, widget.editor)) {
      unawaited(_changes.cancel());
      _query = '';
      _collapsed.clear();
      _listen(widget.editor);
    }
  }

  @override
  void dispose() {
    _changes.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final t = context.l10n.dailynotes;
    final headings = NodeIterator(
      document: widget.editor.document,
      startNode: widget.editor.document.root,
    ).toList().where((node) => node.type == HeadingBlockKeys.type).toList();
    String label(Node node) {
      final text = node.delta?.toPlainText().trim() ?? '';
      return text.isEmpty ? t.untitledHeading : text;
    }

    int level(Node node) {
      final raw = node.attributes[HeadingBlockKeys.level];
      return raw is int ? raw.clamp(1, 6) : 1;
    }

    final query = _query.trim().toLowerCase();
    final searching = query.isNotEmpty;
    final included = <int>{};
    final ancestors = <int>[];
    for (var index = 0; index < headings.length; index++) {
      final node = headings[index];
      while (ancestors.isNotEmpty &&
          level(headings[ancestors.last]) >= level(node)) {
        ancestors.removeLast();
      }
      if (searching) {
        if (label(node).toLowerCase().contains(query)) {
          included.addAll(ancestors);
          included.add(index);
        }
      } else if (!ancestors.any((i) => _collapsed.contains(headings[i].id))) {
        included.add(index);
      }
      ancestors.add(index);
    }
    final filtered = [
      for (var index = 0; index < headings.length; index++)
        if (included.contains(index)) index,
    ];
    return Drawer(
      width: MediaQuery.sizeOf(context).width * 0.85,
      child: SafeArea(
        child: Column(
          children: [
            ListTile(
              title: Text(t.documentOutline),
              trailing: IconButton(
                tooltip: context.l10n.common.close,
                icon: const Icon(LucideIcons.x),
                onPressed: () => Navigator.of(context).pop(),
              ),
            ),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16),
              child: TextField(
                key: ObjectKey(widget.editor),
                focusNode: widget.searchFocusNode,
                onChanged: (value) => setState(() => _query = value),
                decoration: InputDecoration(
                  labelText: t.searchOutline,
                  prefixIcon: const Icon(LucideIcons.search),
                ),
              ),
            ),
            Expanded(
              child: filtered.isEmpty
                  ? Center(
                      child: Text(
                        headings.isEmpty ? t.outlineEmpty : t.outlineNoMatch,
                      ),
                    )
                  : ListView.builder(
                      itemCount: filtered.length,
                      itemBuilder: (context, index) {
                        final originalIndex = filtered[index];
                        final node = headings[originalIndex];
                        final nodeLevel = level(node);
                        final hasChildren =
                            originalIndex + 1 < headings.length &&
                            level(headings[originalIndex + 1]) > nodeLevel;
                        final expanded =
                            searching || !_collapsed.contains(node.id);
                        return ListTile(
                          key: ValueKey('outline-${node.id}'),
                          contentPadding: EdgeInsets.only(
                            left: 8.0 + (nodeLevel - 1) * 16,
                            right: 16,
                          ),
                          leading: SizedBox(
                            width: 40,
                            child: hasChildren
                                ? IconButton(
                                    key: ValueKey('outline-toggle-${node.id}'),
                                    tooltip: expanded
                                        ? context
                                              .l10n
                                              .dailynotes
                                              .outlineCollapse
                                        : context.l10n.dailynotes.outlineExpand,
                                    icon: Icon(
                                      expanded
                                          ? LucideIcons.chevronDown
                                          : LucideIcons.chevronRight,
                                    ),
                                    onPressed: searching
                                        ? null
                                        : () => setState(() {
                                            if (!_collapsed.remove(node.id)) {
                                              _collapsed.add(node.id);
                                            }
                                          }),
                                  )
                                : null,
                          ),
                          title: Text(
                            label(node),
                            maxLines: 2,
                            overflow: TextOverflow.ellipsis,
                          ),
                          onTap: () => widget.onSelect(node),
                        );
                      },
                    ),
            ),
          ],
        ),
      ),
    );
  }
}
