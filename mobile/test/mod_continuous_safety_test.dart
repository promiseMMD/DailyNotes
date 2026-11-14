import 'package:flutter_test/flutter_test.dart';
import 'package:moodiary_mobile/app/home/mod_continuous.dart';
import 'package:moodiary_models/moodiary_models.dart';

Diary record(String id, List<String> tags, {bool show = true}) =>
    Diary.empty(type: DiaryType.tiptap).copyWith(
      id: id, title: id, tags: tags, show: show,
    );

void main() {
  test('topic, child and pins are identified without database changes', () {
    final topic = record('topic1', [ModDiary.topicTag, ModDiary.pinTag,
      '${ModDiary.rankPrefix}0']);
    final child = record('child1', ['${ModDiary.entryPrefix}topic1']);
    final ordinary = record('ordinary1', [ModDiary.pinTag,
      '${ModDiary.rankPrefix}1']);
    final report = ModDiary.audit([topic, child, ordinary]);
    expect(report.topics, 1);
    expect(report.entries, 1);
    expect(report.pins, 2);
    expect(report.issueCount, 0);
    expect(ModDiary.hideFromOrdinaryList(child), isTrue);
    expect(ModDiary.hideFromOrdinaryList(ordinary), isFalse);
  });

  test('orphan child is reported, never removed', () {
    final orphan = record('orphan1', ['${ModDiary.entryPrefix}missing-topic']);
    final report = ModDiary.audit([orphan]);
    expect(report.orphanEntries, 1);
    expect(orphan.tags, contains('${ModDiary.entryPrefix}missing-topic'));
  });

  test('duplicate pin ranks and malformed rank are detected', () {
    final a = record('a', [ModDiary.pinTag, '${ModDiary.rankPrefix}0']);
    final b = record('b', [ModDiary.pinTag, '${ModDiary.rankPrefix}0']);
    final c = record('c', [ModDiary.pinTag, '${ModDiary.rankPrefix}oops']);
    final report = ModDiary.audit([a, b, c]);
    expect(report.duplicatePinRanks, 1);
    expect(report.invalidPinRanks, 1);
  });

  test('creation metadata survives normal Diary JSON round trip', () {
    final original = record('e', [ModDiary.entryPrefix + 't',
      ModDiary.creationPrefix + '2026-11-07T02:20:00.000Z']);
    final decoded = Diary.fromJson(original.toJson());
    expect(decoded.id, original.id);
    expect(decoded.tags, contains(ModDiary.creationPrefix + '2026-11-07T02:20:00.000Z'));
    expect(ModDiary.createdAtOf(decoded), isNotNull);
  });

  test('draft round-trip retains stable ID and event time', () {
    final draft = ModDraft(topicId: 't', entryId: 'stableId',
      text: '睡眠 7 小时', eventTime: DateTime.fromMillisecondsSinceEpoch(1762550000000),
      createdAt: DateTime.fromMillisecondsSinceEpoch(1762550010000));
    final restored = ModDraft.fromJson(draft.toJson(), 't');
    expect(restored.entryId, 'stableId');
    expect(restored.text, '睡眠 7 小时');
    expect(restored.eventTime.millisecondsSinceEpoch, draft.eventTime.millisecondsSinceEpoch);
    expect(() => ModDraft.fromJson(draft.toJson(), 'wrong'), throwsFormatException);
  });

  test('malformed child association does not look like valid topic membership', () {
    final child = record('e', [ModDiary.entryPrefix]);
    final report = ModDiary.audit([child]);
    expect(report.invalidAssociations, 1);
  });
}
