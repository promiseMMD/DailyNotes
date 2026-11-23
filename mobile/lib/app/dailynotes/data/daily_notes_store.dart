import 'dart:async';
import 'dart:convert';
import 'dart:math';

import 'package:flutter/foundation.dart';
import 'package:moodiary_data/moodiary_data.dart';

import 'rich_document_guard.dart';

DateTime _date(Map<String, dynamic> value, String key) =>
    DateTime.parse(value[key] as String);
DateTime? _optionalDate(Map<String, dynamic> value, String key) =>
    value[key] == null ? null : _date(value, key);

@immutable
class DailyNote {
  final String id, title, body;
  final String? folderId;
  final String? documentJson;
  final int? documentVersion;

  /// Database revision of this exact snapshot; never included in the payload.
  final int? storageRevision;
  final List<String> tags;
  final DateTime createdAt, updatedAt;
  final DateTime? deletedAt;

  DailyNote({
    required this.id,
    required this.title,
    required this.body,
    this.folderId,
    this.documentJson,
    this.documentVersion,
    this.storageRevision,
    List<String> tags = const [],
    required this.createdAt,
    required this.updatedAt,
    this.deletedAt,
  }) : tags = List.unmodifiable(tags);

  factory DailyNote.fromJson(
    Map<String, dynamic> value, {
    int? storageRevision,
  }) => DailyNote(
    id: value['id'] as String,
    title: value['title'] as String,
    body: value['body'] as String,
    folderId: value['folderId'] as String?,
    documentJson: value['documentJson'] as String?,
    documentVersion: value['documentVersion'] as int?,
    storageRevision: storageRevision,
    tags: (value['tags'] as List<dynamic>).cast<String>(),
    createdAt: _date(value, 'createdAt'),
    updatedAt: _date(value, 'updatedAt'),
    deletedAt: _optionalDate(value, 'deletedAt'),
  );

  Map<String, dynamic> toJson() => {
    'id': id,
    'title': title,
    'body': body,
    'folderId': folderId,
    if (documentJson != null) 'documentJson': documentJson,
    if (documentVersion != null) 'documentVersion': documentVersion,
    'tags': tags,
    'createdAt': createdAt.toIso8601String(),
    'updatedAt': updatedAt.toIso8601String(),
    'deletedAt': deletedAt?.toIso8601String(),
  };
}

/// The note changed after this editor obtained its snapshot.
class DailyNoteRevisionConflict implements Exception {
  const DailyNoteRevisionConflict();
}

/// A confirmed destination was changed before the note could be committed.
class DailyFolderPathConflict implements Exception {
  const DailyFolderPathConflict();
}

@immutable
class DailyFolderPathSnapshot {
  final String? folderId;
  final String path;
  final String _fingerprint;

  const DailyFolderPathSnapshot._(this.folderId, this.path, this._fingerprint);

  bool matches(DailyFolderPathSnapshot? other) =>
      other != null &&
      folderId == other.folderId &&
      _fingerprint == other._fingerprint;
}

@immutable
class DailyFolder {
  final String id, name;
  final String? parentId;
  final DateTime createdAt, updatedAt;
  const DailyFolder({
    required this.id,
    required this.name,
    this.parentId,
    required this.createdAt,
    required this.updatedAt,
  });
  String get title => name;
  factory DailyFolder.fromJson(Map<String, dynamic> value) => DailyFolder(
    id: value['id'] as String,
    name: value['name'] as String,
    parentId: value['parentId'] as String?,
    createdAt: _date(value, 'createdAt'),
    updatedAt: _date(value, 'updatedAt'),
  );
  Map<String, dynamic> toJson() => {
    'id': id,
    'name': name,
    'parentId': parentId,
    'createdAt': createdAt.toIso8601String(),
    'updatedAt': updatedAt.toIso8601String(),
  };
}

/// A read-only preview of exactly which direct children a removal will affect.
/// The private fingerprint prevents confirming one impact and applying another.
class DailyFolderRemovalPlan {
  final String folderId, folderName;
  final String? parentId;
  final int noteCount, trashedNoteCount, childFolderCount;
  final String _fingerprint;

  const DailyFolderRemovalPlan._({
    required this.folderId,
    required this.folderName,
    required this.parentId,
    required this.noteCount,
    required this.trashedNoteCount,
    required this.childFolderCount,
    required this._fingerprint,
  });
}

