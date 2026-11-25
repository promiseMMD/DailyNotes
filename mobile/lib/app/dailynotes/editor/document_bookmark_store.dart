import 'dart:convert';

import 'package:appflowy_editor/appflowy_editor.dart' as af;
import 'package:crypto/crypto.dart';
import 'package:moodiary_storage/moodiary_storage.dart';

/// The editor's runtime node IDs are not serialized. Until durable block IDs
/// exist, a bookmark is valid only for the exact same document snapshot.
class DocumentBookmark {
  const DocumentBookmark({
    required this.id,
    required this.name,
    required this.digest,
    required this.index,
    required this.alignment,
    this.invalidated = false,
  });

  final String id;
  final String name;
  final String digest;
  // Scroll item zero is the shared business header.
  final int index;
  final double alignment;

  /// Explicitly invalidated when its original in-session block cannot be tracked.
  final bool invalidated;

  DocumentBookmark rename(String value) => DocumentBookmark(
    id: id,
    name: value,
    digest: digest,
    index: index,
    alignment: alignment,
    invalidated: invalidated,
  );

  DocumentBookmark relocate({
    required String digest,
    required int index,
    double? alignment,
  }) => DocumentBookmark(
    id: id,
    name: name,
    digest: digest,
    index: index,
    alignment: alignment ?? this.alignment,
  );

  DocumentBookmark invalidate() => DocumentBookmark(
    id: id,
    name: name,
    digest: digest,
    index: index,
    alignment: alignment,
    invalidated: true,
  );

  Map<String, Object> toJson() => {
    'id': id,
    'name': name,
    'digest': digest,
    'index': index,
    'alignment': alignment,
    if (invalidated) 'invalidated': true,
  };

  static DocumentBookmark fromJson(
    Object? value, {
    bool allowInvalidated = true,
  }) {
    if (value is! Map ||
        value.keys.any(
          (key) => !{
            'id',
            'name',
            'digest',
            'index',
            'alignment',
            if (allowInvalidated) 'invalidated',
          }.contains(key),
        ) ||
        value['id'] is! String ||
        value['name'] is! String ||
        value['digest'] is! String ||
        value['index'] is! int ||
        value['alignment'] is! num ||
        (value.containsKey('invalidated') && value['invalidated'] is! bool)) {
      throw const FormatException('invalid_bookmark');
    }
    final id = value['id'] as String;
    final name = value['name'] as String;
    final digest = value['digest'] as String;
    final index = value['index'] as int;
    final alignment = (value['alignment'] as num).toDouble();
    if (id.isEmpty ||
        id.length > 128 ||
        name.trim().isEmpty ||
        !RegExp(r'^[a-f0-9]{64}$').hasMatch(digest) ||
        index < 0 ||
        !alignment.isFinite ||
        alignment < 0 ||
        alignment >= 1) {
      throw const FormatException('invalid_bookmark_values');
    }
    return DocumentBookmark(
      id: id,
      name: name,
      digest: digest,
      index: index,
      alignment: alignment,
      invalidated: value['invalidated'] == true,
    );
  }
}

String documentBookmarkDigest(af.EditorState editor) => sha256
    .convert(utf8.encode(jsonEncode(editor.document.toJson())))
    .toString();

bool documentBookmarkMatches(
  af.EditorState editor,
  DocumentBookmark bookmark,
) =>
    !editor.isDisposed &&
    !bookmark.invalidated &&
    bookmark.index <= editor.document.root.children.length &&
    bookmark.digest == documentBookmarkDigest(editor);

class DocumentBookmarkSnapshot {
  const DocumentBookmarkSnapshot(this.raw, this.items);
  final String? raw;
  final List<DocumentBookmark> items;
}

/// One record owns one metadata value. A stale list or uncertain readback is
/// never reported as a successful save and must be reloaded before editing.
class DocumentBookmarkStore {
  DocumentBookmarkStore(this.storage, String identity)
    : _key =
          'dailynotes.bookmarks.v1.${base64Url.encode(utf8.encode(identity))}';

  final IKVStorage storage;
  final String _key;

  DocumentBookmarkSnapshot load() {
    final raw = storage.get<String>(_key);
    if (raw == null) return const DocumentBookmarkSnapshot(null, []);
    final decoded = jsonDecode(raw);
    if (decoded is! Map ||
        decoded.length != 2 ||
        (decoded['v'] != 1 && decoded['v'] != 2) ||
        decoded['items'] is! List) {
      throw const FormatException('invalid_bookmark_collection');
    }
    final items = (decoded['items'] as List)
        .map(
          (item) => DocumentBookmark.fromJson(
            item,
            allowInvalidated: decoded['v'] == 2,
          ),
        )
        .toList(growable: false);
    if (items.map((item) => item.id).toSet().length != items.length) {
      throw const FormatException('duplicate_bookmark_id');
    }
    return DocumentBookmarkSnapshot(raw, List.unmodifiable(items));
  }

  DocumentBookmarkSnapshot save(
    DocumentBookmarkSnapshot expected,
    List<DocumentBookmark> items,
  ) {
    // Validate before writing so a caller cannot create metadata that a later
    // load would reject, including duplicate IDs or invalid viewport values.
    final checked = items
        .map((item) => DocumentBookmark.fromJson(item.toJson()))
        .toList(growable: false);
    if (checked.map((item) => item.id).toSet().length != checked.length) {
      throw const FormatException('duplicate_bookmark_id');
    }
    if (storage.get<String>(_key) != expected.raw) {
      throw StateError('bookmark_collection_changed');
    }
    final encoded = jsonEncode({'v': 2, 'items': checked});
    storage.set<String>(_key, encoded);
    if (storage.get<String>(_key) != encoded) {
      throw StateError('bookmark_write_unconfirmed');
    }
    return DocumentBookmarkSnapshot(encoded, List.unmodifiable(checked));
  }
}
