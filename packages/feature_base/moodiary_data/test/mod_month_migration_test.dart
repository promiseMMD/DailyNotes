import 'dart:convert';

import 'package:drift/drift.dart' hide isNull;
import 'package:drift_dev/api/migrations_native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:moodiary_data/moodiary_data.dart';
import 'package:moodiary_data/src/mod_month_schema.dart';
import 'package:sqlite3_simple/sqlite3_simple.dart';

import 'drift/moodiary/generated/schema.dart';
import 'drift/moodiary/generated/schema_v2.dart' as v2;
import 'drift/moodiary/generated/schema_v3.dart' as v3;

void main() {
  driftRuntimeOptions.dontWarnAboutMultipleDatabases = true;
  late SchemaVerifier verifier;

  setUpAll(() {
    loadSimpleExtension();
    installJiebaDict();
    verifier = SchemaVerifier(GeneratedHelper());
  });

  test('W9 upgrade v3 to v5 preserves normal diary exact content and metadata', () async {
    final schema = await verifier.schemaAt(3);
    final old = v3.DatabaseAtV3(schema.newConnection());
    const id = '1c042158-916c-458e-8921-63e8529f6eb0';
    final content = jsonEncode({
      'type': 'doc', 'attrs': {'v': 2},
      'content': [
        {'type': 'paragraph', 'content': [
          {'type': 'text', 'text': '既有的日记不能丢失'},
        ]},
      ],
    });
    await old.into(old.diaries).insert(v3.DiariesCompanion.insert(
      id: id, title: '升级前的旧日记', content: content,
      contentText: '既有的日记不能丢失',
      time: 1730950123456, lastModified: 1730950999888,
      show: 1, type: 'tiptap',
    ));
    await old.close();

    final upgraded = MoodiaryDatabase.forTesting(schema.newConnection());
    final uv = await upgraded.customSelect('PRAGMA user_version').getSingle();
    expect(uv.read<int>('user_version'), 5);
    final diary = await upgraded.customSelect(
      'SELECT title,content,content_text,time,last_modified,show,type '
      'FROM diaries WHERE id = ?',
      variables: [Variable.withString(id)],
    ).getSingle();
    expect(diary.read<String>('title'), '升级前的旧日记');
    expect(diary.read<String>('content'), content);
    expect(diary.read<String>('content_text'), '既有的日记不能丢失');
    expect(diary.read<int>('time'), 1730950123456);
    expect(diary.read<int>('last_modified'), 1730950999888);
    expect(diary.read<int>('show'), 1);
    expect(diary.read<String>('type'), 'tiptap');
    final objects = await upgraded.customSelect(
      "SELECT name FROM sqlite_master WHERE type='table' AND name LIKE 'mod_month_%'",
    ).get();
    expect(objects.map((r) => r.read<String>('name')).toSet(), {
      'mod_month_pages','mod_month_blocks','mod_month_revisions',
      'mod_month_heads','mod_month_ops'
    });
    final untouched = await upgraded.customSelect(
      'SELECT COUNT(*) AS n FROM mod_month_blocks'
    ).getSingle();
    expect(untouched.read<int>('n'), 0);
    await upgraded.close();
  });

  test('W9 upgrade from v2 applies original migration before additive v5', () async {
    final schema = await verifier.schemaAt(2);
    final old = v2.DatabaseAtV2(schema.newConnection());
    await old.into(old.diaries).insert(v2.DiariesCompanion.insert(
      id: 'old-upgrade-row',
      title: '旧版苹果日记',
      content: '',
      contentText: '苹果和工作记录',
      time: 1760000000000,
      lastModified: 1760000000020,
      show: 1,
      mood: 'neutral',
      type: 'tiptap',
    ));
    await old.close();

    final upgraded = MoodiaryDatabase.forTesting(schema.newConnection());
    final uv = await upgraded.customSelect('PRAGMA user_version').getSingle();
    expect(uv.read<int>('user_version'), 5);
    final legacy = await upgraded.customSelect(
      'SELECT title,content_text,mood_level FROM diaries WHERE id = ?',
      variables: [const Variable<String>('old-upgrade-row')],
    ).getSingle();
    expect(legacy.read<String>('title'), '旧版苹果日记');
    expect(legacy.read<String>('content_text'), '苹果和工作记录');
    expect(legacy.readNullable<int>('mood_level'), isNull);
    final v4 = await upgraded.customSelect(
      'SELECT COUNT(*) AS n FROM mod_month_pages',
    ).getSingle();
    expect(v4.read<int>('n'), 0);
    await upgraded.close();
  });

  test('W9.8 existing v4 to v5 keeps native Diary and immutable block graph', () async {
    final schema = await verifier.schemaAt(3);
    final previous = v3.DatabaseAtV3(schema.newConnection());
    await createModMonthSchema((sql) => previous.customStatement(sql));
    const id = '1c042158-916c-458e-8921-63e8529f6eb0';
    const topic = 'topic-2026-learning';
    const block = 'block-v4-legacy-0001';
    const revision = 'revision-v4-legacy-0001';
    const original = '{"type":"doc","attrs":{"v":2},"content":[]}';
    await previous.into(previous.diaries).insert(v3.DiariesCompanion.insert(
      id: id, title: 'old v4 native Diary', content: original,
      contentText: 'preserve', time: 1730950123456,
      lastModified: 1730950999888, show: 1, type: 'tiptap',
    ));
    await previous.customStatement(
      'INSERT INTO mod_month_pages'
      '(topic_id,month_key,diary_id,created_ms) VALUES(?,?,NULL,?)',
      [topic,'2026-11',42],
    );
    await previous.customStatement(
      'INSERT INTO mod_month_blocks'
      '(block_id,topic_id,month_key,kind,created_ms) VALUES(?,?,?,?,?)',
      [block,topic,'2026-11','entry',43],
    );
    await previous.customStatement(
      'INSERT INTO mod_month_revisions'
      '(revision_id,block_id,parent_revision_id,month_key,day_key,'
      'occurred_at_ms,body_json,deleted,edited_at_ms)'
      ' VALUES(?,?,NULL,?,?,?,?,?,?)',
      [revision,block,'2026-11','2026-11-07',44,original,0,45],
    );
    await previous.customStatement(
      'INSERT INTO mod_month_heads(block_id,revision_id) VALUES(?,?)',
      [block,revision],
    );
    await previous.customStatement('PRAGMA user_version = 4');
    await previous.close();

    final upgraded = MoodiaryDatabase.forTesting(schema.newConnection());
    final version = await upgraded.customSelect('PRAGMA user_version').getSingle();
    expect(version.read<int>('user_version'), 5);
    final diary = await upgraded.customSelect(
      'SELECT title,content,content_text,time,last_modified,show '
      'FROM diaries WHERE id=?',
      variables:[Variable.withString(id)],
    ).getSingle();
    expect(diary.read<String>('title'),'old v4 native Diary');
    expect(diary.read<String>('content'), original);
    expect(diary.read<String>('content_text'),'preserve');
    expect(diary.read<int>('time'),1730950123456);
    expect(diary.read<int>('last_modified'),1730950999888);
    expect(diary.read<int>('show'),1);
    final oldBlock = await upgraded.customSelect(
      'SELECT b.topic_id,b.month_key,b.created_ms,'
      'r.revision_id,r.day_key,r.body_json,r.occurred_at_ms,r.edited_at_ms '
      'FROM mod_month_blocks b JOIN mod_month_heads h ON h.block_id=b.block_id '
      'JOIN mod_month_revisions r ON r.revision_id=h.revision_id '
      'WHERE b.block_id=?',
      variables:[Variable.withString(block)],
    ).getSingle();
    expect(oldBlock.read<String>('topic_id'),topic);
    expect(oldBlock.read<String>('month_key'),'2026-11');
    expect(oldBlock.read<int>('created_ms'),43);
    expect(oldBlock.read<String>('revision_id'),revision);
    expect(oldBlock.read<String>('day_key'),'2026-11-07');
    expect(oldBlock.read<String>('body_json'),original);
    expect(oldBlock.read<int>('occurred_at_ms'),44);
    expect(oldBlock.read<int>('edited_at_ms'),45);
    final newTable = await upgraded.customSelect(
      'SELECT COUNT(*) AS n FROM mod_day_pages',
    ).getSingle();
    expect(newTable.read<int>('n'),0);
    await upgraded.close();
  });

}
