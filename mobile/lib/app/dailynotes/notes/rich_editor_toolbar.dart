import 'dart:async';

import 'package:appflowy_editor/appflowy_editor.dart' as af;
import 'package:flutter/foundation.dart' show defaultTargetPlatform;
import 'package:flutter/services.dart';
import 'package:moodiary_i18n/moodiary_i18n.dart';
import 'package:moodiary_logging/moodiary_logging.dart';
import 'package:mui/mui.dart';

import '../editor/document_editor_back_controller.dart';
import '../editor/document_toggle_model.dart';

/// Mobile controls for the AppFlowy document. Business persistence remains in
/// the owning page; no command here reports a local save or submits a draft.
class RichEditorToolbar extends StatefulWidget {
  const RichEditorToolbar({
    super.key,
    required this.editor,
    required this.focusNode,
    required this.editable,
    required this.child,
    this.loadFonts,
    this.scrollController,
    this.showHistoryActionsInToolbar = true,
    this.backController,
  });

  final af.EditorState editor;
  final FocusNode focusNode;
  final af.EditorScrollController? scrollController;
  final bool editable;
  final bool showHistoryActionsInToolbar;
  final DocumentEditorBackController? backController;
  final Widget child;

  /// Loads usable user-imported font families for the formatting picker.
  final Future<({List<String> families, bool hasUnavailable})> Function()?
  loadFonts;

  @override
  State<RichEditorToolbar> createState() => _RichEditorToolbarState();
}

class _SelectionSession {
  _SelectionSession(
    this.selection,
    this.startNode,
    this.endNode,
    this.revision,
    this.selectionRevision,
  );
  af.Selection selection;
  af.Node startNode;
  af.Node endNode;
  int revision;
  int selectionRevision;
  bool expired = false;
}

String _selectedLinkText(af.EditorState editor, af.Selection selection) {
  final normalized = selection.normalized;
  final delta = editor.document.nodeAtPath(normalized.start.path)?.delta;
  if (!normalized.isSingle || delta == null || normalized.isCollapsed) {
    return '';
  }
  return delta
      .slice(normalized.start.offset, normalized.end.offset)
      .toPlainText();
}

/// Applies a single-block link as one undoable transaction. Unchanged text is
/// formatted in place, preserving all existing inline styles. When the label
/// changes, only its differing middle is replaced; unchanged styled prefix and
/// suffix retain their original attributes.
Future<void> _applyLink(
  af.EditorState editor,
  af.Selection selection,
  _LinkResult result,
) async {
  final selected = selection.normalized;
  final node = editor.document.nodeAtPath(selected.start.path);
  final delta = node?.delta;
  if (!selected.isSingle || node == null || delta == null) {
    throw StateError('invalid_link_selection');
  }
  if (result.remove) {
    if (selected.isCollapsed) throw StateError('invalid_link_selection');
    await editor.formatDelta(
      selection,
      {af.AppFlowyRichTextKeys.href: null},
      selectionExtraInfo: {af.selectionExtraInfoDoNotAttachTextService: true},
    );
    return;
  }
  final oldText = _selectedLinkText(editor, selected);
  if (oldText.length != selected.length) {
    throw StateError('unsupported_link_text');
  }
  final newText = result.text.isEmpty ? result.value : result.text;
  if (!selected.isCollapsed && oldText == newText) {
    await editor.formatDelta(
      selection,
      {af.AppFlowyRichTextKeys.href: result.value},
      selectionExtraInfo: {af.selectionExtraInfoDoNotAttachTextService: true},
    );
    return;
  }

  // Compare Unicode scalars, then convert lengths to the UTF-16 offsets used
  // by AppFlowy. This avoids splitting surrogate pairs in emoji or other text.
  final oldRunes = oldText.runes.toList();
  final newRunes = newText.runes.toList();
  var prefix = 0;
  while (prefix < oldRunes.length &&
      prefix < newRunes.length &&
      oldRunes[prefix] == newRunes[prefix]) {
    prefix++;
  }
  var suffix = 0;
  while (suffix < oldRunes.length - prefix &&
      suffix < newRunes.length - prefix &&
      oldRunes[oldRunes.length - 1 - suffix] ==
          newRunes[newRunes.length - 1 - suffix]) {
    suffix++;
  }
  final prefixLength = String.fromCharCodes(oldRunes.take(prefix)).length;
  final oldMiddleLength = String.fromCharCodes(
    oldRunes.skip(prefix).take(oldRunes.length - prefix - suffix),
  ).length;
  final newMiddle = String.fromCharCodes(
    newRunes.skip(prefix).take(newRunes.length - prefix - suffix),
  );
  final attributes = <String, dynamic>{};
  if (selected.isCollapsed) {
    if (editor.sliceUpcomingAttributes) {
      attributes.addAll(delta.sliceAttributes(selected.start.offset) ?? {});
    }
    attributes.addAll(editor.toggledStyle);
  } else {
    final relative = prefixLength < oldText.length
        ? prefixLength
        : prefixLength - 1;
    final at = selected.start.offset + relative;
    final source = delta.slice(at, at + 1);
    if (source.isNotEmpty) attributes.addAll(source.first.attributes ?? {});
  }
  final transaction = editor.transaction
    ..replaceText(
      node,
      selected.start.offset + prefixLength,
      oldMiddleLength,
      newMiddle,
      attributes: attributes,
    )
    ..formatText(node, selected.start.offset, newText.length, {
      af.AppFlowyRichTextKeys.href: result.value,
    });
  transaction.afterSelection = selected.isCollapsed
      ? af.Selection.collapsed(
          af.Position(
            path: selected.start.path,
            offset: selected.start.offset + newText.length,
          ),
        )
      : af.Selection.single(
          path: selected.start.path,
          startOffset: selected.start.offset,
          endOffset: selected.start.offset + newText.length,
        );
  transaction.selectionExtraInfo = {
    af.selectionExtraInfoDoNotAttachTextService: true,
  };
  if (editor.undoManager.undoStack.isNonEmpty) {
    editor.undoManager.undoStack.last.seal();
  }
  await editor.apply(transaction, skipHistoryDebounce: true);
}

class _ToolbarAction {
  const _ToolbarAction(
    this.id,
    this.label,
    this.icon,
    this.onPressed, {
    this.selected = false,
  });
  final String id;
  final String label;
  final IconData icon;
  final VoidCallback? onPressed;
  final bool selected;
}

// A child format route may be covered by another document route while its
// owner remains offstage. Record that transition so it cannot later revive
// the old selection when the covering route is popped.
class _FormatColorRoute extends ModalBottomSheetRoute<bool> {
  _FormatColorRoute({
    required super.builder,
    required super.capturedThemes,
    required super.barrierLabel,
    required super.barrierOnTapHint,
    required this.onCovered,
  }) : super(
         isScrollControlled: true,
         requestFocus: false,
         useSafeArea: true,
         showDragHandle: true,
         modalBarrierColor: Colors.transparent,
       );

  final VoidCallback onCovered;

  @override
  void didChangeNext(Route<dynamic>? nextRoute) {
    super.didChangeNext(nextRoute);
    if (nextRoute != null) onCovered();
  }
}

class _FormatFontRoute extends MaterialPageRoute<void> {
  _FormatFontRoute({required super.builder, required this.onCovered})
    : super(requestFocus: false);

  final VoidCallback onCovered;

  @override
  void didChangeNext(Route<dynamic>? nextRoute) {
    super.didChangeNext(nextRoute);
    if (nextRoute != null) onCovered();
  }
}

typedef _LinkResult = ({bool remove, String value, String text});

class _FormatLinkRoute extends ModalBottomSheetRoute<_LinkResult> {
  _FormatLinkRoute({
    required super.builder,
    required super.capturedThemes,
    required super.barrierLabel,
    required super.barrierOnTapHint,
    required this.onCovered,
  }) : super(
         isScrollControlled: true,
         requestFocus: false,
         useSafeArea: true,
         showDragHandle: true,
       );

  final VoidCallback onCovered;

  @override
  void didChangeNext(Route<dynamic>? nextRoute) {
    super.didChangeNext(nextRoute);
    if (nextRoute != null) onCovered();
  }
}

enum _InsertBlock {
  h1,
  h2,
  h3,
  paragraph,
  todo,
  quote,
  bullet,
  numbered,
  toggle,
  toggleH1,
  toggleH2,
  toggleH3,
  divider,
}

bool _styleActive(af.EditorState editor, af.Selection selection, String key) {
  if (selection.isCollapsed && editor.toggledStyle.containsKey(key)) {
    return editor.toggledStyle[key] == true;
  }
  var selected = selection;
  if (selection.isCollapsed) {
    if (selection.start.offset <= 0) return false;
    selected = af.Selection.single(
      path: selection.start.path,
      startOffset: selection.start.offset - 1,
      endOffset: selection.start.offset,
    );
  }
  final nodes = editor.getNodesInSelection(selected);
  if (nodes.isEmpty) return false;
  return af.NodesExtensions<af.Node>(nodes)
      .allSatisfyInSelection(selected, (delta) {
        final ops = delta.toJson();
        return ops.isNotEmpty &&
            ops.every((raw) {
              if (raw is! Map) return false;
              final attributes = raw['attributes'];
              return attributes is Map && attributes[key] == true;
            });
      });
}

bool _blockTypeActive(
  af.EditorState editor,
  af.Selection selection,
  String type, {
  int? level,
}) {
  final nodes = editor.getNodesInSelection(selection);
  return nodes.isNotEmpty &&
      nodes.every(
        (node) =>
            node.type == type &&
            (type != af.HeadingBlockKeys.type ||
                node.attributes[af.HeadingBlockKeys.level] == level),
      );
}

bool _blockAlignActive(
  af.EditorState editor,
  af.Selection selection,
  String align,
) {
  final nodes = editor.getNodesInSelection(selection);
  return nodes.isNotEmpty &&
      nodes.every(
        (node) => (node.attributes[af.blockComponentAlign] ?? 'left') == align,
      );
}

/// Null is the default style. A mixed or unsupported selection is unknown,
/// rather than silently presenting it as the default.
({bool known, String? value}) _currentInlineString(
  af.EditorState editor,
  af.Selection selection,
  String key,
) {
  ({bool known, String? value}) valueOf(Object? value) => switch (value) {
    null => (known: true, value: null),
    final String text => (known: true, value: text),
    _ => (known: false, value: null),
  };
  if (selection.isCollapsed) {
    if (editor.toggledStyle.containsKey(key)) {
      return valueOf(editor.toggledStyle[key]);
    }
    if (!editor.sliceUpcomingAttributes) return (known: true, value: null);
    final node = editor.document.nodeAtPath(selection.start.path);
    final delta = node?.delta;
    if (delta == null) return (known: false, value: null);
    return valueOf(delta.sliceAttributes(selection.start.offset)?[key]);
  }
  final normalized = selection.normalized;
  final start = editor.document.nodeAtPath(normalized.start.path);
  final end = editor.document.nodeAtPath(normalized.end.path);
  final nodes = editor.getNodesInSelection(normalized);
  if (start == null || end == null || nodes.isEmpty) {
    return (known: false, value: null);
  }
  var seen = false;
  String? value;
  for (final node in nodes) {
    final delta = node.delta;
    if (delta == null) return (known: false, value: null);
    final from = identical(node, start) ? normalized.start.offset : 0;
    final to = identical(node, end) ? normalized.end.offset : delta.length;
    if (from < 0 || to > delta.length || from > to) {
      return (known: false, value: null);
    }
    for (final op in delta.slice(from, to)) {
      if (op is! af.TextInsert || op.length == 0) continue;
      final current = valueOf(op.attributes?[key]);
      if (!current.known || (seen && current.value != value)) {
        return (known: false, value: null);
      }
      seen = true;
      value = current.value;
    }
  }
  return (known: seen, value: value);
}

af.Selection? _selectionSnapshot(af.Selection? selection) => selection == null
    ? null
    : af.Selection(
        start: af.Position(
          path: List.of(selection.start.path),
          offset: selection.start.offset,
        ),
        end: af.Position(
          path: List.of(selection.end.path),
          offset: selection.end.offset,
        ),
      );

