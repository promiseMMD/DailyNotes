import 'dart:async';
import 'dart:convert';

import 'package:appflowy_editor/appflowy_editor.dart' as af;
import 'package:crypto/crypto.dart';
import 'package:moodiary_storage/moodiary_storage.dart';
import 'package:mui/mui.dart';

class _ViewportAnchor {
  const _ViewportAnchor(this.node, this.alignment);

  // Null means the business header, which is the first scroll item.
  final af.Node? node;
  final double alignment;
}

/// Stores a reading position independently of the document and its selection.
/// A serialized position is usable only with exactly the same document bytes;
/// AppFlowy's runtime node IDs do not survive serialization.
class DocumentReadingPosition with WidgetsBindingObserver {
  DocumentReadingPosition({
    required this.editor,
    required this.scroll,
    required this.storage,
    required String identity,
    required this.canRestore,
    required this.canStore,
    required this.restoreOnOpen,
  }) : _key =
           'dailynotes.reading.v1.${base64Url.encode(utf8.encode(identity))}';

  final af.EditorState editor;
  final af.EditorScrollController scroll;
  final IKVStorage storage;
  final bool Function() canRestore;
  final bool Function() canStore;
  final bool restoreOnOpen;
  final String _key;

  StreamSubscription<dynamic>? _transactions;
  Timer? _timer;
  _ViewportAnchor? _anchor;
  String? _digest;
  bool _active = false;
  bool _dirty = false;
  bool _disposed = false;

  String _documentDigest() => _digest ??= sha256
      .convert(utf8.encode(jsonEncode(editor.document.toJson())))
      .toString();

  void start() {
    if (scroll.shrinkWrap || _disposed) return;
    WidgetsBinding.instance.addObserver(this);
    scroll.itemPositionsListener.itemPositions.addListener(_positionChanged);
    _transactions = editor.transactionStream.listen((event) {
      if (event.$1 != af.TransactionTime.after || _disposed) return;
      _digest = null;
      if (_anchor != null) _scheduleWrite();
    });
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_disposed || editor.isDisposed) return;
      if (restoreOnOpen && canRestore()) _restore();
      // Ignore the initial layout and our own restore. Subsequent scrolls
      // capture the actual viewport rather than overwriting it with the top.
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!_disposed && !editor.isDisposed) _active = true;
      });
      WidgetsBinding.instance.scheduleFrame();
    });
  }

  void _restore() {
    try {
      final raw = storage.get<String>(_key);
      if (raw == null || !scroll.itemScrollController.isAttached) return;
      final value = jsonDecode(raw);
      if (value is! Map ||
          value['v'] != 1 ||
          value['digest'] is! String ||
          value['index'] is! int ||
          value['alignment'] is! num) {
        return;
      }
      final index = value['index'] as int;
      final alignment = (value['alignment'] as num).toDouble();
      if (index < 0 ||
          index > editor.document.root.children.length ||
          !alignment.isFinite ||
          alignment < 0 ||
          alignment >= 1 ||
          value['digest'] != _documentDigest() ||
          !canRestore()) {
        return;
      }
      scroll.itemScrollController.jumpTo(index: index, alignment: alignment);
    } catch (_) {
      // Corrupt metadata, inaccessible storage or a changed document must not
      // prevent opening the original document.
    }
  }

  void _positionChanged() {
    if (!_active || _disposed || editor.isDisposed) return;
    final positions =
        scroll.itemPositionsListener.itemPositions.value
            .where(
              (item) =>
                  item.itemLeadingEdge >= 0 &&
                  item.itemLeadingEdge < 1 &&
                  item.itemTrailingEdge > 0 &&
                  item.index >= 0 &&
                  item.index <= editor.document.root.children.length,
            )
            .toList()
          ..sort((a, b) => a.itemLeadingEdge.compareTo(b.itemLeadingEdge));
    if (positions.isEmpty) return;
    final first = positions.first;
    _anchor = _ViewportAnchor(
      first.index == 0 ? null : editor.document.root.children[first.index - 1],
      first.itemLeadingEdge,
    );
    _scheduleWrite();
  }

  void _scheduleWrite() {
    _dirty = true;
    _timer?.cancel();
    _timer = Timer(const Duration(milliseconds: 700), _flush);
  }

  void _flush() {
    if (!_dirty || _disposed || editor.isDisposed || !canStore()) return;
    final anchor = _anchor;
    if (anchor == null) return;
    try {
      final node = anchor.node;
      var index = 0;
      if (node != null) {
        final path = node.path;
        if (path.length != 1 ||
            !identical(editor.document.nodeAtPath(path), node)) {
          return;
        }
        index = path.first + 1;
      }
      storage.set<String>(
        _key,
        jsonEncode({
          'v': 1,
          'digest': _documentDigest(),
          'index': index,
          'alignment': anchor.alignment,
        }),
      );
      _dirty = false;
    } catch (_) {
      // Keep the last stored position on a write failure and allow a retry.
    }
  }

  /// Retry after the owning page confirms that the current document was saved.
  void retryPendingWrite() => _flush();

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state != AppLifecycleState.resumed) _flush();
  }

  void dispose() {
    if (_disposed) return;
    _timer?.cancel();
    _flush();
    _disposed = true;
    if (!scroll.shrinkWrap) {
      scroll.itemPositionsListener.itemPositions.removeListener(
        _positionChanged,
      );
      WidgetsBinding.instance.removeObserver(this);
    }
    unawaited(_transactions?.cancel());
  }
}
