import 'package:material_ui/material_ui.dart';

import '../experimental/local_journal_spike.dart';
import 'soft_components.dart';

/// The source stores UTC timestamps; dates shown to the user use device time.
DateTime? previewLocalDate(DiaryVersion entry) =>
    DateTime.tryParse(entry.savedUtc)?.toLocal();

String previewDateLabel(DateTime date) =>
    '${date.year}年${date.month}月${date.day}日';

bool previewSameDate(DateTime a, DateTime b) =>
    a.year == b.year && a.month == b.month && a.day == b.day;

class PreviewDiaryEntryRow extends StatelessWidget {
  const PreviewDiaryEntryRow({
    required this.entry,
    required this.onOpen,
    super.key,
  });

  final DiaryVersion entry;
  final VoidCallback onOpen;

  @override
  Widget build(BuildContext context) {
    final date = previewLocalDate(entry);
    final text = entry.body.trim();
    final firstLine = text.split('\n').first;
    return InkWell(
      key: Key('preview-diary-${entry.entityId}'),
      onTap: onOpen,
      borderRadius: BorderRadius.circular(9),
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 13),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    firstLine,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                      color: previewInk,
                      fontSize: 14,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  if (text != firstLine) ...[
                    const SizedBox(height: 6),
                    Text(
                      text.substring(firstLine.length).trim(),
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        color: previewMuted, fontSize: 12, height: 1.5,
                      ),
                    ),
                  ],
                  const SizedBox(height: 8),
                  Text(
                    date == null
                        ? '本机测试记录 · 时间未知'
                        : '本机测试记录 · ${date.hour.toString().padLeft(2, '0')}:${date.minute.toString().padLeft(2, '0')} · 版本 ${entry.revision}',
                    style: const TextStyle(color: previewMuted, fontSize: 10),
                  ),
                ],
              ),
            ),
            const SizedBox(width: 8),
            const Icon(Icons.chevron_right, color: previewMuted, size: 19),
          ],
        ),
      ),
    );
  }
}

/// The independent calendar reads the *same* committed diary list.
/// No fake diary counts and no writes/backup happen here.
class PreviewDiaryCalendarPage extends StatefulWidget {
  const PreviewDiaryCalendarPage({required this.entries, super.key});

  final List<DiaryVersion> entries;

  @override
  State<PreviewDiaryCalendarPage> createState() =>
      _PreviewDiaryCalendarPageState();
}

class _PreviewDiaryCalendarPageState extends State<PreviewDiaryCalendarPage> {
  Future<void> _pick() async {
    // Only committed local-test dates are selectable. A blank date used to
    // silently return an empty diary list, which looked like lost records.
    final available = <DateTime>{};
    for (final entry in widget.entries) {
      final date = previewLocalDate(entry);
      if (date != null) {
        available.add(DateTime(date.year, date.month, date.day));
      }
    }
    if (available.isEmpty) return;
    final sorted = available.toList()..sort();
    final selected = await showDatePicker(
      context: context,
      initialDate: sorted.last,
      firstDate: sorted.first,
      lastDate: sorted.last,
      selectableDayPredicate: available.contains,
      helpText: '选择有测试日记的日期',
    );
    if (mounted && selected != null) {
      Navigator.of(context).pop(selected);
    }
  }

  @override
  Widget build(BuildContext context) {
    final dates = <DateTime, int>{};
    for (final entry in widget.entries) {
      final date = previewLocalDate(entry);
      if (date == null) continue;
      final day = DateTime(date.year, date.month, date.day);
      dates.update(day, (count) => count + 1, ifAbsent: () => 1);
    }
    final ordered = dates.keys.toList()
      ..sort((a, b) => b.compareTo(a));
    return Scaffold(
      appBar: AppBar(
        title: const Text('日历总览 · 测试数据'),
        actions: [
          IconButton(
            tooltip: '选择日期',
            icon: const Icon(Icons.calendar_month_outlined),
            onPressed: widget.entries.any((entry) => previewLocalDate(entry) != null) ? _pick : null,
          ),
        ],
      ),
      body: ListView(
        key: const Key('preview-diary-calendar'),
        padding: const EdgeInsets.fromLTRB(21, 0, 21, 30),
        children: [
          const PreviewPageIntro(
            kicker: 'CALENDAR · PREVIEW',
            title: '按日期找回记录',
            subtitle: '仅列出本地测试数据库中实际保存的日记。',
          ),
          if (ordered.isEmpty)
            const PreviewEmptyState(
              icon: Icons.calendar_today_outlined,
              title: '暂无测试日记日期',
              description: '创建测试日记后，日期才会出现在这里。',
            ),
          for (final date in ordered) ...[
            ListTile(
              key: Key('preview-calendar-${date.year}-${date.month}-${date.day}'),
              contentPadding: EdgeInsets.zero,
              title: Text(previewDateLabel(date)),
              subtitle: Text('本地测试日记 ${dates[date]} 篇'),
              trailing: const Icon(Icons.chevron_right),
              onTap: () => Navigator.of(context).pop(date),
            ),
            const PreviewThinDivider(),
          ],
        ],
      ),
    );
  }
}
