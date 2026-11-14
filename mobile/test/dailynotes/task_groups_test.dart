import 'package:flutter_test/flutter_test.dart';
import 'package:moodiary_mobile/app/dailynotes/todos/task_groups.dart';

void main() {
  group('calendar task grouping', () {
    final now = DateTime(2026, 11, 14, 21, 45);

    test('undated, past and current calendar days remain separate', () {
      expect(taskDateGroup(null, now), TaskDateGroup.noDate);
      expect(
        taskDateGroup(DateTime(2026, 11, 13, 23, 59), now),
        TaskDateGroup.overdue,
      );
      expect(
        taskDateGroup(DateTime(2026, 11, 14, 0, 1), now),
        TaskDateGroup.today,
      );
    });

    test('next seven days includes exactly seven following calendar dates', () {
      expect(
        taskDateGroup(DateTime(2026, 11, 15), now),
        TaskDateGroup.nextSevenDays,
      );
      expect(
        taskDateGroup(DateTime(2026, 11, 21, 23, 59), now),
        TaskDateGroup.nextSevenDays,
      );
      expect(taskDateGroup(DateTime(2026, 11, 22), now), TaskDateGroup.later);
    });

    test('cross-month and cross-year groups use calendar arithmetic', () {
      final yearEnd = DateTime(2026, 12, 29, 23, 59);
      expect(
        taskDateGroup(DateTime(2027, 1, 5), yearEnd),
        TaskDateGroup.nextSevenDays,
      );
      expect(taskDateGroup(DateTime(2027, 1, 6), yearEnd), TaskDateGroup.later);
      expect(taskCalendarDay(yearEnd), DateTime(2026, 12, 29));
    });

    test('leap-day boundary remains within following calendar week', () {
      final february = DateTime(2028, 2, 26);
      expect(
        taskDateGroup(DateTime(2028, 3, 4), february),
        TaskDateGroup.nextSevenDays,
      );
      expect(
        taskDateGroup(DateTime(2028, 3, 5), february),
        TaskDateGroup.later,
      );
    });
  });
}