class _RichEditorToolbarState extends State<RichEditorToolbar>
    with WidgetsBindingObserver {
  static const _keyboardToolbarHeight = 42.0;
  // Reserve a usable horizontal target for each button before showing a
  // shortcut. The toolbar's existing height is a separate design constraint.
  static const _minToolbarSlotWidth = 48.0;
  late StreamSubscription<dynamic> _transactions;
  int _revision = 0;
  int _selectionRevision = 0;
  af.Selection? _observedSelection;
  bool _busy = false;
  late final bool Function() _handleEditorBack = _handleFormatBack;
  _SelectionSession? _formatSession;
  af.EditorState? _formatEditor;
  FocusNode? _formatFocus;
  ModalRoute<dynamic>? _formatRoute;
  LocalHistoryEntry? _formatHistory;
  TransitionRoute<dynamic>? _formatChildRoute;
  LocalHistoryEntry? _formatMenuHistory;
  LocalHistoryEntry? _formatInlineHistory;
  final MenuController _formatMoreController = MenuController();
  final MenuController _formatInlineController = MenuController();
  bool _formatOpening = false;
  bool _formatKeyboardWasVisible = false;
  bool _formatNeedsInputReconnect = false;
  bool _disposing = false;
  double _formatHeight = 280;
  double? _formatAnchorBottom;
  int _formatAnchorRevision = 0;
  int _focusRevision = 0;
  int _lifecycleRevision = 0;
  int _formatFocusRevision = 0;
  int _editableRevision = 0;
  int _formatEditableRevision = 0;
  int _routeRevision = 0;
  int _formatRouteRevision = 0;
  ModalRoute<dynamic>? _observedRoute;
  bool? _observedRouteCurrent;
  final _contentKey = GlobalKey();
  bool _geometryQueued = false;
  ({
    Offset position,
    double width,
    double height,
    bool editable,
    _SelectionSession session,
  })?
  _floating;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    widget.backController?.attach(_handleEditorBack);
    widget.focusNode.addListener(_focusChanged);
    widget.scrollController?.offsetNotifier.addListener(
      _scheduleFloatingGeometry,
    );
    _observedSelection = _selectionSnapshot(widget.editor.selection);
    widget.editor.selectionNotifier.addListener(_selectionChanged);
    widget.editor.editableNotifier.addListener(_editorEditableChanged);
    _listenTransactions();
  }

  void _listenTransactions() {
    _transactions = widget.editor.transactionStream.listen((event) {
      if (event.$1 == af.TransactionTime.after) {
        _revision++;
        _scheduleFloatingGeometry();
        if (mounted) setState(() {});
      }
    });
  }

  @override
  void didUpdateWidget(covariant RichEditorToolbar oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!identical(oldWidget.backController, widget.backController)) {
      oldWidget.backController?.detach(_handleEditorBack);
      widget.backController?.attach(_handleEditorBack);
    }
    if (!identical(oldWidget.focusNode, widget.focusNode)) {
      _focusRevision++;
      _scheduleFormatInvalidation();
      oldWidget.focusNode.removeListener(_focusChanged);
      widget.focusNode.addListener(_focusChanged);
    }
    if (!identical(oldWidget.scrollController, widget.scrollController)) {
      oldWidget.scrollController?.offsetNotifier.removeListener(
        _scheduleFloatingGeometry,
      );
      widget.scrollController?.offsetNotifier.addListener(
        _scheduleFloatingGeometry,
      );
      _floating = null;
      _scheduleFloatingGeometry();
    }
    if (!identical(oldWidget.editor, widget.editor)) {
      _scheduleFormatInvalidation();
      oldWidget.editor.selectionNotifier.removeListener(_selectionChanged);
      oldWidget.editor.editableNotifier.removeListener(_editorEditableChanged);
      _transactions.cancel();
      _revision++;
      _selectionRevision++;
      _floating = null;
      _scheduleFloatingGeometry();
      _observedSelection = _selectionSnapshot(widget.editor.selection);
      widget.editor.selectionNotifier.addListener(_selectionChanged);
      widget.editor.editableNotifier.addListener(_editorEditableChanged);
      _listenTransactions();
    }
    if (oldWidget.editable != widget.editable) {
      _editableRevision++;
      _scheduleFormatInvalidation();
      _floating = null;
      _scheduleFloatingGeometry();
    }
  }

  @override
  void dispose() {
    _disposing = true;
    widget.backController?.detach(_handleEditorBack);
    _closeFormatPanel(restoreKeyboard: false);
    WidgetsBinding.instance.removeObserver(this);
    widget.focusNode.removeListener(_focusChanged);
    widget.scrollController?.offsetNotifier.removeListener(
      _scheduleFloatingGeometry,
    );
    widget.editor.selectionNotifier.removeListener(_selectionChanged);
    widget.editor.editableNotifier.removeListener(_editorEditableChanged);
    _transactions.cancel();
    super.dispose();
  }

  void _focusChanged() {
    _focusRevision++;
    _scheduleFloatingGeometry();
    if (mounted) setState(() {});
  }

  void _editorEditableChanged() {
    if (!mounted) return;
    _editableRevision++;
    _scheduleFormatInvalidation();
    _floating = null;
    _scheduleFloatingGeometry();
    final editor = widget.editor;
    // The editor may update its editable flag during its parent's build.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted && identical(widget.editor, editor)) setState(() {});
    });
    WidgetsBinding.instance.scheduleFrame();
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final route = ModalRoute.of(context);
    final current = route?.isCurrent;
    if (!identical(route, _observedRoute) ||
        (_observedRouteCurrent != null && current != _observedRouteCurrent)) {
      final child = _formatChildRoute;
      final expectedChildTransition =
          identical(route, _formatRoute) &&
          child != null &&
          ((current == false && child.isCurrent) ||
              (current == true && !child.isCurrent));
      if (!expectedChildTransition) _routeRevision++;
    }
    _observedRoute = route;
    _observedRouteCurrent = current;
    _scheduleFloatingGeometry();
  }

  @override
  void didChangeMetrics() {
    _scheduleFloatingGeometry();
    if (mounted) setState(() {});
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state != AppLifecycleState.resumed) {
      _focusRevision++;
      _lifecycleRevision++;
    }
  }

  void _selectionChanged() {
    // AppFlowy's PropertyValueNotifier also notifies for unchanged values.
    // Count actual changes, including an away-and-back sequence, instead.
    final current = widget.editor.selection;
    if (_observedSelection != current) {
      _selectionRevision++;
      _observedSelection = _selectionSnapshot(current);
    }
    // The SDK may notify with the same selection when a drag ends.
    _scheduleFloatingGeometry();
    if (mounted) setState(() {});
  }

  bool get _editable =>
      widget.editable && widget.editor.editable && !widget.editor.isDisposed;

  bool get _floatingEligible {
    if (!mounted ||
        widget.editor.isDisposed ||
        _busy ||
        !widget.focusNode.hasFocus ||
        ModalRoute.of(context)?.isCurrent != true) {
      return false;
    }
    final dragMode = widget.editor.selectionExtraInfo?['selection_drag_mode']
        ?.toString();
    if (dragMode == 'MobileSelectionDragMode.leftSelectionHandle' ||
        dragMode == 'MobileSelectionDragMode.rightSelectionHandle' ||
        widget.editor.selectionExtraInfo?[af
                .selectionExtraInfoDisableFloatingToolbar] ==
            true) {
      return false;
    }
    final selection = widget.editor.selection;
    return selection != null &&
        !selection.isCollapsed &&
        _validSelection(selection, allowReadOnly: true) &&
        (_editable ? _textOnly(selection) : _copyableText(selection));
  }

  void _scheduleFloatingGeometry() {
    if (_geometryQueued || !mounted) return;
    _geometryQueued = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _geometryQueued = false;
      if (!mounted) return;
      final session = _floatingEligible ? _capture(allowReadOnly: true) : null;
      final box = _contentKey.currentContext?.findRenderObject();
      if (session == null ||
          box is! RenderBox ||
          !box.attached ||
          !box.hasSize) {
        if (_floating != null) setState(() => _floating = null);
        return;
      }
      final origin = box.localToGlobal(Offset.zero);
      // With the keyboard open the bottom area belongs to the fixed toolbar,
      // so the floating menu must fit inside the remaining editor surface.
      final toolbarHeight = _editable && View.of(context).viewInsets.bottom > 0
          ? _keyboardToolbarHeight
          : 0.0;
      final contentHeight = (box.size.height - toolbarHeight).clamp(
        0.0,
        box.size.height,
      );
      final bounds = origin & Size(box.size.width, contentHeight);
      final visible = widget.editor
          .selectionRects()
          .where((r) => !r.isEmpty && r.overlaps(bounds))
          .toList();
      if (visible.isEmpty) {
        if (_floating != null) setState(() => _floating = null);
        return;
      }
      final first = visible.reduce((a, b) => a.top <= b.top ? a : b);
      final last = visible.reduce((a, b) => a.bottom >= b.bottom ? a : b);
      const itemWidth = 42.0;
      const itemHeight = 44.0;
      const gap = 8.0;
      final editable = _editable;
      final itemCount = !editable
          ? 2
          : session.selection.isSingle
          ? 6
          : 5;
      final maxColumns = (bounds.width / itemWidth).floor();
      if (maxColumns < 1) {
        if (_floating != null) setState(() => _floating = null);
        return;
      }
      // Keep every selection action available without squeezing icons into
      // unusably narrow columns. Balance the rows when the surface is narrow.
      final rows = (itemCount / maxColumns.clamp(1, itemCount)).ceil();
      final columns = (itemCount / rows).ceil();
      final width = columns * itemWidth;
      final height = rows * itemHeight;
      final above = first.top - bounds.top - height - gap;
      final below = last.bottom - bounds.top + gap;
      final double? top = above >= 0
          ? above
          : below + height <= bounds.height
          ? below
          : null;
      if (top == null || width < 42) {
        if (_floating != null) setState(() => _floating = null);
        return;
      }
      final left = (first.center.dx - bounds.left - width / 2).clamp(
        0.0,
        bounds.width - width,
      );
      final position = Offset(left, top);
      final previous = _floating;
      if (previous == null ||
          previous.position != position ||
          previous.width != width ||
          previous.height != height ||
          previous.editable != editable ||
          previous.session.revision != session.revision ||
          previous.session.selectionRevision != session.selectionRevision) {
        setState(
          () => _floating = (
            position: position,
            width: width,
            height: height,
            editable: editable,
            session: session,
          ),
        );
      }
    });
  }

  void _floatingAction(
    _SelectionSession session,
    VoidCallback action, {
    bool requiresEditing = true,
  }) {
    if (!_floatingEligible ||
        !_sessionValid(session, allowReadOnly: !requiresEditing)) {
      if (mounted) _selectionExpired();
      return;
    }
    action();
  }

  Widget _surface(Widget child, bool showFloating) {
    if (showFloating) _scheduleFloatingGeometry();
    final floating = _floating;
    final valid =
        showFloating &&
        floating != null &&
        floating.editable == _editable &&
        _sessionValid(floating.session, allowReadOnly: true);
    return Stack(
      key: _contentKey,
      fit: StackFit.expand,
      children: [
        NotificationListener<ScrollNotification>(
          onNotification: (_) {
            _scheduleFloatingGeometry();
            return false;
          },
          child: child,
        ),
        if (valid)
          Positioned(
            left: floating.position.dx,
            top: floating.position.dy,
            width: floating.width,
            height: floating.height,
            child: Material(
              key: const ValueKey('rich-selection-menu'),
              color: context.theme.colors.surface,
              elevation: 4,
              borderRadius: BorderRadius.circular(8),
              clipBehavior: Clip.antiAlias,
              child: Wrap(
                children: [
                  if (_editable)
                    SizedBox(
                      width: 42,
                      height: 44,
                      child: _floatingButton(
                        'format',
                        context.l10n.editor.toolbar.format,
                        LucideIcons.caseSensitive,
                        floating.session,
                        _openFormat,
                      ),
                    ),
                  if (_editable)
                    SizedBox(
                      width: 42,
                      height: 44,
                      child: _floatingButton(
                        'bold',
                        context.l10n.editor.toolbar.bold,
                        LucideIcons.bold,
                        floating.session,
                        () => _quick(
                          (s) => _toggle(s, af.AppFlowyRichTextKeys.bold),
                        ),
                      ),
                    ),
                  if (_editable)
                    SizedBox(
                      width: 42,
                      height: 44,
                      child: _floatingButton(
                        'italic',
                        context.l10n.editor.toolbar.italic,
                        LucideIcons.italic,
                        floating.session,
                        () => _quick(
                          (s) => _toggle(s, af.AppFlowyRichTextKeys.italic),
                        ),
                      ),
                    ),
                  if (_editable && floating.session.selection.isSingle)
                    SizedBox(
                      width: 42,
                      height: 44,
                      child: _floatingButton(
                        'link',
                        context.l10n.editor.toolbar.link,
                        LucideIcons.link,
                        floating.session,
                        _openLink,
                      ),
                    ),
                  SizedBox(
                    width: 42,
                    height: 44,
                    child: _floatingButton(
                      'copy',
                      MaterialLocalizations.of(context).copyButtonLabel,
                      LucideIcons.copy,
                      floating.session,
                      () => af.copyCommand.execute(widget.editor),
                      requiresEditing: false,
                    ),
                  ),
                  SizedBox(
                    width: 42,
                    height: 44,
                    child: _floatingButton(
                      'select-all',
                      MaterialLocalizations.of(context).selectAllButtonLabel,
                      Icons.select_all,
                      floating.session,
                      () => af.selectAllCommand.execute(widget.editor),
                      requiresEditing: false,
                    ),
                  ),
                ],
              ),
            ),
          ),
      ],
    );
  }

  Widget _floatingButton(
    String id,
    String tooltip,
    IconData icon,
    _SelectionSession session,
    VoidCallback action, {
    bool requiresEditing = true,
  }) => IconButton(
    key: ValueKey('rich-floating-$id'),
    tooltip: tooltip,
    iconSize: 20,
    padding: EdgeInsets.zero,
    icon: Icon(icon),
    onPressed: () =>
        _floatingAction(session, action, requiresEditing: requiresEditing),
  );

  bool _validSelection(af.Selection? selection, {bool allowReadOnly = false}) {
    if (widget.editor.isDisposed ||
        (!allowReadOnly && !_editable) ||
        selection == null) {
      return false;
    }
    bool validPosition(af.Position position) {
      final node = widget.editor.document.nodeAtPath(position.path);
      final delta = node?.delta;
      return delta != null &&
          position.offset >= 0 &&
          position.offset <= delta.length;
    }

    return validPosition(selection.start) && validPosition(selection.end);
  }

  _SelectionSession? _capture({bool allowReadOnly = false}) {
    final selection = widget.editor.selection;
    if (!_validSelection(selection, allowReadOnly: allowReadOnly)) return null;
    final saved = _selectionSnapshot(selection)!;
    return _SelectionSession(
      saved,
      widget.editor.document.nodeAtPath(saved.start.path)!,
      widget.editor.document.nodeAtPath(saved.end.path)!,
      _revision,
      _selectionRevision,
    );
  }

  bool _sessionValid(_SelectionSession session, {bool allowReadOnly = false}) =>
      mounted &&
      !session.expired &&
      _validSelection(session.selection, allowReadOnly: allowReadOnly) &&
      widget.editor.selection == session.selection &&
      session.revision == _revision &&
      session.selectionRevision == _selectionRevision &&
      identical(
        widget.editor.document.nodeAtPath(session.selection.start.path),
        session.startNode,
      ) &&
      identical(
        widget.editor.document.nodeAtPath(session.selection.end.path),
        session.endNode,
      );

  Future<bool> _runSession(
    _SelectionSession session,
    Future<void> Function(af.Selection selection) command, {
    bool allowMovedSelection = false,
  }) async {
    if (_busy || !_sessionValid(session)) return false;
    final before = _revision;
    final selectionBefore = _selectionRevision;
    setState(() => _busy = true);
    try {
      await command(session.selection);
      if (!mounted || !_editable) return false;
      final selection = widget.editor.selection;
      // A command can generate at most one document transaction. If anything
      // else changed concurrently, never reuse the old menu selection.
      if (_revision < before ||
          _revision > before + 1 ||
          _selectionRevision < selectionBefore ||
          _selectionRevision >
              selectionBefore + (allowMovedSelection ? 1 : 0) ||
          !_validSelection(selection) ||
          (!allowMovedSelection && selection != session.selection)) {
        session.expired = true;
        return false;
      }
      session.selection = selection!;
      session.startNode = widget.editor.document.nodeAtPath(
        selection.start.path,
      )!;
      session.endNode = widget.editor.document.nodeAtPath(selection.end.path)!;
      session.revision = _revision;
      session.selectionRevision = _selectionRevision;
      return true;
    } catch (_) {
      session.expired = true;
      return false;
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  bool _copyableText(af.Selection selection) {
    final nodes = widget.editor.getNodesInSelection(selection);
    return nodes.isNotEmpty && nodes.every((node) => node.delta != null);
  }

  bool _textOnly(af.Selection selection) {
    final nodes = widget.editor.getNodesInSelection(selection);
    const supported = {
      af.ParagraphBlockKeys.type,
      af.HeadingBlockKeys.type,
      af.TodoListBlockKeys.type,
      af.BulletedListBlockKeys.type,
      af.NumberedListBlockKeys.type,
      af.QuoteBlockKeys.type,
      DocumentToggleKeys.type,
    };
    return nodes.isNotEmpty &&
        nodes.every(
          (node) => supported.contains(node.type) && node.delta != null,
        );
  }

  bool _canConvert(af.Selection selection) {
    if (!_textOnly(selection)) return false;
    final nodes = widget.editor.getNodesInSelection(selection);
    // AppFlowy's conversion replaces each selected node. Never replace an
    // ancestor and descendant in the same transaction.
    return nodes.isNotEmpty &&
        nodes.every((node) => node.type != DocumentToggleKeys.type) &&
        nodes.every((node) => identical(node.parent, nodes.first.parent));
  }

  Future<void> _toggle(af.Selection selection, String key) =>
      widget.editor.toggleAttribute(
        key,
        selection: selection,
        selectionExtraInfo: {af.selectionExtraInfoDoNotAttachTextService: true},
      );

  Future<void> _convert(
    af.Selection selection,
    String type, {
    int? level,
  }) async {
    if (!_canConvert(selection)) return;
    final nodes = widget.editor.getNodesInSelection(selection);
    final selected = nodes.every(
      (node) =>
          node.type == type &&
          (type != af.HeadingBlockKeys.type ||
              node.attributes[af.HeadingBlockKeys.level] == level),
    );
    final destination = selected && type != af.ParagraphBlockKeys.type
        ? af.ParagraphBlockKeys.type
        : type;
    await widget.editor.formatNode(selection, (node) {
      final attrs = {...node.attributes}
        ..remove(af.HeadingBlockKeys.level)
        ..remove(af.TodoListBlockKeys.checked);
      if (destination == af.HeadingBlockKeys.type) {
        attrs[af.HeadingBlockKeys.level] = level;
      }
      if (destination == af.TodoListBlockKeys.type) {
        attrs[af.TodoListBlockKeys.checked] =
            node.type == af.TodoListBlockKeys.type
            ? (node.attributes[af.TodoListBlockKeys.checked] ?? false)
            : false;
      }
      return node.copyWith(type: destination, attributes: attrs);
    }, selectionExtraInfo: {af.selectionExtraInfoDoNotAttachTextService: true});
  }

  Future<void> _color(af.Selection selection, String key, String? color) async {
    if (selection.isCollapsed) {
      widget.editor.updateToggledStyle(key, color);
    } else {
      await widget.editor.formatDelta(
        selection,
        {key: color},
        selectionExtraInfo: {af.selectionExtraInfoDoNotAttachTextService: true},
      );
    }
  }

  Future<void> _align(af.Selection selection, String value) =>
      widget.editor.updateNode(
        selection,
        (node) => node.copyWith(
          attributes: {...node.attributes, af.blockComponentAlign: value},
        ),
        selectionExtraInfo: {af.selectionExtraInfoDoNotAttachTextService: true},
      );

  Future<void> _quick(Future<void> Function(af.Selection) command) async {
    final session = _formatSession ?? _capture();
    if (session == null || _busy || !_textOnly(session.selection)) return;
    if (_formatSession != null && !_formatValid(session)) return;
    await _runSession(session, command);
  }

  Future<void> _openInsert() async {
    if (_formatSession != null) _closeFormatPanel(restoreKeyboard: false);
    final session = _capture();
    if (session == null ||
        !session.selection.isCollapsed ||
        !_textOnly(session.selection)) {
      return;
    }
    final chosen = await showModalBottomSheet<_InsertBlock>(
      context: context,
      requestFocus: false,
      isScrollControlled: true,
      showDragHandle: true,
      useSafeArea: true,
      builder: (sheet) =>
          _InsertSheet(onSelect: (item) => Navigator.pop(sheet, item)),
    );
    if (chosen == null || !mounted) return;
    final success = await _runSession(
      session,
      (selection) => _insert(selection, chosen),
      allowMovedSelection: true,
    );
    if (!success && mounted) _selectionExpired();
  }

  Future<void> _insert(af.Selection selection, _InsertBlock item) async {
    final path = selection.end.path;
    final current = widget.editor.document.nodeAtPath(path);
    if (current == null || current.delta == null) {
      throw StateError('invalid_selection');
    }
    if (item == _InsertBlock.divider) {
      // An empty paragraph is already the editable block after the divider.
      // Reuse it, including any attributes and descendants, instead of
      // inserting another blank line or leaving the caret on the divider.
      final reuseCurrent =
          current.type == af.ParagraphBlockKeys.type && current.delta!.isEmpty;
      final insertedPath = reuseCurrent ? path : ([...path]..last += 1);
      final next = reuseCurrent ? current : current.next;
      final reuseNext =
          next?.type == af.ParagraphBlockKeys.type &&
          next?.delta?.isEmpty == true;
      final transaction = widget.editor.transaction;
      transaction.insertNodes(insertedPath, [
        af.dividerNode(),
        if (!reuseNext) af.paragraphNode(),
      ]);
      transaction.afterSelection = af.Selection.collapsed(
        af.Position(path: [...insertedPath]..last += 1),
      );
      await _applyInsertedBlock(transaction);
      return;
    }
    final block = switch (item) {
      _InsertBlock.h1 => af.headingNode(level: 1),
      _InsertBlock.h2 => af.headingNode(level: 2),
      _InsertBlock.h3 => af.headingNode(level: 3),
      _InsertBlock.paragraph => af.paragraphNode(),
      _InsertBlock.todo => af.todoListNode(checked: false),
      _InsertBlock.quote => af.quoteNode(),
      _InsertBlock.bullet => af.bulletedListNode(),
      _InsertBlock.numbered => af.numberedListNode(),
      _InsertBlock.toggle => documentToggleNode(),
      _InsertBlock.toggleH1 => documentToggleNode(level: 1),
      _InsertBlock.toggleH2 => documentToggleNode(level: 2),
      _InsertBlock.toggleH3 => documentToggleNode(level: 3),
      _InsertBlock.divider => throw StateError('unreachable'),
    };
    final emptyParagraph =
        current.type == af.ParagraphBlockKeys.type &&
        current.delta!.isEmpty &&
        current.children.isEmpty &&
        current.attributes.keys.every(
          (key) => key == af.ParagraphBlockKeys.delta,
        );
    final nextPath = [...path]..last += 1;
    final transaction = widget.editor.transaction..insertNode(nextPath, block);
    if (emptyParagraph) transaction.deleteNode(current);
    transaction.afterSelection = af.Selection.collapsed(
      af.Position(path: emptyParagraph ? path : nextPath),
    );
    await _applyInsertedBlock(transaction);
  }

  Future<void> _applyInsertedBlock(af.Transaction transaction) async {
    // Insertion is one undo step, independent of the user's preceding typing.
    if (widget.editor.undoManager.undoStack.isNonEmpty) {
      widget.editor.undoManager.undoStack.last.seal();
    }
    await widget.editor.apply(transaction, skipHistoryDebounce: true);
  }

  bool _formatValid(_SelectionSession session) =>
      identical(_formatSession, session) &&
      identical(_formatEditor, widget.editor) &&
      identical(_formatFocus, widget.focusNode) &&
      (_formatRoute?.isCurrent == true ||
          (_formatRoute?.isActive == true &&
              _formatChildRoute?.isCurrent == true)) &&
      _formatRouteRevision == _routeRevision &&
      _formatFocusRevision == _focusRevision &&
      _formatEditableRevision == _editableRevision &&
      !_busy &&
      _sessionValid(session);

  void _scheduleFormatInvalidation() {
    final session = _formatSession;
    if (session == null) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted &&
          identical(_formatSession, session) &&
          (!_editable ||
              !identical(_formatEditor, widget.editor) ||
              !identical(_formatFocus, widget.focusNode) ||
              _formatEditableRevision != _editableRevision)) {
        _closeFormatPanel(restoreKeyboard: false);
      }
    });
  }

  bool _handleFormatBack() {
    if (_formatSession == null) return false;
    final child = _formatChildRoute;
    if (child != null) {
      if (child.isCurrent) {
        child.navigator?.pop();
      } else if (_formatRoute?.isCurrent == true) {
        // A child can already be closed while its keyboard response is still
        // pending. Let a second back cancel the parent session immediately.
        _closeFormatPanel(restoreKeyboard: false);
      }
      return true;
    }
    if (_formatInlineController.isOpen) {
      _formatInlineController.close();
      return true;
    }
    if (_formatMoreController.isOpen) {
      _formatMoreController.close();
      return true;
    }
    _closeFormatPanel(restoreKeyboard: false);
    return true;
  }

  void _formatChildCovered(TransitionRoute<dynamic> child) {
    if (!identical(_formatChildRoute, child)) return;
    _routeRevision++;
  }

  void _pushFormatChild(TransitionRoute<dynamic> child) {
    final session = _formatSession;
    if (session == null ||
        !_formatValid(session) ||
        _formatRoute?.isCurrent != true ||
        _formatChildRoute != null) {
      return;
    }
    final navigator = Navigator.of(context);
    _formatChildRoute = child;
    unawaited(() async {
      await navigator.push(child);
      await child.completed;
      if (mounted && identical(_formatChildRoute, child)) {
        setState(() => _formatChildRoute = null);
      }
    }());
  }

  void _closeFormatPanel({required bool restoreKeyboard}) {
    final session = _formatSession;
    if (session == null) return;
    final shouldRestore =
        restoreKeyboard &&
        _formatKeyboardWasVisible &&
        widget.focusNode.hasFocus &&
        _formatValid(session);
    final reconnectInput = _formatNeedsInputReconnect;
    _formatNeedsInputReconnect = false;
    _formatSession = null;
    _formatEditor = null;
    _formatFocus = null;
    _formatRoute = null;
    _formatAnchorBottom = null;
    final child = _formatChildRoute;
    final history = _formatHistory;
    final menuHistory = _formatMenuHistory;
    final inlineHistory = _formatInlineHistory;
    _formatChildRoute = null;
    _formatHistory = null;
    _formatMenuHistory = null;
    _formatInlineHistory = null;
    menuHistory?.remove();
    inlineHistory?.remove();
    if (_formatMoreController.isOpen) _formatMoreController.close();
    if (_formatInlineController.isOpen) _formatInlineController.close();
    if (child != null) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        final navigator = child.navigator;
        if (navigator != null && navigator.mounted && child.isActive) {
          navigator.removeRoute(child);
        }
      });
      WidgetsBinding.instance.scheduleFrame();
    }
    history?.remove();
    if (!_disposing && mounted) {
      setState(() {});
      _scheduleFloatingGeometry();
    }
    if (shouldRestore) {
      if (reconnectInput) {
        widget.editor.service.keyboardService?.enableKeyBoard(
          session.selection,
        );
      }
      unawaited(
        SystemChannels.textInput
            .invokeMethod<void>('TextInput.show')
            .catchError(
              (Object error, StackTrace stack) => logger.e(
                'Unable to restore the editor keyboard',
                error: error,
                stackTrace: stack,
              ),
            ),
      );
    }
  }

  Future<void> _openFormat() async {
    if (_formatSession != null) {
      _handleFormatBack();
      return;
    }
    if (_formatOpening) return;
    final session = _capture();
    final route = ModalRoute.of(context);
    if (session == null ||
        !_textOnly(session.selection) ||
        route?.isCurrent != true ||
        !widget.focusNode.hasFocus) {
      return;
    }
    final editor = widget.editor;
    final focus = widget.focusNode;
    final initialRects = editor.selectionRects();
    final initialBottom = initialRects.isEmpty
        ? null
        : initialRects
              .map((rect) => rect.bottom)
              .reduce((a, b) => a > b ? a : b);
    final focusRevision = _focusRevision;
    final editableRevision = _editableRevision;
    final routeRevision = _routeRevision;
    final view = View.of(context);
    final keyboardHeight = view.viewInsets.bottom / view.devicePixelRatio;
    final keyboardWasVisible = keyboardHeight > 0;
    final initialHeight = MediaQuery.sizeOf(context).height * .5;
    _formatOpening = true;
    try {
      await SystemChannels.textInput.invokeMethod<void>('TextInput.hide');
    } catch (error, stack) {
      logger.e(
        'Unable to hide the editor keyboard',
        error: error,
        stackTrace: stack,
      );
      return;
    } finally {
      _formatOpening = false;
    }
    if (!mounted ||
        !identical(editor, widget.editor) ||
        !identical(focus, widget.focusNode) ||
        !focus.hasFocus ||
        _focusRevision != focusRevision ||
        _editableRevision != editableRevision ||
        _routeRevision != routeRevision ||
        route?.isCurrent != true ||
        !_sessionValid(session)) {
      return;
    }
    _formatSession = session;
    _formatEditor = editor;
    _formatFocus = focus;
    _formatRoute = route;
    _formatFocusRevision = focusRevision;
    _formatEditableRevision = editableRevision;
    _formatRouteRevision = routeRevision;
    _formatKeyboardWasVisible = keyboardWasVisible;
    _formatNeedsInputReconnect = false;
    _formatHeight = initialHeight;
    _formatAnchorBottom = initialBottom;
    _formatAnchorRevision++;
    late final LocalHistoryEntry entry;
    entry = LocalHistoryEntry(
      impliesAppBarDismissal: false,
      onRemove: () {
        if (!identical(_formatHistory, entry)) return;
        _formatHistory = null;
        _closeFormatPanel(restoreKeyboard: false);
      },
    );
    _formatHistory = entry;
    route!.addLocalHistoryEntry(entry);
    if (mounted) setState(() => _floating = null);
  }

  Future<void> _openColor() async {
    if (_formatSession != null) {
      final session = _formatSession!;
      if (!_formatValid(session)) return;
      final navigator = Navigator.of(context);
      final localizations = MaterialLocalizations.of(context);
      late final _FormatColorRoute child;
      child = _FormatColorRoute(
        onCovered: () => _formatChildCovered(child),
        capturedThemes: InheritedTheme.capture(
          from: context,
          to: navigator.context,
        ),
        barrierLabel: localizations.scrimLabel,
        barrierOnTapHint: localizations.scrimOnTapHint(
          localizations.bottomSheetLabel,
        ),
        builder: (_) => _QuickColorSheet(
          key: const ValueKey('rich-format-color-sheet'),
          editor: widget.editor,
          valid: () => _formatValid(session),
          execute: (command) => _runSession(session, command),
          color: _color,
        ),
      );
      _pushFormatChild(child);
      return;
    }
    final session = _capture();
    if (session == null || !_textOnly(session.selection)) return;
    final keyboardWasVisible =
        View.of(context).viewInsets.bottom > 0 && widget.focusNode.hasFocus;
    await SystemChannels.textInput.invokeMethod<void>('TextInput.hide');
    if (!mounted || !_sessionValid(session)) return;
    final done = await showModalBottomSheet<bool>(
      context: context,
      requestFocus: false,
      isScrollControlled: true,
      useSafeArea: true,
      showDragHandle: true,
      builder: (_) => _QuickColorSheet(
        editor: widget.editor,
        valid: () => _sessionValid(session) && !_busy,
        execute: (command) => _runSession(session, command),
        color: _color,
      ),
    );
    if (done == true &&
        keyboardWasVisible &&
        mounted &&
        widget.focusNode.hasFocus &&
        ModalRoute.of(context)?.isCurrent == true &&
        _sessionValid(session)) {
      await SystemChannels.textInput.invokeMethod<void>('TextInput.show');
    }
  }

  void _openFormatFonts() {
    final session = _formatSession;
    if (session == null || !_formatValid(session)) return;
    late final _FormatFontRoute child;
    child = _FormatFontRoute(
      onCovered: () => _formatChildCovered(child),
      builder: (_) => _FormatFontPage(
        editor: widget.editor,
        valid: () => _formatValid(session),
        execute: (command) => _runSession(session, command),
        color: _color,
        loadFonts: widget.loadFonts,
      ),
    );
    _pushFormatChild(child);
  }

  Future<void> _openFormatLink() async {
    final session = _formatSession;
    if (session == null ||
        !_formatValid(session) ||
        !session.selection.isSingle ||
        _formatChildRoute != null) {
      return;
    }
    final editor = widget.editor;
    final focus = widget.focusNode;
    final lifecycleRevision = _lifecycleRevision;
    final initialFocusRevision = _focusRevision;
    final existing = editor.getDeltaAttributeValueInSelection<String>(
      af.AppFlowyRichTextKeys.href,
      session.selection,
    );
    final navigator = Navigator.of(context);
    final localizations = MaterialLocalizations.of(context);
    late final _FormatLinkRoute child;
    child = _FormatLinkRoute(
      onCovered: () => _formatChildCovered(child),
      capturedThemes: InheritedTheme.capture(
        from: context,
        to: navigator.context,
      ),
      barrierLabel: localizations.scrimLabel,
      barrierOnTapHint: localizations.scrimOnTapHint(
        localizations.bottomSheetLabel,
      ),
      builder: (_) => _LinkDialog(
        key: const ValueKey('rich-format-link-sheet'),
        existing: existing,
        initialText: _selectedLinkText(editor, session.selection),
        asSheet: true,
      ),
    );
    _formatChildRoute = child;
    final result = await navigator.push(child);
    await child.completed;
    if (!mounted ||
        !identical(_formatSession, session) ||
        !identical(_formatChildRoute, child)) {
      return;
    }

    bool focusCanReturn() {
      final primary = FocusManager.instance.primaryFocus;
      return primary == null || focus.hasFocus || primary is FocusScopeNode;
    }

    bool contextIsCurrent() =>
        mounted &&
        identical(_formatSession, session) &&
        identical(_formatChildRoute, child) &&
        identical(widget.editor, editor) &&
        identical(widget.focusNode, focus) &&
        _formatRoute?.isCurrent == true &&
        _routeRevision == _formatRouteRevision &&
        _editableRevision == _formatEditableRevision &&
        _lifecycleRevision == lifecycleRevision &&
        focusCanReturn() &&
        !_busy &&
        !session.expired &&
        _revision == session.revision &&
        _validSelection(session.selection) &&
        identical(
          editor.document.nodeAtPath(session.selection.start.path),
          session.startNode,
        ) &&
        identical(
          editor.document.nodeAtPath(session.selection.end.path),
          session.endNode,
        );

    final selectionUnchanged =
        _selectionRevision == session.selectionRevision &&
        editor.selection == session.selection;
    final selectionClearedByFocus =
        _selectionRevision == session.selectionRevision + 1 &&
        editor.selection == null &&
        _focusRevision > initialFocusRevision;
    if (!contextIsCurrent() ||
        (!selectionUnchanged && !selectionClearedByFocus)) {
      final notify = result != null && _formatRoute?.isCurrent == true;
      _formatChildRoute = null;
      _closeFormatPanel(restoreKeyboard: false);
      if (notify && mounted) _selectionExpired();
      return;
    }

    if (selectionClearedByFocus) {
      unawaited(
        editor.updateSelectionWithReason(
          session.selection,
          extraInfo: {
            af.selectionExtraInfoDoNotAttachTextService: true,
            af.selectionExtraInfoDisableFloatingToolbar: true,
          },
        ),
      );
      session.selectionRevision = _selectionRevision;
    }
    _formatNeedsInputReconnect |= _focusRevision != initialFocusRevision;
    try {
      await SystemChannels.textInput.invokeMethod<void>('TextInput.hide');
    } catch (error, stack) {
      logger.e(
        'Unable to hide the link keyboard',
        error: error,
        stackTrace: stack,
      );
      if (mounted && identical(_formatSession, session)) {
        final notify = result != null && _formatRoute?.isCurrent == true;
        _formatChildRoute = null;
        _closeFormatPanel(restoreKeyboard: false);
        if (notify && mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text(context.l10n.dailynotes.editorLinkApplyFailed),
            ),
          );
        }
      }
      return;
    }
    if (!contextIsCurrent() || !_sessionValid(session)) {
      if (mounted && identical(_formatSession, session)) {
        _formatChildRoute = null;
        _closeFormatPanel(restoreKeyboard: false);
      }
      return;
    }
    focus.requestFocus();
    await WidgetsBinding.instance.endOfFrame;
    if (!contextIsCurrent() || !_sessionValid(session) || !focus.hasFocus) {
      if (mounted && identical(_formatSession, session)) {
        _formatChildRoute = null;
        _closeFormatPanel(restoreKeyboard: false);
      }
      return;
    }
    _formatFocusRevision = _focusRevision;
    _formatChildRoute = null;
    if (result != null) {
      final success = await _runSession(
        session,
        (selection) => _applyLink(editor, selection, result),
        allowMovedSelection: !result.remove,
      );
      if (!success && mounted) _selectionExpired();
    }
    if (mounted && identical(_formatSession, session)) setState(() {});
  }

  Future<void> _openLink() async {
    if (_formatSession != null) _closeFormatPanel(restoreKeyboard: false);
    final session = _capture();
    if (session == null ||
        !session.selection.isSingle ||
        !_textOnly(session.selection)) {
      return;
    }
    final existing = widget.editor.getDeltaAttributeValueInSelection<String>(
      af.AppFlowyRichTextKeys.href,
      session.selection,
    );
    final result = await showDialog<_LinkResult>(
      context: context,
      builder: (_) => _LinkDialog(
        existing: existing,
        initialText: _selectedLinkText(widget.editor, session.selection),
      ),
    );
    if (!mounted) return;
    // AppFlowy's keyboard service clears the selection when the dialog's
    // input takes focus. Restore only that one expected blur transition: any
    // document, node, route, or additional selection change invalidates it.
    if (widget.editor.selection == null &&
        _selectionRevision == session.selectionRevision + 1 &&
        _revision == session.revision &&
        _editable &&
        ModalRoute.of(context)?.isCurrent == true &&
        identical(
          widget.editor.document.nodeAtPath(session.selection.start.path),
          session.startNode,
        ) &&
        identical(
          widget.editor.document.nodeAtPath(session.selection.end.path),
          session.endNode,
        )) {
      widget.editor.selection = session.selection;
      session.selectionRevision = _selectionRevision;
    }
    if (result == null) return;
    final success = await _runSession(
      session,
      (selection) => _applyLink(widget.editor, selection, result),
      allowMovedSelection: !result.remove,
    );
    if (!success && mounted) {
      _selectionExpired();
    } else if (mounted &&
        _sessionValid(session) &&
        ModalRoute.of(context)?.isCurrent == true) {
      widget.focusNode.requestFocus();
    }
  }

  void _selectionExpired() {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(context.l10n.dailynotes.editorSelectionChanged)),
    );
  }

  Widget _button(
    String key,
    String tooltip,
    IconData icon,
    VoidCallback? onPressed, {
    bool selected = false,
  }) => SizedBox(
    width: 42,
    height: 42,
    child: IconButton(
      key: ValueKey('rich-toolbar-$key'),
      tooltip: tooltip,
      padding: EdgeInsets.zero,
      iconSize: 20,
      icon: Icon(icon),
      isSelected: selected,
      style: selected
          ? IconButton.styleFrom(
              backgroundColor: context.theme.colors.secondaryContainer,
            )
          : null,
      onPressed: onPressed,
    ),
  );

  _SelectionSession? _overflowSession;
  List<_ToolbarAction>? _openOverflowActions;

  void _openFormatOverflow(List<_ToolbarAction> actions) {
    final session = _formatSession;
    final route = _formatRoute;
    if (session == null || !_formatValid(session) || route?.isCurrent != true) {
      return;
    }
    _overflowSession = _capture();
    _openOverflowActions = List.of(actions);
    late final LocalHistoryEntry entry;
    entry = LocalHistoryEntry(
      impliesAppBarDismissal: false,
      onRemove: () {
        if (!identical(_formatMenuHistory, entry)) return;
        _formatMenuHistory = null;
        if (_formatMoreController.isOpen) _formatMoreController.close();
      },
    );
    _formatMenuHistory = entry;
    route!.addLocalHistoryEntry(entry);
  }

  void _closeFormatOverflow() {
    final history = _formatMenuHistory;
    _formatMenuHistory = null;
    history?.remove();
    _overflowSession = null;
    _openOverflowActions = null;
  }

  void _openFormatInlineMenu() {
    final session = _formatSession;
    final route = _formatRoute;
    if (session == null || !_formatValid(session) || route?.isCurrent != true) {
      return;
    }
    late final LocalHistoryEntry entry;
    entry = LocalHistoryEntry(
      impliesAppBarDismissal: false,
      onRemove: () {
        if (!identical(_formatInlineHistory, entry)) return;
        _formatInlineHistory = null;
        if (_formatInlineController.isOpen) _formatInlineController.close();
      },
    );
    _formatInlineHistory = entry;
    route!.addLocalHistoryEntry(entry);
  }

  void _closeFormatInlineMenu() {
    final history = _formatInlineHistory;
    _formatInlineHistory = null;
    history?.remove();
  }

  void _invokeOverflowAction(
    String id,
    _SelectionSession? session,
    List<_ToolbarAction>? menuActions, {
    _SelectionSession? fromFormat,
  }) {
    if (session == null ||
        _busy ||
        !_sessionValid(session) ||
        (fromFormat != null && !_formatValid(fromFormat)) ||
        (_formatSession != null && !_formatValid(_formatSession!)) ||
        ModalRoute.of(context)?.isCurrent != true) {
      if (mounted) _selectionExpired();
      return;
    }
    final action = menuActions?.where((item) => item.id == id).firstOrNull;
    action?.onPressed?.call();
  }

  Widget _editorColumn(Widget? toolbar) {
    final session = _formatSession;
    final hasPanel =
        session != null && _editable && identical(_formatEditor, widget.editor);
    return LayoutBuilder(
      builder: (context, constraints) {
        final available = constraints.maxHeight.isFinite
            ? constraints.maxHeight
            : _formatHeight + _keyboardToolbarHeight + 48;
        // TextInput.hide completes before Android has necessarily reported
        // the final inset. Leave a usable editor viewport during that
        // transition; the panel expands to its chosen height once it ends.
        final keyboardVisible = View.of(context).viewInsets.bottom > 0;
        final editorReserve = keyboardVisible
            ? (available * .3).clamp(48.0, 160.0)
            : 48.0;
        final maxPanel =
            (available -
                    (toolbar == null ? 0 : _keyboardToolbarHeight) -
                    editorReserve)
                .clamp(0.0, available);
        final minPanel = maxPanel < 160 ? maxPanel : 160.0;
        final height = _formatHeight.clamp(0.0, maxPanel);
        return Column(
          children: [
            Expanded(child: widget.child),
            ?toolbar,
            if (session != null && hasPanel && height >= 64)
              SizedBox(
                height: height,
                child: _FormatSheet(
                  editor: widget.editor,
                  valid: () => _formatValid(session),
                  execute: (command) => _runSession(session, command),
                  executeMove: (command) =>
                      _runSession(session, command, allowMovedSelection: true),
                  toggle: _toggle,
                  convert: _convert,
                  align: _align,
                  scrollController: widget.scrollController,
                  canConvert: () => _canConvert(session.selection),
                  anchorBottom: _formatAnchorBottom,
                  anchorRevision: _formatAnchorRevision,
                  onClose: () => _closeFormatPanel(restoreKeyboard: true),
                  onResize: (delta) {
                    if (!_formatValid(session)) return;
                    final current = _formatHeight.clamp(minPanel, maxPanel);
                    final next = (current - delta).clamp(minPanel, maxPanel);
                    if ((next - current).abs() <= .1) return;
                    final rects = widget.editor.selectionRects();
                    setState(() {
                      _formatAnchorBottom = rects.isEmpty
                          ? null
                          : rects
                                .map((rect) => rect.bottom)
                                .reduce((a, b) => a > b ? a : b);
                      _formatAnchorRevision++;
                      _formatHeight = next;
                    });
                  },
                  openColor: _openColor,
                  openFonts: _openFormatFonts,
                  openLink: _openFormatLink,
                  inlineMenuController: _formatInlineController,
                  onInlineMenuOpen: _openFormatInlineMenu,
                  onInlineMenuClose: _closeFormatInlineMenu,
                ),
              ),
          ],
        );
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final selection = widget.editor.selection;
    final keyboard = View.of(context).viewInsets.bottom > 0;
    final hasPanel =
        _formatSession != null &&
        _editable &&
        identical(_formatEditor, widget.editor);
    final show =
        _editable &&
        widget.focusNode.hasFocus &&
        _validSelection(selection) &&
        (keyboard || hasPanel);
    final showFloating = !hasPanel && _floatingEligible;
    // Keep the editor at the same position in the tree across mode changes.
    if (!show) {
      return _surface(_editorColumn(null), showFloating);
    }
    final selected = selection!;
    final isRange = !selected.isCollapsed;
    final node = widget.editor.document.nodeAtPath(selected.start.path);
    final isList =
        node != null &&
        const {
          af.TodoListBlockKeys.type,
          af.BulletedListBlockKeys.type,
          af.NumberedListBlockKeys.type,
        }.contains(node.type);
    final canText =
        !_busy &&
        _textOnly(selected) &&
        (_formatSession == null || _formatValid(_formatSession!));
    final canBlock = canText && selected.isSingle;
    final canConvertBlock = canBlock && _canConvert(selected);
    final actions = <_ToolbarAction>[
      _ToolbarAction(
        'todo',
        l10n.editor.toolbar.taskList,
        LucideIcons.listTodo,
        !isRange && canConvertBlock
            ? () => _quick((s) => _convert(s, af.TodoListBlockKeys.type))
            : null,
      ),
      _ToolbarAction(
        'bullet',
        l10n.editor.toolbar.bulletList,
        LucideIcons.list,
        !isRange && canConvertBlock
            ? () => _quick((s) => _convert(s, af.BulletedListBlockKeys.type))
            : null,
      ),
      _ToolbarAction(
        'numbered',
        l10n.editor.toolbar.orderedList,
        LucideIcons.listOrdered,
        !isRange && canConvertBlock
            ? () => _quick((s) => _convert(s, af.NumberedListBlockKeys.type))
            : null,
      ),
      _ToolbarAction(
        'outdent',
        l10n.editor.toolbar.outdent,
        LucideIcons.outdent,
        !isRange && isList && canBlock && af.isOutdentable(widget.editor)
            ? () {
                if (_editable && af.isOutdentable(widget.editor)) {
                  af.outdentCommand.execute(widget.editor);
                }
              }
            : null,
      ),
      _ToolbarAction(
        'indent',
        l10n.editor.toolbar.indent,
        LucideIcons.indent,
        !isRange && isList && canBlock && af.isIndentable(widget.editor)
            ? () {
                if (_editable && af.isIndentable(widget.editor)) {
                  af.indentCommand.execute(widget.editor);
                }
              }
            : null,
      ),
      for (final (id, label, icon, attribute) in [
        (
          'bold',
          l10n.editor.toolbar.bold,
          LucideIcons.bold,
          af.AppFlowyRichTextKeys.bold,
        ),
        (
          'italic',
          l10n.editor.toolbar.italic,
          LucideIcons.italic,
          af.AppFlowyRichTextKeys.italic,
        ),
        (
          'underline',
          l10n.editor.toolbar.underline,
          LucideIcons.underline,
          af.AppFlowyRichTextKeys.underline,
        ),
        (
          'strike',
          l10n.editor.toolbar.strike,
          LucideIcons.strikethrough,
          af.AppFlowyRichTextKeys.strikethrough,
        ),
      ])
        _ToolbarAction(
          id,
          label,
          icon,
          canText ? () => _quick((s) => _toggle(s, attribute)) : null,
          selected: _styleActive(widget.editor, selected, attribute),
        ),
      _ToolbarAction(
        'code',
        l10n.editor.toolbar.inlineCode,
        LucideIcons.code,
        canText
            ? () => _quick((s) => _toggle(s, af.AppFlowyRichTextKeys.code))
            : null,
        selected: _styleActive(
          widget.editor,
          selected,
          af.AppFlowyRichTextKeys.code,
        ),
      ),
      _ToolbarAction(
        'color',
        l10n.dailynotes.editorTextColor,
        LucideIcons.baseline,
        canText ? _openColor : null,
      ),
      if (selected.isSingle)
        _ToolbarAction(
          'link',
          l10n.editor.toolbar.link,
          LucideIcons.link,
          canText ? _openLink : null,
        ),
      if (widget.showHistoryActionsInToolbar)
        _ToolbarAction(
          'undo',
          l10n.editor.toolbar.undo,
          LucideIcons.undo2,
          !_busy && !widget.editor.undoManager.undoStack.isEmpty
              ? () {
                  if (_editable) af.undoCommand.execute(widget.editor);
                }
              : null,
        ),
      if (widget.showHistoryActionsInToolbar)
        _ToolbarAction(
          'redo',
          l10n.editor.toolbar.redo,
          LucideIcons.redo2,
          !_busy && !widget.editor.undoManager.redoStack.isEmpty
              ? () {
                  if (_editable) af.redoCommand.execute(widget.editor);
                }
              : null,
        ),
    ];
    // Context mappings are provisional; all other applicable actions remain
    // accessible in More. Screens with top history actions omit duplicates.
    final quickCandidates = isRange
        ? <String>['bold', 'italic', 'underline', if (selected.isSingle) 'link']
        : isList
        ? <String>['outdent', 'indent', 'todo', 'bullet']
        : <String>['todo', 'bullet', 'numbered', 'bold'];
    final eligibleQuickIds = quickCandidates
        .where((id) => actions.firstWhere((a) => a.id == id).onPressed != null)
        .toList();
    final insertAction = _ToolbarAction(
      'insert',
      l10n.editor.toolbar.insert,
      LucideIcons.plus,
      !isRange && canBlock ? _openInsert : null,
    );
    final formatAction = _ToolbarAction(
      'format',
      l10n.editor.toolbar.format,
      LucideIcons.caseSensitive,
      canText ? _openFormat : null,
      selected: hasPanel,
    );
    final closeAction = _ToolbarAction(
      'close',
      l10n.editor.toolbar.hideKeyboard,
      LucideIcons.chevronDown,
      () {
        if (_formatSession != null) {
          _closeFormatPanel(restoreKeyboard: false);
        }
        SystemChannels.textInput.invokeMethod<void>('TextInput.hide');
      },
    );
    return _surface(
      _editorColumn(
        Material(
          key: const ValueKey('rich-keyboard-toolbar'),
          color: context.theme.colors.surface,
          child: SizedBox(
            height: _keyboardToolbarHeight,
            child: LayoutBuilder(
              builder: (context, constraints) {
                final maxSlots = eligibleQuickIds.length + 4;
                final slots = constraints.maxWidth.isFinite
                    ? (constraints.maxWidth / _minToolbarSlotWidth)
                          .floor()
                          .clamp(1, maxSlots)
                    : maxSlots;
                final showInsert = slots >= 2;
                final showFormat = slots >= 3;
                final showClose = slots >= 4;
                final quickCount = (slots - 4).clamp(
                  0,
                  eligibleQuickIds.length,
                );
                final quickIds = eligibleQuickIds.take(quickCount).toSet();
                final visible = [
                  for (final id in eligibleQuickIds.take(quickCount))
                    actions.firstWhere((a) => a.id == id),
                ];
                final overflow = [
                  if (!showInsert) insertAction,
                  if (!showFormat) formatAction,
                  ...actions.where((action) => !quickIds.contains(action.id)),
                  if (!showClose) closeAction,
                ];
                final menuFormatSession = hasPanel ? _formatSession : null;
                Widget button(_ToolbarAction action) => Expanded(
                  key: ValueKey('rich-toolbar-slot-${action.id}'),
                  child: _button(
                    action.id,
                    action.label,
                    action.icon,
                    action.onPressed,
                    selected: action.selected,
                  ),
                );
                return Row(
                  children: [
                    if (showInsert) button(insertAction),
                    if (showFormat) button(formatAction),
                    for (final action in visible) button(action),
                    Expanded(
                      key: const ValueKey('rich-toolbar-slot-more'),
                      child: hasPanel
                          ? MenuAnchor(
                              controller: _formatMoreController,
                              consumeOutsideTap: true,
                              onOpen: () => _openFormatOverflow(overflow),
                              onClose: _closeFormatOverflow,
                              menuChildren: [
                                for (final action in overflow)
                                  MenuItemButton(
                                    key: ValueKey('rich-overflow-${action.id}'),
                                    requestFocusOnHover: false,
                                    closeOnActivate: false,
                                    onPressed: action.onPressed == null
                                        ? null
                                        : () {
                                            final session = _overflowSession;
                                            final menuActions =
                                                _openOverflowActions;
                                            _formatMoreController.close();
                                            _invokeOverflowAction(
                                              action.id,
                                              session,
                                              menuActions,
                                              fromFormat: menuFormatSession,
                                            );
                                          },
                                    leadingIcon: Icon(action.icon, size: 20),
                                    trailingIcon: action.selected
                                        ? const Icon(
                                            LucideIcons.check,
                                            size: 18,
                                          )
                                        : null,
                                    child: Text(action.label),
                                  ),
                              ],
                              builder: (context, controller, _) => IconButton(
                                key: const ValueKey('rich-toolbar-more'),
                                tooltip: l10n.common.more,
                                icon: const Icon(LucideIcons.ellipsis),
                                iconSize: 20,
                                padding: EdgeInsets.zero,
                                onPressed:
                                    menuFormatSession != null &&
                                        _formatValid(menuFormatSession)
                                    ? () {
                                        if (!_formatValid(menuFormatSession)) {
                                          return;
                                        }
                                        if (controller.isOpen) {
                                          controller.close();
                                        } else {
                                          controller.open();
                                        }
                                      }
                                    : null,
                              ),
                            )
                          : PopupMenuButton<String>(
                              key: const ValueKey('rich-toolbar-more'),
                              tooltip: l10n.common.more,
                              icon: const Icon(LucideIcons.ellipsis),
                              iconSize: 20,
                              padding: EdgeInsets.zero,
                              requestFocus: false,
                              onOpened: () {
                                _overflowSession = _capture();
                                _openOverflowActions = List.of(overflow);
                              },
                              onCanceled: () {
                                _overflowSession = null;
                                _openOverflowActions = null;
                              },
                              onSelected: (id) {
                                final session = _overflowSession;
                                final menuActions = _openOverflowActions;
                                _overflowSession = null;
                                _openOverflowActions = null;
                                _invokeOverflowAction(id, session, menuActions);
                              },
                              itemBuilder: (_) => [
                                for (final action in overflow)
                                  PopupMenuItem<String>(
                                    key: ValueKey('rich-overflow-${action.id}'),
                                    value: action.id,
                                    enabled: action.onPressed != null,
                                    child: Row(
                                      children: [
                                        Icon(action.icon, size: 20),
                                        const SizedBox(width: 12),
                                        Expanded(child: Text(action.label)),
                                        if (action.selected)
                                          const Icon(
                                            LucideIcons.check,
                                            size: 18,
                                          ),
                                      ],
                                    ),
                                  ),
                              ],
                            ),
                    ),
                    if (showClose) button(closeAction),
                  ],
                );
              },
            ),
          ),
        ),
      ),
      showFloating,
    );
  }
}

// Values and order are taken from AppFlowy 0.15.1's mobile color panel:
// https://github.com/AppFlowy-IO/AppFlowy/blob/0.15.1/frontend/appflowy_flutter/lib/plugins/document/presentation/editor_plugins/mobile_toolbar_v3/aa_menu/_color_list.dart
// Saved values from earlier DailyNotes builds remain untouched until edited.
List<(String, String?, Color)> _editorColors(BuildContext context, String key) {
  final t = context.l10n.dailynotes;
  if (key == af.AppFlowyRichTextKeys.textColor) {
    final choices = <(String, String?)>[
      (t.editorColorDefault, null),
      (t.editorColorRed, '0xffdb3636'),
      (t.editorColorOrange, '0xffea8f06'),
      (t.editorColorGreen, '0xff18a166'),
      (t.editorColorBlue, '0xff205eee'),
      (t.editorColorPurple, '0xffc619c9'),
    ];
    return [
      for (final (label, value) in choices)
        (
          label,
          value,
          value == null
              ? context.theme.colors.onSurface
              : Color(int.parse(value)),
        ),
    ];
  }
  const light = <String>[
    '0xffe8e0ff',
    '0xffffe6fd',
    '0xffffdae6',
    '0xffffefe3',
    '0xfff5ffdc',
    '0xffddffd6',
    '0xffdefff1',
    '0xffe1fbff',
    '0xffffadad',
    '0xffffe088',
    '0xffa7df4a',
    '0xffd4c0ff',
    '0xfffdb2fe',
    '0xffffd18b',
    '0xff65e7f0',
    '0xff71e6b4',
    '0xff80f1ff',
  ];
  const dark = <String>[
    '0xff8b80ad',
    '0xff987195',
    '0xff906d78',
    '0xffa68b77',
    '0xff88936d',
    '0xff72936b',
    '0xff6b9483',
    '0xff658b90',
    '0xff95405a',
    '0xffa6784d',
    '0xff6e9234',
    '0xff6455a2',
    '0xff924f83',
    '0xffa48f34',
    '0xff29a3ac',
    '0xff2e9f84',
    '0xff405ea6',
  ];
  final values = context.theme.colors.brightness == Brightness.dark
      ? dark
      : light;
  return [
    (t.editorColorDefault, null, context.theme.colors.surface),
    for (var i = 0; i < values.length; i++)
      (
        '${t.editorHighlightColor} ${i + 1}',
        values[i],
        Color(int.parse(values[i])),
      ),
  ];
}

bool _samePaletteColor(String? current, String? value) {
  if (current == value || (value == null && current == '')) return true;
  if (current == null || value == null) return false;
  final currentColor = af.ColorExtension(current).tryToColor();
  final paletteColor = af.ColorExtension(value).tryToColor();
  return currentColor != null && currentColor == paletteColor;
}

class _QuickColorSheet extends StatefulWidget {
  const _QuickColorSheet({
    super.key,
    required this.editor,
    required this.valid,
    required this.execute,
    required this.color,
  });
  final af.EditorState editor;
  final bool Function() valid;
  final Future<bool> Function(_FormatCommand) execute;
  final Future<void> Function(af.Selection, String, String?) color;

  @override
  State<_QuickColorSheet> createState() => _QuickColorSheetState();
}

class _QuickColorSheetState extends State<_QuickColorSheet> {
  late final StreamSubscription<dynamic> _changes;
  bool _running = false;
  bool _expired = false;

  @override
  void initState() {
    super.initState();
    widget.editor.selectionNotifier.addListener(_changed);
    _changes = widget.editor.transactionStream.listen((event) {
      if (event.$1 == af.TransactionTime.after) _changed();
    });
  }

  void _changed() {
    if (mounted) setState(() {});
  }

  @override
  void dispose() {
    widget.editor.selectionNotifier.removeListener(_changed);
    _changes.cancel();
    super.dispose();
  }

  Future<void> _select(String key, String? value) async {
    if (!mounted ||
        _running ||
        _expired ||
        !widget.valid() ||
        ModalRoute.of(context)?.isCurrent != true) {
      return;
    }
    setState(() => _running = true);
    final success = await widget.execute(
      (selection) => widget.color(selection, key, value),
    );
    if (!mounted) return;
    setState(() {
      _running = false;
      _expired = !success;
    });
  }

  void _close() {
    if (mounted && ModalRoute.of(context)?.isCurrent == true) {
      Navigator.pop(context, true);
    }
  }

  @override
  Widget build(BuildContext context) {
    final t = context.l10n.dailynotes;
    final valid =
        !_expired && ModalRoute.isCurrentOf(context) == true && widget.valid();
    final enabled = !_running && valid;
    Widget palette(String key, String identifier) {
      final selection = widget.editor.selection;
      final current = valid && selection != null
          ? _currentInlineString(widget.editor, selection, key)
          : (known: false, value: null);
      final textPalette = key == af.AppFlowyRichTextKeys.textColor;
      return GridView.count(
        key: ValueKey('rich-color-grid-$identifier'),
        crossAxisCount: 6,
        shrinkWrap: true,
        physics: const NeverScrollableScrollPhysics(),
        mainAxisSpacing: 4,
        crossAxisSpacing: 4,
        children: [
          for (final (label, value, color) in _editorColors(context, key))
            Builder(
              builder: (context) {
                final selected =
                    current.known && _samePaletteColor(current.value, value);
                final checkColor = value == null
                    ? context.theme.colors.onSurface
                    : color.computeLuminance() > .5
                    ? (context.theme.colors.brightness == Brightness.dark
                          ? context.theme.colors.onInverseSurface
                          : context.theme.colors.onSurface)
                    : (context.theme.colors.brightness == Brightness.dark
                          ? context.theme.colors.onSurface
                          : context.theme.colors.onInverseSurface);
                return Tooltip(
                  message: label,
                  child: Semantics(
                    button: true,
                    selected: selected,
                    enabled: enabled,
                    child: InkWell(
                      key: ValueKey(
                        'rich-quick-color-$identifier-${value ?? 'default'}',
                      ),
                      onTap: enabled ? () => _select(key, value) : null,
                      borderRadius: BorderRadius.circular(12),
                      child: Container(
                        margin: const EdgeInsets.all(3),
                        decoration: BoxDecoration(
                          color: textPalette
                              ? context.theme.colors.surface
                              : color,
                          borderRadius: BorderRadius.circular(12),
                          border: Border.all(
                            color: selected
                                ? context.theme.colors.primary
                                : context.theme.colors.outline,
                            width: selected ? 2 : 1,
                          ),
                        ),
                        alignment: Alignment.center,
                        child: textPalette
                            ? Text(
                                'A',
                                key: selected
                                    ? const ValueKey(
                                        'rich-quick-color-selected-text',
                                      )
                                    : null,
                                style: context
                                    .theme
                                    .typography
                                    .titleLarge
                                    .onSurface
                                    .copyWith(color: color),
                              )
                            : selected
                            ? Icon(
                                LucideIcons.check,
                                key: const ValueKey(
                                  'rich-quick-color-selected-background',
                                ),
                                size: 20,
                                color: checkColor,
                              )
                            : null,
                      ),
                    ),
                  ),
                );
              },
            ),
        ],
      );
    }

    return SafeArea(
      child: SingleChildScrollView(
        padding: const EdgeInsets.fromLTRB(16, 0, 16, 24),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            Row(
              children: [
                Expanded(
                  child: Text(
                    t.editorTextColor,
                    style: context.theme.typography.titleMedium.onSurface,
                  ),
                ),
                TextButton(
                  key: const ValueKey('rich-color-done'),
                  onPressed: _close,
                  child: Text(t.editorFormatDone),
                ),
              ],
            ),
            if (!valid && !_running) Text(t.editorSelectionChanged),
            palette(af.AppFlowyRichTextKeys.textColor, 'text'),
            const SizedBox(height: 18),
            Text(
              t.editorHighlightColor,
              style: context.theme.typography.titleMedium.onSurface,
            ),
            const SizedBox(height: 8),
            palette(af.AppFlowyRichTextKeys.backgroundColor, 'background'),
          ],
        ),
      ),
    );
  }
}

