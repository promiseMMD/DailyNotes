import 'dart:async';

import 'package:appflowy_editor/appflowy_editor.dart' as af;
import 'package:flutter/services.dart';
import 'package:moodiary_i18n/moodiary_i18n.dart';
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
  });

  final af.EditorState editor;
  final FocusNode focusNode;
  final bool editable;
  final Widget child;

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

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    widget.focusNode.addListener(_focusChanged);
    _observedSelection = _selectionSnapshot(widget.editor.selection);
    widget.editor.selectionNotifier.addListener(_selectionChanged);
    _listenTransactions();
  }

  void _listenTransactions() {
    _transactions = widget.editor.transactionStream.listen((event) {
      if (event.$1 == af.TransactionTime.after) {
        _revision++;
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
    if (!identical(oldWidget.editor, widget.editor)) {
      oldWidget.editor.selectionNotifier.removeListener(_selectionChanged);
      _transactions.cancel();
      _revision++;
      _selectionRevision++;
      _observedSelection = _selectionSnapshot(widget.editor.selection);
      widget.editor.selectionNotifier.addListener(_selectionChanged);
      _listenTransactions();
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    widget.focusNode.removeListener(_focusChanged);
    widget.editor.selectionNotifier.removeListener(_selectionChanged);
    _transactions.cancel();
    super.dispose();
  }

  void _focusChanged() {
    if (mounted) setState(() {});
  }

  @override
  void didChangeMetrics() {
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
    if (mounted) setState(() {});
  }

  bool get _editable =>
      widget.editable && widget.editor.editable && !widget.editor.isDisposed;

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
    if (!selection.isSingle || !_textOnly(selection)) return;
    final current = widget.editor.document.nodeAtPath(selection.start.path);
    if (current == null) return;
    final selected =
        current.type == type &&
        (type != af.HeadingBlockKeys.type ||
            current.attributes[af.HeadingBlockKeys.level] == level);
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
        attrs[af.TodoListBlockKeys.checked] = false;
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
      // The editor library inserts a divider and maintains a following text block.
      af.dividerMobileToolbarItem.actionHandler!(context, widget.editor);
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

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final selection = widget.editor.selection;
    final keyboard = View.of(context).viewInsets.bottom > 0;
    final show =
        _editable &&
        widget.focusNode.hasFocus &&
        _validSelection(selection) &&
        (keyboard || !selection!.isCollapsed);
    // Keep the editor at the same element-tree position as keyboard and
    // selection state change; rebuilding the editor would lose IME state.
    if (!show) return Column(children: [Expanded(child: widget.child)]);
    final isRange = !selection!.isCollapsed;
    final node = widget.editor.document.nodeAtPath(selection.start.path);
    final isList =
        node != null &&
        const {
          af.TodoListBlockKeys.type,
          af.BulletedListBlockKeys.type,
          af.NumberedListBlockKeys.type,
        }.contains(node.type);
    final canText = !_busy && _textOnly(selection);
    final canBlock = canText && selection.isSingle;
    return Column(
      children: [
        Expanded(child: widget.child),
        Material(
          color: context.theme.colors.surface,
          child: SizedBox(
            height: 42,
            child: Row(
              children: [
                Expanded(
                  child: SingleChildScrollView(
                    scrollDirection: Axis.horizontal,
                    child: Row(
                      children: [
                        if (!isRange)
                          _button(
                            'insert',
                            l10n.editor.toolbar.insert,
                            LucideIcons.plus,
                            canBlock ? _openInsert : null,
                          ),
                        _button(
                          'format',
                          l10n.editor.toolbar.format,
                          LucideIcons.caseSensitive,
                          canText ? _openFormat : null,
                        ),
                        if (!isRange && isList) ...[
                          _button(
                            'outdent',
                            l10n.editor.toolbar.outdent,
                            LucideIcons.outdent,
                            canBlock && af.isOutdentable(widget.editor)
                                ? () {
                                    if (_editable &&
                                        af.isOutdentable(widget.editor)) {
                                      af.outdentCommand.execute(widget.editor);
                                    }
                                  }
                                : null,
                          ),
                          _button(
                            'indent',
                            l10n.editor.toolbar.indent,
                            LucideIcons.indent,
                            canBlock && af.isIndentable(widget.editor)
                                ? () {
                                    if (_editable &&
                                        af.isIndentable(widget.editor)) {
                                      af.indentCommand.execute(widget.editor);
                                    }
                                  }
                                : null,
                          ),
                        ],
                        if (!isRange) ...[
                          _button(
                            'todo',
                            l10n.editor.toolbar.taskList,
                            LucideIcons.listTodo,
                            canBlock
                                ? () => _quick(
                                    (s) =>
                                        _convert(s, af.TodoListBlockKeys.type),
                                  )
                                : null,
                          ),
                          _button(
                            'bullet',
                            l10n.editor.toolbar.bulletList,
                            LucideIcons.list,
                            canBlock
                                ? () => _quick(
                                    (s) => _convert(
                                      s,
                                      af.BulletedListBlockKeys.type,
                                    ),
                                  )
                                : null,
                          ),
                          _button(
                            'numbered',
                            l10n.editor.toolbar.orderedList,
                            LucideIcons.listOrdered,
                            canBlock
                                ? () => _quick(
                                    (s) => _convert(
                                      s,
                                      af.NumberedListBlockKeys.type,
                                    ),
                                  )
                                : null,
                          ),
                        ],
                        _button(
                          'bold',
                          l10n.editor.toolbar.bold,
                          LucideIcons.bold,
                          canText
                              ? () => _quick(
                                  (s) =>
                                      _toggle(s, af.AppFlowyRichTextKeys.bold),
                                )
                              : null,
                          selected: _styleActive(
                            widget.editor,
                            selection,
                            af.AppFlowyRichTextKeys.bold,
                          ),
                        ),
                        _button(
                          'italic',
                          l10n.editor.toolbar.italic,
                          LucideIcons.italic,
                          canText
                              ? () => _quick(
                                  (s) => _toggle(
                                    s,
                                    af.AppFlowyRichTextKeys.italic,
                                  ),
                                )
                              : null,
                          selected: _styleActive(
                            widget.editor,
                            selection,
                            af.AppFlowyRichTextKeys.italic,
                          ),
                        ),
                        _button(
                          'underline',
                          l10n.editor.toolbar.underline,
                          LucideIcons.underline,
                          canText
                              ? () => _quick(
                                  (s) => _toggle(
                                    s,
                                    af.AppFlowyRichTextKeys.underline,
                                  ),
                                )
                              : null,
                          selected: _styleActive(
                            widget.editor,
                            selection,
                            af.AppFlowyRichTextKeys.underline,
                          ),
                        ),
                        _button(
                          'strike',
                          l10n.editor.toolbar.strike,
                          LucideIcons.strikethrough,
                          canText
                              ? () => _quick(
                                  (s) => _toggle(
                                    s,
                                    af.AppFlowyRichTextKeys.strikethrough,
                                  ),
                                )
                              : null,
                          selected: _styleActive(
                            widget.editor,
                            selection,
                            af.AppFlowyRichTextKeys.strikethrough,
                          ),
                        ),
                        _button(
                          'color',
                          l10n.dailynotes.editorTextColor,
                          LucideIcons.baseline,
                          canText ? _openColor : null,
                        ),
                        if (!isRange) ...[
                          _button(
                            'undo',
                            l10n.editor.toolbar.undo,
                            LucideIcons.undo2,
                            _busy || widget.editor.undoManager.undoStack.isEmpty
                                ? null
                                : () {
                                    if (_editable) {
                                      af.undoCommand.execute(widget.editor);
                                    }
                                  },
                          ),
                          _button(
                            'redo',
                            l10n.editor.toolbar.redo,
                            LucideIcons.redo2,
                            _busy || widget.editor.undoManager.redoStack.isEmpty
                                ? null
                                : () {
                                    if (_editable) {
                                      af.redoCommand.execute(widget.editor);
                                    }
                                  },
                          ),
                        ],
                      ],
                    ),
                  ),
                ),
                _button(
                  'close',
                  l10n.editor.toolbar.hideKeyboard,
                  LucideIcons.chevronDown,
                  () {
                    SystemChannels.textInput.invokeMethod<void>(
                      'TextInput.hide',
                    );
                  },
                ),
              ],
            ),
          ),
        ),
      ],
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
  });
  final af.EditorState editor;
  final bool Function() valid;
  final Future<bool> Function(_FormatCommand) execute;
  final Future<bool> Function(_FormatCommand) executeMove;
  final Future<void> Function(af.Selection, String) toggle;
  final Future<void> Function(af.Selection, String, {int? level}) convert;
  final Future<void> Function(af.Selection, String, String?) color;
  final Future<void> Function(af.Selection, String) align;

  @override
  State<_FormatSheet> createState() => _FormatSheetState();
}

class _FormatSheetState extends State<_FormatSheet> {
  String? _colorKey;
  bool _running = false;
  bool _expired = false;
  late final StreamSubscription<dynamic> _changes;

  @override
  void initState() {
    super.initState();
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
    final canBlock = enabled && widget.editor.selection?.isSingle == true;
    return PopScope(
      canPop: _colorKey == null,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop && _colorKey != null) setState(() => _colorKey = null);
      },
      child: DraggableScrollableSheet(
        expand: false,
        initialChildSize: 0.5,
        minChildSize: 0.25,
        maxChildSize: 0.9,
        builder: (context, controller) => Material(
          borderRadius: const BorderRadius.vertical(top: Radius.circular(18)),
          clipBehavior: Clip.antiAlias,
          child: Column(
            children: [
              Center(
                child: Container(
                  width: 40,
                  height: 4,
                  margin: const EdgeInsets.only(top: 8),
                  decoration: BoxDecoration(
                    color: context.theme.colors.outlineVariant,
                    borderRadius: BorderRadius.circular(3),
                  ),
                ),
              ),
              ListTile(
                leading: _colorKey == null
                    ? null
                    : IconButton(
                        tooltip: t.editorBackToFormat,
                        icon: const Icon(LucideIcons.arrowLeft),
                        onPressed: () => setState(() => _colorKey = null),
                      ),
                title: Text(
                  _colorKey == af.AppFlowyRichTextKeys.textColor
                      ? t.editorTextColor
                      : _colorKey == af.AppFlowyRichTextKeys.backgroundColor
                      ? t.editorHighlightColor
                      : e.format,
                ),
                trailing: TextButton(
                  onPressed: () => Navigator.pop(context, true),
                  child: Text(t.editorFormatDone),
                ),
              ),
              if (!selectionValid && !_running)
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 16),
                  child: Text(t.editorSelectionChanged),
                ),
              Expanded(
                child: _colorKey != null
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
