import 'dart:async';

import 'package:appflowy_editor/appflowy_editor.dart' as af;

import 'document_bookmark_store.dart';

/// Allows an owning page to report a confirmed save before it is popped.
class DocumentBookmarkRebaseController {
  DocumentBookmarkRebaser? _target;

  void attach(DocumentBookmarkRebaser target) => _target = target;

  void detach(DocumentBookmarkRebaser target) {
    if (identical(_target, target)) _target = null;
  }

  void documentSaved() => _target?.documentSaved();
}

class _TrackedBookmark {
  const _TrackedBookmark(this.digest, this.index, this.node);

  final String digest;
  final int index;
  // Null identifies the document header, not an AppFlowy block.
  final af.Node? node;
}

/// Carries bookmarks through edits only while their original live nodes can be
/// identified and the owning page has confirmed the resulting document save.
/// No runtime node ID is persisted or used to rebind a previously stale item.
class DocumentBookmarkRebaser {
  DocumentBookmarkRebaser({
    required this.editor,
    required this.store,
    required this.canStore,
  });

  final af.EditorState editor;
  final DocumentBookmarkStore store;
  final bool Function() canStore;
  StreamSubscription<dynamic>? _changes;
  Map<String, _TrackedBookmark> _tracked = {};
  bool _pending = false;
  bool _disposed = false;

  void start() {
    if (_disposed) return;
    _changes = editor.transactionStream.listen((event) {
      if (_disposed || editor.isDisposed) return;
      if (event.$1 == af.TransactionTime.before) {
        if (!_pending) _capture();
      } else if (event.$1 == af.TransactionTime.after) {
        // Even when there are no usable bookmarks, wait for the save before
        // looking again. This avoids hashing a long document on every keystroke.
        _pending = true;
      }
    });
  }

  void _capture() {
    _tracked = {};
    if (!canStore()) return;
    try {
      final items = store.load().items;
      if (items.isEmpty) return;
      final digest = documentBookmarkDigest(editor);
      final children = editor.document.root.children;
      for (final item in items) {
        if (item.invalidated ||
            item.digest != digest ||
            item.index > children.length) {
          continue;
        }
        _tracked[item.id] = _TrackedBookmark(
          item.digest,
          item.index,
          item.index == 0 ? null : children[item.index - 1],
        );
      }
    } catch (_) {
      // Invalid or unavailable bookmark metadata must never interrupt typing.
      _tracked = {};
    }
  }

  int? _currentIndex(_TrackedBookmark tracked) {
    final node = tracked.node;
    if (node == null) return 0;
    try {
      final path = node.path;
      if (path.length != 1 ||
          !identical(editor.document.nodeAtPath(path), node)) {
        return null;
      }
      return path.first + 1;
    } catch (_) {
      return null;
    }
  }

  /// The current editor snapshot must already be durably acknowledged by the
  /// owning page; failures leave the previous bookmark data intact or stale.
  void documentSaved() {
    if (!_pending || _disposed || editor.isDisposed || !canStore()) return;
    if (_tracked.isEmpty) {
      _pending = false;
      return;
    }
    try {
      final snapshot = store.load();
      final digest = documentBookmarkDigest(editor);
      var changed = false;
      final next = <DocumentBookmark>[];
      for (final item in snapshot.items) {
        final tracked = _tracked[item.id];
        if (tracked == null ||
            item.digest != tracked.digest ||
            item.index != tracked.index) {
          next.add(item);
          continue;
        }
        final index = _currentIndex(tracked);
        if (index == null) {
          changed = true;
          next.add(item.invalidate());
          continue;
        }
        if (digest != item.digest || index != item.index) {
          changed = true;
          next.add(item.relocate(digest: digest, index: index));
        } else {
          next.add(item);
        }
      }
      if (changed) store.save(snapshot, next);
      _pending = false;
      _tracked = {};
    } catch (_) {
      // A storage failure or concurrent metadata edit is not a document-save
      // failure. Retain the original anchors and retry on a later safe update.
    }
  }

  void dispose() {
    if (_disposed) return;
    documentSaved();
    _disposed = true;
    unawaited(_changes?.cancel());
    _tracked = {};
  }
}
