/// Calendar-day grouping keeps planned dates independent of notification consent.
enum TaskDateGroup { overdue, today, nextSevenDays, later, noDate }

DateTime taskCalendarDay(DateTime value) =>
    DateTime(value.year, value.month, value.day);

TaskDateGroup taskDateGroup(DateTime? dueAt, DateTime now) {
  if (dueAt == null) return TaskDateGroup.noDate;
  final today = taskCalendarDay(now);
  final due = taskCalendarDay(dueAt);
  if (due.isBefore(today)) return TaskDateGroup.overdue;
  if (due == today) return TaskDateGroup.today;
  // Calendar arithmetic, rather than a 24-hour duration, also works across DST.
  final weekEnd = DateTime(today.year, today.month, today.day + 7);
  return !due.isAfter(weekEnd)
      ? TaskDateGroup.nextSevenDays
      : TaskDateGroup.later;
}
