import 'package:dailynotes/src/app.dart';
import 'package:dailynotes/src/preview/soft_components.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';

void main() {
  testWidgets('diary becomes a reading-first preview without quick-entry card',
      (tester) async {
    await tester.pumpWidget(const DailyNotesApp());

    expect(find.text('好好记录，慢慢生活'), findsOneWidget);
    expect(find.text('长期记录'), findsOneWidget);
    expect(find.text('最近日记'), findsOneWidget);
    expect(find.textContaining('记录一下今天'), findsNothing);
    expect(find.byType(PreviewCreateGlyph), findsOneWidget);
    expect(find.text('暂无可读取的日记'), findsOneWidget);
    expect(find.byTooltip('置顶菜单'), findsOneWidget);
    expect(find.byTooltip('排序菜单'), findsOneWidget);
  });

  testWidgets('Moodiary-inspired drawer preserves the approved entry order',
      (tester) async {
    await tester.pumpWidget(const DailyNotesApp());
    await tester.tap(find.byTooltip('打开侧边栏'));
    await tester.pumpAndSettle();

    final first = tester.getTopLeft(find.text('我的'));
    final second = tester.getTopLeft(find.text('数据同步与备份'));
    final third = tester.getTopLeft(find.text('定制'));
    final fourth = tester.getTopLeft(find.text('分类管理'));
    expect(first.dy, lessThan(second.dy));
    expect(second.dy, lessThan(third.dy));
    expect(third.dy, lessThan(fourth.dy));

    final width = tester.getSize(find.byType(Drawer)).width;
    final screen = tester.view.physicalSize.width / tester.view.devicePixelRatio;
    expect(width / screen, inInclusiveRange(0.70, 0.80));
    expect(find.text('设置'), findsOneWidget);
  });

  testWidgets('notes and todo retain independent compact top tabs',
      (tester) async {
    await tester.pumpWidget(const DailyNotesApp());

    await tester.tap(find.text('待办').last);
    await tester.pumpAndSettle();
    expect(find.text('把今天留给重要的事'), findsOneWidget);
    expect(find.text('当天待办'), findsOneWidget);
    await tester.tap(find.text('分组待办'));
    await tester.pumpAndSettle();
    expect(find.text('按时间分组'), findsOneWidget);

    await tester.tap(find.text('笔记').last);
    await tester.pumpAndSettle();
    expect(find.text('想法，都有自己的位置'), findsOneWidget);
    expect(find.text('查看全部'), findsOneWidget);
    await tester.tap(find.text('知识库'));
    await tester.pumpAndSettle();
    expect(find.text('一级知识主题'), findsOneWidget);
  });

  testWidgets('narrow device pages do not overflow or fake data-health success',
      (tester) async {
    tester.view.physicalSize = const Size(360, 760);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    await tester.pumpWidget(const DailyNotesApp());
    expect(tester.takeException(), isNull);
    await tester.tap(find.byTooltip('打开侧边栏'));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    await tester.tap(find.text('数据健康检查'));
    await tester.pumpAndSettle();
    expect(find.text('健康状态：未检查'), findsOneWidget);
    expect(find.text('本地数据库'), findsOneWidget);
    expect(tester.takeException(), isNull);
    expect(find.text('健康状态：正常'), findsNothing);
  });
}
