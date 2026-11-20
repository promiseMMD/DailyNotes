import 'dart:async';

import 'package:appflowy_editor/appflowy_editor.dart' as af;
import 'package:flutter/foundation.dart' show defaultTargetPlatform;
import 'package:flutter/services.dart';
import 'package:moodiary_i18n/moodiary_i18n.dart';
import 'package:moodiary_logging/moodiary_logging.dart';
import 'package:mui/mui.dart';

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
  });

  final af.EditorState editor;
  final FocusNode focusNode;
  final af.EditorScrollController? scrollController;
  final bool editable;
  final bool showHistoryActionsInToolbar;
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

enum _InsertBlock {
  h1,
  h2,
  h3,
  paragraph,
  todo,
  quote,
  bullet,
  numbered,
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

/// The default family is represented by null; known=false represents a mixed
/// or otherwise indeterminate selection, not the default font.
({bool known, String? family}) _currentFont(
  af.EditorState editor,
  af.Selection selection,
) {
  final key = af.AppFlowyRichTextKeys.fontFamily;
  ({bool known, String? family}) valueOf(Object? value) => switch (value) {
    null => (known: true, family: null),
    final String family => (known: true, family: family),
    _ => (known: false, family: null),
  };
  if (selection.isCollapsed) {
    if (editor.toggledStyle.containsKey(key)) {
      return valueOf(editor.toggledStyle[key]);
    }
    if (!editor.sliceUpcomingAttributes) return (known: true, family: null);
    final node = editor.document.nodeAtPath(selection.start.path);
    final delta = node?.delta;
    if (delta == null) return (known: false, family: null);
    return valueOf(delta.sliceAttributes(selection.start.offset)?[key]);
  }
  final normalized = selection.normalized;
  final start = editor.document.nodeAtPath(normalized.start.path);
  final end = editor.document.nodeAtPath(normalized.end.path);
  final nodes = editor.getNodesInSelection(normalized);
  if (start == null || end == null || nodes.isEmpty) {
    return (known: false, family: null);
  }
  var seen = false;
  String? family;
  for (final node in nodes) {
    final delta = node.delta;
    if (delta == null) return (known: false, family: null);
    final from = identical(node, start) ? normalized.start.offset : 0;
    final to = identical(node, end) ? normalized.end.offset : delta.length;
    if (from < 0 || to > delta.length || from > to) {
      return (known: false, family: null);
    }
    for (final op in delta.slice(from, to)) {
      if (op is! af.TextInsert || op.length == 0) continue;
      final current = valueOf(op.attributes?[key]);
      if (!current.known || (seen && current.family != family)) {
        return (known: false, family: null);
      }
      seen = true;
      family = current.family;
    }
  }
  return (known: seen, family: family);
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
  late StreamSubscription<dynamic> _transactions;
  int _revision = 0;
  int _selectionRevision = 0;
  af.Selection? _observedSelection;
  bool _busy = false;
  final _contentKey = GlobalKey();
  bool _geometryQueued = false;
  ({Offset position, double width, _SelectionSession session})? _floating;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    widget.focusNode.addListener(_focusChanged);
    widget.scrollController?.offsetNotifier.addListener(
      _scheduleFloatingGeometry,
    );
    _observedSelection = _selectionSnapshot(widget.editor.selection);
    widget.editor.selectionNotifier.addListener(_selectionChanged);
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
    if (!identical(oldWidget.focusNode, widget.focusNode)) {
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
      oldWidget.editor.selectionNotifier.removeListener(_selectionChanged);
      _transactions.cancel();
      _revision++;
      _selectionRevision++;
      _floating = null;
      _scheduleFloatingGeometry();
      _observedSelection = _selectionSnapshot(widget.editor.selection);
      widget.editor.selectionNotifier.addListener(_selectionChanged);
      _listenTransactions();
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    widget.focusNode.removeListener(_focusChanged);
    widget.scrollController?.offsetNotifier.removeListener(
      _scheduleFloatingGeometry,
    );
    widget.editor.selectionNotifier.removeListener(_selectionChanged);
    _transactions.cancel();
    super.dispose();
  }

  void _focusChanged() {
    _scheduleFloatingGeometry();
    if (mounted) setState(() {});
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _scheduleFloatingGeometry();
  }

  @override
  void didChangeMetrics() {
    _scheduleFloatingGeometry();
    if (mounted) setState(() {});
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
        !_editable ||
        _busy ||
        !widget.focusNode.hasFocus ||
        View.of(context).viewInsets.bottom > 0 ||
        ModalRoute.of(context)?.isCurrent != true) {
      return false;
    }
    final dragMode = widget.editor.selectionExtraInfo?['selection_drag_mode']
        ?.toString();
    if (dragMode == 'MobileSelectionDragMode.leftSelectionHandle' ||
        dragMode == 'MobileSelectionDragMode.rightSelectionHandle') {
      return false;
    }
    final selection = widget.editor.selection;
    return selection != null &&
        !selection.isCollapsed &&
        _validSelection(selection) &&
        _textOnly(selection);
  }

