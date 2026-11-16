import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:moodiary_data/moodiary_data.dart';
import 'package:moodiary_di/moodiary_di.dart';
import 'package:moodiary_i18n/moodiary_i18n.dart';
import 'package:moodiary_mobile/app/home/mod_continuous.dart';
import 'package:moodiary_mobile/app/home/mod_month_native.dart';
import 'package:moodiary_mobile/app/home/mod_month_page.dart';
import 'package:moodiary_mobile/app/home/mod_month_store.dart';
import 'package:moodiary_mobile/app/home/mod_month_updates.dart';
import 'package:moodiary_models/moodiary_models.dart';
import 'package:moodiary_storage/moodiary_storage.dart';
import 'package:moodiary_storage/testing.dart';
import 'package:mui/mui.dart';

const topicId = 'aac26e25-4a1d-4b4c-b256-9b0c347d36e2';
const body =
    '{"type":"doc","attrs":{"v":2},"content":[{"type":"paragraph","content":[{"type":"text","text":"cached native record"}]}]}';

class _ControlledRepository extends ModNativeMonthRepository {
  bool fail = false;
  String text = body;
  ModStoredBlock? appended;
  List<ModStoredBlock> extra = [];
  _ControlledRepository(ModMonthStore store, DiaryRepository diaries)
    : super(store: store, diaries: diaries);
  @override
  Future<ModNativeMonthSnapshot> load(String id, String month) async {
    if (fail) throw StateError('format or storage failure');
    return ModNativeMonthSnapshot(
      topic: Diary.create(
        title: 'Native topic',
        content: body,
        contentText: 'topic',
        imageName: [],
        audioName: [],
        videoName: [],
        tags: [ModDiary.topicTag],
        type: DiaryType.tiptap,
      ).copyWith(id: topicId),
      monthKey: month,
      months: [month],
      legacyCount: 7,
      blocks: [
        ModStoredBlock(
          blockId: 'native-block-widget',
          revisionId: 'native-revision-widget',
          parentRevisionId: null,
          topicId: topicId,
          monthKey: month,
          kind: 'entry',
          dayKey: '$month-01',
          occurredAtMs: 1794038400123,
          editedAtMs: 1794038400123,
          tiptapJson: text,
          deleted: false,
        ),
        ...extra.where((block) => block.monthKey == month),
        if (appended != null && appended!.monthKey == month) appended!,
      ],
    );
  }
}

