/// Month-level edit log for Moodiary 3.0.
/// Pure, side-effect-free domain model: deliberately does NOT write an original
/// Diary or sync it to WebDAV until the safety adapter is implemented.
///
/// Immutable revisions form a per-block DAG. Merge is a set-union of complete
/// revisions, not a last-modified-wins overwrite. Parallel edits remain as
/// multiple heads until the user resolves them. Tombstones are revisions too.
import 'dart:convert';

const modMonthSummaryId = '@summary';

class ModMonthValidationException implements Exception {
  final String message;
  const ModMonthValidationException(this.message);
  @override
  String toString() => 'ModMonthValidationException: $message';
}

class ModMonthConflictException implements Exception {
  final String message;
  const ModMonthConflictException(this.message);
  @override
  String toString() => 'ModMonthConflictException: $message';
}

/// A stable identity for the one logical Diary for a topic/calendar month.
class ModMonthIdentity {
  final String topicId;
  final String month; // YYYY-MM (calendar month assigned by the topic zone).
  const ModMonthIdentity({required this.topicId, required this.month});

  String get key => '$topicId|$month';

  void validate() {
    if (topicId.trim().isEmpty || !RegExp(r'^\d{4}-(0[1-9]|1[0-2])$').hasMatch(month)) {
      throw const ModMonthValidationException('Invalid topic or YYYY-MM month');
    }
  }
}

class ModMonthRevision {
  final String blockId;
  final String revisionId;
  final String? parentRevisionId;
  final bool deleted;
  final bool summary;
  final String eventDay; // YYYY-MM-DD, explicit calendar date, no device-zone inference.
  final String eventClock; // HH:mm
  final String title;
  /// TipTap JSON is stored as an opaque value, never coerced to plain Markdown.
  final String contentJson;
  final List<String> attachments;
  /// UTC ISO8601; for audit only, NEVER used to select the winning revision.
  final String editedAtUtc;

  ModMonthRevision({
    required this.blockId, required this.revisionId,
    required this.parentRevisionId, required this.deleted,
    required this.summary, required this.eventDay, required this.eventClock,
    required this.title, required this.contentJson,
    required Iterable<String> attachments, required this.editedAtUtc,
  }) : attachments = List.unmodifiable(attachments);

  void validate(ModMonthIdentity identity) {
    if (blockId.isEmpty || revisionId.isEmpty || revisionId == parentRevisionId) {
      throw const ModMonthValidationException('Empty IDs or self-parent revision');
    }
    if (blockId == modMonthSummaryId && !summary || summary && blockId != modMonthSummaryId) {
      throw const ModMonthValidationException('Invalid summary identity');
    }
    if (summary) {
      if (eventDay.isNotEmpty || eventClock.isNotEmpty || attachments.isNotEmpty) {
        throw const ModMonthValidationException('Summary has event/attachment fields');
      }
    } else {
      final date = RegExp(r'^(\d{4})-(\d{2})-(\d{2})$').firstMatch(eventDay);
      if (date == null || eventDay.substring(0, 7) != identity.month) {
        throw const ModMonthValidationException('Block belongs to another month');
      }
      final y = int.parse(date[1]!); final m = int.parse(date[2]!); final d = int.parse(date[3]!);
      final canonical = DateTime.utc(y, m, d);
      if (canonical.year != y || canonical.month != m || canonical.day != d ||
          !RegExp(r'^([01][0-9]|2[0-3]):[0-5][0-9]$').hasMatch(eventClock)) {
        throw const ModMonthValidationException('Invalid calendar date or clock time');
      }
    }
    if (editedAtUtc.isEmpty || DateTime.tryParse(editedAtUtc)?.isUtc != true) {
      throw const ModMonthValidationException('editedAt must be UTC');
    }
    if (attachments.toSet().length != attachments.length || attachments.any((s) => s.isEmpty)) {
      throw const ModMonthValidationException('Duplicate/empty attachment references');
    }
    if (contentJson.isNotEmpty) {
      try {
        final obj = jsonDecode(contentJson);
        if (obj is! Map<String, dynamic>) {
          throw const FormatException('Not a document object');
        }
      } catch (_) {
        throw const ModMonthValidationException('Invalid TipTap JSON object');
      }
    }
  }