class _InsertSheet extends StatelessWidget {
  const _InsertSheet({required this.onSelect});
  final ValueChanged<_InsertBlock> onSelect;
  @override
  Widget build(BuildContext context) {
    final e = context.l10n.editor.toolbar;
    final t = context.l10n.dailynotes;
    final entries = <(_InsertBlock, String, IconData)>[
      (_InsertBlock.h1, t.editorHeading1, LucideIcons.heading1),
      (_InsertBlock.h2, t.editorHeading2, LucideIcons.heading2),
      (_InsertBlock.h3, t.editorHeading3, LucideIcons.heading3),
      (_InsertBlock.paragraph, e.paragraph, LucideIcons.type),
      (_InsertBlock.todo, e.taskList, LucideIcons.listTodo),
      (_InsertBlock.quote, e.quote, LucideIcons.quote),
      (_InsertBlock.bullet, e.bulletList, LucideIcons.list),
      (_InsertBlock.numbered, e.orderedList, LucideIcons.listOrdered),
      (_InsertBlock.toggle, t.editorToggle, LucideIcons.chevronRight),
      (_InsertBlock.toggleH1, t.editorToggleHeading1, LucideIcons.heading1),
      (_InsertBlock.toggleH2, t.editorToggleHeading2, LucideIcons.heading2),
      (_InsertBlock.toggleH3, t.editorToggleHeading3, LucideIcons.heading3),
      (_InsertBlock.divider, e.divider, LucideIcons.minus),
    ];
    return SizedBox(
      height: MediaQuery.sizeOf(context).height * 0.65,
      child: Column(
        children: [
          ListTile(
            title: Text(e.insert),
            trailing: IconButton(
              tooltip: context.l10n.common.close,
              icon: const Icon(LucideIcons.x),
              onPressed: () => Navigator.pop(context),
            ),
          ),
          Expanded(
            child: ListView.builder(
              itemCount: entries.length,
              itemBuilder: (context, i) {
                final (kind, label, icon) = entries[i];
                return ListTile(
                  key: ValueKey('rich-insert-${kind.name}'),
                  leading: Icon(icon),
                  title: Text(label),
                  onTap: () => onSelect(kind),
                );
              },
            ),
          ),
        ],
      ),
    );
  }
}

