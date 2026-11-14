import 'package:moodiary_i18n/moodiary_i18n.dart';
import 'package:moodiary_router/moodiary_router.dart';
import 'package:mui/mui.dart';

import '../data/daily_notes_store.dart';

/// Soft-deleted preview entities stay recoverable. No permanent deletion here.
class DailyNotesRecyclePage extends StatelessWidget {
  final DailyNotesStore store;
  const DailyNotesRecyclePage({super.key, required this.store});

  @override
  Widget build(BuildContext context) {
    final text = context.l10n.dailynotesNavigation;
    Future<void> restore(Future<void> Function() action) async {
      try {
        await action();
      } catch (error) {
        if (!context.mounted) return;
        await showDialog<void>(
          context: context,
          builder: (_) => AlertDialog(
            title: Text(text.restoreFailed),
            content: SelectableText(error.toString()),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(context),
                child: Text(context.l10n.common.cancel),
              ),
            ],
          ),
        );
      }
    }

    Widget deleted(String title, String kind, Future<void> Function() action) =>
        ListTile(
          title: Text(title.isEmpty ? text.untitled : title),
          subtitle: Text(kind),
          trailing: TextButton(
            onPressed: () => restore(action),
            child: Text(text.restore),
          ),
        );
    return Scaffold(
      appBar: AppBar(title: Text(text.recycle)),
      body: ListenableBuilder(
        listenable: store,
        builder: (context, _) => ListView(
          padding: const EdgeInsets.all(12),
          children: [
            Card.filled(
              child: ListTile(
                leading: const Icon(LucideIcons.bookText),
                title: Text(text.diaryRecycle),
                trailing: const Icon(LucideIcons.chevronRight),
                onTap: () => const RecycleRoute().push(context),
              ),
            ),
            const SizedBox(height: 10),
            Text(
              text.recycleScope,
              style: context.theme.typography.bodySmall.onSurfaceVariant,
            ),
            if (store.deletedNotes.isEmpty &&
                store.deletedTasks.isEmpty &&
                store.deletedTopics.isEmpty)
              Padding(
                padding: const EdgeInsets.all(24),
                child: Center(child: Text(text.recycleEmpty)),
              ),
            for (final note in store.deletedNotes)
              deleted(note.title, text.notes, () => store.restoreNote(note.id)),
            for (final task in store.deletedTasks)
              deleted(task.title, text.tasks, () => store.restoreTask(task.id)),
            for (final topic in store.deletedTopics)
              deleted(
                topic.title,
                text.topics,
                () => store.restoreTopic(topic.id),
              ),
          ],
        ),
      ),
    );
  }
}