@immutable
class KnowledgeTopic {
  final String id, title;
  final String? parentId;
  final DateTime createdAt, updatedAt;
  final DateTime? deletedAt;
  final String? deletionGroup;
  // Only untouched promoted children may return to a restored parent.
  final String? promotedBy;
  const KnowledgeTopic({
    required this.id,
    required this.title,
    this.parentId,
    required this.createdAt,
    required this.updatedAt,
    this.deletedAt,
    this.deletionGroup,
    this.promotedBy,
  });
  String get name => title;
  factory KnowledgeTopic.fromJson(Map<String, dynamic> value) => KnowledgeTopic(
    id: value['id'] as String,
    title: value['title'] as String,
    parentId: value['parentId'] as String?,
    createdAt: _date(value, 'createdAt'),
    updatedAt: _date(value, 'updatedAt'),
    deletedAt: _optionalDate(value, 'deletedAt'),
    deletionGroup: value['deletionGroup'] as String?,
    promotedBy: value['promotedBy'] as String?,
  );
  Map<String, dynamic> toJson() => {
    'id': id,
    'title': title,
    'parentId': parentId,
    'createdAt': createdAt.toIso8601String(),
    'updatedAt': updatedAt.toIso8601String(),
    'deletedAt': deletedAt?.toIso8601String(),
    'deletionGroup': deletionGroup,
    'promotedBy': promotedBy,
  };
}

@immutable
class DailyTask {
  final String id, title, body, listName;
  final bool completed;
  final DateTime createdAt, updatedAt;
  final DateTime? dueAt, deletedAt;
  const DailyTask({
    required this.id,
    required this.title,
    this.body = '',
    this.listName = '默认清单',
    this.completed = false,
    required this.createdAt,
    required this.updatedAt,
    this.dueAt,
    this.deletedAt,
  });
  String get details => body;
  factory DailyTask.fromJson(Map<String, dynamic> value) => DailyTask(
    id: value['id'] as String,
    title: value['title'] as String,
    body: value['body'] as String,
    listName: value['listName'] as String,
    completed: value['completed'] as bool,
    createdAt: _date(value, 'createdAt'),
    updatedAt: _date(value, 'updatedAt'),
    dueAt: _optionalDate(value, 'dueAt'),
    deletedAt: _optionalDate(value, 'deletedAt'),
  );
  Map<String, dynamic> toJson() => {
    'id': id,
    'title': title,
    'body': body,
    'listName': listName,
    'completed': completed,
    'createdAt': createdAt.toIso8601String(),
    'updatedAt': updatedAt.toIso8601String(),
    'dueAt': dueAt?.toIso8601String(),
    'deletedAt': deletedAt?.toIso8601String(),
  };
}

class _Stored {
  final String kind;
  final int revision;
  final Map<String, dynamic> value;
  const _Stored(this.kind, this.revision, this.value);
}

class _Link {
  final String id, noteId, topicId;
  final int revision;
  final DateTime? deletedAt;
  const _Link(
    this.id,
    this.noteId,
    this.topicId,
    this.deletedAt,
    this.revision,
  );
  Map<String, dynamic> toJson() => {
    'id': id,
    'noteId': noteId,
    'topicId': topicId,
    'deletedAt': deletedAt?.toIso8601String(),
    'revision': revision,
  };
}

class _State {
  final Map<String, _Stored> records;
  final Map<String, _Link> links;
  final Set<String> archivedNoteIds;
  final Set<String> writes = {}, linkWrites = {};
  int pending;
  _State(this.records, this.links, this.pending, {Set<String>? archivedNoteIds})
    : archivedNoteIds = archivedNoteIds ?? {};
  void put(String kind, Map<String, dynamic> value) {
    final id = value['id'] as String;
    records[id] = _Stored(kind, (records[id]?.revision ?? 0) + 1, value);
    writes.add(id);
  }

  Map<String, dynamic> require(String id, String kind, {bool deleted = false}) {
    final row = records[id];
    if (row == null ||
        row.kind != kind ||
        (!deleted && row.value['deletedAt'] != null)) {
      throw StateError('entity_not_available:$kind:$id');
    }
    return row.value;
  }
}

/// Local-first preview data. Every mutation and its durable sync event commit in
/// one SQLite transaction. Events are queued only; no WebDAV success is implied.
///
/// The dn_* namespace is versioned independently of Moodiary's generated schema,
/// following the existing mod_month schema extension pattern. Existing diary
/// tables and schema migration history are never modified by this store.
class DailyNotesStore extends ChangeNotifier {
  final MoodiaryDatabase database;
  final DateTime Function() _clock;
  final Future<void> Function()? beforeOutboxWrite;
  final Random _random = Random.secure();
  Future<void> _tail = Future.value();
  _State _state = _State({}, {}, 0);
  bool _opened = false;
  final Map<String, Map<String, Object?>> _drafts = {};

  DailyNotesStore(
    this.database, {
    DateTime Function()? clock,
    @visibleForTesting this.beforeOutboxWrite,
  }) : _clock = clock ?? DateTime.now;