class _LinkDialog extends StatefulWidget {
  const _LinkDialog({
    super.key,
    required this.existing,
    required this.initialText,
    this.asSheet = false,
  });
  final String? existing;
  final String initialText;
  final bool asSheet;

  @override
  State<_LinkDialog> createState() => _LinkDialogState();
}

class _LinkDialogState extends State<_LinkDialog> {
  late final TextEditingController _controller;
  late final TextEditingController _textController;
  String? _error;
  String? _textError;

  @override
  void initState() {
    super.initState();
    _controller = TextEditingController(text: widget.existing ?? '');
    _textController = TextEditingController(text: widget.initialText);
  }

  @override
  void dispose() {
    _controller.dispose();
    _textController.dispose();
    super.dispose();
  }

  void _save() {
    if (!mounted || ModalRoute.of(context)?.isCurrent != true) return;
    if (RegExp(r'[\r\n\u2028\u2029]').hasMatch(_textController.text)) {
      setState(
        () => _textError = context.l10n.dailynotes.editorLinkTextInvalid,
      );
      return;
    }
    var value = _controller.text.trim();
    final parsed = Uri.tryParse(value);
    if (parsed != null && !parsed.hasScheme) value = 'https://$value';
    final uri = Uri.tryParse(value);
    final valid =
        uri != null &&
        !value.contains(RegExp(r'\s')) &&
        (({'http', 'https'}.contains(uri.scheme) && uri.host.isNotEmpty) ||
            ({'mailto', 'tel'}.contains(uri.scheme) && uri.path.isNotEmpty));
    if (!valid) {
      setState(() => _error = context.l10n.dailynotes.editorLinkInvalid);
      return;
    }
    Navigator.pop(context, (
      remove: false,
      value: value,
      text: _textController.text,
    ));
  }

