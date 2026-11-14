import 'dart:async';

import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:moodiary_data/moodiary_data.dart';
import 'package:moodiary_di/moodiary_di.dart';
import 'package:moodiary_i18n/moodiary_i18n.dart';
import 'package:moodiary_mobile/app/dailynotes/data/daily_notes_store.dart';
import 'package:moodiary_mobile/app/dailynotes/notes/note_editor_page.dart';
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

  Future<void> showEditor(WidgetTester tester) async {
    await tester.binding.setSurfaceSize(const Size(430, 900));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(
      TranslationProvider(
        child: MaterialApp(
          theme: buildMuiTheme(brightness: Brightness.light),
          home: DailyNoteEditorPage(store: store),
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
    expect(tester.takeException(), isNull);
  });
}