  int get pendingOperationCount => _state.pending;
  bool get isOpen => _opened;
  // Keep all existing consumers' query semantics until their UI is migrated.
  List<DailyNote> get notes => _notes(deleted: false);
  List<DailyNote> get unarchivedNotes =>
      _notes(deleted: false, archived: false);
  List<DailyNote> get archivedNotes => _notes(deleted: false, archived: true);
  // Trashed notes remain available to the recycle bin regardless of whether
  // they had previously been archived.
  List<DailyNote> get deletedNotes => _notes(deleted: true);
  List<DailyTask> get tasks => _tasks(deleted: false);
  List<DailyTask> get deletedTasks => _tasks(deleted: true);
  List<KnowledgeTopic> get topics => _topics(deleted: false);
  List<KnowledgeTopic> get deletedTopics => _topics(deleted: true);
  List<DailyFolder> get folders => List.unmodifiable(
    _state.records.values
        .where((r) => r.kind == 'folder' && r.value['deletedAt'] == null)
        .map((r) => DailyFolder.fromJson(r.value)),
  );

  List<DailyNote> _notes({required bool deleted, bool? archived}) {
    final result = _state.records.values
        .where(
          (r) =>
              r.kind == 'note' &&
              (r.value['deletedAt'] != null) == deleted &&
              (archived == null ||
                  _state.archivedNoteIds.contains(r.value['id']) == archived),
        )
        .map((r) => DailyNote.fromJson(r.value, storageRevision: r.revision))
        .toList();
    result.sort((a, b) => b.updatedAt.compareTo(a.updatedAt));
    return List.unmodifiable(result);
  }

  List<DailyTask> _tasks({required bool deleted}) => List.unmodifiable(
    _state.records.values
        .where(
          (r) => r.kind == 'task' && (r.value['deletedAt'] != null) == deleted,
        )
        .map((r) => DailyTask.fromJson(r.value)),
  );
  List<KnowledgeTopic> _topics({required bool deleted}) => List.unmodifiable(
    _state.records.values
        .where(
          (r) => r.kind == 'topic' && (r.value['deletedAt'] != null) == deleted,
        )
        .map((r) => KnowledgeTopic.fromJson(r.value)),
  );

  List<DailyNote> notesForTopic(String topicId) {
    if (!topics.any((t) => t.id == topicId)) return const [];
    final ids = _state.links.values
        .where((l) => l.topicId == topicId && l.deletedAt == null)
        .map((l) => l.noteId)
        .toSet();
    return List.unmodifiable(notes.where((n) => ids.contains(n.id)));
  }

  List<KnowledgeTopic> topicsForNote(String noteId) {
    if (!notes.any((n) => n.id == noteId)) return const [];
    final ids = _state.links.values
        .where((l) => l.noteId == noteId && l.deletedAt == null)
        .map((l) => l.topicId)
        .toSet();
    return List.unmodifiable(topics.where((t) => ids.contains(t.id)));
  }

  /// Archive state is an organizational property, not a replacement note,
  /// deleted record, user-content revision, or trigger for WebDAV.
  bool isNoteArchived(String noteId) => _state.archivedNoteIds.contains(noteId);

  /// Explicit filtered counterpart to the existing notesForTopic getter.
  List<DailyNote> unarchivedNotesForTopic(String topicId) {
    final archived = _state.archivedNoteIds;
    return List.unmodifiable(
      notesForTopic(topicId).where((note) => !archived.contains(note.id)),
    );
  }

  List<DailyNote> archivedNotesForTopic(String topicId) {
    if (!topics.any((t) => t.id == topicId)) return const [];
    final ids = _state.links.values
        .where((link) => link.topicId == topicId && link.deletedAt == null)
        .map((link) => link.noteId)
        .toSet();
    return List.unmodifiable(
      archivedNotes.where((note) => ids.contains(note.id)),
    );
  }

  /// Retain the original ancestors of folders containing archived notes. This
  /// is only a filtered read model; it never modifies folders or relationships.
  List<DailyFolder> get foldersWithArchivedNotes {
    final all = folders;
    final byId = {for (final folder in all) folder.id: folder};
    final visible = <String>{};
    for (final note in archivedNotes) {
      var id = note.folderId;
      while (id != null && visible.add(id)) {
        id = byId[id]?.parentId;
      }
    }
    return List.unmodifiable(
      all.where((folder) => visible.contains(folder.id)),
    );
  }

  /// Retain all ancestors of topics directly linked to an archived note.
  List<KnowledgeTopic> get topicsWithArchivedNotes {
    final all = topics;
    final byId = {for (final topic in all) topic.id: topic};
    final archivedIds = archivedNotes.map((note) => note.id).toSet();
    final visible = <String>{};
    for (final link in _state.links.values) {
      if (link.deletedAt != null || !archivedIds.contains(link.noteId)) {
        continue;
      }
      String? id = link.topicId;
      while (id != null && visible.add(id)) {
        id = byId[id]?.parentId;
      }
    }
    return List.unmodifiable(all.where((topic) => visible.contains(topic.id)));
  }