  Map<String, Object?> toJson() => {
    'blockId': blockId, 'revisionId': revisionId,
    'parentRevisionId': parentRevisionId, 'deleted': deleted,
    'summary': summary, 'eventDay': eventDay, 'eventClock': eventClock,
    'title': title, 'contentJson': contentJson,
    'attachments': attachments, 'editedAtUtc': editedAtUtc,
  };

  factory ModMonthRevision.fromJson(Map<String, dynamic> json) {
    final raw = json['attachments'];
    if (raw is! List || raw.any((x) => x is! String)) {
      throw const ModMonthValidationException('Invalid attachment list');
    }
    try {
      return ModMonthRevision(
        blockId: json['blockId'] as String,
        revisionId: json['revisionId'] as String,
        parentRevisionId: json['parentRevisionId'] as String?,
        deleted: json['deleted'] as bool,
        summary: json['summary'] as bool,
        eventDay: json['eventDay'] as String,
        eventClock: json['eventClock'] as String,
        title: json['title'] as String,
        contentJson: json['contentJson'] as String,
        attachments: raw.cast<String>(),
        editedAtUtc: json['editedAtUtc'] as String,
      );
    } catch (_) {
      throw const ModMonthValidationException('Malformed month revision');
    }
  }
}

class ModMonthBlockState {
  final String blockId;
  /// A single head is a resolved state; 2+ heads means unresolved conflict.
  final List<ModMonthRevision> heads;
  ModMonthBlockState(this.blockId, Iterable<ModMonthRevision> heads)
      : heads = List.unmodifiable(heads);
  bool get conflicted => heads.length != 1;
  bool get deleted => heads.length == 1 && heads.single.deleted;
  ModMonthRevision? get resolved => conflicted ? null : heads.single;
}

class ModMonthLedger {
  static const schemaVersion = 1;
  final ModMonthIdentity identity;
  final Map<String, ModMonthRevision> _revisions;

  ModMonthLedger._(this.identity, this._revisions);

  factory ModMonthLedger.empty(ModMonthIdentity identity) {
    identity.validate();
    return ModMonthLedger._(identity, {});
  }

  factory ModMonthLedger.fromRevisions(
    ModMonthIdentity identity, Iterable<ModMonthRevision> revisions,
  ) {
    identity.validate();
    final byId = <String, ModMonthRevision>{};
    for (final r in revisions) {
      r.validate(identity);
      final existing = byId[r.revisionId];
      if (existing != null && jsonEncode(existing.toJson()) != jsonEncode(r.toJson())) {
        throw ModMonthConflictException('Revision ID collision: ${r.revisionId}');
      }
      byId[r.revisionId] = r;
    }
    // No dangling parents or cross-block lineage. A complete immutable log is
    // required: partial sync must fail closed, never publish a shorter history.
    for (final r in byId.values) {
      if (r.parentRevisionId == null) continue;
      final parent = byId[r.parentRevisionId];
      if (parent == null || parent.blockId != r.blockId || parent.summary != r.summary) {
        throw ModMonthValidationException('Missing/mismatched parent: ${r.revisionId}');
      }
      final visited = <String>{r.revisionId};
      var cursor = r.parentRevisionId;
      while (cursor != null) {
        if (!visited.add(cursor)) {
          throw const ModMonthValidationException('Cyclic edit ancestry');
        }
        cursor = byId[cursor]?.parentRevisionId;
      }
    }
    final roots = <String, int>{};
    for (final r in byId.values.where((v) => v.parentRevisionId == null)) {
      roots.update(r.blockId, (x) => x + 1, ifAbsent: () => 1);
    }
    if (roots.values.any((n) => n > 1)) {
      // Simultaneous create with same blockId must be flagged, not merged.
      throw const ModMonthConflictException('Duplicate root for same Block ID');
    }
    return ModMonthLedger._(identity, Map.unmodifiable(byId));
  }

