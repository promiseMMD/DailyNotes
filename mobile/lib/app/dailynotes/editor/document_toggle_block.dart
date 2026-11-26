import 'dart:async';

import 'package:appflowy_editor/appflowy_editor.dart' as af;
import 'package:moodiary_i18n/moodiary_i18n.dart';
import 'package:mui/mui.dart';

import 'document_toggle_model.dart';

/// Fold state is a presentation override, kept separate from stored content.
class DocumentToggleController extends ChangeNotifier {
  final Expando<bool> _collapsed = Expando<bool>();

  bool isCollapsed(af.Node node) =>
      _collapsed[node] ?? node.attributes[DocumentToggleKeys.collapsed] == true;

  void setCollapsed(af.Node node, bool value) {
    if (isCollapsed(node) == value) return;
    _collapsed[node] = value;
    notifyListeners();
  }

  bool expandAncestors(af.Node node) {
    var parent = node.parent;
    var changed = false;
    while (parent != null) {
      if (parent.type == DocumentToggleKeys.type && isCollapsed(parent)) {
        _collapsed[parent] = false;
        changed = true;
      }
      parent = parent.parent;
    }
    if (changed) notifyListeners();
    return changed;
  }
}

af.CharacterShortcutEvent documentToggleEnter(
  DocumentToggleController folds,
) => af.CharacterShortcutEvent(
  key: 'dailynotes toggle enter',
  character: '\n',
  handler: (editor) async {
    final selection = editor.selection;
    if (selection == null) return false;
    if (!selection.isSingle) {
      try {
        for (final selectedNode in editor.getNodesInSelection(selection)) {
          af.Node? ancestor = selectedNode;
          while (ancestor != null) {
            if (ancestor.type == DocumentToggleKeys.type) {
              final context = ancestor.key.currentContext;
              if (context != null && context.mounted) {
                ScaffoldMessenger.maybeOf(context)?.showSnackBar(
                  SnackBar(
                    content: Text(
                      context.l10n.dailynotes.toggleComplexSelection,
                    ),
                  ),
                );
              }
              return true;
            }
            ancestor = ancestor.parent;
          }
        }
      } catch (_) {
        return true;
      }
      return false;
    }
    final selected = selection.normalized;
    final node = editor.document.nodeAtPath(selected.start.path);
    final delta = node?.delta;
    if (node == null || node.type != DocumentToggleKeys.type || delta == null) {
      return false;
    }
    final offset = selected.start.offset;
    final end = selected.end.offset;
    if (offset < 0 || end < offset || end > delta.length) return true;
    final transaction = editor.transaction;
    final path = node.path;
    if (folds.isCollapsed(node)) {
      if (offset == 0 && selected.isCollapsed) {
        // Keep an existing subtree even for an empty toggle title.
        transaction.insertNode(path, af.paragraphNode());
        transaction.afterSelection = af.Selection.collapsed(
          af.Position(path: path),
        );
      } else {
        final suffix = af.Delta.fromJson(delta.slice(end).toJson());
        final next = [...path]..last += 1;
        transaction
          ..deleteText(node, offset, delta.length - offset)
          ..insertNode(
            next,
            documentToggleNode(
              level: node.attributes[DocumentToggleKeys.level] as int?,
              delta: suffix,
              collapsed: true,
            ),
          )
          ..afterSelection = af.Selection.collapsed(af.Position(path: next));
      }
    } else {
      final suffix = af.Delta.fromJson(delta.slice(end).toJson());
      final child = [...path, 0];
      transaction
        ..deleteText(node, offset, delta.length - offset)
        ..insertNode(child, af.paragraphNode(delta: suffix))
        ..afterSelection = af.Selection.collapsed(af.Position(path: child));
    }
    await editor.apply(transaction);
    return true;
  },
);

class DocumentToggleBuilder extends af.BlockComponentBuilder {
  DocumentToggleBuilder(this.folds);

  final DocumentToggleController folds;

  @override
  af.BlockComponentWidget build(af.BlockComponentContext context) {
    return _DocumentToggleWidget(
      key: context.node.key,
      node: context.node,
      configuration: configuration,
      folds: folds,
    );
  }

  @override
  af.BlockComponentValidate get validate =>
      (node) => node.delta != null;
}

class _DocumentToggleWidget extends af.BlockComponentStatefulWidget {
  const _DocumentToggleWidget({
    super.key,
    required super.node,
    required super.configuration,
    required this.folds,
  });

  final DocumentToggleController folds;

  @override
  State<_DocumentToggleWidget> createState() => _DocumentToggleWidgetState();
}

