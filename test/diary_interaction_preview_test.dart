import 'package:dailynotes/src/app.dart';
import 'package:dailynotes/src/experimental/diary_autosave_session.dart';
import 'package:dailynotes/src/experimental/local_journal_spike.dart';
import 'package:dailynotes/src/preview/preview_diary_repository.dart';
import 'package:dailynotes/src/preview/diary_interaction_widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';

class FakePreviewDiaryRepository implements PreviewDiaryRepository {
  final entries = <String, DiaryVersion>{};
  int writeCount = 0;
  bool failWrites = false;
  bool closed = false;

  void seed(String id, String body, String utc) {
    entries[id] = DiaryVersion(
      entityId: id,
      revision: 1,
      body: body,
      savedUtc: utc,
    );
  }

  @override
  Future<List<DiaryVersion>> listDiaries() async =>
      List<DiaryVersion>.unmodifiable(entries.values);

  @override
  Future<ExperimentalDiarySession> openEditor(String id) =>
      ExperimentalDiarySession.openWithCallbacksForTest(
        entityId: id,
        read: (key) async => entries[key],
        save: ({
          required String entityId,
          required String body,
          required int expectedRevision,
        }) async {
          if (failWrites) throw StateError('injected failed write');
          final old = entries[entityId];
          if (expectedRevision != (old?.revision ?? 0)) {
            throw RevisionMismatch(expectedRevision, old?.revision ?? 0);
          }
          writeCount++;
          final committed = DiaryVersion(
            entityId: entityId,
            revision: expectedRevision + 1,
            body: body,
            savedUtc: DateTime.utc(2026, 11, 14, 12, writeCount)
                .toIso8601String(),
          );
          entries[entityId] = committed;
          return committed;
        },
      );

  @override
  Future<void> close() async => closed = true;
}

