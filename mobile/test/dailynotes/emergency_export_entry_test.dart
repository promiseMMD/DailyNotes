import 'dart:convert';
import 'dart:typed_data';

import 'package:appflowy_editor/appflowy_editor.dart' as af;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:moodiary_data/moodiary_data.dart';
import 'package:moodiary_di/moodiary_di.dart';
import 'package:moodiary_i18n/moodiary_i18n.dart';
import 'package:moodiary_mobile/app/dailynotes/data/daily_notes_store.dart';
import 'package:moodiary_mobile/app/dailynotes/diary/rich_diary_page.dart';
import 'package:moodiary_mobile/app/dailynotes/notes/rich_note_editor_page.dart';
import 'package:moodiary_mobile/app/dailynotes/recovery/emergency_document_exporter.dart';
import 'package:moodiary_mobile/app/dailynotes/recovery/emergency_note_export.dart';
import 'package:moodiary_mobile/app/home/mod_month_composer.dart';
import 'package:moodiary_mobile/app/home/mod_month_native.dart';
import 'package:moodiary_mobile/app/home/mod_month_store.dart';
import 'package:moodiary_models/moodiary_models.dart';
import 'package:moodiary_storage/moodiary_storage.dart';
import 'package:moodiary_storage/testing.dart';
import 'package:mui/mui.dart';

class _FailingDiaryRepository extends DiaryRepository {
  _FailingDiaryRepository(super.database);

  @override
  Future<bool> insertADiaryIfAbsent(Diary diary) =>
      Future.error(StateError('disk'));
}

class _FailingDraftStore extends DailyNotesStore {
  _FailingDraftStore(super.database);

  @override
  Future<void> saveDraft(String key, Map<String, Object?> payload) =>
      Future.error(StateError('disk'));
}

Widget _app(Widget page) => TranslationProvider(
  child: MaterialApp(
    theme: buildMuiTheme(brightness: Brightness.light),
    localizationsDelegates: const [
      af.AppFlowyEditorLocalizations.delegate,
      ...GlobalMaterialLocalizations.delegates,
      GlobalMuiLocalizations.delegate,
    ],
    // This mirrors the current app composition root.
    // ignore: deprecated_member_use
    builder: (context, child) => MaterialUiCompatibilityBridge(child: child!),
    home: page,
  ),
);

Future<void> _password(WidgetTester tester) async {
  await tester.pumpAndSettle();
  await tester.enterText(
    find.byKey(const ValueKey('emergency-password')),
    'secret',
  );
  await tester.enterText(
    find.byKey(const ValueKey('emergency-password-confirmation')),
    'secret',
  );
  await tester.tap(find.text(l10n.dailynotes.confirm).last);
  await tester.pumpAndSettle();
}

