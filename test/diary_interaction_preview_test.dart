import 'package:dailynotes/src/app.dart';
import 'package:dailynotes/src/experimental/diary_autosave_session.dart';
import 'package:dailynotes/src/experimental/local_journal_spike.dart';
import 'package:dailynotes/src/preview/preview_diary_repository.dart';
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

  testWidgets('sort choices change visible order but never change DB',
      (tester) async {
    final repo = FakePreviewDiaryRepository()
      ..seed('older', '较早的一篇', '2026-11-12T10:00:00.000Z')
      ..seed('newer', '较新的一篇', '2026-11-14T10:00:00.000Z');

    await tester.pumpWidget(DailyNotesApp(previewRepository: repo));
    await tester.pumpAndSettle();
    expect(
      tester.getTopLeft(find.text('较新的一篇')).dy,
      lessThan(tester.getTopLeft(find.text('较早的一篇')).dy),
    );

    await tester.tap(find.byTooltip('排序菜单'));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('sort-oldest')));
    await tester.pumpAndSettle();
    expect(
      tester.getTopLeft(find.text('较早的一篇')).dy,
      lessThan(tester.getTopLeft(find.text('较新的一篇')).dy),
    );
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