  List<ModMonthRevision> get revisions => List.unmodifiable(_revisions.values.toList()
    ..sort((a, b) => a.revisionId.compareTo(b.revisionId)));

  List<ModMonthBlockState> get blocks {
    final children = _revisions.values.map((v) => v.parentRevisionId).whereType<String>().toSet();
    final headsByBlock = <String, List<ModMonthRevision>>{};
    for (final r in _revisions.values) {
      if (children.contains(r.revisionId)) continue;
      headsByBlock.putIfAbsent(r.blockId, () => []).add(r);
    }
    final keys = headsByBlock.keys.toList()..sort();
    return List.unmodifiable(keys.map((k) => ModMonthBlockState(k,
      headsByBlock[k]!..sort((a, b) => a.revisionId.compareTo(b.revisionId)))));
  }

  List<ModMonthBlockState> get conflicts => List.unmodifiable(blocks.where((b) => b.conflicted));

  ModMonthBlockState? byId(String id) {
    for (final b in blocks) { if (b.blockId == id) return b; }
    return null;
  }

  List<ModMonthRevision> get timeline {
    final visible = [for (final b in blocks)
      if (b.blockId != modMonthSummaryId && !b.conflicted && !b.deleted) b.heads.single];
    visible.sort((a,b) {
      final byDay = a.eventDay.compareTo(b.eventDay);
      if (byDay != 0) return byDay;
      final byClock = a.eventClock.compareTo(b.eventClock);
      if (byClock != 0) return byClock;
      return a.blockId.compareTo(b.blockId);
    });
    return List.unmodifiable(visible);
  }

  /// Latest three events selected from event time, returned chronologically.
  List<ModMonthRevision> get preview {
    final ordered = timeline.reversed.take(3).toList().reversed.toList();
    return List.unmodifiable(ordered);
  }

  ModMonthLedger add(ModMonthRevision revision) {
    if (_revisions.containsKey(revision.revisionId)) {
      final existing = _revisions[revision.revisionId]!;
      if (jsonEncode(existing.toJson()) == jsonEncode(revision.toJson())) return this;
      throw const ModMonthConflictException('Same revision ID with different payload');
    }
    if (revision.parentRevisionId == null && byId(revision.blockId) != null) {
      throw const ModMonthConflictException('Block already exists');
    }
    if (revision.parentRevisionId != null) {
      final state = byId(revision.blockId);
      if (state == null || state.conflicted ||
          state.resolved?.revisionId != revision.parentRevisionId) {
        throw const ModMonthConflictException('Stale block revision; preserve draft');
      }
    }
    return ModMonthLedger.fromRevisions(identity, [..._revisions.values, revision]);
  }

  /// OR-set merge of immutable revision graphs. No last-write-wins behavior.
  ModMonthLedger merge(ModMonthLedger remote) {
    if (identity.key != remote.identity.key) {
      throw const ModMonthConflictException('Different topic/month cannot merge');
    }
    return ModMonthLedger.fromRevisions(identity,
      [..._revisions.values, ...remote._revisions.values]);
  }

  String encode() => jsonEncode({
    'schema': schemaVersion,
    'topicId': identity.topicId,
    'month': identity.month,
    'revisions': [for (final r in revisions) r.toJson()],
  });

  factory ModMonthLedger.decode(String raw) {
    try {
      final j = jsonDecode(raw);
      if (j is! Map<String, dynamic> || j['schema'] != schemaVersion ||
          j['topicId'] is! String || j['month'] is! String || j['revisions'] is! List) {
        throw const ModMonthValidationException('Unsupported ledger schema');
      }
      final id = ModMonthIdentity(topicId: j['topicId'] as String, month: j['month'] as String);
      final records = <ModMonthRevision>[];
      for (final item in (j['revisions'] as List)) {
        if (item is! Map<String, dynamic>) throw const ModMonthValidationException('Invalid revision');
        records.add(ModMonthRevision.fromJson(item));
      }
      return ModMonthLedger.fromRevisions(id, records);
    } on ModMonthValidationException { rethrow; }
      on ModMonthConflictException { rethrow; }
      catch (_) { throw const ModMonthValidationException('Invalid month ledger document'); }
  }
}
