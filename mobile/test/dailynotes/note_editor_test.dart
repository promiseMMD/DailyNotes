import 'dart:async';
import 'dart:typed_data';

import 'package:flutter/services.dart';

import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:moodiary_data/moodiary_data.dart';
import 'package:moodiary_di/moodiary_di.dart';
import 'package:moodiary_i18n/moodiary_i18n.dart';
import 'package:moodiary_mobile/app/dailynotes/data/daily_notes_store.dart';
import 'package:moodiary_mobile/app/dailynotes/notes/note_editor_page.dart';
import 'package:moodiary_mobile/app/dailynotes/notes/rich_note_editor_page.dart';
import 'package:moodiary_mobile/app/dailynotes/recovery/emergency_note_export.dart';
import 'package:moodiary_storage/moodiary_storage.dart';
import 'package:moodiary_storage/testing.dart';
import 'package:mui/mui.dart';

class _SaveAttempt {
  final String title, body;
  final Completer<DailyNote> result = Completer();
  _SaveAttempt(this.title, this.body);
  void complete() => result.complete(
    DailyNote(
      id: 'note-1',
      title: title,
      body: body,
      createdAt: DateTime(2026, 11, 15),
      updatedAt: DateTime(2026, 11, 15),
    ),
  );
}

class _ControlledStore extends DailyNotesStore {
  _ControlledStore(super.db);
  final attempts = <_SaveAttempt>[];
  bool alwaysFail = false;
  @override
  Future<DailyNote> saveNote({
    String? id,
    required String title,
    required String body,
    String? folderId,
    List<String> tags = const [],
  }) {
    if (alwaysFail) return Future.error(StateError('disk_failure'));
    final attempt = _SaveAttempt(title, body);
    attempts.add(attempt);
    return attempt.result.future;
  }
}