  /// Persist a desired state, not a toggle: duplicate requests are idempotent.
  /// Callers must not expose this until an archive browser and failure feedback
  /// are available. Uncommitted metadata never changes the visible state.
  Future<void> setNoteArchived(String id, {required bool archived}) =>
      _serialize(() async {
        if (!_opened) throw StateError('dailynotes_not_open');
        final next = await database.transaction(() async {
          final state = await _readState();
          state.require(id, 'note');
          final current = state.archivedNoteIds.contains(id);
          if (current == archived) return state;
          final key = 'archive:note:$id';
          if (archived) {
            await database.customStatement(
              'INSERT INTO dn_metadata (key, value) VALUES (?, ?)',
              [key, '1'],
            );
            state.archivedNoteIds.add(id);
          } else {
            await database.customStatement(
              'DELETE FROM dn_metadata WHERE key = ?',
              [key],
            );
            state.archivedNoteIds.remove(id);
          }
          return state;
        });
        _state = next;
        notifyListeners();
      });

  /// Reload the database-backed read model when returning to a browser that
  /// may have been modified by another store instance.
  Future<void> refresh() => _serialize(() async {
    if (!_opened) throw StateError('dailynotes_not_open');
    _state = await database.transaction(_readState);
    notifyListeners();
  });

  Future<void> open() => _serialize(() async {
    if (_opened) return;
    await database.transaction(() async {
      await database.customStatement(
        'CREATE TABLE IF NOT EXISTS dn_metadata (key TEXT PRIMARY KEY, value TEXT NOT NULL)',
      );
      final version = await database
          .customSelect(
            "SELECT value FROM dn_metadata WHERE key = 'schema_version'",
          )
          .get();
      if (version.isNotEmpty && version.single.read<String>('value') != '1') {
        throw StateError('unsupported_dailynotes_schema');
      }
      await database.customStatement(
        'CREATE TABLE IF NOT EXISTS dn_records (id TEXT PRIMARY KEY, kind TEXT NOT NULL, revision INTEGER NOT NULL, payload TEXT NOT NULL)',
      );
      await database.customStatement(
        'CREATE TABLE IF NOT EXISTS dn_links (id TEXT PRIMARY KEY, note_id TEXT NOT NULL REFERENCES dn_records(id), topic_id TEXT NOT NULL REFERENCES dn_records(id), deleted_at TEXT, revision INTEGER NOT NULL, UNIQUE(note_id, topic_id))',
      );
      await database.customStatement(
        'CREATE TABLE IF NOT EXISTS dn_outbox (sequence INTEGER PRIMARY KEY AUTOINCREMENT, event_id TEXT NOT NULL UNIQUE, entity_id TEXT NOT NULL, kind TEXT NOT NULL, revision INTEGER NOT NULL, operation TEXT NOT NULL, changed_at TEXT NOT NULL, payload TEXT NOT NULL)',
      );
      await database.customStatement(
        "INSERT OR IGNORE INTO dn_metadata (key, value) VALUES ('schema_version', '1')",
      );
    });
    _state = await _readState();
    final drafts = await database
        .customSelect(
          "SELECT key, value FROM dn_metadata WHERE key LIKE 'draft:%'",
        )
        .get();
    for (final row in drafts) {
      _drafts[row.read<String>('key').substring(6)] = (jsonDecode(
        row.read<String>('value'),
      ) as Map<String, dynamic>).cast<String, Object?>();
    }
    _opened = true;
    notifyListeners();
  });

  Future<_State> _readState() async {
    final rows = await database
        .customSelect('SELECT id, kind, revision, payload FROM dn_records')
        .get();
    final records = <String, _Stored>{};
    for (final row in rows) {
      final value =
          jsonDecode(row.read<String>('payload')) as Map<String, dynamic>;
      final id = row.read<String>('id');
      if (value['id'] != id) throw StateError('invalid_dailynotes_identity');
      records[id] = _Stored(
        row.read<String>('kind'),
        row.read<int>('revision'),
        value,
      );
    }
    final rowsLinks = await database
        .customSelect(
          'SELECT id, note_id, topic_id, deleted_at, revision FROM dn_links',
        )
        .get();
    final links = <String, _Link>{};
    for (final row in rowsLinks) {
      final id = row.read<String>('id');
      final deleted = row.readNullable<String>('deleted_at');
      links[id] = _Link(
        id,
        row.read<String>('note_id'),
        row.read<String>('topic_id'),
        deleted == null ? null : DateTime.parse(deleted),
        row.read<int>('revision'),
      );
    }
    final count = await database
        .customSelect('SELECT COUNT(*) AS count FROM dn_outbox')
        .getSingle();
    final archives = await database
        .customSelect(
          "SELECT key, value FROM dn_metadata WHERE key LIKE 'archive:note:%'",
        )
        .get();
    final archived = <String>{};
    for (final row in archives) {
      final key = row.read<String>('key');
      if (row.read<String>('value') != '1' ||
          key.length <= 'archive:note:'.length) {
        throw StateError('invalid_note_archive_metadata');
      }
      archived.add(key.substring('archive:note:'.length));
    }
    return _State(
      records,
      links,
      count.read<int>('count'),
      archivedNoteIds: archived,
    );
  }

