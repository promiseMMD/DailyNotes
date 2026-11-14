import 'package:moodiary_data/moodiary_data.dart';
import 'package:moodiary_di/moodiary_di.dart';
import 'package:moodiary_i18n/moodiary_i18n.dart';
import 'package:moodiary_mobile/app/home/mod_continuous.dart';
import 'package:moodiary_mobile/app/me/me_page.dart';
import 'package:moodiary_router/moodiary_router.dart';
import 'package:moodiary_utils/moodiary_utils.dart';
import 'package:mui/mui.dart';

import '../data/daily_notes_store.dart';
import 'daily_notes_health_page.dart';
import 'daily_notes_recycle_page.dart';

class DailyNotesProfilePage extends StatefulWidget {
  final DailyNotesStore store;
  const DailyNotesProfilePage({super.key, required this.store});

  @override
  State<DailyNotesProfilePage> createState() => _DailyNotesProfilePageState();
}

class _ProfileStats {
  final int diaryCount;
  final int diaryWords;
  final int longCount;
  final int longWords;
  final Set<DateTime> writingDays;

  const _ProfileStats({
    required this.diaryCount,
    required this.diaryWords,
    required this.longCount,
    required this.longWords,
    required this.writingDays,
  });
}

class _DailyNotesProfilePageState extends State<DailyNotesProfilePage> {
  late Future<_ProfileStats> _stats = _load();
  bool _expandedWords = false;

  Future<_ProfileStats> _load() async {
    final diaries = (await getIt<DiaryRepository>().getAllDiaries())
        .where((d) => d.show)
        .toList();
    final ordinary = diaries.where((d) => !ModDiary.hideFromOrdinaryList(d));
    final children = diaries.where(ModDiary.isChild);
    // Ambiguous current heads cannot produce trustworthy word statistics.
    final conflicts = await widget.store.database
        .customSelect(
          'SELECT block_id FROM mod_month_heads GROUP BY block_id HAVING COUNT(*) > 1 LIMIT 1',
        )
        .get();
    if (conflicts.isNotEmpty) {
      throw StateError(
        'Unresolved long-record revisions prevent reliable statistics',
      );
    }
    // Read only current, live monthly revisions, retaining all original rows.
    final blocks = await widget.store.database.customSelect('''
SELECT r.body_json, r.occurred_at_ms
FROM mod_month_heads h
JOIN mod_month_revisions r ON r.revision_id = h.revision_id
JOIN mod_month_blocks b ON b.block_id = h.block_id
JOIN diaries d ON d.id = b.topic_id
WHERE r.deleted = 0 AND d.show = 1
''').get();
    final days = <DateTime>{};
    void addDay(DateTime date) {
      final local = date.toLocal();
      days.add(DateTime(local.year, local.month, local.day));
    }

    for (final diary in ordinary) {
      addDay(diary.time);
    }
    for (final entry in children) {
      addDay(entry.time);
    }
    var monthWords = 0;
    for (final block in blocks) {
      monthWords += TiptapContent.countCharacters(
        TiptapContent.parse(block.read<String>('body_json')).plainText,
      );
      addDay(
        DateTime.fromMillisecondsSinceEpoch(
          block.read<int>('occurred_at_ms'),
          isUtc: true,
        ),
      );
    }
    return _ProfileStats(
      diaryCount: ordinary.length,
      diaryWords: ordinary.fold(
        0,
        (sum, d) => sum + TiptapContent.countCharacters(d.contentText),
      ),
      longCount: diaries.where(ModDiary.isTopic).length,
      longWords:
          children.fold<int>(
            0,
            (sum, d) => sum + TiptapContent.countCharacters(d.contentText),
          ) +
          monthWords,
      writingDays: days,
    );
  }