  @override
  Widget build(BuildContext context) {
    final title = Text(context.l10n.editor.toolbar.link);
    final textField = TextField(
      key: const ValueKey('rich-link-text'),
      controller: _textController,
      maxLines: 1,
      decoration: InputDecoration(
        labelText: context.l10n.editor.toolbar.linkText,
        errorText: _textError,
      ),
    );
    final field = TextField(
      key: const ValueKey('rich-link-address'),
      controller: _controller,
      autofocus: true,
      keyboardType: TextInputType.url,
      decoration: InputDecoration(
        labelText: context.l10n.dailynotes.editorLinkAddress,
        errorText: _error,
      ),
    );
    final actions = <Widget>[
      TextButton(
        onPressed: () => Navigator.pop(context),
        child: Text(context.l10n.common.cancel),
      ),
      if (widget.existing != null)
        TextButton(
          key: const ValueKey('rich-link-remove'),
          onPressed: () =>
              Navigator.pop(context, (remove: true, value: '', text: '')),
          child: Text(context.l10n.dailynotes.editorLinkRemove),
        ),
      TextButton(
        key: const ValueKey('rich-link-save'),
        onPressed: _save,
        child: Text(context.l10n.common.save),
      ),
    ];
    if (!widget.asSheet) {
      return AlertDialog(
        title: title,
        content: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [textField, const SizedBox(height: 12), field],
          ),
        ),
        actions: actions,
      );
    }
    return SafeArea(
      child: Padding(
        padding: EdgeInsets.only(
          bottom: MediaQuery.viewInsetsOf(context).bottom,
        ),
        child: SingleChildScrollView(
          padding: const EdgeInsets.fromLTRB(24, 8, 24, 20),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              DefaultTextStyle(
                style: context.theme.typography.titleLarge.onSurface,
                child: title,
              ),
              const SizedBox(height: 16),
              textField,
              const SizedBox(height: 12),
              field,
              const SizedBox(height: 12),
              Wrap(alignment: WrapAlignment.end, children: actions),
            ],
          ),
        ),
      ),
    );
  }
}