  Map<String, Object?>? draft(String key) {
    final value = _drafts[key];
    return value == null ? null : Map.unmodifiable(value);
  }

  /// A snapshot of draft keys and payloads for the caller's scoped prefix.
  Map<String, Map<String, Object?>> draftsWithPrefix(String prefix) {
    if (!_opened) throw StateError('dailynotes_not_open');
    return Map.unmodifiable({
      for (final entry in _drafts.entries)
        if (entry.key.startsWith(prefix))
          entry.key: Map<String, Object?>.unmodifiable(entry.value),
    });
  }

  Future<void> saveDraft(String key, Map<String, Object?> payload) =>
      _serialize(() async {
        if (!_opened) throw StateError('dailynotes_not_open');
        final encoded = jsonEncode(payload);
        await database.customStatement(
          'INSERT INTO dn_metadata (key, value) VALUES (?, ?) ON CONFLICT(key) DO UPDATE SET value=excluded.value',
          ['draft:$key', encoded],
        );
        _drafts[key] = (jsonDecode(encoded) as Map<String, dynamic>)
            .cast<String, Object?>();
        notifyListeners();
      });

  Future<void> removeDraft(String key) => _serialize(() async {
    if (!_opened) throw StateError('dailynotes_not_open');
    await database.customStatement('DELETE FROM dn_metadata WHERE key = ?', [
      'draft:$key',
    ]);
    _drafts.remove(key);
    notifyListeners();
  });

  Future<T> _serialize<T>(Future<T> Function() action) {
    final done = Completer<T>();
    _tail = _tail.then((_) async {
      try {
        done.complete(await action());
      } catch (error, stack) {
        done.completeError(error, stack);
      }
    });
    return done.future;
  }

  String _id() =>
      'dn_${_clock().microsecondsSinceEpoch}_${List.generate(16, (_) => _random.nextInt(16).toRadixString(16)).join()}';

  Future<T> _commit<T>(T Function(_State state, DateTime now) mutate) =>
      _serialize(() async {
        if (!_opened) throw StateError('dailynotes_not_open');
        late T result;
        final next = await database.transaction(() async {
          final state = await _readState();
          final now = _clock().toUtc();
          result = mutate(state, now);
          for (final id in state.writes) {
            final row = state.records[id]!;
            await database.customStatement(
              'INSERT INTO dn_records (id, kind, revision, payload) VALUES (?, ?, ?, ?) ON CONFLICT(id) DO UPDATE SET kind=excluded.kind, revision=excluded.revision, payload=excluded.payload',
              [id, row.kind, row.revision, jsonEncode(row.value)],
            );
            await beforeOutboxWrite?.call();
            await _event(
              state,
              id,
              row.kind,
              row.revision,
              row.value['deletedAt'] == null ? 'upsert' : 'trash',
              row.value,
              now,
            );
          }
          for (final id in state.linkWrites) {
            final link = state.links[id]!;
            await database.customStatement(
              'INSERT INTO dn_links (id, note_id, topic_id, deleted_at, revision) VALUES (?, ?, ?, ?, ?) ON CONFLICT(id) DO UPDATE SET deleted_at=excluded.deleted_at, revision=excluded.revision',
              [
                link.id,
                link.noteId,
                link.topicId,
                link.deletedAt?.toIso8601String(),
                link.revision,
              ],
            );
            await beforeOutboxWrite?.call();
            await _event(
              state,
              id,
              'link',
              link.revision,
              link.deletedAt == null ? 'upsert' : 'unlink',
              link.toJson(),
              now,
            );
          }
          return state;
        });
        _state = next;
        notifyListeners();
        return result;
      });

  Future<void> _event(
    _State state,
    String id,
    String kind,
    int revision,
    String operation,
    Map<String, dynamic> payload,
    DateTime now,
  ) async {
    await database.customStatement(
      'INSERT INTO dn_outbox (event_id, entity_id, kind, revision, operation, changed_at, payload) VALUES (?, ?, ?, ?, ?, ?, ?)',
      [
        _id(),
        id,
        kind,
        revision,
        operation,
        now.toIso8601String(),
        jsonEncode(payload),
      ],
    );
    state.pending++;
  }

  Future<DailyNote> saveNote({
    String? id,
    required String title,
    required String body,
    String? folderId,
    List<String> tags = const [],
  }) => _commit((state, now) {
    if (title.trim().isEmpty && body.trim().isEmpty) {
      throw StateError('empty_note');
    }
    if (folderId != null) state.require(folderId, 'folder');
    final old = id == null ? null : state.require(id, 'note');
    if (old != null && old['documentJson'] != null) {
      throw StateError('rich_document_requires_compatible_editor');
    }
    final note = DailyNote(
      id: id ?? _id(),
      title: title,
      body: body,
      folderId: folderId,
      tags: tags
          .map((t) => t.trim())
          .where((t) => t.isNotEmpty)
          .toSet()
          .toList(),
      createdAt: old == null ? now : _date(old, 'createdAt'),
      updatedAt: now,
    );
    state.put('note', note.toJson());
    return DailyNote.fromJson(
      note.toJson(),
      storageRevision: state.records[note.id]!.revision,
    );
  });

