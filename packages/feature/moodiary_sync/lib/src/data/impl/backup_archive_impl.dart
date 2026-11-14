import 'package:injectable/injectable.dart';
import 'package:moodiary_data/moodiary_data.dart';
import 'package:moodiary_di/moodiary_di.dart';

import '../archive_apply.dart';
import '../mod_month_full_backup_archive_v1.dart';
import '../mod_month_verified_manifest_v2.dart';
import '../mod_month_zip_preflight_v2.dart';
import 'local_archive.dart';

@LazySingleton(as: IBackupArchive)
class SyncBackupArchive implements IBackupArchive {
  const SyncBackupArchive();

  @override
  Future<String> export() => ModMonthFullBackupArchiveV1.export(
    db: getIt<MoodiaryDatabase>(),
  );

  @override
  Future<BackupImportResult> import(String zipPath) async {
    // Existing ordinary backup ZIPs must remain importable. A ZIP with an
    // incomplete V2 history marker is rejected instead of being downgraded.
    // The legacy branch preserves the upstream RestorePolicy exactly.
    final names = await ModMonthZipPreflightV2.inspectForBackupRouting(zipPath);
    final fullHistory =
        ModMonthZipPreflightV2.hasCompleteFullHistoryMarkers(names);
    final report = fullHistory
        ? await ModMonthFullBackupArchiveV1.importZip(
            zipPath: zipPath,
            db: getIt<MoodiaryDatabase>(),
          )
        : await LocalArchive.import(
            zipPath,
            // Preserve original metadata only for first import into an empty
            // modded app. Never change ordinary nonempty backup restore.
            policy: await ModMonthFullBackupArchiveV1.originalImportPolicyFor(
              getIt<MoodiaryDatabase>(),
            ),
          );
    return BackupImportResult(
      diaryCount: report.pulled.diaries,
      categoryCount: report.pulled.categories,
      mediaCount: report.pulled.mediaFiles,
      failed: report.failed,
      cancelled: report.cancelled,
      skipped: report.skipped,
    );
  }
}
