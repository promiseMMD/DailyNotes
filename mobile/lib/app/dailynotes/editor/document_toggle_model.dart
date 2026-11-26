import 'package:appflowy_editor/appflowy_editor.dart' as af;

/// Data keys follow AppFlowy 0.15.1's toggle-list block format.
abstract final class DocumentToggleKeys {
  static const type = 'toggle_list';
  static const collapsed = 'collapsed';
  static const level = 'level';
}

af.Node documentToggleNode({
  int? level,
  af.Delta? delta,
  bool collapsed = false,
  Iterable<af.Node> children = const [],
}) => af.Node(
  type: DocumentToggleKeys.type,
  children: children,
  attributes: {
    af.blockComponentDelta: (delta ?? af.Delta()).toJson(),
    DocumentToggleKeys.collapsed: collapsed,
    DocumentToggleKeys.level: ?level,
  },
);