  /// Captures the destination and every ancestor at their current revisions.
  /// A null id denotes the stable, uncategorized destination.
  DailyFolderPathSnapshot? folderPathSnapshot(String? id) =>
      _folderPathSnapshot(_state, id);

  DailyFolderPathSnapshot? _folderPathSnapshot(_State state, String? id) {
    if (id == null) return const DailyFolderPathSnapshot._(null, '', '[]');
    final ancestors = <_Stored>[];
    final seen = <String>{};
    String? cursor = id;
    while (cursor != null && seen.add(cursor)) {
      final row = state.records[cursor];
      if (row == null ||
          row.kind != 'folder' ||
          row.value['deletedAt'] != null) {
        return null;
      }
      ancestors.add(row);
      cursor = row.value['parentId'] as String?;
    }
    if (cursor != null) return null;
    final path = ancestors.reversed.toList();
    return DailyFolderPathSnapshot._(
      id,
      path.map((row) => row.value['name'] as String).join(' / '),
      jsonEncode([
        for (final row in path)
          [
            row.value['id'],
            row.revision,
            row.value['name'],
            row.value['parentId'],
          ],
      ]),
    );
  }

  /// Stores the versioned AppFlowy document and its derived text together
  /// with the local revision and outbox event. Unknown versions fail closed.
  Future<DailyNote> saveRichNote({
    String? id,
    required String title,
    required String plainText,
    required String documentJson,
    required int documentVersion,
    String? folderId,
    List<String> tags = const [],
    int? expectedRevision,
    DailyFolderPathSnapshot? expectedFolderPath,
  }) => _commit((state, now) {
    if (documentVersion != 1) throw StateError('unsupported_document_version');
    validateRichDocument(documentJson);
    if (title.trim().isEmpty && plainText.trim().isEmpty) {
      throw StateError('empty_note');
    }
    if (expectedFolderPath != null &&
        (expectedFolderPath.folderId != folderId ||
            !expectedFolderPath.matches(
              _folderPathSnapshot(state, folderId),
            ))) {
      throw const DailyFolderPathConflict();
    }
    if (folderId != null) state.require(folderId, 'folder');
    if (id != null &&
        expectedRevision != null &&
        (state.records[id]?.kind != 'note' ||
            state.records[id]?.value['deletedAt'] != null ||
            state.records[id]?.revision != expectedRevision)) {
      throw const DailyNoteRevisionConflict();
    }
    final old = id == null ? null : state.require(id, 'note');
    if (old != null && old['documentJson'] != null) {
      if (old['documentVersion'] != 1) {
        throw StateError('unsupported_document_version');
      }
      validateRichDocument(old['documentJson'] as String);
    }
    final note = DailyNote(
      id: id ?? _id(),
      title: title,
      body: plainText,
      documentJson: documentJson,
      documentVersion: documentVersion,
      folderId: folderId,
      tags: tags
          .map((t) => t.trim())
          .where((t) => t.isNotEmpty)
          .toSet()
          .toList(),
      createdAt: old == null ? now : _date(old, 'createdAt'),
      updatedAt: now,
    );
    state.put('note', note.toJson());
    return DailyNote.fromJson(
      note.toJson(),
      storageRevision: state.records[note.id]!.revision,
    );
  });

  Future<DailyFolder> createFolder(String name, {String? parentId}) =>
      _commit((state, now) {
        if (name.trim().isEmpty) throw StateError('empty_folder_name');
        if (parentId != null) state.require(parentId, 'folder');
        final folder = DailyFolder(
          id: _id(),
          name: _uniqueFolderName(state, name.trim(), parentId),
          parentId: parentId,
          createdAt: now,
          updatedAt: now,
        );
        state.put('folder', folder.toJson());
        return folder;
      });

  Future<DailyFolder> renameFolder(String id, String name) =>
      _commit((state, now) {
        final old = state.require(id, 'folder');
        final trimmed = name.trim();
        if (trimmed.isEmpty) throw StateError('empty_folder_name');
        final updated = {
          ...old,
          'name': _uniqueFolderName(
            state,
            trimmed,
            old['parentId'] as String?,
            except: id,
          ),
          'updatedAt': now.toIso8601String(),
        };
        state.put('folder', updated);
        return DailyFolder.fromJson(updated);
      });