void main() {
  setUpAll(() async {
    getIt.registerSingleton<IKVStorage>(MemoryKVStorage());
    await setupPluralResolvers();
    await LocaleSettings.setLocale(AppLocale.zh);
  });
  tearDownAll(() => getIt.reset());

  testWidgets('failed note export uses the actual rich editor buffer', (
    tester,
  ) async {
    final db = MoodiaryDatabase.forTesting(NativeDatabase.memory());
    final store = DailyNotesStore(
      db,
      beforeOutboxWrite: () async => throw StateError('disk'),
    );
    await store.open();
    EmergencyNoteSnapshot? saved;
    final exporter = EmergencyDocumentExporter(
      createArchive: (snapshot, _) async {
        saved = snapshot;
        return Uint8List.fromList([1]);
      },
      saveArchive: (_) async => Uri.parse('content://note'),
    );
    await tester.binding.setSurfaceSize(const Size(430, 900));
    addTearDown(() async {
      await tester.pumpWidget(const SizedBox());
      store.dispose();
      await db.close();
      await tester.binding.setSurfaceSize(null);
    });
    await tester.pumpWidget(
      _app(RichNoteEditorPage(store: store, testEmergencyExporter: exporter)),
    );
    await tester.pumpAndSettle();
    final editor = tester
        .widget<af.AppFlowyEditor>(find.byType(af.AppFlowyEditor))
        .editorState;
    await editor.insertText(0, '当前笔记', path: [0]);
    await tester.pump(const Duration(milliseconds: 700));
    await tester.pumpAndSettle();
    expect(store.notes, isEmpty);
    await tester.tap(find.byKey(const ValueKey('note-emergency-export')));
    await _password(tester);
    expect(saved?.kind, EmergencyRecordKind.note);
    expect(saved?.body, '当前笔记');
    expect(
      jsonDecode(saved!.documentJson!)['document']['children'].toString(),
      contains('当前笔记'),
    );
    expect(
      find.text(l10n.dailynotes.richEmergencyExportPartial),
      findsOneWidget,
    );
    expect(store.notes, isEmpty);
    expect(editor.document.toJson().toString(), contains('当前笔记'));
  });

  testWidgets('failed diary export preserves unsaved text and the exit guard', (
    tester,
  ) async {
    final db = MoodiaryDatabase.forTesting(NativeDatabase.memory());
    final repository = _FailingDiaryRepository(db);
    EmergencyNoteSnapshot? saved;
    final exporter = EmergencyDocumentExporter(
      createArchive: (snapshot, _) async {
        saved = snapshot;
        return Uint8List.fromList([1]);
      },
      saveArchive: (_) async => Uri.parse('content://diary'),
    );
    await tester.binding.setSurfaceSize(const Size(430, 900));
    addTearDown(() async {
      await tester.pumpWidget(const SizedBox());
      await db.close();
      await tester.binding.setSurfaceSize(null);
    });
    await tester.pumpWidget(
      _app(
        RichDiaryPage(repository: repository, testEmergencyExporter: exporter),
      ),
    );
    await tester.pumpAndSettle();
    final editor = tester
        .widget<af.AppFlowyEditor>(find.byType(af.AppFlowyEditor))
        .editorState;
    await editor.insertText(0, '当前日记', path: [0]);
    await tester.pump(const Duration(milliseconds: 700));
    await tester.pumpAndSettle();
    expect(await repository.getAllDiaries(), isEmpty);
    await tester.tap(find.byKey(const ValueKey('diary-emergency-export')));
    await _password(tester);
    expect(saved?.kind, EmergencyRecordKind.diary);
    expect(saved?.body, '当前日记');
    expect(saved?.metadata['diaryId'], isNotNull);
    expect(saved?.metadata['dateTime'], isNotNull);
    expect(saved?.documentJson, contains('当前日记'));
    expect(await repository.getAllDiaries(), isEmpty);
    await tester.tap(find.byIcon(LucideIcons.arrowLeft).first);
    await tester.pumpAndSettle();
    expect(find.text(l10n.dailynotes.unsavedExitTitle), findsOneWidget);
    expect(find.text(l10n.dailynotes.emergencyExport), findsOneWidget);
    expect(editor.document.toJson().toString(), contains('当前日记'));
  });

  testWidgets('long-record export preserves a draft without submitting it', (
    tester,
  ) async {
    final db = MoodiaryDatabase.forTesting(NativeDatabase.memory());
    final drafts = _FailingDraftStore(db);
    await drafts.open();
    final store = ModMonthStore(db);
    final repository = ModNativeMonthRepository(
      store: store,
      diaries: DiaryRepository(db),
    );
    EmergencyNoteSnapshot? saved;
    final exporter = EmergencyDocumentExporter(
      createArchive: (snapshot, _) async {
        saved = snapshot;
        return Uint8List.fromList([1]);
      },
      saveArchive: (_) async => Uri.parse('content://long-record'),
    );
    await tester.binding.setSurfaceSize(const Size(430, 900));
    addTearDown(() async {
      await tester.pumpWidget(const SizedBox());
      drafts.dispose();
      await db.close();
      await tester.binding.setSurfaceSize(null);
    });
    await tester.pumpWidget(
      _app(
        ModMonthComposer(
          repository: repository,
          topicId: 'topic-1',
          topicTitle: '长期记录',
          monthKey: '2026-11',
          initialDayKey: '2026-11-17',
          draftStore: drafts,
          draftKey: 'draft-1',
          testEmergencyExporter: exporter,
        ),
      ),
    );
    await tester.pumpAndSettle();
    final editor = tester
        .widget<af.AppFlowyEditor>(find.byType(af.AppFlowyEditor))
        .editorState;
    await editor.insertText(0, '尚未提交', path: [0]);
    await tester.pump(const Duration(milliseconds: 700));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('long-draft-emergency-export')));
    await _password(tester);
    expect(saved?.kind, EmergencyRecordKind.longRecord);
    expect(saved?.body, '尚未提交');
    expect(saved?.documentJson, contains('尚未提交'));
    expect(saved?.metadata['draft'], isTrue);
    expect(saved?.metadata['topicId'], 'topic-1');
    expect(saved?.metadata['dayKey'], '2026-11-17');
    expect(await store.monthKeysForTopic('topic-1'), isEmpty);
    await tester.tap(find.byIcon(LucideIcons.x).first);
    await tester.pumpAndSettle();
    expect(find.text(l10n.month.leaveTitle), findsOneWidget);
    expect(find.text(l10n.dailynotes.emergencyExport), findsOneWidget);
    await tester.tap(find.text(l10n.month.retainAndLeave));
    await tester.pumpAndSettle();
    expect(find.byType(ModMonthComposer), findsOneWidget);
    expect(editor.document.toJson().toString(), contains('尚未提交'));
    expect(await store.monthKeysForTopic('topic-1'), isEmpty);
  });
}