class _DocumentToggleWidgetState extends State<_DocumentToggleWidget>
    with
        af.SelectableMixin,
        af.DefaultSelectableMixin,
        af.BlockComponentConfigurable,
        af.BlockComponentBackgroundColorMixin,
        af.NestedBlockComponentStatefulWidgetMixin,
        af.BlockComponentTextDirectionMixin,
        af.BlockComponentAlignMixin {
  @override
  final forwardKey = GlobalKey(debugLabel: 'toggle-rich-text');

  @override
  GlobalKey<State<StatefulWidget>> get containerKey => node.key;

  @override
  final blockComponentKey = GlobalKey(debugLabel: 'toggle-component');

  @override
  af.BlockComponentConfiguration get configuration => widget.configuration;

  @override
  af.Node get node => widget.node;

  @override
  void initState() {
    super.initState();
    widget.folds.addListener(_foldChanged);
  }

  @override
  void didUpdateWidget(covariant _DocumentToggleWidget oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!identical(oldWidget.folds, widget.folds)) {
      oldWidget.folds.removeListener(_foldChanged);
      widget.folds.addListener(_foldChanged);
    }
  }

  void _foldChanged() {
    if (mounted) setState(() {});
  }

  @override
  void dispose() {
    widget.folds.removeListener(_foldChanged);
    super.dispose();
  }

  bool _inside(af.Position position) {
    final ancestor = node.path;
    final path = position.path;
    if (path.length <= ancestor.length) return false;
    for (var i = 0; i < ancestor.length; i++) {
      if (path[i] != ancestor[i]) return false;
    }
    return true;
  }

  void _toggle() {
    final collapsed = widget.folds.isCollapsed(node);
    final selection = editorState.selection;
    if (!collapsed &&
        selection != null &&
        (_inside(selection.start) || _inside(selection.end))) {
      ScaffoldMessenger.maybeOf(context)?.showSnackBar(
        SnackBar(content: Text(context.l10n.dailynotes.toggleSelectionInside)),
      );
      return;
    }
    widget.folds.setCollapsed(node, !collapsed);
  }

  Future<void> _addChild() async {
    if (!editorState.editable || editorState.isDisposed) return;
    final path = [...node.path, 0];
    final transaction = editorState.transaction
      ..insertNode(path, af.paragraphNode())
      ..afterSelection = af.Selection.collapsed(af.Position(path: path));
    await editorState.apply(transaction);
  }

  @override
  Widget build(BuildContext context) => widget.folds.isCollapsed(node)
      ? buildComponent(context)
      : super.build(context);

  @override
  Widget buildComponent(
    BuildContext context, {
    bool withBackgroundColor = true,
  }) {
    final direction = calculateTextDirection(
      layoutDirection: Directionality.maybeOf(context),
    );
    final rawLevel = node.attributes[DocumentToggleKeys.level];
    final level = rawLevel is int ? rawLevel : null;
    final headingStyle = switch (level) {
      1 => context.theme.typography.headlineSmall.emphasized.onSurface,
      2 => context.theme.typography.titleLarge.emphasized.onSurface,
      null => null,
      _ => context.theme.typography.titleMedium.emphasized.onSurface,
    };
    TextSpan decorateHeading(TextSpan span) {
      final style = headingStyle;
      if (style == null) return span;
      final heading = style.copyWith(
        color: span.style?.color,
        fontFamily: span.style?.fontFamily,
      );
      return span.copyWith(
        style: span.style?.combine(heading) ?? heading,
        children: span.children
            ?.map((child) => child is TextSpan ? decorateHeading(child) : child)
            .toList(growable: false),
      );
    }

    final collapsed = widget.folds.isCollapsed(node);
    Widget child = Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          textDirection: direction,
          children: [
            IconButton(
              key: ValueKey('toggle-block-${node.id}'),
              tooltip: collapsed
                  ? context.l10n.dailynotes.toggleExpand
                  : context.l10n.dailynotes.toggleCollapse,
              icon: Icon(
                collapsed ? LucideIcons.chevronRight : LucideIcons.chevronDown,
              ),
              onPressed: _toggle,
              visualDensity: VisualDensity.compact,
            ),
            Expanded(
              child: af.AppFlowyRichText(
                key: forwardKey,
                delegate: this,
                node: node,
                editorState: editorState,
                placeholderText: placeholderText,
                textSpanDecorator: (span) => decorateHeading(
                  span.updateTextStyle(textStyleWithTextSpan(textSpan: span)),
                ),
                placeholderTextSpanDecorator: (span) => span
                    .updateTextStyle(headingStyle)
                    .updateTextStyle(
                      placeholderTextStyleWithTextSpan(textSpan: span),
                    ),
                textDirection: direction,
                textAlign: alignment?.toTextAlign ?? textAlign,
                cursorColor: editorState.editorStyle.cursorColor,
                selectionColor: editorState.editorStyle.selectionColor,
              ),
            ),
          ],
        ),
        if (!collapsed && node.children.isEmpty && editorState.editable)
          Padding(
            padding: const EdgeInsets.only(left: 40),
            child: TextButton(
              key: ValueKey('toggle-add-child-${node.id}'),
              onPressed: () => unawaited(_addChild()),
              child: Text(context.l10n.dailynotes.toggleAddContent),
            ),
          ),
      ],
    );
    child = af.BlockSelectionContainer(
      node: node,
      key: blockComponentKey,
      delegate: this,
      listenable: editorState.selectionNotifier,
      remoteSelection: editorState.remoteSelections,
      blockColor: editorState.editorStyle.selectionColor,
      supportTypes: const [af.BlockSelectionType.block],
      child: child,
    );
    return Container(
      padding: padding,
      decoration: withBackgroundColor ? decoration : null,
      child: child,
    );
  }
}
