import 'package:flutter/foundation.dart';

import 'local_journal_spike.dart';

/// A replaceable editor-state experiment, not production autosave.
///
/// The first non-empty edit initiates a local save; subsequent changes are
/// serialized and coalesced to the latest body. Every saved state means a
/// SQLite transaction has already resolved successfully. No WebDAV actions
/// occur. Failed or conflicting writes are NOT retried automatically.
///
/// DN-020/021/047/148. Trigger cadence and durable draft policy are pending.
enum ExperimentalSavePhase { untouched, writing, savedLocally, failed }

class ExperimentalDiarySession extends ChangeNotifier {
  ExperimentalDiarySession._({
    required this._journal,
    required this.entityId,
    required int revision,
    required String persistedBody,
  })  :         _revision = revision,
        _persistedBody = persistedBody,
        _draft = persistedBody,
        _phase = revision == 0
            ? ExperimentalSavePhase.untouched
            : ExperimentalSavePhase.savedLocally;

  final LocalJournalSpike _journal;
  final String entityId;

  int _revision;
  String _persistedBody;
  String _draft;
  ExperimentalSavePhase _phase;
  Object? _lastError;
  bool _blocked = false;
  bool _writing = false;
  bool _disposed = false;
  Future<void>? _pumpFuture;

  /// Loads the latest committed revision, never an assumed successful save.
  static Future<ExperimentalDiarySession> open({
    required LocalJournalSpike journal,
    required String entityId,
  }) async {
    if (entityId.trim().isEmpty) {
      throw ArgumentError.value(entityId, 'entityId');
    }
    final existing = await journal.readDiary(entityId);
    return ExperimentalDiarySession._(
      _journal: journal,
      entityId: entityId,
      revision: existing?.revision ?? 0,
      persistedBody: existing?.body ?? '',
    );
  }

  String get text => _draft;
  String get persistedBody => _persistedBody;
  int get savedRevision => _revision;
  ExperimentalSavePhase get phase => _phase;
  Object? get lastError => _lastError;
  bool get hasUncommittedText => _draft != _persistedBody;
  bool get isWriting => _writing;

  /// A page must block departure until no write is in flight, and either
  /// nothing has ever been written or the visible draft matches the last
  /// successfully committed body. Never treat failed writes as "saved".
  bool get canLeaveSafely =>
      !_writing &&
      !_blocked &&
      !hasUncommittedText &&
      (_phase == ExperimentalSavePhase.untouched ||
          _phase == ExperimentalSavePhase.savedLocally);

  void changeText(String next) {
    _assertOpen();
    if (next == _draft) return;
    _draft = next;

    // An edit after failure must not trigger a hidden retry.
    if (_blocked) {
      _phase = ExperimentalSavePhase.failed;
      notifyListeners();
      return;
    }

    if (!_writing && _draft == _persistedBody) {
      _phase = _revision == 0
          ? ExperimentalSavePhase.untouched
          : ExperimentalSavePhase.savedLocally;
      _lastError = null;
      notifyListeners();
      return;
    }

    _phase = ExperimentalSavePhase.writing;
    notifyListeners();
    _ensurePump();
  }

  /// Retry only by explicit user action, never via timer or implicit reconnect.
  /// This may still fail for a stale revision: no content is overwritten.
  Future<void> retry() async {
    _assertOpen();
    if (_writing) {
      await waitForIdle();
      return;
    }

    _blocked = false;
    _lastError = null;
    if (_draft == _persistedBody) {
      _phase = _revision == 0
          ? ExperimentalSavePhase.untouched
          : ExperimentalSavePhase.savedLocally;
      notifyListeners();
      return;
    }

    _phase = ExperimentalSavePhase.writing;
    notifyListeners();
    _ensurePump();
    await waitForIdle();
  }

  void _ensurePump() {
    if (_writing || _blocked || _disposed || _draft == _persistedBody) {
      return;
    }
    _writing = true;
    // Schedule after assigning the Future: even immediate validation failures
    // must not leave a completed stale Future behind in _pumpFuture.
    _pumpFuture = Future<void>.microtask(_pump);
  }

  Future<void> _pump() async {
    try {
      while (!_disposed && !_blocked && _draft != _persistedBody) {
        final snapshot = _draft;
        if (snapshot.trim().isEmpty) {
          // Empty-body semantics are not decided. Do not delete or rewrite
          // a previous diary revision as an accidental empty entry.
          _fail(StateError('Empty-body draft policy is not yet approved'));
          break;
        }

        try {
          final saved = await _journal.saveDiary(
            entityId: entityId,
            body: snapshot,
            expectedRevision: _revision,
          );
          _revision = saved.revision;
          _persistedBody = saved.body;
          if (!_disposed) {
            _phase = _draft == _persistedBody
                ? ExperimentalSavePhase.savedLocally
                : ExperimentalSavePhase.writing;
            notifyListeners();
          }
        } catch (error) {
          _fail(error);
          break;
        }
      }
    } finally {
      _writing = false;
      _pumpFuture = null;
      if (!_disposed && !_blocked && _draft == _persistedBody) {
        _phase = _revision == 0
            ? ExperimentalSavePhase.untouched
            : ExperimentalSavePhase.savedLocally;
        notifyListeners();
      }
    }
  }

  void _fail(Object error) {
    _blocked = true;
    _lastError = error;
    if (!_disposed) {
      _phase = ExperimentalSavePhase.failed;
      notifyListeners();
    }
  }

  /// Test/control barrier: resolves when the currently queued work is done,
  /// whether successful or failed. This never claims a save succeeded.
  Future<void> waitForIdle() async {
    while (_pumpFuture != null) {
      await _pumpFuture;
    }
  }

  void _assertOpen() {
    if (_disposed) throw StateError('Editor session is already disposed');
  }

  @override
  void dispose() {
    // Never call dispose() as a substitute for an explicit safe-leave check.
    // The unfinished draft is currently memory-only and not crash-safe.
    _disposed = true;
    super.dispose();
  }
}