void main() {
  late MoodiaryDatabase db;
  late _ControlledStore store;
  setUpAll(() async {
    getIt.registerSingleton<IKVStorage>(MemoryKVStorage());
    await setupPluralResolvers();
    await LocaleSettings.setLocale(AppLocale.zh);
  });
  tearDownAll(() => getIt.reset());
  setUp(() {
    db = MoodiaryDatabase.forTesting(NativeDatabase.memory());
    store = _ControlledStore(db);
  });
  tearDown(() async {
    store.dispose();
    await db.close();
  });

  Future<void> showEditor(
    WidgetTester tester, {
    Future<Uint8List> Function(EmergencyNoteSnapshot, String)? archive,
    Future<Uri?> Function(Uint8List)? save,
    DailyNote? note,
  }) async {
    await tester.binding.setSurfaceSize(const Size(430, 900));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(
      TranslationProvider(
        child: MaterialApp(
          theme: buildMuiTheme(brightness: Brightness.light),
          home: DailyNoteEditorPage(
            store: store,
            note: note,
            createEmergencyArchive: archive,
            saveEmergencyArchive: save,
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  testWidgets('saved indicator waits for successful persistence', (
    tester,
  ) async {
    await showEditor(tester);
    await tester.enterText(find.byType(TextField).at(1), 'Keep this thought');
    await tester.pump(const Duration(milliseconds: 500));
    expect(store.attempts, hasLength(1));
    expect(find.textContaining('本机已保存'), findsNothing);
    store.attempts.single.complete();
    await tester.pumpAndSettle();
    expect(find.textContaining('本机已保存'), findsOneWidget);
    expect(find.text('Keep this thought'), findsOneWidget);
    expect(find.text('本机保存，尚未同步'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'edits during an in-flight write remain pending and save newest input',
    (tester) async {
      await showEditor(tester);
      final body = find.byType(TextField).at(1);
      await tester.enterText(body, 'First revision');
      await tester.pump(const Duration(milliseconds: 500));
      await tester.enterText(body, 'Second revision');
      await tester.pump(const Duration(milliseconds: 500));
      expect(store.attempts, hasLength(1));
      store.attempts.first.complete();
      await tester.pump();
      expect(store.attempts, hasLength(2));
      expect(store.attempts.last.body, 'Second revision');
      expect(find.textContaining('本机已保存'), findsNothing);
      store.attempts.last.complete();
      await tester.pumpAndSettle();
      expect(find.textContaining('本机已保存'), findsOneWidget);
      expect(find.text('Second revision'), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('failed save retains text and blocks accidental navigation', (
    tester,
  ) async {
    store.alwaysFail = true;
    await showEditor(tester);
    await tester.enterText(find.byType(TextField).at(1), 'Unsaved content');
    await tester.pump(const Duration(milliseconds: 500));
    await tester.pumpAndSettle();
    expect(find.textContaining('保存失败'), findsOneWidget);
    expect(find.textContaining('本机已保存'), findsNothing);
    await tester.tap(find.byIcon(LucideIcons.arrowLeft));
    await tester.pumpAndSettle();
    expect(find.text('内容尚未保存'), findsOneWidget);
    expect(find.text('继续编辑'), findsOneWidget);
    expect(find.text('Unsaved content'), findsOneWidget);
    expect(find.text('复制内容'), findsWidgets);
    expect(find.text('应急导出 ZIP'), findsOneWidget);
    await tester.tap(find.text('应急导出 ZIP'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('确认').last);
    await tester.pumpAndSettle();
    expect(find.text('密码不能为空且两次必须一致'), findsOneWidget);
    await tester.tap(find.text('取消').last);
    await tester.pumpAndSettle();
    expect(find.text('放弃未保存内容'), findsOneWidget);
    await tester.tap(find.text('放弃未保存内容'));
    await tester.pumpAndSettle();
    expect(find.text('确认丢失未保存内容？'), findsOneWidget);
    await tester.tap(find.text('取消').last);
    await tester.pumpAndSettle();
    expect(find.text('内容尚未保存'), findsOneWidget);
    expect(find.text('Unsaved content'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
  testWidgets(
    'emergency export uses current unsaved text and reports partial success only after saving',
    (tester) async {
      store.alwaysFail = true;
      EmergencyNoteSnapshot? captured;
      await showEditor(
        tester,
        archive: (snapshot, password) async {
          captured = snapshot;
          expect(password, 'secret');
          return Uint8List.fromList([1, 2]);
        },
        save: (bytes) async {
          expect(bytes, [1, 2]);
          return Uri.parse('content://example/saved');
        },
      );
      await tester.enterText(find.byType(TextField).at(1), 'latest unsaved');
      await tester.pump(const Duration(milliseconds: 500));
      await tester.pumpAndSettle();
      await tester.tap(find.byIcon(LucideIcons.arrowLeft));
      await tester.pumpAndSettle();
      await tester.tap(find.text('应急导出 ZIP'));
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(TextField).at(2), 'secret');
      await tester.enterText(find.byType(TextField).at(3), 'secret');
      await tester.tap(find.text('确认').last);
      await tester.pumpAndSettle();
      expect(captured?.body, 'latest unsaved');
      expect(find.text('已导出部分内容：仅当前笔记文字，不含附件'), findsOneWidget);
      expect(find.text('内容尚未保存'), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );
  testWidgets('emergency destination cancelled retains unsaved edits', (
    tester,
  ) async {
    store.alwaysFail = true;
    await showEditor(
      tester,
      archive: (_, __) async => Uint8List.fromList([1]),
      save: (_) async {
        return null;
      },
    );
    await tester.enterText(find.byType(TextField).at(1), 'unsaved work');
    await tester.pump(const Duration(milliseconds: 500));
    await tester.pumpAndSettle();
    await tester.tap(find.byIcon(LucideIcons.arrowLeft));
    await tester.pumpAndSettle();
    await tester.tap(find.text('应急导出 ZIP'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField).at(2), 'password');
    await tester.enterText(find.byType(TextField).at(3), 'password');
    await tester.tap(find.text('确认').last);
    await tester.pumpAndSettle();
    expect(find.text('已取消导出，编辑内容仍保留'), findsOneWidget);
    expect(find.text('已导出部分内容：仅当前笔记文字，不含附件'), findsNothing);
    expect(find.text('unsaved work'), findsOneWidget);
    expect(find.text('内容尚未保存'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('emergency destination failed retains unsaved edits', (
    tester,
  ) async {
    store.alwaysFail = true;
    await showEditor(
      tester,
      archive: (_, __) async => Uint8List.fromList([1]),
      save: (_) async {
        throw StateError('storage failure');
      },
    );
    await tester.enterText(find.byType(TextField).at(1), 'unsaved work');
    await tester.pump(const Duration(milliseconds: 500));
    await tester.pumpAndSettle();
    await tester.tap(find.byIcon(LucideIcons.arrowLeft));
    await tester.pumpAndSettle();
    await tester.tap(find.text('应急导出 ZIP'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField).at(2), 'password');
    await tester.enterText(find.byType(TextField).at(3), 'password');
    await tester.tap(find.text('确认').last);
    await tester.pumpAndSettle();
    expect(find.text('应急导出失败，请重试或复制内容'), findsOneWidget);
    expect(find.text('已导出部分内容：仅当前笔记文字，不含附件'), findsNothing);
    expect(find.text('unsaved work'), findsOneWidget);
    expect(find.text('内容尚未保存'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
  testWidgets(
    'editing after a failed save keeps warning until retry succeeds',
    (tester) async {
      store.alwaysFail = true;
      await showEditor(tester);
      await tester.enterText(find.byType(TextField).at(1), 'first');
      await tester.pump(const Duration(milliseconds: 500));
      await tester.pumpAndSettle();
      expect(find.textContaining('保存失败'), findsOneWidget);
      await tester.enterText(find.byType(TextField).at(1), 'latest');
      await tester.pump(const Duration(milliseconds: 100));
      expect(find.textContaining('保存失败'), findsOneWidget);
      expect(find.textContaining('本机已保存'), findsNothing);
      await tester.pump(const Duration(milliseconds: 500));
      await tester.pumpAndSettle();
      expect(find.textContaining('保存失败'), findsOneWidget);
      expect(find.text('latest'), findsOneWidget);
      store.alwaysFail = false;
      await tester.tap(find.text('重试'));
      await tester.pump();
      expect(store.attempts, hasLength(1));
      expect(find.textContaining('保存失败'), findsOneWidget);
      store.attempts.single.complete();
      await tester.pumpAndSettle();
      expect(find.textContaining('保存失败'), findsNothing);
      expect(find.textContaining('本机已保存'), findsOneWidget);
    },
  );
  testWidgets(
    'existing note opens read-only and unlock does not focus keyboard',
    (tester) async {
      final note = DailyNote(
        id: 'original',
        title: 'Title',
        body: 'Original body',
        createdAt: DateTime(2026),
        updatedAt: DateTime(2026),
      );
      await showEditor(tester, note: note);
      expect(
        tester.widget<TextField>(find.byType(TextField).at(0)).readOnly,
        isTrue,
      );
      expect(
        tester.widget<TextField>(find.byType(TextField).at(1)).readOnly,
        isTrue,
      );
      await tester.tap(find.byTooltip('解锁编辑'));
      await tester.pump();
      expect(
        tester.widget<TextField>(find.byType(TextField).at(1)).readOnly,
        isFalse,
      );
      expect(tester.testTextInput.isVisible, isFalse);
      expect(store.attempts, isEmpty);
    },
  );
  testWidgets(
    'locking after a failed save preserves latest unsaved edits and retry',
    (tester) async {
      final note = DailyNote(
        id: 'original',
        title: 'Title',
        body: 'Saved body',
        createdAt: DateTime(2026),
        updatedAt: DateTime(2026),
      );
      store.alwaysFail = true;
      await showEditor(tester, note: note);
      await tester.tap(find.byTooltip('解锁编辑'));
      await tester.pump();
      await tester.enterText(find.byType(TextField).at(1), 'Latest unsaved');
      await tester.pump(const Duration(milliseconds: 500));
      await tester.pumpAndSettle();
      expect(find.textContaining('保存失败'), findsOneWidget);
      await tester.tap(find.byTooltip('锁定编辑'));
      await tester.pumpAndSettle();
      expect(
        tester.widget<TextField>(find.byType(TextField).at(1)).readOnly,
        isTrue,
      );
      expect(find.text('Latest unsaved'), findsOneWidget);
      expect(find.textContaining('保存失败'), findsOneWidget);
      await tester.tap(find.byTooltip('解锁编辑'));
      await tester.pump();
      expect(find.text('Latest unsaved'), findsOneWidget);
      store.alwaysFail = false;
      await tester.tap(find.text('重试'));
      await tester.pump();
      expect(store.attempts.single.body, 'Latest unsaved');
      store.attempts.single.complete();
      await tester.pumpAndSettle();
      expect(find.textContaining('本机已保存'), findsOneWidget);
    },
  );
  testWidgets('unsupported rich document is preserved and never saved', (
    tester,
  ) async {
    final note = DailyNote(
      id: 'original',
      title: 'Title',
      body: 'Original',
      documentJson: '{invalid',
      documentVersion: 1,
      createdAt: DateTime(2026),
      updatedAt: DateTime(2026),
    );
    await tester.pumpWidget(
      TranslationProvider(
        child: MaterialApp(
          theme: buildMuiTheme(brightness: Brightness.light),
          home: RichNoteEditorPage(store: store, note: note),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('文档格式暂不支持或内容损坏，已保留原文，请勿覆盖。'), findsOneWidget);
    String? copied;
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      SystemChannels.platform,
      (call) async {
        if (call.method == 'Clipboard.setData')
          copied = (call.arguments as Map)['text'] as String?;
        return null;
      },
    );
    addTearDown(
      () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        SystemChannels.platform,
        null,
      ),
    );
    await tester.tap(find.text('复制原始文档 JSON'));
    await tester.pumpAndSettle();
    expect(copied, '{invalid');
    expect(store.attempts, isEmpty);
    expect(tester.takeException(), isNull);
  });
  testWidgets(
    'old retry success does not clear failure while newer revision is pending',
    (tester) async {
      store.alwaysFail = true;
      await showEditor(tester);
      await tester.enterText(find.byType(TextField).at(1), 'old');
      await tester.pump(const Duration(milliseconds: 500));
      await tester.pumpAndSettle();
      expect(find.textContaining('保存失败'), findsOneWidget);
      store.alwaysFail = false;
      await tester.tap(find.text('重试'));
      await tester.pump();
      await tester.enterText(find.byType(TextField).at(1), 'new');
      await tester.pump(const Duration(milliseconds: 500));
      store.attempts.first.complete();
      await tester.pump();
      expect(store.attempts, hasLength(2));
      expect(find.textContaining('保存失败'), findsOneWidget);
      expect(find.textContaining('本机已保存'), findsNothing);
      expect(store.attempts.last.body, 'new');
      store.attempts.last.complete();
      await tester.pumpAndSettle();
      expect(find.textContaining('本机已保存'), findsOneWidget);
    },
  );
}
