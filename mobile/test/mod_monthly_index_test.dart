import 'package:flutter_test/flutter_test.dart';
import 'package:moodiary_models/moodiary_models.dart';
import 'package:moodiary_mobile/app/home/mod_monthly_index.dart';

Diary makeDiary(String id, DateTime event) => Diary.create(
  title: '测试记录', content: '{}', contentText: id,
  imageName: const [], audioName: const [], videoName: const [],
  tags: const [], type: DiaryType.tiptap,
).copyWith(id: id, time: event);

void main() {
  test('monthly projection is read only and groups days descending', () {
    final original = [
      makeDiary('b', DateTime(2026, 11, 7, 19)),
      makeDiary('a', DateTime(2026, 11, 7, 8)),
      makeDiary('old', DateTime(2026, 10, 29)),
      makeDiary('mid', DateTime(2026, 11, 6, 12)),
    ];
    final months = ModMonthlyIndex.fromChildDiaries(original);
    expect(months.map((m) => m.key), ['2026-11', '2026-10']);
    expect(months[0].days.map((d) => d.date.day), [7, 6]);
    expect(months[0].days[0].records.map((r) => r.id), ['a', 'b']);
    expect(months[0].recordCount, 3);
    expect(months[0].latestPreview.map((r) => r.id), ['mid', 'a', 'b']);
    expect(original.map((r) => r.id), ['b', 'a', 'old', 'mid']);
  });
  test('empty, hidden and fewer-than-three previews', () {
    expect(ModMonthlyIndex.fromChildDiaries([]), isEmpty);
    final month = ModMonthlyIndex.fromChildDiaries([
      makeDiary('one', DateTime(2026, 11, 1)),
      makeDiary('hidden', DateTime(2026, 11, 2)).copyWith(show: false),
    ]).single;
    expect(month.latestPreview.map((r) => r.id), ['one']);
    expect(month.recordCount, 1);
  });
  test('equal event times have stable ID order', () {
    final now = DateTime(2026, 11, 7, 12);
    final month = ModMonthlyIndex.fromChildDiaries([
      makeDiary('z', now), makeDiary('a', now),
    ]).single;
    expect(month.days.single.records.map((r) => r.id), ['a', 'z']);
  });
}
