import 'dart:convert';

import 'package:appflowy_editor/appflowy_editor.dart' as af;

import '../data/rich_document_guard.dart';

/// Stores the complete AppFlowy document as the authority inside a versioned
/// Tiptap-compatible container. The Tiptap paragraphs are a search/list
/// projection only and must never be used to replace the native document.
class DailyNotesDocumentEnvelope {
  static const nativeKey = 'dailyNotesAppFlowy';
  // This is a local storage guard, independent from the smaller LAN request
  // limit. The envelope includes both the native document and search text.
  static const maxBytes = 2 * 1024 * 1024;
  static const maxNodes = 4000;
  static const maxDepth = 64;

  static List<Map<String, Object?>> _projection(af.Document document) {
    final result = <Map<String, Object?>>[];
    void visit(af.Node node) {
      final delta = node.delta;
      if (delta != null) {
        final text = delta.toPlainText();
        result.add({
          'type': 'paragraph',
          if (text.isNotEmpty)
            'content': [
              {'type': 'text', 'text': text},
            ],
        });
      }
      for (final child in node.children) {
        visit(child);
      }
    }

    visit(document.root);
    if (result.isEmpty) result.add({'type': 'paragraph'});
    return result;
  }

  static String plainText(af.Document document) =>
      _projection(document)
          .map((block) {
            final content = block['content'];
            return content is List && content.isNotEmpty
                ? (content.first as Map)['text'] as String
                : '';
          })
          .join('\n');

  static void _limit(Object? value, [int depth = 0, List<int>? counter]) {
    final count = counter ?? [0];
    if (depth > maxDepth || ++count[0] > maxNodes * 12) {
      throw const FormatException('document_too_complex');
    }
    if (value is Map) {
      for (final entry in value.entries) {
        if (entry.key is! String) throw const FormatException('invalid_key');
        _limit(entry.value, depth + 1, count);
      }
    } else if (value is List) {
      for (final item in value) {
        _limit(item, depth + 1, count);
      }
    } else if (value != null &&
        value is! String &&
        value is! num &&
        value is! bool) {
      throw const FormatException('invalid_value');
    }
  }

  static String encode(af.Document document) {
    final native = document.toJson();
    _limit(native);
    validateRichDocument(jsonEncode(native));
    final encoded = jsonEncode({
      'type': 'doc',
      'attrs': {
        'v': 2,
        nativeKey: {'version': 1, 'document': native},
      },
      'content': _projection(document),
    });
    if (utf8.encode(encoded).length > maxBytes) {
      throw const FormatException('document_too_large');
    }
    return encoded;
  }

  static bool hasNativeDocument(String raw) {
    try {
      final root = jsonDecode(raw);
      return root is Map &&
          root['attrs'] is Map &&
          (root['attrs'] as Map).containsKey(nativeKey);
    } catch (_) {
      return false;
    }
  }

  /// Rejects mismatched previews and unknown envelope fields instead of
  /// silently overwriting content edited by a different editor.
  static af.Document decode(String raw) {
    if (utf8.encode(raw).length > maxBytes) {
      throw const FormatException('document_too_large');
    }
    final root = jsonDecode(raw);
    _limit(root);
    if (root is! Map<String, dynamic> || root['type'] != 'doc') {
      throw const FormatException('invalid_document');
    }
    final attrs = root['attrs'];
    if (attrs is Map && attrs.containsKey(nativeKey)) {
      if (root.keys.any(
            (k) => !const {'type', 'attrs', 'content'}.contains(k),
          ) ||
          attrs.keys.any((k) => k != 'v' && k != nativeKey) ||
          attrs['v'] != 2) {
        throw const FormatException('invalid_native_envelope');
      }
      final payload = attrs[nativeKey];
      if (payload is! Map ||
          payload.length != 2 ||
          payload['version'] != 1 ||
          payload['document'] is! Map) {
        throw const FormatException('invalid_native_payload');
      }
      final native = validateRichDocument(jsonEncode(payload['document']));
      final document = af.Document.fromJson(native);
      if (jsonEncode(root['content']) != jsonEncode(_projection(document))) {
        throw const FormatException('document_projection_mismatch');
      }
      return document;
    }
    return _decodeLegacy(root);
  }

  /// A deliberately narrow, lossless legacy adapter. Unknown nodes/marks do
  /// not enter the AppFlowy editor, and the original bytes remain untouched.
  static af.Document _decodeLegacy(Map<String, dynamic> root) {
    if (root.keys.any((k) => !const {'type', 'attrs', 'content'}.contains(k))) {
      throw const FormatException('unsupported_legacy_document');
    }
    final attrs = root['attrs'];
    if (attrs is! Map || attrs.length != 1 || attrs['v'] != 2) {
      throw const FormatException('unsupported_legacy_document');
    }
    final content = root['content'];
    if (content is! List || content.isEmpty || content.length > maxNodes) {
      throw const FormatException('unsupported_legacy_document');
    }
    final blocks = <af.Node>[];
    for (final block in content) {
      if (block is! Map ||
          block.keys.any(
            (k) => !const {'type', 'attrs', 'content'}.contains(k),
          )) {
        throw const FormatException('unsupported_legacy_block');
      }
      final type = block['type'];
      if (type != 'paragraph' && type != 'heading') {
        throw const FormatException('unsupported_legacy_block');
      }
      final blockAttrs = block['attrs'];
      var level = 1;
      if (type == 'heading') {
        if (blockAttrs is! Map ||
            blockAttrs.length != 1 ||
            blockAttrs['level'] is! int ||
            blockAttrs['level'] < 1 ||
            blockAttrs['level'] > 6) {
          throw const FormatException('unsupported_legacy_heading');
        }
        level = blockAttrs['level'] as int;
      } else if (blockAttrs != null) {
        throw const FormatException('unsupported_legacy_paragraph');
      }
      final delta = af.Delta();
      final parts = block['content'];
      if (parts != null && parts is! List) {
        throw const FormatException('unsupported_legacy_inline');
      }
      for (final part in (parts as List? ?? const [])) {
        if (part is! Map ||
            part['type'] != 'text' ||
            part['text'] is! String ||
            (part['text'] as String).isEmpty ||
            part.keys.any(
              (k) => !const {'type', 'text', 'marks'}.contains(k),
            )) {
          throw const FormatException('unsupported_legacy_inline');
        }
        final style = <String, dynamic>{};
        final marks = part['marks'];
        if (marks != null && marks is! List) {
          throw const FormatException('unsupported_legacy_marks');
        }
        for (final mark in (marks as List? ?? const [])) {
          if (mark is! Map || mark.length != 1 || mark['type'] is! String) {
            throw const FormatException('unsupported_legacy_mark');
          }
          final key = switch (mark['type']) {
            'bold' => af.AppFlowyRichTextKeys.bold,
            'italic' => af.AppFlowyRichTextKeys.italic,
            'underline' => af.AppFlowyRichTextKeys.underline,
            'strike' => af.AppFlowyRichTextKeys.strikethrough,
            _ => throw const FormatException('unsupported_legacy_mark'),
          };
          if (style.containsKey(key))
            throw const FormatException('duplicate_mark');
          style[key] = true;
        }
        delta.insert(
          part['text'] as String,
          attributes: style.isEmpty ? null : style,
        );
      }
      blocks.add(
        type == 'heading'
            ? af.headingNode(level: level, delta: delta)
            : af.paragraphNode(delta: delta),
      );
    }
    return af.Document(root: af.pageNode(children: blocks));
  }
}