  DailyFolderRemovalPlan _folderRemovalPlan(_State state, String id) {
    final folder = state.require(id, 'folder');
    final parentId = folder['parentId'] as String?;
    if (parentId == id) throw StateError('invalid_folder_parent');
    if (parentId != null) state.require(parentId, 'folder');
    var noteCount = 0;
    var trashedNoteCount = 0;
    var childFolderCount = 0;
    final fingerprint = <String>[];
    for (final entry in state.records.entries) {
      final row = entry.value;
      final value = row.value;
      var relevant = entry.key == id || entry.key == parentId;
      if (row.kind == 'folder' && value['deletedAt'] == null) {
        if (value['parentId'] == id) childFolderCount++;
        relevant =
            relevant ||
            value['parentId'] == id ||
            value['parentId'] == parentId;
      }
      if (row.kind == 'note' && value['folderId'] == id) {
        if (value['deletedAt'] == null) {
          noteCount++;
        } else {
          trashedNoteCount++;
        }
        relevant = true;
      }
      if (relevant) fingerprint.add('${entry.key}:${row.kind}:${row.revision}');
    }
    fingerprint.sort();
    return DailyFolderRemovalPlan._(
      folderId: id,
      folderName: folder['name'] as String,
      parentId: parentId,
      noteCount: noteCount,
      trashedNoteCount: trashedNoteCount,
      childFolderCount: childFolderCount,
      fingerprint: jsonEncode(fingerprint),
    );
  }

  Future<DailyFolderRemovalPlan> planFolderRemoval(String id) =>
      _serialize(() async {
        if (!_opened) throw StateError('dailynotes_not_open');
        return _folderRemovalPlan(await _readState(), id);
      });

  /// Soft-delete the folder and transfer its direct contents atomically.
  /// A stale impact preview is rejected rather than silently moving new data.
  Future<void> removeFolder(DailyFolderRemovalPlan plan) =>
      _commit((state, now) {
        final current = _folderRemovalPlan(state, plan.folderId);
        if (current._fingerprint != plan._fingerprint) {
          throw StateError('folder_removal_plan_changed');
        }
        final folder = state.require(plan.folderId, 'folder');
        final direct = state.records.entries.toList();
        state.put('folder', {
          ...folder,
          'deletedAt': now.toIso8601String(),
          'updatedAt': now.toIso8601String(),
        });
        for (final entry in direct) {
          final row = entry.value;
          final value = row.value;
          if (row.kind == 'folder' &&
              value['deletedAt'] == null &&
              value['parentId'] == plan.folderId) {
            state.put('folder', {
              ...value,
              'name': _uniqueFolderName(
                state,
                value['name'] as String,
                plan.parentId,
                except: entry.key,
              ),
              'parentId': plan.parentId,
              'updatedAt': now.toIso8601String(),
            });
          } else if (row.kind == 'note' && value['folderId'] == plan.folderId) {
            state.put('note', {
              ...value,
              'folderId': plan.parentId,
              'updatedAt': now.toIso8601String(),
            });
          }
        }
      });

  String _uniqueFolderName(
    _State state,
    String proposed,
    String? parentId, {
    String? except,
  }) {
    final names = state.records.values
        .where(
          (r) =>
              r.kind == 'folder' &&
              r.value['deletedAt'] == null &&
              r.value['parentId'] == parentId &&
              r.value['id'] != except,
        )
        .map((r) => r.value['name'])
        .toSet();
    var name = proposed;
    var index = 2;
    while (names.contains(name)) {
      name = '$proposed ($index)';
      index++;
    }
    return name;
  }

  Future<KnowledgeTopic> createTopic(String title, {String? parentId}) =>
      _commit((state, now) {
        if (title.trim().isEmpty) throw StateError('empty_topic_title');
        if (parentId != null) state.require(parentId, 'topic');
        final topic = KnowledgeTopic(
          id: _id(),
          title: title.trim(),
          parentId: parentId,
          createdAt: now,
          updatedAt: now,
        );
        state.put('topic', topic.toJson());
        return topic;
      });

  Future<void> linkNote(String noteId, String topicId) => _commit((state, now) {
    state.require(noteId, 'note');
    state.require(topicId, 'topic');
    final matches = state.links.values.where(
      (l) => l.noteId == noteId && l.topicId == topicId,
    );
    final existing = matches.isEmpty ? null : matches.first;
    if (existing != null && existing.deletedAt == null) return;
    final link = _Link(
      existing?.id ?? _id(),
      noteId,
      topicId,
      null,
      (existing?.revision ?? 0) + 1,
    );
    state.links[link.id] = link;
    state.linkWrites.add(link.id);
  });

  Future<void> unlinkNote(String noteId, String topicId) => _commit((
    state,
    now,
  ) {
    final links = state.links.values
        .where(
          (l) =>
              l.noteId == noteId && l.topicId == topicId && l.deletedAt == null,
        )
        .toList();
    for (final link in links) {
      state.links[link.id] = _Link(
        link.id,
        noteId,
        topicId,
        now,
        link.revision + 1,
      );
      state.linkWrites.add(link.id);
    }
  });