void main() {
  late MoodiaryDatabase db;
  late _ControlledRepository repository;
  setUp(() {
    getIt.registerSingleton<IKVStorage>(MemoryKVStorage());
    db = MoodiaryDatabase.forTesting(NativeDatabase.memory());
    repository = _ControlledRepository(ModMonthStore(db), DiaryRepository(db));
  });
  tearDown(() async {
    await db.close();
    await getIt.reset();
  });

  Future<void> mount(
    WidgetTester tester, {
    Future<ModStoredBlock?> Function(String, String?)? testAppend,
  }) async {
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(
      TranslationProvider(
        child: MaterialApp(
          theme: buildMuiTheme(brightness: .light),
          localizationsDelegates: const [
            ...GlobalMaterialLocalizations.delegates,
            GlobalMuiLocalizations.delegate,
          ],
          builder: (context, child) =>
              MaterialUiCompatibilityBridge(child: child!),
          home: ModMonthPage(
            topicId: topicId,
            repository: repository,
            openLegacy: () async {},
            testAppend: testAppend,
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  testWidgets(
    'native month shows local-only status, real block and explicit legacy boundary',
    (tester) async {
      await mount(tester);
      expect(find.text('Native topic'), findsOneWidget);
      expect(find.text('cached native record'), findsOneWidget);
      expect(find.text('1 · cached native record'), findsOneWidget);
      expect(find.text(l10n.month.localOnly), findsOneWidget);
      expect(find.text(l10n.month.legacy(count: 7)), findsOneWidget);
      expect(
        tester
            .widget<FloatingActionButton>(find.byType(FloatingActionButton))
            .onPressed,
        isNotNull,
      );
    },
  );

  testWidgets(
    'PC invalidation updates native list but failed validation keeps cached rows read-only',
    (tester) async {
      await mount(tester);
      repository.text = body.replaceAll(
        'cached native record',
        'PC committed record',
      );
      ModMonthUpdates.publish(topicId);
      await tester.pumpAndSettle();
      expect(find.text('PC committed record'), findsOneWidget);
      repository.fail = true;
      ModMonthUpdates.publish(topicId);
      await tester.pumpAndSettle();
      expect(find.text('PC committed record'), findsOneWidget);
      expect(find.text(l10n.month.readOnly), findsOneWidget);
      expect(
        tester
            .widget<FloatingActionButton>(find.byType(FloatingActionButton))
            .onPressed,
        isNull,
      );
      final edit = find.widgetWithText(TextButton, l10n.diary.edit);
      expect(tester.widget<TextButton>(edit).onPressed, isNull);
      repository.fail = false;
      await tester.tap(find.widgetWithText(TextButton, l10n.common.retry));
      await tester.pumpAndSettle();
      expect(
        tester
            .widget<FloatingActionButton>(find.byType(FloatingActionButton))
            .onPressed,
        isNotNull,
      );
    },
  );

  testWidgets(
    'confirmed append opens its month and remains visible outside the search filter',
    (tester) async {
      const appended = ModStoredBlock(
        blockId: 'appended-id-123',
        revisionId: 'appended-revision',
        parentRevisionId: null,
        topicId: topicId,
        monthKey: '2030-02',
        kind: 'entry',
        dayKey: '2030-02-05',
        occurredAtMs: 1896480000000,
        editedAtMs: 1896480000000,
        tiptapJson: '{"type":"doc","attrs":{"v":2},"content":[{"type":"paragraph","content":[{"type":"text","text":"new append text"}]}]}',
        deleted: false,
      );
      await mount(
        tester,
        testAppend: (month, day) async {
          repository.appended = appended;
          return appended;
        },
      );
      await tester.enterText(find.byType(TextField), 'unmatched');
      await tester.tap(find.byType(FloatingActionButton));
      await tester.pumpAndSettle();
      expect(find.text('2030-02'), findsOneWidget);
      expect(find.text('new append text'), findsOneWidget);
      expect(find.text(l10n.month.locatedOutsideFilter), findsOneWidget);
      expect(
        tester.widget<TextField>(find.byType(TextField)).controller?.text ??
            tester
                .widget<EditableText>(find.byType(EditableText))
                .controller
                .text,
        'unmatched',
      );
      expect(find.text(l10n.month.locateFailed), findsNothing);
    },
  );

  testWidgets('cancelled append does not claim success or navigate', (
    tester,
  ) async {
    await mount(tester, testAppend: (month, day) async => null);
    await tester.tap(find.byType(FloatingActionButton));
    await tester.pumpAndSettle();
    expect(find.text('cached native record'), findsOneWidget);
    expect(find.text(l10n.month.savedLocal), findsNothing);
    expect(find.text(l10n.month.locateFailed), findsNothing);
  });

  testWidgets(
    'locates an appended record beyond the first page in a long list',
    (tester) async {
      const month = '2030-02';
      repository.extra = List.generate(
        70,
        (index) => ModStoredBlock(
          blockId: 'extra-block-$index',
          revisionId: 'extra-revision-$index',
          parentRevisionId: null,
          topicId: topicId,
          monthKey: month,
          kind: 'entry',
          dayKey: '$month-01',
          occurredAtMs: 1794038400123 + index,
          editedAtMs: 1794038400123,
          tiptapJson: body,
          deleted: false,
        ),
      );
      const appended = ModStoredBlock(
        blockId: 'appended-id-long',
        revisionId: 'appended-revision-long',
        parentRevisionId: null,
        topicId: topicId,
        monthKey: month,
        kind: 'entry',
        dayKey: '$month-05',
        occurredAtMs: 1896480000000,
        editedAtMs: 1896480000000,
        tiptapJson: '{"type":"doc","attrs":{"v":2},"content":[{"type":"paragraph","content":[{"type":"text","text":"distant append"}]}]}',
        deleted: false,
      );
      await mount(
        tester,
        testAppend: (_, __) async {
          repository.appended = appended;
          return appended;
        },
      );
      await tester.tap(find.byType(FloatingActionButton));
      await tester.pumpAndSettle();
      expect(find.text('distant append'), findsOneWidget);
      expect(find.text(l10n.month.locateFailed), findsNothing);
    },
  );
}
