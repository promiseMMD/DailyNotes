import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:moodiary_data/moodiary_data.dart';
import 'package:moodiary_di/moodiary_di.dart';
import 'package:moodiary_mobile/app/di/bootstrap.dart';
import 'package:moodiary_storage/moodiary_storage.dart';
import 'package:moodiary_storage/testing.dart';

void main() {
  test('reset stops before clearing settings when protected history exists', () async {
    final db = MoodiaryDatabase.forTesting(NativeDatabase.memory());
    final settings = MemoryKVStorage()..set('retained', 'yes');
    getIt.registerSingleton<MoodiaryDatabase>(db);
    getIt.registerSingleton<IKVStorage>(settings);
    addTearDown(() async {
      await getIt.reset();
      await db.close();
    });
    await db.customStatement(
      'INSERT INTO mod_month_pages(topic_id, month_key, diary_id, created_ms) '
      'VALUES(?, ?, NULL, ?)',
      ['topic', '2026-11', 1],
    );
    await db.customStatement(
      'INSERT INTO mod_month_blocks(block_id, topic_id, month_key, kind, created_ms) '
      'VALUES(?, ?, ?, ?, ?)',
      ['block', 'topic', '2026-11', 'entry', 1],
    );
    await db.customStatement(
      'INSERT INTO mod_month_revisions(revision_id, block_id, parent_revision_id, '
      'month_key, day_key, occurred_at_ms, body_json, deleted, edited_at_ms) '
      'VALUES(?, ?, NULL, ?, ?, ?, ?, ?, ?)',
      ['revision', 'block', '2026-11', '2026-11-01', 1, '{}', 0, 1],
    );

    await expectLater(
      resetAllData(),
      throwsA(isA<HistoryRetentionException>()),
    );
    expect(settings.get<String>('retained'), 'yes');
    expect(
      (await db
              .customSelect('SELECT COUNT(*) AS n FROM mod_month_revisions')
              .getSingle())
          .read<int>('n'),
      1,
    );
  });
}
