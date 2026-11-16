import 'dart:convert';

import 'package:appflowy_editor/appflowy_editor.dart';
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:moodiary_data/moodiary_data.dart';
import 'package:moodiary_di/moodiary_di.dart';
import 'package:moodiary_i18n/moodiary_i18n.dart';
import 'package:moodiary_mobile/app/dailynotes/data/daily_notes_store.dart';
import 'package:moodiary_mobile/app/dailynotes/notes/rich_note_editor_page.dart';
import 'package:moodiary_storage/moodiary_storage.dart';
import 'package:moodiary_storage/testing.dart';
import 'package:mui/mui.dart';

void main() {
  setUpAll(() async {
    getIt.registerSingleton<IKVStorage>(MemoryKVStorage());
    await setupPluralResolvers();
    await LocaleSettings.setLocale(AppLocale.zh);
  });
  tearDownAll(() => getIt.reset());

  testWidgets('rich editor changes are saved in the note and its outbox', (
    tester,
  ) async {
    final db = MoodiaryDatabase.forTesting(NativeDatabase.memory());
    final store = DailyNotesStore(db);
    await store.open();
    final editor = EditorState.blank(withInitialText: true);
    await tester.binding.setSurfaceSize(const Size(430, 900));
    await tester.pumpWidget(
      TranslationProvider(
        child: MaterialApp(
          theme: buildMuiTheme(brightness: Brightness.light),
          localizationsDelegates: const [
            AppFlowyEditorLocalizations.delegate,
            ...GlobalMaterialLocalizations.delegates,
          ],
          home: RichNoteEditorPage(store: store, testEditor: editor),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(
      tester.widget<AppFlowyEditor>(find.byType(AppFlowyEditor)).autoFocus,
      isTrue,
    );
    expect(editor.selection, isNotNull);
    await editor.insertText(0, '富文本测试', path: [0]);
    await tester.pump(const Duration(milliseconds: 600));
    await tester.pumpAndSettle();
    expect(store.notes, hasLength(1));
    expect(store.notes.single.body, contains('富文本测试'));
    expect(store.notes.single.documentJson, contains('富文本测试'));
    expect(store.notes.single.documentVersion, 1);
    expect(store.pendingOperationCount, greaterThan(0));
    await tester.pumpWidget(const SizedBox());
    store.dispose();
    await db.close();
    await tester.binding.setSurfaceSize(null);
  });
  testWidgets('failed transaction keeps editor text and never reports saved', (
    tester,
  ) async {
    final db = MoodiaryDatabase.forTesting(NativeDatabase.memory());
    final store = DailyNotesStore(
      db,
      beforeOutboxWrite: () async => throw StateError('disk'),
    );
    await store.open();
    final editor = EditorState.blank(withInitialText: true);
    await tester.binding.setSurfaceSize(const Size(430, 900));
    await tester.pumpWidget(
      TranslationProvider(
        child: MaterialApp(
          theme: buildMuiTheme(brightness: Brightness.light),
          localizationsDelegates: const [
            AppFlowyEditorLocalizations.delegate,
            ...GlobalMaterialLocalizations.delegates,
          ],
          home: RichNoteEditorPage(store: store, testEditor: editor),
        ),
      ),
    );
    await tester.pumpAndSettle();
    await editor.insertText(0, '未保存', path: [0]);
    await tester.pump(const Duration(milliseconds: 600));
    await tester.pumpAndSettle();
    expect(store.notes, isEmpty);
    expect(find.textContaining('保存失败'), findsOneWidget);
    expect(find.textContaining('本机已保存'), findsNothing);
    expect(editor.document.toJson().toString(), contains('未保存'));
    await tester.tap(find.byIcon(LucideIcons.arrowLeft));
    await tester.pumpAndSettle();
    expect(find.text('复制文档 JSON'), findsOneWidget);
    expect(find.text('应急导出 ZIP'), findsOneWidget);
    expect(find.text('重试'), findsWidgets);
    await tester.tap(find.text('放弃未保存内容'));
    await tester.pumpAndSettle();
    expect(find.text('确认丢失未保存内容？'), findsOneWidget);
    await tester.tap(find.text('取消').last);
    await tester.pumpAndSettle();
    expect(editor.document.toJson().toString(), contains('未保存'));

    await tester.pumpWidget(const SizedBox());
    store.dispose();
    await db.close();
    await tester.binding.setSurfaceSize(null);
  });

  testWidgets('saved document reopens read-only with original content', (
    tester,
  ) async {
    final db = MoodiaryDatabase.forTesting(NativeDatabase.memory());
    final store = DailyNotesStore(db);
    await store.open();
    final source = EditorState.blank(withInitialText: true);
    await source.insertText(0, '已保存文本', path: [0]);
    final note = await store.saveRichNote(
      title: 'Title',
      plainText: '已保存文本',
      documentJson: jsonEncode(source.document.toJson()),
      documentVersion: 1,
    );
    source.dispose();
    await tester.binding.setSurfaceSize(const Size(430, 900));
    await tester.pumpWidget(
      TranslationProvider(
        child: MaterialApp(
          theme: buildMuiTheme(brightness: Brightness.light),
          localizationsDelegates: const [
            AppFlowyEditorLocalizations.delegate,
            ...GlobalMaterialLocalizations.delegates,
          ],
          home: RichNoteEditorPage(store: store, note: note),
        ),
      ),
    );
    await tester.pumpAndSettle();
    final editor = tester.widget<AppFlowyEditor>(find.byType(AppFlowyEditor));
    expect(editor.editorState.editable, isFalse);
    expect(editor.autoFocus, isFalse);
    expect(editor.editorState.document.toJson().toString(), contains('已保存文本'));
    expect(find.byTooltip('解锁编辑'), findsOneWidget);
    await tester.pumpWidget(const SizedBox());
    store.dispose();
    await db.close();
    await tester.binding.setSurfaceSize(null);
  });
  testWidgets('unknown node fields remain protected and cannot be edited', (
    tester,
  ) async {
    final db = MoodiaryDatabase.forTesting(NativeDatabase.memory());
    final store = DailyNotesStore(db);
    await store.open();
    const raw =
        '{"document":{"type":"page","children":[{"type":"paragraph","future_field":"must keep"}]}}';
    final note = DailyNote(
      id: 'future',
      title: 'Title',
      body: 'preview',
      documentJson: raw,
      documentVersion: 1,
      createdAt: DateTime(2026),
      updatedAt: DateTime(2026),
    );
    await tester.pumpWidget(
      TranslationProvider(
        child: MaterialApp(
          theme: buildMuiTheme(brightness: Brightness.light),
          localizationsDelegates: const [
            AppFlowyEditorLocalizations.delegate,
            ...GlobalMaterialLocalizations.delegates,
          ],
          home: RichNoteEditorPage(store: store, note: note),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('文档格式暂不支持或内容损坏，已保留原文，请勿覆盖。'), findsOneWidget);
    expect(find.text('复制原始文档 JSON'), findsOneWidget);
    expect(store.pendingOperationCount, 0);
    await tester.pumpWidget(const SizedBox());
    store.dispose();
    await db.close();
  });
}
