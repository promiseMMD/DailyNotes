// Moodiary 3.0 development: read-only projection of existing Beta child diaries.
// This layer MUST NOT migrate, rewrite or delete any original Diary object.
// A real month Diary + block revision protocol is a subsequent P0 milestone.
import 'package:moodiary_models/moodiary_models.dart';

class ModMonthDay {
  final DateTime date;
  final List<Diary> records;
  ModMonthDay(this.date, Iterable<Diary> records)
      : records = List.unmodifiable(records);
}

class ModMonth {
  final String key;
  final List<ModMonthDay> days;
  ModMonth(this.key, Iterable<ModMonthDay> days)
      : days = List.unmodifiable(days);

  int get recordCount => days.fold(0, (total, day) => total + day.records.length);
  int get recordedDays => days.length;

  /// Latest three events, presented in chronological order for the feed.
  List<Diary> get latestPreview {
    final ordered = <Diary>[for (final day in days) ...day.records]
      ..sort((a, b) {
        final diff = b.time.compareTo(a.time);
        return diff != 0 ? diff : b.id.compareTo(a.id);
      });
    return List.unmodifiable(ordered.take(3).toList()
      ..sort((a, b) {
        final diff = a.time.compareTo(b.time);
        return diff != 0 ? diff : a.id.compareTo(b.id);
      }));
  }
}

class ModMonthlyIndex {
  /// Groups visible children from ONE topic. Never treats technical tags as
  /// user-visible labels. The UI displays the title of the resolved topic.
  static List<ModMonth> fromChildDiaries(Iterable<Diary> children) {
    final byMonth = <String, Map<String, List<Diary>>>{};
    final dates = <String, DateTime>{};
    for (final diary in children) {
      if (!diary.show) continue;
      final local = diary.time.toLocal();
      final yearMonth = '${local.year.toString().padLeft(4, '0')}-${local.month.toString().padLeft(2, '0')}';
      final dayKey = '${local.year.toString().padLeft(4, '0')}-${local.month.toString().padLeft(2, '0')}-${local.day.toString().padLeft(2, '0')}';
      dates[dayKey] = DateTime(local.year, local.month, local.day);
      byMonth.putIfAbsent(yearMonth, () => {}).putIfAbsent(dayKey, () => []).add(diary);
    }
    final months = byMonth.keys.toList()..sort((a, b) => b.compareTo(a));
    return List.unmodifiable(months.map((key) {
      final byDay = byMonth[key]!;
      final dayKeys = byDay.keys.toList()..sort((a, b) => b.compareTo(a));
      return ModMonth(key, dayKeys.map((dayKey) {
        final ascending = [...byDay[dayKey]!]
          ..sort((a, b) {
            final diff = a.time.compareTo(b.time);
            return diff != 0 ? diff : a.id.compareTo(b.id);
          });
        return ModMonthDay(dates[dayKey]!, ascending);
      }));
    }));
  }
}