  @override
  Widget build(BuildContext context) {
    final text = context.l10n.dailynotesNavigation;
    return Scaffold(
      appBar: AppBar(
        title: Text(text.profile),
        actions: [
          IconButton(
            tooltip: text.refresh,
            icon: const Icon(LucideIcons.refreshCw),
            onPressed: () => setState(() => _stats = _load()),
          ),
        ],
      ),
      body: ListenableBuilder(
        listenable: widget.store,
        builder: (context, _) => FutureBuilder<_ProfileStats>(
          future: _stats,
          builder: (context, result) {
            final stats = result.data;
            final notes = widget.store.notes;
            final noteWords = notes.fold<int>(
              0,
              (sum, note) => sum + TiptapContent.countCharacters(note.body),
            );
            final totalWords = stats == null
                ? null
                : stats.diaryWords + stats.longWords + noteWords;
            return ListView(
              padding: const EdgeInsets.fromLTRB(16, 8, 16, 28),
              children: [
                Text(
                  text.footprint,
                  style:
                      context.theme.typography.titleMedium.emphasized.onSurface,
                ),
                const SizedBox(height: 10),
                if (result.hasError)
                  Card.filled(
                    child: Padding(
                      padding: const EdgeInsets.all(16),
                      child: Text('${text.statsUnavailable}\n${result.error}'),
                    ),
                  )
                else if (stats == null)
                  const Center(
                    child: Padding(
                      padding: EdgeInsets.all(24),
                      child: CircularProgressIndicator(),
                    ),
                  )
                else ...[
                  _WritingHeatmap(days: stats.writingDays),
                  const SizedBox(height: 6),
                  Text(
                    text.heatmapScope,
                    style: context.theme.typography.bodySmall.onSurfaceVariant,
                  ),
                ],
                const SizedBox(height: 18),
                Card.filled(
                  child: Column(
                    children: [
                      ListTile(
                        leading: const Icon(LucideIcons.text),
                        title: Text(text.totalWords),
                        subtitle: Text(
                          totalWords?.toString() ?? text.notAvailable,
                        ),
                        trailing: Icon(
                          _expandedWords
                              ? LucideIcons.chevronUp
                              : LucideIcons.chevronDown,
                        ),
                        onTap: () =>
                            setState(() => _expandedWords = !_expandedWords),
                      ),
                      if (_expandedWords) ...[
                        _count(text.diaryWords, stats?.diaryWords),
                        _count(text.noteWords, noteWords),
                        _count(text.longWords, stats?.longWords),
                      ],
                    ],
                  ),
                ),
                const SizedBox(height: 8),
                Card.filled(
                  child: Column(
                    children: [
                      _count(text.diaries, stats?.diaryCount),
                      _count(text.notes, notes.length),
                      _count(text.longRecords, stats?.longCount),
                      _count(text.topics, widget.store.topics.length),
                      _count(text.tasks, widget.store.tasks.length),
                      _count(
                        text.tasksCompleted,
                        widget.store.tasks
                            .where((task) => task.completed)
                            .length,
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 12),
                Text(
                  text.reviewPending,
                  style: context.theme.typography.bodySmall.onSurfaceVariant,
                ),
                const SizedBox(height: 16),
                Card.filled(
                  child: Column(
                    children: [
                      ListTile(
                        leading: const Icon(LucideIcons.trash2),
                        title: Text(text.recycle),
                        trailing: const Icon(LucideIcons.chevronRight),
                        onTap: () => Navigator.of(context).push(
                          MaterialPageRoute<void>(
                            builder: (_) =>
                                DailyNotesRecyclePage(store: widget.store),
                          ),
                        ),
                      ),
                      ListTile(
                        leading: const Icon(LucideIcons.heartPulse),
                        title: Text(text.health),
                        trailing: const Icon(LucideIcons.chevronRight),
                        onTap: () => Navigator.of(context).push(
                          MaterialPageRoute<void>(
                            builder: (_) =>
                                DailyNotesHealthPage(store: widget.store),
                          ),
                        ),
                      ),
                      ListTile(
                        leading: const Icon(LucideIcons.chartNoAxesCombined),
                        title: Text(text.originalReview),
                        trailing: const Icon(LucideIcons.chevronRight),
                        onTap: () => Navigator.of(context).push(
                          MaterialPageRoute<void>(
                            builder: (_) => const MePage(),
                          ),
                        ),
                      ),
                      ListTile(
                        leading: const Icon(LucideIcons.images),
                        title: Text(context.l10n.media.title),
                        trailing: const Icon(LucideIcons.chevronRight),
                        onTap: () => const MediaRoute().push(context),
                      ),
                    ],
                  ),
                ),
              ],
            );
          },
        ),
      ),
    );
  }

  Widget _count(String label, int? count) => ListTile(
    dense: true,
    title: Text(label),
    trailing: Text(
      count?.toString() ?? context.l10n.dailynotesNavigation.notAvailable,
    ),
  );
}

class _WritingHeatmap extends StatelessWidget {
  final Set<DateTime> days;
  const _WritingHeatmap({required this.days});

  @override
  Widget build(BuildContext context) {
    final now = DateTime.now();
    final today = DateTime(now.year, now.month, now.day);
    final colors = context.theme.colors;
    return Wrap(
      spacing: 4,
      runSpacing: 4,
      children: [
        for (var index = 83; index >= 0; index--)
          Builder(
            builder: (context) {
              final day = DateTime(today.year, today.month, today.day - index);
              final written = days.contains(day);
              return Tooltip(
                message:
                    '${day.year}-${day.month.toString().padLeft(2, '0')}-${day.day.toString().padLeft(2, '0')}',
                child: Container(
                  width: 17,
                  height: 17,
                  decoration: BoxDecoration(
                    color: written
                        ? colors.primary
                        : colors.surfaceContainerHighest,
                    borderRadius: BorderRadius.circular(4),
                  ),
                ),
              );
            },
          ),
      ],
    );
  }
}
