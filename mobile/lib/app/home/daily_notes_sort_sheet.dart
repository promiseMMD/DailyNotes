import 'package:moodiary_i18n/moodiary_i18n.dart';
import 'package:moodiary_models/moodiary_models.dart';
import 'package:moodiary_storage/moodiary_storage.dart';
import 'package:mui/mui.dart';

/// Changes only the ordinary diary order; pinned long records have their own
/// stable ranking and are deliberately not rewritten here (DN-166).
Future<void> showDailyNotesDiarySort(BuildContext context) => MSheet.show<void>(
  context,
  builder: (context) => MSheetScaffold<void>(
    title: context.l10n.diary.sortTitle,
    icon: LucideIcons.arrowDownUp,
    child: ValueListenableBuilder<int>(
      valueListenable: MoodiaryKVs.homeSortMode.getNotifier(),
      builder: (context, selected, _) => Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          for (final sort in [DiarySort.timeDesc, DiarySort.timeAsc])
            MSheetOptionTile<int>(
              option: MSheetOption(
                value: sort.number,
                label: sort == DiarySort.timeDesc
                    ? context.l10n.diary.sortNewestFirst
                    : context.l10n.diary.sortOldestFirst,
                icon: sort == DiarySort.timeDesc
                    ? LucideIcons.arrowDown
                    : LucideIcons.arrowUp,
              ),
              selected: selected == sort.number,
              onTap: () {
                MoodiaryKVs.homeSortMode.set(sort.number);
                Navigator.of(context).pop();
              },
            ),
        ],
      ),
    ),
  ),
);
