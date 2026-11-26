import 'dart:convert';

import 'package:appflowy_editor/appflowy_editor.dart';

import '../editor/document_toggle_model.dart';

/// Reject structures the current editor would ignore or cannot render.
/// The caller keeps the original serialized bytes for recovery.
Map<String, dynamic> validateRichDocument(String raw) {
  final decoded = jsonDecode(raw);
  if (decoded is! Map<String, dynamic> ||
      decoded.length != 1 ||
      decoded['document'] is! Map<String, dynamic>) {
    throw const FormatException('unsupported_document');
  }
  void validateNode(Object? value) {
    if (value is! Map<String, dynamic> ||
        value.keys.any(
          (key) => !const {'type', 'data', 'children'}.contains(key),
        )) {
      throw const FormatException('unsupported_node_fields');
    }
    final type = value['type'];
    if (type is! String ||
        (!standardBlockComponentBuilderMap.containsKey(type) &&
            type != DocumentToggleKeys.type)) {
      throw const FormatException('unsupported_node_type');
    }
    if (value.containsKey('data') && value['data'] is! Map) {
      throw const FormatException('unsupported_node_data');
    }
    // Delta.fromJson silently ignores unknown operations and unknown fields
    // in otherwise valid operations. Editing that node serializes the parsed
    // delta again, permanently dropping them. Keep unsupported data outside
    // the editable path instead of letting an unrelated edit overwrite it.
    final data = value['data'];
    if (type == DocumentToggleKeys.type &&
        (data is! Map ||
            data['delta'] is! List ||
            (data.containsKey(DocumentToggleKeys.collapsed) &&
                data[DocumentToggleKeys.collapsed] is! bool) ||
            (data.containsKey(DocumentToggleKeys.level) &&
                (data[DocumentToggleKeys.level] is! int ||
                    data[DocumentToggleKeys.level] < 1 ||
                    data[DocumentToggleKeys.level] > 6)))) {
      throw const FormatException('unsupported_toggle');
    }
    if (data is Map && data.containsKey('delta')) {
      final delta = data['delta'];
      if (delta is! List) {
        throw const FormatException('unsupported_delta');
      }
      for (final operation in delta) {
        if (operation is! Map ||
            operation['insert'] is! String ||
            operation.keys.any(
              (key) => key != 'insert' && key != 'attributes',
            ) ||
            (operation['attributes'] != null &&
                operation['attributes'] is! Map)) {
          throw const FormatException('unsupported_delta_operation');
        }
      }
    }
    if (value.containsKey('children')) {
      final children = value['children'];
      if (children is! List) {
        throw const FormatException('unsupported_children');
      }
      for (final child in children) {
        validateNode(child);
      }
    }
  }

  validateNode(decoded['document']);
  return decoded;
}
