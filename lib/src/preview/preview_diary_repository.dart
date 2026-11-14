import 'dart:async';
import 'dart:io';

import 'package:sqflite/sqflite.dart';

import '../experimental/diary_autosave_session.dart';
import '../experimental/local_journal_spike.dart';

/// Narrow adapter over the *experimental* SQLite journal.
///
/// The dedicated database basename prevents this interaction experiment
/// from claiming to own any future production or Moodiary data. It is not
/// an approved schema or a backup. No data migration or import is performed.
abstract class PreviewDiaryRepository {
  Future<List<DiaryVersion>> listDiaries();

  Future<ExperimentalDiarySession> openEditor(String entityId);

  Future<void> close();
}

class SqlitePreviewDiaryRepository implements PreviewDiaryRepository {
  Future<LocalJournalSpike>? _opening;
  bool _closed = false;

  Future<LocalJournalSpike> _db() {
    if (_closed) throw StateError('Preview journal already closed');
    return _opening ??= _openDatabase();
  }

  Future<LocalJournalSpike> _openDatabase() async {
    final dir = await getDatabasesPath();
    final filename = '${dir}${Platform.pathSeparator}'
        'dailynotes_interaction_preview_v1.db';
    return LocalJournalSpike.open(
      factory: databaseFactory,
      path: filename,
    );
  }

  @override
  Future<List<DiaryVersion>> listDiaries() async =>
      (await _db()).listCommittedDiaries();

  @override
  Future<ExperimentalDiarySession> openEditor(String entityId) async =>
      ExperimentalDiarySession.open(
        journal: await _db(),
        entityId: entityId,
      );

  @override
  Future<void> close() async {
    _closed = true;
    final opening = _opening;
    if (opening != null) {
      await (await opening).close();
    }
  }
}