void main() {
  testWidgets('create -> commit -> list -> reopen -> edit is a real UI path',
      (tester) async {
    final repo = FakePreviewDiaryRepository();
    await tester.pumpWidget(DailyNotesApp(previewRepository: repo));
    await tester.pumpAndSettle();
    expect(find.text('暂无可读取的日记'), findsOneWidget);

    await tester.tap(find.text('新建'));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('experimental-diary-input')), findsOneWidget);
    await tester.enterText(
      find.byKey(const Key('experimental-diary-input')),
      '第一篇真实流程测试日记',
    );
    await tester.pumpAndSettle();
    expect(find.text('本机已保存'), findsOneWidget);
    expect(repo.writeCount, 1);

    await tester.pageBack();
    await tester.pumpAndSettle();
    expect(find.text('第一篇真实流程测试日记'), findsOneWidget);
    expect(repo.entries, hasLength(1));

    await tester.tap(find.text('第一篇真实流程测试日记'));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('experimental-diary-input')), findsOneWidget);
    expect(
      find.text('第一篇真实流程测试日记'),
      findsOneWidget,
    );
    await tester.enterText(
      find.byKey(const Key('experimental-diary-input')),
      '第一篇已经重新编辑',
    );
    await tester.pumpAndSettle();
    await tester.pageBack();
    await tester.pumpAndSettle();

    expect(find.text('第一篇已经重新编辑'), findsOneWidget);
    expect(repo.entries, hasLength(1)); // Edit never creates a second entry.
    expect(repo.entries.values.single.revision, 2);
    expect(repo.writeCount, 2);
    await tester.pumpWidget(const SizedBox.shrink());
    expect(repo.closed, isTrue);
  });

  testWidgets('search filters actual committed text, close restores rows',
      (tester) async {
    final repo = FakePreviewDiaryRepository()
      ..seed('one', '今天修好了 Stage 设备',
          '2026-11-14T10:00:00.000Z')
      ..seed('two', '今天研究 Overlay 技术',
          '2026-11-14T11:00:00.000Z');

    await tester.pumpWidget(DailyNotesApp(previewRepository: repo));
    await tester.pumpAndSettle();
    expect(find.text('今天修好了 Stage 设备'), findsOneWidget);
    expect(find.text('今天研究 Overlay 技术'), findsOneWidget);

    await tester.tap(find.byTooltip('搜索菜单'));
    await tester.pumpAndSettle();
    await tester.enterText(
      find.byKey(const Key('preview-diary-search')),
      'Stage',
    );
    await tester.pumpAndSettle();
    expect(find.text('今天修好了 Stage 设备'), findsOneWidget);
    expect(find.text('今天研究 Overlay 技术'), findsNothing);

    await tester.tap(find.byTooltip('搜索菜单'));
    await tester.pumpAndSettle();
    expect(find.text('今天研究 Overlay 技术'), findsOneWidget);
    expect(repo.writeCount, 0);
  });

  testWidgets('clear search resets visible text and restores all committed rows',
      (tester) async {
    // The diary list is lazy: on the default 800x600 test viewport, rows
    // below the search field are not built and find.text reports a false
    // negative. Give this interaction test a phone-sized tall viewport.
    await tester.binding.setSurfaceSize(const Size(800, 1600));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final repo = FakePreviewDiaryRepository()
      ..seed('one', 'Stage 故障记录', '2026-11-14T10:00:00.000Z')
      ..seed('two', 'Overlay 调整记录', '2026-11-14T11:00:00.000Z');
    await tester.pumpWidget(DailyNotesApp(previewRepository: repo));
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('搜索菜单'));
    await tester.pumpAndSettle();
    final field = find.byKey(const Key('preview-diary-search'));
    await tester.enterText(field, 'Stage');
    await tester.pumpAndSettle();
    expect(find.text('Overlay 调整记录'), findsNothing);
    expect(tester.widget<TextField>(field).controller!.text, 'Stage');

    await tester.tap(find.byTooltip('清除搜索'));
    await tester.pumpAndSettle();
    expect(tester.widget<TextField>(field).controller!.text, isEmpty);
    expect(find.text('Stage 故障记录'), findsOneWidget);
    expect(find.text('Overlay 调整记录'), findsOneWidget);
    expect(repo.writeCount, 0);

    await tester.enterText(field, 'Overlay');
    await tester.pumpAndSettle();
    expect(find.text('Stage 故障记录'), findsNothing);
    await tester.tap(find.byTooltip('搜索菜单'));
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('搜索菜单'));
    await tester.pumpAndSettle();
    expect(tester.widget<TextField>(field).controller!.text, isEmpty);
    expect(find.text('Stage 故障记录'), findsOneWidget);
    expect(find.text('Overlay 调整记录'), findsOneWidget);
    expect(repo.writeCount, 0);
  });

  testWidgets('sort choices change visible order but never change DB',
      (tester) async {
    final repo = FakePreviewDiaryRepository()
      ..seed('older', '较早的一篇', '2026-11-12T10:00:00.000Z')
      ..seed('newer', '较新的一篇', '2026-11-14T10:00:00.000Z');

    await tester.pumpWidget(DailyNotesApp(previewRepository: repo));
    await tester.pumpAndSettle();
    List<String> order() {
      final list = tester.widget<ListView>(
        find.byKey(const Key('diary-page')),
      );
      final delegate = list.childrenDelegate as SliverChildListDelegate;
      return delegate.children
          .whereType<PreviewDiaryEntryRow>()
          .map((row) => row.entry.entityId)
          .toList();
    }
    expect(order(), orderedEquals(['newer', 'older']));

    await tester.tap(find.byTooltip('排序菜单'));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('sort-oldest')));
    await tester.pumpAndSettle();
    expect(order(), orderedEquals(['older', 'newer']));
    expect(repo.writeCount, 0);
  });

  testWidgets('drawer calendar day filters diary list without modifying data',
      (tester) async {
    final repo = FakePreviewDiaryRepository()
      ..seed('day-1', '第一天测试', '2026-11-12T08:00:00.000Z')
      ..seed('day-2', '第二天测试', '2026-11-14T08:00:00.000Z');
    await tester.pumpWidget(DailyNotesApp(previewRepository: repo));
    await tester.pumpAndSettle();

    await tester.tap(find.byTooltip('打开侧边栏'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('日历总览'));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('preview-diary-calendar')), findsOneWidget);
    expect(find.text('本地测试日记 1 篇'), findsNWidgets(2));

    await tester.tap(
      find.byKey(const Key('preview-calendar-2026-11-12')),
    );
    await tester.pumpAndSettle();
    expect(find.text('第一天测试'), findsOneWidget);
    expect(find.text('第二天测试'), findsNothing);
    expect(find.textContaining('日期：'), findsOneWidget);
    expect(repo.writeCount, 0);
  });


  testWidgets('calendar picker disables empty dates and selects a saved day',
      (tester) async {
    final emptyRepo = FakePreviewDiaryRepository();
    await tester.pumpWidget(DailyNotesApp(previewRepository: emptyRepo));
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('打开侧边栏'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('日历总览'));
    await tester.pumpAndSettle();
    // Tooltip wraps the button in Flutter 3.50; inspect the actual
    // IconButton ancestor rather than casting the tooltip widget.
    final disabled = tester.widget<IconButton>(
      find.ancestor(
        of: find.byIcon(Icons.calendar_month_outlined),
        matching: find.byType(IconButton),
      ).first,
    );
    expect(disabled.onPressed, isNull);

    final repo = FakePreviewDiaryRepository()
      ..seed('one', '十二号测试', '2026-11-12T08:00:00.000Z')
      ..seed('two', '十四号测试', '2026-11-14T08:00:00.000Z');
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pumpWidget(DailyNotesApp(previewRepository: repo));
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('打开侧边栏'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('日历总览'));
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('选择日期'));
    await tester.pumpAndSettle();
    expect(find.text('选择有测试日记的日期'), findsOneWidget);
    await tester.tap(find.text('12').last);
    await tester.pumpAndSettle();
    // Confirm through the dialog action, not a locale-specific label:
    // CI uses en-US ('OK'), while Chinese devices display '确定'.
    final confirmAction = find.descendant(
      of: find.byType(DatePickerDialog),
      matching: find.byType(TextButton),
    ).last;
    expect(confirmAction, findsOneWidget);
    await tester.tap(confirmAction);
    await tester.pumpAndSettle();
    expect(find.text('十二号测试'), findsOneWidget);
    expect(find.text('十四号测试'), findsNothing);
    expect(repo.writeCount, 0);
  });

  testWidgets('failed local write stays visible and cannot leave without warning',
      (tester) async {
    final repo = FakePreviewDiaryRepository()..failWrites = true;
    await tester.pumpWidget(DailyNotesApp(previewRepository: repo));
    await tester.pumpAndSettle();
    await tester.tap(find.text('新建'));
    await tester.pumpAndSettle();
    await tester.enterText(
      find.byKey(const Key('experimental-diary-input')),
      '未成功保存的重要测试内容',
    );
    await tester.pumpAndSettle();
    expect(find.textContaining('本机保存失败'), findsOneWidget);
    expect(repo.entries, isEmpty);
    await tester.pageBack();
    await tester.pumpAndSettle();
    expect(find.text('存在未完成的本机保存'), findsOneWidget);
    expect(find.byKey(const Key('experimental-diary-input')), findsOneWidget);

    await tester.tap(find.text('继续编辑'));
    await tester.pumpAndSettle();
    expect(find.text('未成功保存的重要测试内容'), findsOneWidget);
    repo.failWrites = false;
    await tester.tap(find.byKey(const Key('experimental-retry')));
    await tester.pumpAndSettle();
    expect(find.text('本机已保存'), findsOneWidget);
    await tester.pageBack();
    await tester.pumpAndSettle();
    expect(find.text('未成功保存的重要测试内容'), findsOneWidget);
    expect(repo.entries, hasLength(1));
  });
}
