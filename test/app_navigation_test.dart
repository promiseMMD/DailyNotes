import 'package:dailynotes/src/app.dart';
import 'package:material_ui/material_ui.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('four main pages share an independent fifth create destination', (tester) async {
    await tester.pumpWidget(const DailyNotesApp());

    expect(find.byKey(const Key('diary-page')), findsOneWidget);
    await tester.tap(find.text('待办').last);
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('todo-page')), findsOneWidget);
    expect(find.text('当天待办'), findsOneWidget);

    await tester.tap(find.text('笔记').last);
    await tester.pumpAndSettle();
    expect(find.text('常用文件夹'), findsOneWidget);
    await tester.tap(find.text('知识库'));
    await tester.pumpAndSettle();
    expect(find.text('一级知识主题'), findsOneWidget);

    await tester.tap(find.text('助手').last);
    await tester.pumpAndSettle();
    expect(find.text('尚未接入 AI 服务'), findsOneWidget);
  });

  testWidgets('create explicitly refuses to claim a successful save', (tester) async {
    await tester.pumpWidget(const DailyNotesApp());
    await tester.tap(find.text('新建'));
    await tester.pump();
    expect(find.textContaining('不会创建、保存或同步任何真实数据'), findsOneWidget);
  });

  testWidgets('drawer stays at 70-80 percent and health checks never claim success', (tester) async {
    await tester.pumpWidget(const DailyNotesApp());
    await tester.tap(find.byTooltip('打开侧边栏'));
    await tester.pumpAndSettle();

    final drawer = tester.getSize(find.byType(Drawer));
    final screen = tester.view.physicalSize.width / tester.view.devicePixelRatio;
    expect(drawer.width / screen, inInclusiveRange(0.70, 0.80));

    await tester.tap(find.text('数据健康检查'));
    await tester.pumpAndSettle();
    expect(find.text('健康状态：未检查'), findsOneWidget);
    expect(find.text('备份有效性'), findsOneWidget);

    await tester.tap(find.text('备份有效性'));
    await tester.pumpAndSettle();
    expect(find.textContaining('未执行真实检测'), findsOneWidget);
  });

  testWidgets('sorting is a compact bottom sheet without invented sort fields', (tester) async {
    await tester.pumpWidget(const DailyNotesApp());
    await tester.tap(find.byTooltip('排序菜单'));
    await tester.pumpAndSettle();

    expect(find.text('日记排序'), findsOneWidget);
    expect(find.textContaining('排序字段与默认顺序尚未确认'), findsOneWidget);
  });
}
