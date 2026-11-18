import 'dart:async';

import 'package:fast_image/fast_image.dart';
import 'package:moodiary_data/moodiary_data.dart';
import 'package:moodiary_di/moodiary_di.dart';
import 'package:moodiary_editor/moodiary_editor.dart'
    show EditorMigrationService, resolveEditorPage;
import 'package:moodiary_files/moodiary_files.dart';
import 'package:moodiary_logging/moodiary_logging.dart';
import 'package:moodiary_migration/moodiary_migration.dart'
    show EngineMigrationService;
import 'package:moodiary_ml/moodiary_ml.dart' show EmbeddingModelManager;
import 'package:moodiary_platform/moodiary_platform.dart';
import 'package:moodiary_storage/moodiary_storage.dart';
import 'package:moodiary_sync/moodiary_sync.dart';

Future<void> bootstrapPlatform() async {
  await PlatformService.get().init();
  await AppFiles.initCreateDir();
  FastImageRuntime.configure(
    imageDir: AppFiles.imageDir,
    thumbDir: AppFiles.imageThumbDir,
    log: logger.d,
  );
  AppLogger.configure(logFilePath: AppFiles.getErrorLogPath());
}

void runStartupMaintenance() {
  unawaited(resolveEditorPage());
  unawaited(purgeExpiredTombstones());
  unawaited(purgeSyncMediaTemp());
  unawaited(getIt<EmbedIndexService>().drain());
  getIt<EmbedQueueWatcher>().start();
}

Future<void> resetAllData() async {
  final failed = <String>[];
  Future<void> step(String name, Future<void> Function() run) async {
    try {
      await run();
    } catch (e, s) {
      logger.e('resetAllData: $name failed', error: e, stackTrace: s);
      failed.add(name);
    }
  }

  // Never fall back to deleting database files after an error: the failed
  // database may contain revisions that cannot be inspected or reconstructed.
  final db = getIt.maybeGet<MoodiaryDatabase>();
  if (db == null) {
    throw StateError('Reset blocked: cannot verify protected history.');
  }
  await db.clearAll();
  await step('kv.clear', () async => getIt.maybeGet<IKVStorage>()?.clear());
  await Future.wait([
    step('secureKv.clear', () async {
      await getIt.maybeGet<ISecureKVStorage>()?.clear();
    }),
    step('legacyPrefs.clear', LegacyPrefsKVSource.clearStore),
    step('media.reset', AppFiles.resetUserMediaDirs),
    step('cache.clear', () => AppFiles.clearCache(protectWorkspaces: false)),
    step(
      'editorBackups.delete',
      () => AppFiles.deleteDir(EditorMigrationService.backupDirPath),
    ),
    step(
      'models.delete',
      () => AppFiles.deleteDir(EmbeddingModelManager.modelsDirPath),
    ),
    step(
      'isarBackup.delete',
      () => AppFiles.deleteFile(
        AppFiles.getRealPath('database', 'default.isar.v273bak'),
      ),
    ),
    step(
      'isar.delete',
      () =>
          AppFiles.deleteFile(AppFiles.getRealPath('database', 'default.isar')),
    ),
    step(
      'legacyBackup.delete',
      () => AppFiles.deleteFile(
        AppFiles.getRealPath(
          'database',
          EngineMigrationService.legacyBackupFileName,
        ),
      ),
    ),
  ]);
  if (failed.isNotEmpty) {
    throw StateError('resetAllData: ${failed.join(', ')} failed');
  }
}