  Future<DailyTask> saveTask({
    String? id,
    required String title,
    String body = '',
    DateTime? dueAt,
    String listName = '默认清单',
    bool completed = false,
  }) => _commit((state, now) {
    if (title.trim().isEmpty) throw StateError('empty_task_title');
    final old = id == null ? null : state.require(id, 'task');
    final task = DailyTask(
      id: id ?? _id(),
      title: title.trim(),
      body: body,
      dueAt: dueAt,
      listName: listName,
      completed: completed,
      createdAt: old == null ? now : _date(old, 'createdAt'),
      updatedAt: now,
    );
    state.put('task', task.toJson());
    return task;
  });

  Future<void> toggleTask(String id) => _commit((state, now) {
    final value = {...state.require(id, 'task')};
    value['completed'] = !(value['completed'] as bool);
    value['updatedAt'] = now.toIso8601String();
    state.put('task', value);
  });

  Future<void> deleteNote(String id, {int? expectedRevision}) =>
      _trash(id, 'note', expectedRevision: expectedRevision);
  Future<void> deleteTask(String id) => _trash(id, 'task');
  Future<void> restoreNote(String id) => _restore(id, 'note');
  Future<void> restoreTask(String id) => _restore(id, 'task');

  Future<void> _trash(String id, String kind, {int? expectedRevision}) =>
      _commit((state, now) {
        if (expectedRevision != null &&
            (state.records[id]?.kind != kind ||
                state.records[id]?.value['deletedAt'] != null ||
                state.records[id]?.revision != expectedRevision)) {
          throw const DailyNoteRevisionConflict();
        }
        final value = {...state.require(id, kind, deleted: true)};
        if (value['deletedAt'] != null) return;
        value['deletedAt'] = now.toIso8601String();
        value['updatedAt'] = now.toIso8601String();
        state.put(kind, value);
      });

  Future<void> _restore(String id, String kind) => _commit((state, now) {
    final value = {...state.require(id, kind, deleted: true)};
    if (value['deletedAt'] == null) return;
    if (kind == 'note' && value['folderId'] != null) {
      final folder = state.records[value['folderId']];
      if (folder == null || folder.value['deletedAt'] != null) {
        value['folderId'] = null;
      }
    }
    value['deletedAt'] = null;
    value['updatedAt'] = now.toIso8601String();
    state.put(kind, value);
  });

  Future<void> deleteTopic(String id, {bool includeChildren = true}) =>
      _commit((state, now) {
        final root = state.require(id, 'topic');
        final ids = <String>{id};
        if (includeChildren) {
          var changed = true;
          while (changed) {
            changed = false;
            for (final entry in state.records.entries) {
              if (entry.value.kind == 'topic' &&
                  entry.value.value['deletedAt'] == null &&
                  ids.contains(entry.value.value['parentId']) &&
                  ids.add(entry.key)) {
                changed = true;
              }
            }
          }
        } else {
          for (final entry in state.records.entries.toList()) {
            if (entry.value.kind == 'topic' &&
                entry.value.value['deletedAt'] == null &&
                entry.value.value['parentId'] == id) {
              state.put('topic', {
                ...entry.value.value,
                'parentId': root['parentId'],
                'promotedBy': id,
                'updatedAt': now.toIso8601String(),
              });
            }
          }
        }
        final group = _id();
        for (final child in ids) {
          state.put('topic', {
            ...state.require(child, 'topic'),
            'deletedAt': now.toIso8601String(),
            'deletionGroup': group,
            'updatedAt': now.toIso8601String(),
          });
        }
      });

  Future<void> restoreTopic(String id) => _commit((state, now) {
    final root = state.require(id, 'topic', deleted: true);
    if (root['deletedAt'] == null) return;
    final group = root['deletionGroup'];
    final restoreIds = <String>{id};
    // Restore descendants from the same deletion, never a separately trashed tree.
    var changed = true;
    while (changed) {
      changed = false;
      for (final entry in state.records.entries) {
        final value = entry.value.value;
        if (entry.value.kind == 'topic' &&
            value['deletedAt'] != null &&
            value['deletionGroup'] == group &&
            restoreIds.contains(value['parentId']) &&
            restoreIds.add(entry.key)) {
          changed = true;
        }
      }
    }
    for (final child in restoreIds) {
      final value = {...state.require(child, 'topic', deleted: true)};
      final parent = value['parentId'] as String?;
      if (parent != null &&
          !restoreIds.contains(parent) &&
          (state.records[parent] == null ||
              state.records[parent]!.value['deletedAt'] != null)) {
        value['parentId'] = null;
      }
      value['deletedAt'] = null;
      value['deletionGroup'] = null;
      value['updatedAt'] = now.toIso8601String();
      state.put('topic', value);
    }
    for (final entry in state.records.entries.toList()) {
      final value = entry.value.value;
      if (entry.value.kind == 'topic' &&
          value['deletedAt'] == null &&
          value['promotedBy'] == id &&
          value['updatedAt'] == root['deletedAt']) {
        state.put('topic', {
          ...value,
          'parentId': id,
          'promotedBy': null,
          'updatedAt': now.toIso8601String(),
        });
      }
    }
  });
}