typedef _FormatCommand = Future<void> Function(af.Selection selection);

class _FormatSheet extends StatefulWidget {
  const _FormatSheet({
    required this.editor,
    required this.valid,
    required this.execute,
    required this.executeMove,
    required this.toggle,
    required this.convert,
    required this.align,
    required this.scrollController,
    required this.canConvert,
    required this.anchorBottom,
    required this.anchorRevision,
    required this.onClose,
    required this.onResize,
    required this.openColor,
    required this.openFonts,
    required this.openLink,
    required this.inlineMenuController,
    required this.onInlineMenuOpen,
    required this.onInlineMenuClose,
  });
  final af.EditorState editor;
  final af.EditorScrollController? scrollController;
  final bool Function() valid;
  final bool Function() canConvert;
  final double? anchorBottom;
  final int anchorRevision;
  final VoidCallback onClose;
  final ValueChanged<double> onResize;
  final VoidCallback openColor;
  final VoidCallback openFonts;
  final VoidCallback openLink;
  final MenuController inlineMenuController;
  final VoidCallback onInlineMenuOpen;
  final VoidCallback onInlineMenuClose;
  final Future<bool> Function(_FormatCommand) execute;
  final Future<bool> Function(_FormatCommand) executeMove;
  final Future<void> Function(af.Selection, String) toggle;
  final Future<void> Function(af.Selection, String, {int? level}) convert;
  final Future<void> Function(af.Selection, String) align;

