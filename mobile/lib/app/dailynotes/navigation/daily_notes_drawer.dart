import 'package:moodiary_diary/moodiary_diary.dart'
    show CategoryDrawer, ViewModeSheet;
import 'package:moodiary_i18n/moodiary_i18n.dart';
import 'package:moodiary_mobile/app/settings/setting_routes.dart';
import 'package:moodiary_router/moodiary_router.dart';
import 'package:mui/mui.dart';

import '../data/daily_notes_store.dart';
import 'daily_notes_archive_page.dart';
import 'daily_notes_health_page.dart';
import 'daily_notes_profile_page.dart';

class DailyNotesDrawer extends StatelessWidget {
  final DailyNotesStore store;

  const DailyNotesDrawer({super.key, required this.store});

  @override
  Widget build(BuildContext context) {
    final text = context.l10n.dailynotesNavigation;
    void open(Widget page) {
      final navigator = Navigator.of(context);
      navigator.pop();
      navigator.push(MaterialPageRoute<void>(builder: (_) => page));
    }

    void route(MoodiaryRouteBase destination) {
      Navigator.of(context).pop();
      destination.push(context);
    }

    Widget item(String label, IconData icon, VoidCallback action) => ListTile(
      dense: true,
      leading: Icon(icon, size: 21),
      title: Text(label),
      onTap: action,
    );
    void pending(String title) => open(DailyNotesPendingPage(title: title));

    return Drawer(
      width: MediaQuery.sizeOf(context).width * .75,
      child: SafeArea(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(24, 22, 20, 16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    'DailyNotes',
                    style: context
                        .theme
                        .typography
                        .titleLarge
                        .emphasized
                        .onSurface,
                  ),
                  const SizedBox(height: 4),
                  Text(
                    text.preview,
                    style:
                        context.theme.typography.labelMedium.onSurfaceVariant,
                  ),
                ],
              ),
            ),
            Expanded(
              child: ListView(
                padding: const EdgeInsets.symmetric(horizontal: 8),
                children: [
                  item(
                    text.profile,
                    LucideIcons.circleUser,
                    () => open(DailyNotesProfilePage(store: store)),
                  ),
                  item(
                    text.sync,
                    LucideIcons.refreshCw,
                    () => route(const BackupSyncRoute()),
                  ),
                  item(text.customize, LucideIcons.palette, () {
                    Navigator.of(context).pop();
                    showModalBottomSheet<void>(
                      context: context,
                      builder: (sheetContext) => SafeArea(
                        child: Column(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            ListTile(
                              leading: const Icon(LucideIcons.palette),
                              title: Text(text.customize),
                              onTap: () {
                                Navigator.of(sheetContext).pop();
                                const AccentRoute().push(context);
                              },
                            ),
                            ListTile(
                              leading: const Icon(LucideIcons.layoutList),
                              title: Text(text.diaryViewMode),
                              onTap: () {
                                Navigator.of(sheetContext).pop();
                                ViewModeSheet.show(context);
                              },
                            ),
                          ],
                        ),
                      ),
                    );
                  }),
                  item(text.categories, LucideIcons.folders, () {
                    final navigator = Navigator.of(context);
                    navigator.pop();
                    showModalBottomSheet<void>(
                      context: context,
                      builder: (sheetContext) => SafeArea(
                        child: Column(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            ListTile(
                              leading: const Icon(LucideIcons.listFilter),
                              title: Text(text.categoryFilter),
                              onTap: () {
                                Navigator.of(sheetContext).pop();
                                showModalBottomSheet<void>(
                                  context: context,
                                  isScrollControlled: true,
                                  builder: (_) => SizedBox(
                                    height:
                                        MediaQuery.sizeOf(context).height * .8,
                                    child: const CategoryDrawer(),
                                  ),
                                );
                              },
                            ),
                            ListTile(
                              leading: const Icon(LucideIcons.folders),
                              title: Text(text.categories),
                              onTap: () {
                                Navigator.of(sheetContext).pop();
                                const CategoryManagerRoute().push(context);
                              },
                            ),
                          ],
                        ),
                      ),
                    );
                  }),
                  item(
                    text.archive,
                    LucideIcons.archive,
                    () => open(DailyNotesArchivePage(store: store)),
                  ),
                  item(
                    text.calendar,
                    LucideIcons.calendarDays,
                    () => route(const CalendarRoute()),
                  ),
                  item(
                    text.health,
                    LucideIcons.heartPulse,
                    () => open(DailyNotesHealthPage(store: store)),
                  ),
                  item(
                    text.recent,
                    LucideIcons.history,
                    () => pending(text.recent),
                  ),
                  item(
                    text.privacy,
                    LucideIcons.shield,
                    () => route(const SettingRoute()),
                  ),
                  item(
                    text.importExport,
                    LucideIcons.fileOutput,
                    () => route(const ExportRoute()),
                  ),
                ],
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 6, 20, 10),
              child: Text(
                text.localOnlyWarning,
                style: context.theme.typography.labelSmall.onSurfaceVariant,
              ),
            ),
            const Divider(height: 1),
            Padding(
              padding: const EdgeInsets.fromLTRB(8, 4, 8, 8),
              child: item(
                text.settings,
                LucideIcons.settings,
                () => route(const SettingRoute()),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class DailyNotesPendingPage extends StatelessWidget {
  final String title;
  const DailyNotesPendingPage({super.key, required this.title});

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: Text(title)),
    body: Padding(
      padding: const EdgeInsets.all(24),
      child: Text(context.l10n.dailynotesNavigation.planned),
    ),
  );
}
