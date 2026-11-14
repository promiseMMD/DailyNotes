import 'package:moodiary_i18n/moodiary_i18n.dart';
import 'package:mui/mui.dart';

import '../data/daily_notes_store.dart';
import 'task_groups.dart';
import 'todo_editor_page.dart';

/// Both views read the same records. Creating a task never creates a second
/// record for its date or list grouping.
class DailyNotesTodosPage extends StatefulWidget {
  final DailyNotesStore store;

  const DailyNotesTodosPage({super.key, required this.store});

  @override
  State<DailyNotesTodosPage> createState() => DailyNotesTodosPageState();
}

class DailyNotesTodosPageState extends State<DailyNotesTodosPage> {
  DateTime _selectedDay = taskCalendarDay(DateTime.now());
  bool _calendarVisible = false;
  final Set<String> _mutating = {};

  Future<void> createTodo() => _openEditor();

  Future<void> _openEditor([DailyTask? task]) async {
    await Navigator.of(context).push<void>(
      MaterialPageRoute(
        builder: (_) => DailyNotesTodoEditorPage(
          store: widget.store,
          task: task,
          initialDueDate: task == null ? _selectedDay : null,
        ),
      ),
    );
  }

  Future<void> _toggle(DailyTask task) async {
    if (!_mutating.add(task.id)) return;
    setState(() {});
    try {
      await widget.store.toggleTask(task.id);
    } catch (_) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(context.l10n.dailynotes.saveFailed)),
        );
      }
    } finally {
      _mutating.remove(task.id);
      if (mounted) setState(() {});
    }
  }

  List<DailyTask> _sorted(Iterable<DailyTask> tasks) {
    final result = tasks.toList();
    result.sort((a, b) {
      final dueA = a.dueAt;
      final dueB = b.dueAt;
      if (dueA != null && dueB == null) return -1;
      if (dueA == null && dueB != null) return 1;
      final byDue = dueA == null ? 0 : dueA.compareTo(dueB!);
      return byDue != 0 ? byDue : a.createdAt.compareTo(b.createdAt);
    });
    return result;
  }

  @override
  Widget build(BuildContext context) {
    return DefaultTabController(
      length: 2,
      child: Scaffold(
        appBar: AppBar(
          title: Text(context.l10n.dailynotes.todosTitle),
          bottom: TabBar(
            tabs: [
              Tab(text: context.l10n.dailynotes.todayTodos),
              Tab(text: context.l10n.dailynotes.groupedTodos),
            ],
          ),
        ),
        body: ListenableBuilder(
          listenable: widget.store,
          builder: (context, _) {
            final tasks = widget.store.tasks;
            return TabBarView(
              children: [_todayView(tasks), _groupedView(tasks)],
            );
          },
        ),
      ),
    );
  }

  Widget _todayView(List<DailyTask> tasks) {
    final today = taskCalendarDay(DateTime.now());
    final active = tasks.where((task) => !task.completed);
    final onDay = _sorted(
      active.where(
        (task) =>
            task.dueAt != null && taskCalendarDay(task.dueAt!) == _selectedDay,
      ),
    );
    final overdue = _selectedDay == today
        ? _sorted(
            active.where(
              (task) =>
                  taskDateGroup(task.dueAt, today) == TaskDateGroup.overdue,
            ),
          )
        : <DailyTask>[];
    final undated = _selectedDay == today
        ? _sorted(active.where((task) => task.dueAt == null))
        : <DailyTask>[];
    final completed = _sorted(
      tasks.where(
        (task) =>
            task.completed &&
            (task.dueAt == null
                ? _selectedDay == today
                : taskCalendarDay(task.dueAt!) == _selectedDay),
      ),
    );
    return ListView(
      padding: EdgeInsets.fromLTRB(
        16,
        12,
        16,
        110 + MediaQuery.paddingOf(context).bottom,
      ),
      children: [
        Row(
          children: [
            Expanded(
              child: Text(
                MaterialLocalizations.of(context).formatFullDate(_selectedDay),
                style: context.theme.typography.titleSmall.emphasized.onSurface,
              ),
            ),
            IconButton(
              tooltip: context.l10n.dailynotes.chooseDate,
              icon: Icon(
                _calendarVisible
                    ? LucideIcons.chevronUp
                    : LucideIcons.calendarDays,
              ),
              onPressed: () =>
                  setState(() => _calendarVisible = !_calendarVisible),
            ),
            if (_selectedDay != today)
              TextButton(
                onPressed: () => setState(() => _selectedDay = today),
                child: Text(context.l10n.dailynotes.today),
              ),
          ],
        ),
        if (_calendarVisible)
          CalendarDatePicker(
            key: ValueKey(_selectedDay),
            initialDate: _selectedDay,
            firstDate: DateTime(2000),
            lastDate: DateTime(2100, 12, 31),
            onDateChanged: (date) => setState(() => _selectedDay = date),
          ),
        if (overdue.isNotEmpty)
          _section(context.l10n.dailynotes.overdue, overdue),
        if (onDay.isNotEmpty)
          _section(
            _selectedDay == today
                ? context.l10n.dailynotes.today
                : MaterialLocalizations.of(context)
                      .formatShortDate(_selectedDay),
            onDay,
          ),
        if (undated.isNotEmpty)
          _section(context.l10n.dailynotes.noDate, undated),
        if (overdue.isEmpty && onDay.isEmpty && undated.isEmpty) _empty(),
        if (completed.isNotEmpty) _completedSection(completed),
      ],
    );
  }

  Widget _groupedView(List<DailyTask> tasks) {
    final now = DateTime.now();
    final active = tasks.where((task) => !task.completed);
    final completed = _sorted(tasks.where((task) => task.completed));
    return ListView(
      padding: EdgeInsets.fromLTRB(
        16,
        12,
        16,
        110 + MediaQuery.paddingOf(context).bottom,
      ),
      children: [
        if (active.isEmpty) _empty(),
        for (final group in TaskDateGroup.values)
          if (active.any((task) => taskDateGroup(task.dueAt, now) == group))
            _section(
              _groupLabel(group),
              _sorted(
                active.where((task) => taskDateGroup(task.dueAt, now) == group),
              ),
            ),
        if (completed.isNotEmpty) _completedSection(completed),
      ],
    );
  }

  String _groupLabel(TaskDateGroup group) => switch (group) {
    TaskDateGroup.overdue => context.l10n.dailynotes.overdue,
    TaskDateGroup.today => context.l10n.dailynotes.today,
    TaskDateGroup.nextSevenDays => context.l10n.dailynotes.nextSevenDays,
    TaskDateGroup.later => context.l10n.dailynotes.later,
    TaskDateGroup.noDate => context.l10n.dailynotes.noDate,
  };

  Widget _section(String label, List<DailyTask> tasks) => Padding(
    padding: const EdgeInsets.only(bottom: 16),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.symmetric(vertical: 8, horizontal: 4),
          child: Text(
            '$label · ${tasks.length}',
            style: context.theme.typography.labelLarge.onSurfaceVariant,
          ),
        ),
        for (final task in tasks) _taskRow(task),
      ],
    ),
  );

  Widget _completedSection(List<DailyTask> tasks) => ExpansionTile(
    tilePadding: const EdgeInsets.symmetric(horizontal: 4),
    title: Text(
      '${context.l10n.dailynotes.completed} · ${tasks.length}',
      style: context.theme.typography.labelLarge.onSurfaceVariant,
    ),
    children: [for (final task in tasks) _taskRow(task)],
  );

  Widget _taskRow(DailyTask task) => Padding(
    padding: const EdgeInsets.symmetric(vertical: 2),
    child: Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Checkbox(
          value: task.completed,
          onChanged: _mutating.contains(task.id) ? null : (_) => _toggle(task),
          semanticLabel: task.completed
              ? context.l10n.dailynotes.markIncomplete
              : context.l10n.dailynotes.markComplete,
        ),
        Expanded(
          child: InkWell(
            borderRadius: BorderRadius.circular(12),
            onTap: () => _openEditor(task),
            child: Padding(
              padding: const EdgeInsets.symmetric(vertical: 10),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    task.title,
                    style: context.theme.typography.bodyLarge.onSurface
                        .copyWith(
                          decoration: task.completed
                              ? TextDecoration.lineThrough
                              : TextDecoration.none,
                        ),
                  ),
                  if (task.body.trim().isNotEmpty) ...[
                    const SizedBox(height: 3),
                    Text(
                      task.body,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style:
                          context.theme.typography.bodySmall.onSurfaceVariant,
                    ),
                  ],
                  if (task.dueAt != null) ...[
                    const SizedBox(height: 3),
                    Text(
                      MaterialLocalizations.of(context)
                          .formatShortDate(task.dueAt!),
                      style:
                          context.theme.typography.labelSmall.onSurfaceVariant,
                    ),
                  ],
                ],
              ),
            ),
          ),
        ),
      ],
    ),
  );

  Widget _empty() => Padding(
    padding: const EdgeInsets.symmetric(vertical: 48),
    child: Column(
      children: [
        Icon(
          LucideIcons.listChecks,
          size: 36,
          color: context.theme.colors.onSurfaceVariant,
        ),
        const SizedBox(height: 12),
        Text(
          context.l10n.dailynotes.noTodos,
          style: context.theme.typography.titleSmall.onSurface,
        ),
        const SizedBox(height: 6),
        Text(
          context.l10n.dailynotes.noTodosHint,
          textAlign: TextAlign.center,
          style: context.theme.typography.bodySmall.onSurfaceVariant,
        ),
      ],
    ),
  );
}
