/// LAN invalidation journal for Moodiary V3.
///
/// This stream communicates *committed* changes only. It never transmits
/// diary bodies, images or drafts. Receivers re-read the authoritative mobile
/// repository over authenticated HTTP. Lost events require a fresh snapshot.
import 'dart:async';
import 'dart:collection';
import 'dart:math';

class ModLanChange {
  final String epoch;
  final int sequence;
  final String kind;
  final String id;
  final String source;

  const ModLanChange({
    required this.epoch,
    required this.sequence,
    required this.kind,
    required this.id,
    required this.source,
  });

  Map<String, Object> toJson() => {
    'type': 'invalidate',
    'epoch': epoch,
    'sequence': sequence,
    'kind': kind,
    'id': id,
    'source': source,
  };
}

class ModLanEventHub {
  ModLanEventHub({String? epoch, this.capacity = 256})
      : assert(capacity > 0),
        epoch = epoch ?? _randomEpoch();

  final String epoch;
  final int capacity;
  int _sequence = 0;
  final Queue<ModLanChange> _history = Queue<ModLanChange>();
  final StreamController<ModLanChange> _controller =
      StreamController<ModLanChange>.broadcast(sync: true);

  int get sequence => _sequence;
  Stream<ModLanChange> get changes => _controller.stream;

  ModLanChange publish({
    required String kind,
    required String id,
    String source = 'local',
  }) {
    if (_controller.isClosed) throw StateError('Event hub already closed');
    if (!const {'created', 'updated', 'deleted'}.contains(kind) || id.isEmpty) {
      throw ArgumentError('Invalid change notification');
    }
    final change = ModLanChange(
      epoch: epoch,
      sequence: ++_sequence,
      kind: kind,
      id: id,
      source: source,
    );
    _history.addLast(change);
    while (_history.length > capacity) {
      _history.removeFirst();
    }
    _controller.add(change);
    return change;
  }

  /// Returns null when this cursor is outside the replay window.
  /// A reset forces the client to re-query complete list snapshots.
  List<ModLanChange>? replayAfter(int after) {
    if (after < 0 || after > _sequence) return null;
    if (_history.isEmpty) return after == _sequence ? [] : null;
    if (after < _history.first.sequence - 1) return null;
    return List.unmodifiable(_history.where((e) => e.sequence > after));
  }

  Future<void> close() => _controller.close();

  static String _randomEpoch() {
    final random = Random.secure();
    return List.generate(16, (_) => random.nextInt(256).toRadixString(16).padLeft(2, '0')).join();
  }
}
