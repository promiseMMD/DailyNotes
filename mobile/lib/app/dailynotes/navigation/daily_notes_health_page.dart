import 'package:moodiary_i18n/moodiary_i18n.dart';
import 'package:mui/mui.dart';

import '../data/daily_notes_store.dart';

/// Explicit, read-only local inspection. Never repairs or clears stored data.
class DailyNotesHealthPage extends StatefulWidget {
  final DailyNotesStore store;
  const DailyNotesHealthPage({super.key, required this.store});

  @override
  State<DailyNotesHealthPage> createState() => _DailyNotesHealthPageState();
}

class _DailyNotesHealthPageState extends State<DailyNotesHealthPage> {
  Future<List<String>>? _check;
  DateTime? _checkedAt;

  Future<List<String>> _run() async {
    final rows = await widget.store.database
        .customSelect('PRAGMA quick_check')
        .get();
    final result = rows.map((r) => r.data.values.first.toString()).toList();
    if (mounted) setState(() => _checkedAt = DateTime.now());
    return result;
  }

  @override
  Widget build(BuildContext context) {
    final text = context.l10n.dailynotesNavigation;
    return Scaffold(
      appBar: AppBar(title: Text(text.health)),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          Text(
            text.readOnlyCheck,
            style: context.theme.typography.bodyMedium.onSurfaceVariant,
          ),
          const SizedBox(height: 12),
          FutureBuilder<List<String>>(
            future: _check,
            builder: (context, result) {
              final status = result.connectionState == ConnectionState.waiting
                  ? text.checking
                  : result.hasError
                  ? text.checkFailed
                  : result.hasData
                  ? (result.data!.isNotEmpty &&
                            result.data!.every((r) => r == 'ok')
                        ? text.quickCheckPassed
                        : text.checkFailed)
                  : text.notChecked;
              return Card.filled(
                child: ListTile(
                  leading: const Icon(LucideIcons.database),
                  title: Text(text.localDatabase),
                  subtitle: Text(status),
                  onTap: () => showDialog<void>(
                    context: context,
                    builder: (_) => AlertDialog(
                      title: Text(text.localDatabase),
                      content: SelectableText(
                        [
                          status,
                          text.databaseScope,
                          if (_checkedAt != null)
                            _checkedAt!.toLocal().toString(),
                          if (result.hasError) result.error.toString(),
                          if (result.hasData) ...result.data!,
                        ].join('\n\n'),
                      ),
                      actions: [
                        TextButton(
                          onPressed: () => Navigator.pop(context),
                          child: Text(context.l10n.common.cancel),
                        ),
                      ],
                    ),
                  ),
                ),
              );
            },
          ),
          for (final label in [
            text.attachments,
            text.backups,
            text.syncConsistency,
          ])
            Card.filled(
              child: ListTile(
                leading: const Icon(LucideIcons.circleHelp),
                title: Text(label),
                subtitle: Text(text.unverified),
                onTap: () => showDialog<void>(
                  context: context,
                  builder: (_) => AlertDialog(
                    title: Text(label),
                    content: Text(text.unverifiedDetail),
                    actions: [
                      TextButton(
                        onPressed: () => Navigator.pop(context),
                        child: Text(context.l10n.common.cancel),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          const SizedBox(height: 12),
          FilledButton.icon(
            onPressed: () => setState(() => _check = _run()),
            icon: const Icon(LucideIcons.scanLine),
            label: Text(text.runLocalCheck),
          ),
          const SizedBox(height: 8),
          Text(
            text.healthLimits,
            style: context.theme.typography.bodySmall.onSurfaceVariant,
          ),
        ],
      ),
    );
  }
}