  @override
  State<_FormatSheet> createState() => _FormatSheetState();
}

class _FormatSheetState extends State<_FormatSheet> {
  bool _running = false;
  bool _expired = false;
  late final StreamSubscription<dynamic> _changes;
  final _surfaceKey = GlobalKey();
  final _inlineCodeItemKey = GlobalKey();
  final _contentController = ScrollController();
  bool _longPressCodeSelected = false;
  bool _visibilityScheduled = false;
  bool _adjustingScroll = false;
  bool _anchorPending = true;
  double? _pendingAnchor;
  double? _openingAnchor;
  double? _lastSelectionBottom;
  double? _lastViewInset;
  Size? _lastViewSize;

  @override
  void didUpdateWidget(covariant _FormatSheet oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.anchorRevision != widget.anchorRevision) {
      _pendingAnchor = widget.anchorBottom;
      _anchorPending = true;
      _openingAnchor = null;
    }
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _scheduleVisibilityCheck();
  }

  void _scheduleVisibilityCheck() {
    if (_visibilityScheduled || widget.scrollController == null) return;
    _visibilityScheduled = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _visibilityScheduled = false;
      if (!mounted ||
          _adjustingScroll ||
          !widget.valid() ||
          ModalRoute.of(context)?.isCurrent != true) {
        return;
      }
      final box = _surfaceKey.currentContext?.findRenderObject();
      if (box is! RenderBox || !box.attached || !box.hasSize) return;
      final sheet = box.localToGlobal(Offset.zero) & box.size;
      final rectangles = widget.editor
          .selectionRects()
          .where(
            (rect) =>
                rect.right > sheet.left &&
                rect.left < sheet.right &&
                rect.top < sheet.bottom &&
                rect.bottom > 0,
          )
          .toList();
      if (rectangles.isEmpty) return;
      final bottom = rectangles
          .map((rect) => rect.bottom)
          .reduce((a, b) => a > b ? a : b);
      final limit =
          sheet.top - _RichEditorToolbarState._keyboardToolbarHeight - 8;
      final anchor = _pendingAnchor;
      final desired = _anchorPending && anchor != null
          ? (anchor < limit ? anchor : limit)
          : limit;
      final delta = _anchorPending && anchor != null
          ? bottom - desired
          : bottom > limit
          ? bottom - limit
          : 0.0;
      _anchorPending = false;
      if (delta.abs() <= .5) {
        _lastSelectionBottom = bottom;
        return;
      }
      final scroll = widget.scrollController!;
      if (scroll.shrinkWrap) {
        if (!scroll.scrollController.hasClients) return;
      } else if (!scroll.itemScrollController.isAttached) {
        return;
      }
      _adjustingScroll = true;
      final movement = scroll.shrinkWrap
          ? scroll.animateTo(
              offset: scroll.scrollController.offset + delta,
              duration: const Duration(milliseconds: 120),
              curve: Curves.easeOut,
            )
          : scroll.scrollOffsetController.animateScroll(
              offset: delta,
              duration: const Duration(milliseconds: 120),
              curve: Curves.easeOut,
            );
      unawaited(
        movement
            .catchError((Object error, StackTrace stack) {
              if (mounted) {
                logger.e(
                  'Unable to reveal editor selection',
                  error: error,
                  stackTrace: stack,
                );
              }
            })
            .whenComplete(() {
              _adjustingScroll = false;
              if (!mounted || !widget.valid()) return;
              final now = widget.editor.selectionRects();
              if (now.isEmpty) return;
              final newBottom = now
                  .map((rect) => rect.bottom)
                  .reduce((a, b) => a > b ? a : b);
              _lastSelectionBottom = newBottom;
              // Retry after progress or when another resize happened while
              // this scroll adjustment was still in flight.
              if (_anchorPending ||
                  (newBottom > limit && bottom - newBottom > .5)) {
                _scheduleVisibilityCheck();
                WidgetsBinding.instance.scheduleFrame();
              }
            }),
      );
    });
  }

  @override
  void initState() {
    super.initState();
    _pendingAnchor = widget.anchorBottom;
    _openingAnchor = widget.anchorBottom;
    widget.editor.selectionNotifier.addListener(_contextChanged);
    _changes = widget.editor.transactionStream.listen((event) {
      if (event.$1 == af.TransactionTime.after) _contextChanged();
    });
  }

  void _contextChanged() {
    if (mounted) setState(() {});
  }

  @override
  void dispose() {
    widget.editor.selectionNotifier.removeListener(_contextChanged);
    _contentController.dispose();
    _changes.cancel();
    super.dispose();
  }

  Future<void> _perform(_FormatCommand command, {bool move = false}) async {
    if (_running || _expired || !widget.valid()) {
      if (mounted) setState(() => _expired = true);
      return;
    }
    setState(() => _running = true);
    final success = await (move
        ? widget.executeMove(command)
        : widget.execute(command));
    if (!mounted) return;
    setState(() {
      _running = false;
      _expired = !success;
    });
  }

  Widget _icon(
    String tooltip,
    IconData icon,
    VoidCallback? onPressed, {
    bool selected = false,
  }) => SizedBox(
    width: 48,
    child: IconButton(
      key: ValueKey('rich-format-$tooltip'),
      tooltip: tooltip,
      icon: Icon(icon, size: 20),
      isSelected: selected,
      style: selected
          ? IconButton.styleFrom(
              backgroundColor: context.theme.colors.secondaryContainer,
            )
          : null,
      onPressed: onPressed,
    ),
  );

  Widget _row(List<Widget> children) => SingleChildScrollView(
    scrollDirection: Axis.horizontal,
    child: Row(children: children),
  );

  void _showInlineMenu() {
    if (!mounted || _running || _expired || !widget.valid()) return;
    if (!widget.inlineMenuController.isOpen) widget.inlineMenuController.open();
  }

  void _applyInlineCode() {
    if (!mounted || _running || _expired || !widget.valid()) return;
    if (widget.inlineMenuController.isOpen) widget.inlineMenuController.close();
    unawaited(_perform((s) => widget.toggle(s, af.AppFlowyRichTextKeys.code)));
  }

  Widget _linkAndCode(bool enabled, bool canLink, bool codeSelected) {
    final e = context.l10n.editor.toolbar;
    final controller = widget.inlineMenuController;
    return MenuAnchor(
      controller: controller,
      onOpen: widget.onInlineMenuOpen,
      onClose: widget.onInlineMenuClose,
      menuChildren: [
        KeyedSubtree(
          key: _inlineCodeItemKey,
          child: MenuItemButton(
            key: ValueKey('rich-format-${e.inlineCode}'),
            onPressed: enabled ? _applyInlineCode : null,
            leadingIcon: const Icon(LucideIcons.code, size: 20),
            trailingIcon: codeSelected ? const Icon(LucideIcons.check) : null,
            child: Text(e.inlineCode),
          ),
        ),
      ],
      builder: (context, _, _) => GestureDetector(
        key: const ValueKey('rich-format-link-code'),
        behavior: HitTestBehavior.opaque,
        onLongPressStart: enabled
            ? (_) {
                if (!widget.valid()) return;
                _longPressCodeSelected = true;
                _showInlineMenu();
              }
            : null,
        onLongPressMoveUpdate: enabled
            ? (details) {
                final box = _inlineCodeItemKey.currentContext
                    ?.findRenderObject();
                if (box is! RenderBox || !box.attached || !box.hasSize) return;
                final left = box.localToGlobal(Offset.zero).dx;
                _longPressCodeSelected =
                    details.globalPosition.dx >= left &&
                    details.globalPosition.dx <= left + box.size.width;
              }
            : null,
        onLongPressUp: enabled
            ? () {
                if (_longPressCodeSelected) {
                  _applyInlineCode();
                } else if (controller.isOpen) {
                  controller.close();
                }
                _longPressCodeSelected = false;
              }
            : null,
        onLongPressCancel: () {
          _longPressCodeSelected = false;
          if (controller.isOpen) controller.close();
        },
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            SizedBox(
              width: 42,
              child: Tooltip(
                message: e.link,
                triggerMode: TooltipTriggerMode.manual,
                child: Semantics(
                  label: e.link,
                  child: IconButton(
                    key: const ValueKey('rich-format-link'),
                    icon: const Icon(LucideIcons.link, size: 20),
                    onPressed: canLink ? widget.openLink : null,
                  ),
                ),
              ),
            ),
            SizedBox(
              width: 30,
              child: Tooltip(
                message: e.inlineCode,
                triggerMode: TooltipTriggerMode.manual,
                child: Semantics(
                  label: e.inlineCode,
                  child: IconButton(
                    key: const ValueKey('rich-format-code-more'),
                    icon: const Icon(LucideIcons.chevronDown, size: 16),
                    onPressed: enabled ? _showInlineMenu : null,
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _blockButton({
    required String label,
    required String keyName,
    required bool selected,
    required VoidCallback? onPressed,
  }) => Semantics(
    key: ValueKey('rich-format-$keyName'),
    label: label,
    button: true,
    enabled: onPressed != null,
    selected: selected,
    onTap: onPressed,
    child: ExcludeSemantics(
      child: TextButton(
        onPressed: onPressed,
        style: selected
            ? TextButton.styleFrom(
                backgroundColor: context.theme.colors.secondaryContainer,
              )
            : null,
        child: Text(label),
      ),
    ),
  );

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final e = l10n.editor.toolbar;
    final t = l10n.dailynotes;
    final selectionValid = !_expired && widget.valid();
    final enabled = !_running && selectionValid;
    final canBlock = enabled && widget.canConvert();
    final selection = selectionValid ? widget.editor.selection : null;
    final canLink = enabled && selection != null && selection.isSingle;
    bool blockSelected(String type, {int? level}) =>
        selection != null &&
        _blockTypeActive(widget.editor, selection, type, level: level);
    bool aligned(String value) =>
        selection != null && _blockAlignActive(widget.editor, selection, value);
    final view = View.of(context);
    final inset = view.viewInsets.bottom / view.devicePixelRatio;
    final viewSize = MediaQuery.sizeOf(context);
    final previousInset = _lastViewInset;
    if (previousInset == null && inset == 0) _openingAnchor = null;
    if ((previousInset != null && previousInset != inset) ||
        (_lastViewSize != null && _lastViewSize != viewSize)) {
      _pendingAnchor = previousInset != null && inset < previousInset
          ? _openingAnchor ?? _lastSelectionBottom ?? widget.anchorBottom
          : _lastSelectionBottom ?? widget.anchorBottom;
      _anchorPending = true;
      if (inset == 0) _openingAnchor = null;
    }
    _lastViewInset = inset;
    _lastViewSize = viewSize;
    _scheduleVisibilityCheck();
    return KeyedSubtree(
      key: const ValueKey('rich-format-panel'),
      child: Material(
        key: _surfaceKey,
        clipBehavior: Clip.antiAlias,
        child: Column(
          children: [
            Semantics(
              label: e.format,
              onIncrease: enabled ? () => widget.onResize(-80) : null,
              onDecrease: enabled ? () => widget.onResize(80) : null,
              child: GestureDetector(
                key: const ValueKey('rich-format-drag-handle'),
                behavior: HitTestBehavior.opaque,
                onVerticalDragUpdate: enabled
                    ? (details) => widget.onResize(details.delta.dy)
                    : null,
                child: SizedBox(
                  height: 20,
                  width: double.infinity,
                  child: Center(
                    child: Container(
                      width: 36,
                      height: 4,
                      decoration: BoxDecoration(
                        color: context.theme.colors.outline,
                        borderRadius: BorderRadius.circular(2),
                      ),
                    ),
                  ),
                ),
              ),
            ),
            ListTile(
              title: Text(e.format),
              trailing: TextButton(
                key: const ValueKey('rich-format-done'),
                onPressed: widget.onClose,
                child: Text(t.editorFormatDone),
              ),
            ),
            if (!selectionValid && !_running)
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 16),
                child: Text(t.editorSelectionChanged),
              ),
            Expanded(
              child: ListView(
                controller: _contentController,
                padding: const EdgeInsets.symmetric(horizontal: 12),
                children: [
                  _row([
                    for (final level in [1, 2, 3])
                      _blockButton(
                        label: 'H$level',
                        keyName: 'heading-$level',
                        selected: blockSelected(
                          af.HeadingBlockKeys.type,
                          level: level,
                        ),
                        onPressed: canBlock
                            ? () => _perform(
                                (s) => widget.convert(
                                  s,
                                  af.HeadingBlockKeys.type,
                                  level: level,
                                ),
                              )
                            : null,
                      ),
                    _blockButton(
                      label: e.paragraph,
                      keyName: 'paragraph',
                      selected: blockSelected(af.ParagraphBlockKeys.type),
                      onPressed: canBlock
                          ? () => _perform(
                              (s) =>
                                  widget.convert(s, af.ParagraphBlockKeys.type),
                            )
                          : null,
                    ),
                  ]),
                  const Divider(height: 1),
                  _row([
                    _icon(
                      e.bold,
                      LucideIcons.bold,
                      enabled
                          ? () => _perform(
                              (s) => widget.toggle(
                                s,
                                af.AppFlowyRichTextKeys.bold,
                              ),
                            )
                          : null,
                      selected:
                          selectionValid &&
                          widget.editor.selection != null &&
                          _styleActive(
                            widget.editor,
                            widget.editor.selection!,
                            af.AppFlowyRichTextKeys.bold,
                          ),
                    ),
                    _icon(
                      e.italic,
                      LucideIcons.italic,
                      enabled
                          ? () => _perform(
                              (s) => widget.toggle(
                                s,
                                af.AppFlowyRichTextKeys.italic,
                              ),
                            )
                          : null,
                      selected:
                          selectionValid &&
                          widget.editor.selection != null &&
                          _styleActive(
                            widget.editor,
                            widget.editor.selection!,
                            af.AppFlowyRichTextKeys.italic,
                          ),
                    ),
                    _icon(
                      e.underline,
                      LucideIcons.underline,
                      enabled
                          ? () => _perform(
                              (s) => widget.toggle(
                                s,
                                af.AppFlowyRichTextKeys.underline,
                              ),
                            )
                          : null,
                      selected:
                          selectionValid &&
                          widget.editor.selection != null &&
                          _styleActive(
                            widget.editor,
                            widget.editor.selection!,
                            af.AppFlowyRichTextKeys.underline,
                          ),
                    ),
                    _icon(
                      e.strike,
                      LucideIcons.strikethrough,
                      enabled
                          ? () => _perform(
                              (s) => widget.toggle(
                                s,
                                af.AppFlowyRichTextKeys.strikethrough,
                              ),
                            )
                          : null,
                      selected:
                          selectionValid &&
                          widget.editor.selection != null &&
                          _styleActive(
                            widget.editor,
                            widget.editor.selection!,
                            af.AppFlowyRichTextKeys.strikethrough,
                          ),
                    ),
                    _icon(
                      t.editorTextColor,
                      LucideIcons.baseline,
                      enabled ? widget.openColor : null,
                    ),
                  ]),
                  const Divider(height: 1),
                  _row([
                    _icon(
                      e.taskList,
                      LucideIcons.listTodo,
                      canBlock
                          ? () => _perform(
                              (s) =>
                                  widget.convert(s, af.TodoListBlockKeys.type),
                            )
                          : null,
                      selected: blockSelected(af.TodoListBlockKeys.type),
                    ),
                    _icon(
                      e.bulletList,
                      LucideIcons.list,
                      canBlock
                          ? () => _perform(
                              (s) => widget.convert(
                                s,
                                af.BulletedListBlockKeys.type,
                              ),
                            )
                          : null,
                      selected: blockSelected(af.BulletedListBlockKeys.type),
                    ),
                    _icon(
                      e.orderedList,
                      LucideIcons.listOrdered,
                      canBlock
                          ? () => _perform(
                              (s) => widget.convert(
                                s,
                                af.NumberedListBlockKeys.type,
                              ),
                            )
                          : null,
                      selected: blockSelected(af.NumberedListBlockKeys.type),
                    ),
                    _icon(
                      e.quote,
                      LucideIcons.quote,
                      canBlock
                          ? () => _perform(
                              (s) => widget.convert(s, af.QuoteBlockKeys.type),
                            )
                          : null,
                      selected: blockSelected(af.QuoteBlockKeys.type),
                    ),
                    _linkAndCode(
                      enabled,
                      canLink,
                      selection != null &&
                          _styleActive(
                            widget.editor,
                            selection,
                            af.AppFlowyRichTextKeys.code,
                          ),
                    ),
                    _icon(
                      t.editorAlignLeft,
                      LucideIcons.alignLeft,
                      enabled
                          ? () => _perform((s) => widget.align(s, 'left'))
                          : null,
                      selected: aligned('left'),
                    ),
                    _icon(
                      t.editorAlignCenter,
                      LucideIcons.alignCenter,
                      enabled
                          ? () => _perform((s) => widget.align(s, 'center'))
                          : null,
                      selected: aligned('center'),
                    ),
                    _icon(
                      t.editorAlignRight,
                      LucideIcons.alignRight,
                      enabled
                          ? () => _perform((s) => widget.align(s, 'right'))
                          : null,
                      selected: aligned('right'),
                    ),
                  ]),
                  const Divider(height: 1),
                  _row([
                    TextButton.icon(
                      key: const ValueKey('rich-format-font'),
                      onPressed: enabled ? widget.openFonts : null,
                      icon: const Icon(LucideIcons.type, size: 20),
                      label: Text(t.editorFont),
                    ),
                    _icon(
                      e.outdent,
                      LucideIcons.outdent,
                      enabled && af.isOutdentable(widget.editor)
                          ? () => _perform(
                              (_) async =>
                                  af.outdentCommand.execute(widget.editor),
                              move: true,
                            )
                          : null,
                    ),
                    _icon(
                      e.indent,
                      LucideIcons.indent,
                      enabled && af.isIndentable(widget.editor)
                          ? () => _perform(
                              (_) async =>
                                  af.indentCommand.execute(widget.editor),
                              move: true,
                            )
                          : null,
                    ),
                  ]),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _FormatFontPage extends StatefulWidget {
  const _FormatFontPage({
    required this.editor,
    required this.valid,
    required this.execute,
    required this.color,
    required this.loadFonts,
  });

  final af.EditorState editor;
  final bool Function() valid;
  final Future<bool> Function(_FormatCommand) execute;
  final Future<void> Function(af.Selection, String, String?) color;
  final Future<({List<String> families, bool hasUnavailable})> Function()?
  loadFonts;

  @override
  State<_FormatFontPage> createState() => _FormatFontPageState();
}

class _FormatFontPageState extends State<_FormatFontPage> {
  late final StreamSubscription<dynamic> _changes;
  bool _loading = true;
  bool _loadFailed = false;
  bool _running = false;
  bool _expired = false;
  List<String> _importedFonts = [];

  @override
  void initState() {
    super.initState();
    widget.editor.selectionNotifier.addListener(_changed);
    _changes = widget.editor.transactionStream.listen((event) {
      if (event.$1 == af.TransactionTime.after) _changed();
    });
    unawaited(_load());
  }

  void _changed() {
    if (mounted) setState(() {});
  }

  Future<void> _load() async {
    try {
      final catalog =
          await (widget.loadFonts?.call() ??
              Future.value((families: <String>[], hasUnavailable: false)));
      if (!mounted) return;
      setState(() {
        _importedFonts = catalog.families;
        _loadFailed = catalog.hasUnavailable;
        _loading = false;
      });
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _loadFailed = true;
        _loading = false;
      });
    }
  }

  Future<void> _select(String? family) async {
    if (!mounted ||
        _running ||
        _expired ||
        !widget.valid() ||
        ModalRoute.of(context)?.isCurrent != true) {
      return;
    }
    setState(() => _running = true);
    final success = await widget.execute(
      (selection) =>
          widget.color(selection, af.AppFlowyRichTextKeys.fontFamily, family),
    );
    if (!mounted) return;
    setState(() {
      _running = false;
      _expired = !success;
    });
    if (success &&
        widget.valid() &&
        ModalRoute.of(context)?.isCurrent == true) {
      Navigator.of(context).pop();
    }
  }

  void _close() {
    if (mounted && ModalRoute.of(context)?.isCurrent == true) {
      Navigator.of(context).pop();
    }
  }

  @override
  void dispose() {
    widget.editor.selectionNotifier.removeListener(_changed);
    _changes.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final t = context.l10n.dailynotes;
    final valid =
        !_expired && ModalRoute.isCurrentOf(context) == true && widget.valid();
    final enabled = !_running && valid;
    final ios = defaultTargetPlatform == TargetPlatform.iOS;
    final options = <(String, String?)>[
      (t.editorFontDefault, null),
      (t.editorFontSans, ios ? 'Helvetica' : 'sans-serif'),
      (t.editorFontSerif, ios ? 'Georgia' : 'serif'),
      (t.editorFontMono, ios ? 'Menlo' : 'monospace'),
      for (final family in _importedFonts.toSet()) (family, family),
    ];
    final selection = widget.editor.selection;
    final current = enabled && selection != null
        ? _currentInlineString(
            widget.editor,
            selection,
            af.AppFlowyRichTextKeys.fontFamily,
          )
        : (known: false, value: null);
    final seen = <String?>{};
    final uniqueOptions = options.where((option) => seen.add(option.$2));
    return Scaffold(
      key: const ValueKey('rich-format-font-page'),
      appBar: AppBar(
        leading: IconButton(
          tooltip: t.editorBackToFormat,
          icon: const Icon(LucideIcons.arrowLeft),
          onPressed: _close,
        ),
        title: Text(t.editorFont),
        actions: [
          TextButton(
            key: const ValueKey('rich-font-done'),
            onPressed: _close,
            child: Text(t.editorFormatDone),
          ),
        ],
      ),
      body: ListView(
        children: [
          if (_loading) const LinearProgressIndicator(),
          if (_loadFailed)
            Padding(
              padding: const EdgeInsets.all(16),
              child: Text(t.editorFontLoadFailed),
            ),
          if (!valid && !_running)
            Padding(
              padding: const EdgeInsets.all(16),
              child: Text(t.editorSelectionChanged),
            ),
          for (final (label, family) in uniqueOptions)
            ListTile(
              key: ValueKey('rich-font-${family ?? 'default'}'),
              selected: current.known && current.value == family,
              trailing: current.known && current.value == family
                  ? const Icon(LucideIcons.check)
                  : null,
              title: Text(
                label,
                style: context.theme.typography.bodyLarge.onSurface.copyWith(
                  fontFamily: family,
                ),
              ),
              onTap: enabled ? () => _select(family) : null,
            ),
        ],
      ),
    );
  }
}