  void _scheduleFloatingGeometry() {
    if (_geometryQueued || !mounted) return;
    _geometryQueued = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _geometryQueued = false;
      if (!mounted) return;
      final session = _floatingEligible ? _capture() : null;
      final box = _contentKey.currentContext?.findRenderObject();
      if (session == null ||
          box is! RenderBox ||
          !box.attached ||
          !box.hasSize) {
        if (_floating != null) setState(() => _floating = null);
        return;
      }
      final bounds = box.localToGlobal(Offset.zero) & box.size;
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
      const height = 44.0;
      const gap = 8.0;
      final width = (session.selection.isSingle ? 210.0 : 168.0).clamp(
        0.0,
        bounds.width,
      );
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
          previous.session.revision != session.revision ||
          previous.session.selectionRevision != session.selectionRevision) {
        setState(
          () =>
              _floating = (position: position, width: width, session: session),
        );
      }
    });
  }

  void _floatingAction(_SelectionSession session, VoidCallback action) {
    if (!_floatingEligible || !_sessionValid(session)) {
      if (mounted) _selectionExpired();
      return;
    }
    action();
  }

  Widget _surface(Widget child, bool showFloating) {
    if (showFloating) _scheduleFloatingGeometry();
    final floating = _floating;
    final valid =
        showFloating && floating != null && _sessionValid(floating.session);
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
            height: 44,
            child: Material(
              key: const ValueKey('rich-selection-menu'),
              color: context.theme.colors.surface,
              elevation: 4,
              borderRadius: BorderRadius.circular(8),
              clipBehavior: Clip.antiAlias,
              child: Row(
                children: [
                  Expanded(
                    child: _floatingButton(
                      'format',
                      context.l10n.editor.toolbar.format,
                      LucideIcons.caseSensitive,
                      floating.session,
                      _openFormat,
                    ),
                  ),
                  Expanded(
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
                  Expanded(
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
                  if (floating.session.selection.isSingle)
                    Expanded(
                      child: _floatingButton(
                        'link',
                        context.l10n.editor.toolbar.link,
                        LucideIcons.link,
                        floating.session,
                        _openLink,
                      ),
                    ),
                  Expanded(
                    child: _floatingButton(
                      'copy',
                      MaterialLocalizations.of(context).copyButtonLabel,
                      LucideIcons.copy,
                      floating.session,
                      () => af.copyCommand.execute(widget.editor),
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
    VoidCallback action,
  ) => IconButton(
    key: ValueKey('rich-floating-$id'),
    tooltip: tooltip,
    iconSize: 20,
    padding: EdgeInsets.zero,
    icon: Icon(icon),
    onPressed: () => _floatingAction(session, action),
  );

  bool _validSelection(af.Selection? selection) {
    if (!_editable || selection == null) return false;
    bool validPosition(af.Position position) {
      final node = widget.editor.document.nodeAtPath(position.path);
      final delta = node?.delta;
      return delta != null &&
          position.offset >= 0 &&
          position.offset <= delta.length;
    }

    return validPosition(selection.start) && validPosition(selection.end);
  }

  _SelectionSession? _capture() {
    final selection = widget.editor.selection;
    if (!_validSelection(selection)) return null;
    final saved = _selectionSnapshot(selection)!;
    return _SelectionSession(
      saved,
      widget.editor.document.nodeAtPath(saved.start.path)!,
      widget.editor.document.nodeAtPath(saved.end.path)!,
      _revision,
      _selectionRevision,
    );
  }

  bool _sessionValid(_SelectionSession session) =>
      mounted &&
      !session.expired &&
      _validSelection(session.selection) &&
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

  bool _textOnly(af.Selection selection) {
    final nodes = widget.editor.getNodesInSelection(selection);
    const supported = {
      af.ParagraphBlockKeys.type,
      af.HeadingBlockKeys.type,
      af.TodoListBlockKeys.type,
      af.BulletedListBlockKeys.type,
      af.NumberedListBlockKeys.type,
      af.QuoteBlockKeys.type,
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
    final session = _capture();
    if (session == null || _busy || !_textOnly(session.selection)) return;
    await _runSession(session, command);
  }

  Future<void> _openInsert() async {
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
      // Match AppFlowy's insertion order but await the transaction so the
      // selection session cannot complete before the document is updated.
      final insertedPath = current.delta!.isEmpty
          ? path
          : ([...path]..last += 1);
      final next = current.next;
      final transaction = widget.editor.transaction
        ..insertNode(insertedPath, af.dividerNode());
      if (next == null ||
          next.type != af.ParagraphBlockKeys.type ||
          next.delta?.isNotEmpty == true) {
        transaction.insertNode(insertedPath, af.paragraphNode());
      }
      transaction.afterSelection = af.Selection.collapsed(
        af.Position(path: [...insertedPath]..last += 1),
      );
      await widget.editor.apply(transaction);
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
      _InsertBlock.divider => throw StateError('unreachable'),
    };
    final emptyParagraph =
        current.type == af.ParagraphBlockKeys.type &&
        current.delta!.toPlainText().isEmpty &&
        current.children.isEmpty;
    final nextPath = [...path]..last += 1;
    final transaction = widget.editor.transaction..insertNode(nextPath, block);
    if (emptyParagraph) transaction.deleteNode(current);
    transaction.afterSelection = af.Selection.collapsed(
      af.Position(path: emptyParagraph ? path : nextPath),
    );
    await widget.editor.apply(transaction);
  }

  Future<void> _openFormat() async {
    final session = _capture();
    if (session == null || !_textOnly(session.selection)) return;
    // Scaffold removes bottom viewInsets from its body after resizing it.
    final keyboardWasVisible =
        View.of(context).viewInsets.bottom > 0 && widget.focusNode.hasFocus;
    await SystemChannels.textInput.invokeMethod<void>('TextInput.hide');
    if (!mounted || !_sessionValid(session)) return;
    final done = await showModalBottomSheet<bool>(
      context: context,
      requestFocus: false,
      isScrollControlled: true,
      useSafeArea: true,
      backgroundColor: Colors.transparent,
      builder: (_) => _FormatSheet(
        editor: widget.editor,
        valid: () => _sessionValid(session) && !_busy,
        execute: (command) => _runSession(session, command),
        executeMove: (command) =>
            _runSession(session, command, allowMovedSelection: true),
        toggle: _toggle,
        convert: _convert,
        color: _color,
        align: _align,
        loadFonts: widget.loadFonts,
        scrollController: widget.scrollController,
        canConvert: () => _canConvert(session.selection),
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

  Future<void> _openColor() async {
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

  Future<void> _openLink() async {
    final session = _capture();
    if (session == null ||
        session.selection.isCollapsed ||
        !session.selection.isSingle ||
        !_textOnly(session.selection)) {
      return;
    }
    final existing = widget.editor.getDeltaAttributeValueInSelection<String>(
      af.AppFlowyRichTextKeys.href,
      session.selection,
    );
    final result = await showDialog<({bool remove, String value})>(
      context: context,
      builder: (_) => _LinkDialog(existing: existing),
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
      (selection) => widget.editor.formatDelta(
        selection,
        {af.AppFlowyRichTextKeys.href: result.remove ? null : result.value},
        selectionExtraInfo: {af.selectionExtraInfoDoNotAttachTextService: true},
      ),
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

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final selection = widget.editor.selection;
    final keyboard = View.of(context).viewInsets.bottom > 0;
    final show =
        _editable &&
        widget.focusNode.hasFocus &&
        _validSelection(selection) &&
        keyboard;
    final showFloating = _floatingEligible;
    // Keep the editor at the same position in the tree across mode changes.
    if (!show) {
      return _surface(
        Column(children: [Expanded(child: widget.child)]),
        showFloating,
      );
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
    final canText = !_busy && _textOnly(selected);
    final canBlock = canText && selected.isSingle;
    final actions = <_ToolbarAction>[
      _ToolbarAction(
        'todo',
        l10n.editor.toolbar.taskList,
        LucideIcons.listTodo,
        !isRange && canBlock
            ? () => _quick((s) => _convert(s, af.TodoListBlockKeys.type))
            : null,
      ),
      _ToolbarAction(
        'bullet',
        l10n.editor.toolbar.bulletList,
        LucideIcons.list,
        !isRange && canBlock
            ? () => _quick((s) => _convert(s, af.BulletedListBlockKeys.type))
            : null,
      ),
      _ToolbarAction(
        'numbered',
        l10n.editor.toolbar.orderedList,
        LucideIcons.listOrdered,
        !isRange && canBlock
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
        'color',
        l10n.dailynotes.editorTextColor,
        LucideIcons.baseline,
        canText ? _openColor : null,
      ),
      if (isRange && selected.isSingle)
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
    final quickIds = quickCandidates
        .where((id) => actions.firstWhere((a) => a.id == id).onPressed != null)
        .toList();
    final visible = [
      for (final id in quickIds) actions.firstWhere((a) => a.id == id),
    ];
    final overflow = actions.where((a) => !quickIds.contains(a.id)).toList();
    return _surface(
      Column(
        children: [
          Expanded(child: widget.child),
          Material(
            color: context.theme.colors.surface,
            child: SizedBox(
              height: 42,
              child: Row(
                children: [
                  Expanded(
                    child: _button(
                      'insert',
                      l10n.editor.toolbar.insert,
                      LucideIcons.plus,
                      !isRange && canBlock ? _openInsert : null,
                    ),
                  ),
                  Expanded(
                    child: _button(
                      'format',
                      l10n.editor.toolbar.format,
                      LucideIcons.caseSensitive,
                      canText ? _openFormat : null,
                    ),
                  ),
                  for (final action in visible)
                    Expanded(
                      child: _button(
                        action.id,
                        action.label,
                        action.icon,
                        action.onPressed,
                        selected: action.selected,
                      ),
                    ),
                  Expanded(
                    child: PopupMenuButton<String>(
                      key: const ValueKey('rich-toolbar-more'),
                      tooltip: l10n.common.more,
                      icon: const Icon(LucideIcons.ellipsis),
                      iconSize: 20,
                      padding: EdgeInsets.zero,
                      requestFocus: false,
                      onOpened: () => _overflowSession = _capture(),
                      onCanceled: () => _overflowSession = null,
                      onSelected: (id) {
                        final session = _overflowSession;
                        _overflowSession = null;
                        if (session == null || !_sessionValid(session)) {
                          if (mounted) _selectionExpired();
                          return;
                        }
                        final action = overflow
                            .where((a) => a.id == id)
                            .firstOrNull;
                        action?.onPressed?.call();
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
                              ],
                            ),
                          ),
                      ],
                    ),
                  ),
                  Expanded(
                    child: _button(
                      'close',
                      l10n.editor.toolbar.hideKeyboard,
                      LucideIcons.chevronDown,
                      () => SystemChannels.textInput.invokeMethod<void>(
                        'TextInput.hide',
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
      false,
    );
  }
}

List<(String, String?, Color)> _editorColors(BuildContext context) {
  final t = context.l10n.dailynotes;
  final choices = <(String, String?)>[
    (t.editorColorDefault, null),
    (t.editorColorRed, '0xffd32f2f'),
    (t.editorColorOrange, '0xffef6c00'),
    (t.editorColorYellow, '0xffffc107'),
    (t.editorColorGreen, '0xff388e3c'),
    (t.editorColorBlue, '0xff1976d2'),
    (t.editorColorPurple, '0xff7b1fa2'),
  ];
  // Swatches and persisted colors must share exactly the same value.
  return [
    for (final (label, value) in choices)
      (
        label,
        value,
        value == null ? context.theme.colors.surface : Color(int.parse(value)),
      ),
  ];
}

String? _colorValue(String key, String? value) =>
    value != null && key == af.AppFlowyRichTextKeys.backgroundColor
    ? value.replaceFirst('0xff', '0x4d')
    : value;

class _QuickColorSheet extends StatefulWidget {
  const _QuickColorSheet({
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
    if (_running || _expired || !widget.valid()) return;
    setState(() => _running = true);
    final success = await widget.execute(
      (selection) => widget.color(selection, key, _colorValue(key, value)),
    );
    if (!mounted) return;
    setState(() {
      _running = false;
      _expired = !success;
    });
  }

  @override
  Widget build(BuildContext context) {
    final t = context.l10n.dailynotes;
    final valid = !_expired && widget.valid();
    final enabled = !_running && valid;
    Widget palette(String key, String identifier) => Wrap(
      spacing: 8,
      runSpacing: 8,
      children: [
        for (final (label, value, color) in _editorColors(context))
          Tooltip(
            message: label,
            child: InkWell(
              key: ValueKey(
                'rich-quick-color-$identifier-${value ?? 'default'}',
              ),
              onTap: enabled ? () => _select(key, value) : null,
              borderRadius: BorderRadius.circular(24),
              child: Container(
                width: 42,
                height: 42,
                decoration: BoxDecoration(
                  color: color,
                  shape: BoxShape.circle,
                  border: Border.all(color: context.theme.colors.outline),
                ),
                child: value == null
                    ? const Icon(LucideIcons.ban, size: 20)
                    : null,
              ),
            ),
          ),
      ],
    );
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
                  onPressed: () => Navigator.pop(context, true),
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
  const _LinkDialog({required this.existing});
  final String? existing;

  @override
  State<_LinkDialog> createState() => _LinkDialogState();
}

class _LinkDialogState extends State<_LinkDialog> {
  late final TextEditingController _controller;
  String? _error;

  @override
  void initState() {
    super.initState();
    _controller = TextEditingController(text: widget.existing ?? '');
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  void _save() {
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
    Navigator.pop(context, (remove: false, value: value));
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
    title: Text(context.l10n.editor.toolbar.link),
    content: TextField(
      key: const ValueKey('rich-link-address'),
      controller: _controller,
      autofocus: true,
      keyboardType: TextInputType.url,
      decoration: InputDecoration(
        labelText: context.l10n.dailynotes.editorLinkAddress,
        errorText: _error,
      ),
    ),
    actions: [
      TextButton(
        onPressed: () => Navigator.pop(context),
        child: Text(context.l10n.common.cancel),
      ),
      if (widget.existing != null)
        TextButton(
          key: const ValueKey('rich-link-remove'),
          onPressed: () => Navigator.pop(context, (remove: true, value: '')),
          child: Text(context.l10n.dailynotes.editorLinkRemove),
        ),
      TextButton(
        key: const ValueKey('rich-link-save'),
        onPressed: _save,
        child: Text(context.l10n.common.save),
      ),
    ],
  );
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
    required this.color,
    required this.align,
    required this.loadFonts,
    required this.scrollController,
    required this.canConvert,
  });
  final af.EditorState editor;
  final af.EditorScrollController? scrollController;
  final bool Function() valid;
  final bool Function() canConvert;
  final Future<bool> Function(_FormatCommand) execute;
  final Future<bool> Function(_FormatCommand) executeMove;
  final Future<void> Function(af.Selection, String) toggle;
  final Future<void> Function(af.Selection, String, {int? level}) convert;
  final Future<void> Function(af.Selection, String, String?) color;
  final Future<void> Function(af.Selection, String) align;
  final Future<({List<String> families, bool hasUnavailable})> Function()?
  loadFonts;

  @override
  State<_FormatSheet> createState() => _FormatSheetState();
}

class _FormatSheetState extends State<_FormatSheet> {
  String? _colorKey;
  bool _fontView = false;
  bool _fontLoading = false;
  bool _fontLoadFailed = false;
  List<String> _importedFonts = [];
  bool _running = false;
  bool _expired = false;
  late final StreamSubscription<dynamic> _changes;
  final _surfaceKey = GlobalKey();
  final _sheetController = DraggableScrollableController();
  Animation<double>? _routeAnimation;
  bool _visibilityScheduled = false;
  bool _adjustingScroll = false;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final animation = ModalRoute.of(context)?.animation;
    if (_routeAnimation != animation) {
      _routeAnimation?.removeListener(_scheduleVisibilityCheck);
      _routeAnimation = animation;
      _routeAnimation?.addListener(_scheduleVisibilityCheck);
    }
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
          ModalRoute.of(context)?.isCurrent != true ||
          _routeAnimation?.status == AnimationStatus.reverse) {
        return;
      }
      final box = _surfaceKey.currentContext?.findRenderObject();
      if (box is! RenderBox || !box.attached || !box.hasSize) return;
      final sheet = box.localToGlobal(Offset.zero) & box.size;
      final covered = widget.editor
          .selectionRects()
          .where(
            (rect) =>
                rect.bottom > sheet.top &&
                rect.top < sheet.bottom &&
                rect.right > sheet.left &&
                rect.left < sheet.right,
          )
          .toList();
      if (covered.isEmpty) return;
      final bottom = covered
          .map((rect) => rect.bottom)
          .reduce((a, b) => a > b ? a : b);
      final delta = bottom - sheet.top + 8;
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
              // The moving sheet can cover more text during a scroll. Retry
              // only after actual progress, so document boundaries cannot loop.
              if (bottom - newBottom > .5) {
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
    _sheetController.addListener(_scheduleVisibilityCheck);
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
    _routeAnimation?.removeListener(_scheduleVisibilityCheck);
    _sheetController.removeListener(_scheduleVisibilityCheck);
    _sheetController.dispose();
    _changes.cancel();
    super.dispose();
  }

  Future<void> _perform(
    _FormatCommand command, {
    bool move = false,
    bool closeColor = false,
  }) async {
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
      if (success && closeColor) _colorKey = null;
    });
  }

  void _backToFormat() => setState(() {
    _colorKey = null;
    _fontView = false;
  });

  Future<void> _openFonts() async {
    setState(() {
      _fontView = true;
      _fontLoading = true;
      _fontLoadFailed = false;
    });
    try {
      final catalog =
          await (widget.loadFonts?.call() ??
              Future.value((families: <String>[], hasUnavailable: false)));
      if (!mounted || !_fontView) return;
      setState(() {
        _importedFonts = catalog.families;
        _fontLoadFailed = catalog.hasUnavailable;
        _fontLoading = false;
      });
    } catch (_) {
      if (!mounted || !_fontView) return;
      setState(() {
        _fontLoadFailed = true;
        _fontLoading = false;
      });
    }
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

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final e = l10n.editor.toolbar;
    final t = l10n.dailynotes;
    final selectionValid = !_expired && widget.valid();
    final enabled = !_running && selectionValid;
    final canBlock = enabled && widget.canConvert();
    return PopScope(
      canPop: _colorKey == null && !_fontView,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop && (_colorKey != null || _fontView)) _backToFormat();
      },
      child: DraggableScrollableSheet(
        controller: _sheetController,
        expand: false,
        initialChildSize: 0.5,
        minChildSize: 0.25,
        maxChildSize: 0.9,
        builder: (context, controller) => Material(
          key: _surfaceKey,
          borderRadius: const BorderRadius.vertical(top: Radius.circular(18)),
          clipBehavior: Clip.antiAlias,
          child: Column(
            children: [
              GestureDetector(
                key: const ValueKey('rich-format-drag-handle'),
                behavior: HitTestBehavior.opaque,
                onVerticalDragUpdate: (details) {
                  final box = _surfaceKey.currentContext?.findRenderObject();
                  if (!_sheetController.isAttached ||
                      box is! RenderBox ||
                      !box.hasSize ||
                      _sheetController.size <= 0) {
                    return;
                  }
                  final parentHeight = box.size.height / _sheetController.size;
                  if (parentHeight <= 0) return;
                  _sheetController.jumpTo(
                    (_sheetController.size - details.delta.dy / parentHeight)
                        .clamp(.25, .9),
                  );
                },
                child: SizedBox(
                  height: 24,
                  child: Center(
                    child: Container(
                      width: 40,
                      height: 4,
                      decoration: BoxDecoration(
                        color: context.theme.colors.outlineVariant,
                        borderRadius: BorderRadius.circular(3),
                      ),
                    ),
                  ),
                ),
              ),
              ListTile(
                leading: _colorKey == null && !_fontView
                    ? null
                    : IconButton(
                        tooltip: t.editorBackToFormat,
                        icon: const Icon(LucideIcons.arrowLeft),
                        onPressed: _backToFormat,
                      ),
                title: Text(
                  _fontView
                      ? t.editorFont
                      : _colorKey == af.AppFlowyRichTextKeys.textColor
                      ? t.editorTextColor
                      : _colorKey == af.AppFlowyRichTextKeys.backgroundColor
                      ? t.editorHighlightColor
                      : e.format,
                ),
                trailing: TextButton(
                  onPressed: () {
                    if (_fontView || _colorKey != null) {
                      _backToFormat();
                    } else {
                      Navigator.pop(context, true);
                    }
                  },
                  child: Text(t.editorFormatDone),
                ),
              ),
              if (!selectionValid && !_running)
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 16),
                  child: Text(t.editorSelectionChanged),
                ),
              Expanded(
                child: _fontView
                    ? _fonts(context, controller, enabled)
                    : _colorKey != null
                    ? _colors(context, controller, enabled)
                    : ListView(
                        controller: controller,
                        padding: const EdgeInsets.symmetric(horizontal: 12),
                        children: [
                          _row([
                            TextButton(
                              onPressed: canBlock
                                  ? () => _perform(
                                      (s) => widget.convert(
                                        s,
                                        af.ParagraphBlockKeys.type,
                                      ),
                                    )
                                  : null,
                              child: Text(e.paragraph),
                            ),
                            for (final level in [1, 2, 3])
                              TextButton(
                                onPressed: canBlock
                                    ? () => _perform(
                                        (s) => widget.convert(
                                          s,
                                          af.HeadingBlockKeys.type,
                                          level: level,
                                        ),
                                      )
                                    : null,
                                child: Text('H$level'),
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
                              enabled
                                  ? () => setState(
                                      () => _colorKey =
                                          af.AppFlowyRichTextKeys.textColor,
                                    )
                                  : null,
                            ),
                            _icon(
                              t.editorHighlightColor,
                              LucideIcons.highlighter,
                              enabled
                                  ? () => setState(
                                      () => _colorKey = af
                                          .AppFlowyRichTextKeys
                                          .backgroundColor,
                                    )
                                  : null,
                            ),
                          ]),
                          const Divider(height: 1),
                          _row([
                            _icon(
                              e.taskList,
                              LucideIcons.listTodo,
                              canBlock
                                  ? () => _perform(
                                      (s) => widget.convert(
                                        s,
                                        af.TodoListBlockKeys.type,
                                      ),
                                    )
                                  : null,
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
                            ),
                            _icon(
                              e.quote,
                              LucideIcons.quote,
                              canBlock
                                  ? () => _perform(
                                      (s) => widget.convert(
                                        s,
                                        af.QuoteBlockKeys.type,
                                      ),
                                    )
                                  : null,
                            ),
                            _icon(
                              t.editorAlignLeft,
                              LucideIcons.alignLeft,
                              enabled
                                  ? () =>
                                        _perform((s) => widget.align(s, 'left'))
                                  : null,
                            ),
                            _icon(
                              t.editorAlignCenter,
                              LucideIcons.alignCenter,
                              enabled
                                  ? () => _perform(
                                      (s) => widget.align(s, 'center'),
                                    )
                                  : null,
                            ),
                            _icon(
                              t.editorAlignRight,
                              LucideIcons.alignRight,
                              enabled
                                  ? () => _perform(
                                      (s) => widget.align(s, 'right'),
                                    )
                                  : null,
                            ),
                          ]),
                          const Divider(height: 1),
                          _row([
                            TextButton.icon(
                              key: const ValueKey('rich-format-font'),
                              onPressed: enabled ? _openFonts : null,
                              icon: const Icon(LucideIcons.type, size: 20),
                              label: Text(t.editorFont),
                            ),
                            _icon(
                              e.outdent,
                              LucideIcons.outdent,
                              enabled && af.isOutdentable(widget.editor)
                                  ? () => _perform(
                                      (_) async => af.outdentCommand.execute(
                                        widget.editor,
                                      ),
                                      move: true,
                                    )
                                  : null,
                            ),
                            _icon(
                              e.indent,
                              LucideIcons.indent,
                              enabled && af.isIndentable(widget.editor)
                                  ? () => _perform(
                                      (_) async => af.indentCommand.execute(
                                        widget.editor,
                                      ),
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
      ),
    );
  }

  Widget _fonts(
    BuildContext context,
    ScrollController controller,
    bool enabled,
  ) {
    final t = context.l10n.dailynotes;
    // Android fonts are available on the target platform. The iOS equivalents
    // provide the same categories on iOS instead of pretending Android names exist.
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
        ? _currentFont(widget.editor, selection)
        : (known: false, family: null);
    final seen = <String?>{};
    final uniqueOptions = options.where((option) => seen.add(option.$2));
    return ListView(
      controller: controller,
      children: [
        if (_fontLoading) const LinearProgressIndicator(),
        if (_fontLoadFailed)
          Padding(
            padding: const EdgeInsets.all(16),
            child: Text(t.editorFontLoadFailed),
          ),
        for (final (label, family) in uniqueOptions)
          ListTile(
            key: ValueKey('rich-font-${family ?? 'default'}'),
            selected: current.known && current.family == family,
            trailing: current.known && current.family == family
                ? const Icon(LucideIcons.check)
                : null,
            title: Text(
              label,
              style: context.theme.typography.bodyLarge.onSurface.copyWith(
                fontFamily: family,
              ),
            ),
            onTap: enabled
                ? () async {
                    await _perform(
                      (s) => widget.color(
                        s,
                        af.AppFlowyRichTextKeys.fontFamily,
                        family,
                      ),
                    );
                    if (mounted && !_expired) _backToFormat();
                  }
                : null,
          ),
      ],
    );
  }

  Widget _colors(
    BuildContext context,
    ScrollController controller,
    bool enabled,
  ) {
    final values = _editorColors(context);
    return ListView(
      controller: controller,
      padding: const EdgeInsets.all(16),
      children: [
        Wrap(
          spacing: 12,
          runSpacing: 12,
          children: [
            for (final (label, value, color) in values)
              Tooltip(
                message: label,
                child: InkWell(
                  key: ValueKey('rich-color-${value ?? 'default'}'),
                  onTap: enabled
                      ? () => _perform(
                          (s) => widget.color(
                            s,
                            _colorKey!,
                            _colorValue(_colorKey!, value),
                          ),
                          closeColor: true,
                        )
                      : null,
                  borderRadius: BorderRadius.circular(24),
                  child: Container(
                    width: 44,
                    height: 44,
                    decoration: BoxDecoration(
                      color: color,
                      shape: BoxShape.circle,
                      border: Border.all(color: context.theme.colors.outline),
                    ),
                    child: value == null
                        ? const Icon(LucideIcons.ban, size: 20)
                        : null,
                  ),
                ),
              ),
          ],
        ),
      ],
    );
  }
}
