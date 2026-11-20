import 'dart:async';
import 'dart:convert';

import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:moodiary_data/moodiary_data.dart';
import 'package:moodiary_di/moodiary_di.dart';
import 'package:moodiary_editor/moodiary_editor.dart';
import 'package:moodiary_i18n/moodiary_i18n.dart';
import 'package:moodiary_mobile/app/home/mod_month_composer.dart';
import 'package:moodiary_mobile/app/dailynotes/data/daily_notes_store.dart';
import 'package:moodiary_mobile/app/home/mod_month_native.dart';
import 'package:moodiary_mobile/app/home/mod_month_store.dart';
import 'package:moodiary_storage/moodiary_storage.dart';
import 'package:moodiary_storage/testing.dart';
import 'package:mui/mui.dart';

const validBody =
    '{"type":"doc","attrs":{"v":2},"content":[{"type":"paragraph","content":[{"type":"text","text":"native draft"}]}]}';
const topicId = 'aac26e25-4a1d-4b4c-b256-9b0c347d36e2';

class _Editor extends MoodiaryEditorController {
  String document = validBody;
  bool fail = false;
  Completer<String>? delayedSnapshot;
  @override
  Future<void> blur() async {}
  @override
  Future<String> snapshot() async {
    if (fail) throw TimeoutException('no editor acknowledgement');
    final delayed = delayedSnapshot;
    delayedSnapshot = null;
    if (delayed != null) return delayed.future;
    return document;
  }
}

class _DraftStore extends DailyNotesStore {
  bool failWrites = false;
  Completer<void>? blockNext;
  _DraftStore(super.database);

  @override
  Future<void> saveDraft(String key, Map<String, Object?> payload) async {
    final block = blockNext;
    blockNext = null;
    if (block != null) await block.future;
    if (failWrites) throw StateError('draft_write_failed');
    await super.saveDraft(key, payload);
  }
}

class _Repository extends ModNativeMonthRepository {
  final attempts = <ModMonthMutation>[];
  bool uncertain = false;
  bool conflict = false;
  _Repository(ModMonthStore store, DiaryRepository diaries)
    : super(store: store, diaries: diaries);
  @override
  Future<ModStoredBlock> commit(ModMonthMutation attempt) async {
    attempts.add(attempt);
    if (conflict) throw const ModMonthStoreException('stale_revision');
    if (uncertain) throw StateError('lost acknowledgement');
    return ModStoredBlock(
      blockId: attempt.blockId,
      revisionId: attempt.revisionId,
      parentRevisionId: attempt.parentRevisionId,
      topicId: topicId,
      monthKey: attempt.monthKey,
      kind: attempt.kind,
      dayKey: attempt.dayKey,
      occurredAtMs: attempt.occurredAtMs,
      editedAtMs: 1794038400000,
      tiptapJson: attempt.tiptapJson,
      deleted: attempt.deleted,
    );
  }
}

void main() {
  late MoodiaryDatabase db;
  late _Repository repository;
  late _Editor editor;
  setUp(() {
    getIt.registerSingleton<IKVStorage>(MemoryKVStorage());
    db = MoodiaryDatabase.forTesting(NativeDatabase.memory());
    repository = _Repository(ModMonthStore(db), DiaryRepository(db));
    editor = _Editor();
  });
  tearDown(() async {
    await db.close();
    await getIt.reset();
  });
  Future<void> mount(
    WidgetTester tester, {
    DailyNotesStore? drafts,
    Map<String, Object?>? initialDraft,
  }) async {
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1;
    tester.view.viewInsets = const FakeViewPadding(bottom: 320);
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    addTearDown(tester.view.resetViewInsets);
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
          home: Scaffold(
            body: Builder(
              builder: (context) => TextButton(
                key: const ValueKey('launch-composer'),
                onPressed: () => Navigator.of(context).push(
                  MaterialPageRoute<void>(
                    builder: (_) => ModMonthComposer(
                      repository: repository,
                      topicId: topicId,
                      monthKey: '2026-11',
                      editorController: editor,
                      draftStore: drafts,
                      draftKey: drafts == null ? null : 'composer-test',
                      initialDraft: initialDraft,
                    ),
                  ),
                ),
                child: const Text('Open editor'),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('launch-composer')));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
  }

  testWidgets('missing editor acknowledgement never calls the writer', (
    tester,
  ) async {
    editor.fail = true;
    await mount(tester);
    expect(
      tester.widget<MoodiaryEditor>(find.byType(MoodiaryEditor)).bodyOnly,
      true,
    );
    await tester.tap(find.widgetWithText(FilledButton, l10n.common.save));
    await tester.pumpAndSettle();
    expect(repository.attempts, isEmpty);
    expect(find.text(l10n.month.snapshotFailed), findsOneWidget);
  });

  testWidgets(
    'unsupported rich paste remains editable and cannot be silently flattened',
    (tester) async {
      editor.document = jsonEncode({
        'type': 'doc',
        'attrs': {'v': 2},
        'content': [
          {'type': 'table', 'content': []},
        ],
      });
      await mount(tester);
      await tester.tap(find.widgetWithText(FilledButton, l10n.common.save));
      await tester.pumpAndSettle();
      expect(repository.attempts, isEmpty);
      expect(editor.document, contains('table'));
      expect(
        tester.widget<FilledButton>(find.byType(FilledButton).last).onPressed,
        isNotNull,
      );
    },
  );

  testWidgets(
    'uncertain save freezes one immutable operation and retry reuses every byte',
    (tester) async {
      repository.uncertain = true;
      await mount(tester);
      await tester.tap(find.widgetWithText(FilledButton, l10n.common.save));
      await tester.pumpAndSettle();
      expect(find.text(l10n.month.uncertain), findsOneWidget);
      final first = repository.attempts.single;
      editor.document = validBody.replaceAll(
        'native draft',
        'must not replace attempt',
      );
      await tester.tap(find.widgetWithText(FilledButton, l10n.month.retrySame));
      await tester.pumpAndSettle();
      expect(repository.attempts.length, 2);
      expect(identical(repository.attempts.last, first), true);
      expect(repository.attempts.last.toJson(), first.toJson());
      expect(repository.attempts.last.tiptapJson, validBody);
    },
  );

  testWidgets(
    'conflict preserves draft and does not offer an automatic rebase',
    (tester) async {
      repository.conflict = true;
      await mount(tester);
      await tester.tap(find.widgetWithText(FilledButton, l10n.common.save));
      await tester.pumpAndSettle();
      expect(find.text(l10n.month.conflict), findsOneWidget);
      expect(repository.attempts.single.tiptapJson, validBody);
      expect(
        tester.widget<FilledButton>(find.byType(FilledButton).last).onPressed,
        isNull,
      );
      await tester.tap(find.byKey(const ValueKey('long-document-more')));
      await tester.pumpAndSettle();
      expect(find.text(l10n.month.copyDraft), findsOneWidget);
    },
  );

  testWidgets('empty append leaves without retention dialog', (tester) async {
    editor.document =
        '{"type":"doc","attrs":{"v":2},"content":[{"type":"paragraph"}]}';
    await mount(tester);
    await tester.tap(find.byTooltip(l10n.common.close));
    await tester.pumpAndSettle();
    expect(find.byType(AlertDialog), findsNothing);
    expect(find.byKey(const ValueKey('launch-composer')), findsOneWidget);
    expect(repository.attempts, isEmpty);
  });

  testWidgets('back retains acknowledged content as a local draft', (
    tester,
  ) async {
    final drafts = DailyNotesStore(db);
    addTearDown(drafts.dispose);
    await drafts.open();
    await mount(tester, drafts: drafts);
    await tester.tap(find.byTooltip(l10n.common.close));
    await tester.pumpAndSettle();
    expect(find.text(l10n.month.retainDraftMessage), findsOneWidget);
    await tester.tap(find.text(l10n.month.retainAndLeave));
    await tester.pumpAndSettle();
    expect(drafts.draft('composer-test')!['body'], validBody);
    expect(repository.attempts, isEmpty);
    expect(find.byKey(const ValueKey('launch-composer')), findsOneWidget);
  });

  testWidgets('typing saves the newest draft locally without submitting', (
    tester,
  ) async {
    final drafts = _DraftStore(db);
    addTearDown(drafts.dispose);
    await drafts.open();
    await mount(tester, drafts: drafts);
    final changed = validBody.replaceAll('native draft', 'newest draft');
    editor.document = changed;
    tester.widget<MoodiaryEditor>(find.byType(MoodiaryEditor)).onChanged!(
      changed,
    );
    await tester.pump(const Duration(milliseconds: 300));
    expect(drafts.draft('composer-test'), isNull);
    expect(find.byTooltip(l10n.month.draftAutosavePending), findsOneWidget);
    await tester.pump(const Duration(milliseconds: 300));
    await tester.pumpAndSettle();
    expect(drafts.draft('composer-test')!['body'], changed);
    expect(find.byTooltip(l10n.month.draftAutosaved), findsOneWidget);
    expect(repository.attempts, isEmpty);
  });

  testWidgets('a delayed old save cannot report newer changes as saved', (
    tester,
  ) async {
    final drafts = _DraftStore(db);
    addTearDown(drafts.dispose);
    await drafts.open();
    final gate = Completer<void>();
    drafts.blockNext = gate;
    await mount(tester, drafts: drafts);
    final first = validBody.replaceAll('native draft', 'first edit');
    final second = validBody.replaceAll('native draft', 'second edit');
    editor.document = first;
    tester.widget<MoodiaryEditor>(find.byType(MoodiaryEditor)).onChanged!(
      first,
    );
    await tester.pump(const Duration(milliseconds: 500));
    await tester.pump();
    editor.document = second;
    tester.widget<MoodiaryEditor>(find.byType(MoodiaryEditor)).onChanged!(
      second,
    );
    await tester.pump();
    gate.complete();
    await tester.pump();
    await tester.pump();
    expect(find.byTooltip(l10n.month.draftAutosaved), findsNothing);
    await tester.pump(const Duration(milliseconds: 500));
    await tester.pumpAndSettle();
    expect(drafts.draft('composer-test')!['body'], second);
    expect(find.byTooltip(l10n.month.draftAutosaved), findsOneWidget);
  });

  testWidgets('a late editor snapshot cannot overwrite a newer change', (
    tester,
  ) async {
    final drafts = _DraftStore(db);
    addTearDown(drafts.dispose);
    await drafts.open();
    await mount(tester, drafts: drafts);
    final first = validBody.replaceAll('native draft', 'old snapshot');
    final second = validBody.replaceAll('native draft', 'current edit');
    final snapshot = Completer<String>();
    editor.delayedSnapshot = snapshot;
    editor.document = first;
    tester.widget<MoodiaryEditor>(find.byType(MoodiaryEditor)).onChanged!(
      first,
    );
    await tester.pump(const Duration(milliseconds: 500));
    await tester.pump();
    editor.document = second;
    tester.widget<MoodiaryEditor>(find.byType(MoodiaryEditor)).onChanged!(
      second,
    );
    snapshot.complete(first);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 500));
    await tester.pumpAndSettle();
    expect(drafts.draft('composer-test')!['body'], second);
    expect(find.byTooltip(l10n.month.draftAutosaved), findsOneWidget);
  });

  testWidgets('failed autosave retains content and can be retried', (
    tester,
  ) async {
    final drafts = _DraftStore(db)..failWrites = true;
    addTearDown(drafts.dispose);
    await drafts.open();
    await mount(tester, drafts: drafts);
    final changed = validBody.replaceAll('native draft', 'unsaved content');
    editor.document = changed;
    tester.widget<MoodiaryEditor>(find.byType(MoodiaryEditor)).onChanged!(
      changed,
    );
    await tester.pump(const Duration(milliseconds: 500));
    await tester.pumpAndSettle();
    expect(find.text(l10n.month.draftAutosaveFailed), findsOneWidget);
    expect(find.byTooltip(l10n.month.draftAutosaved), findsNothing);
    drafts.failWrites = false;
    await tester.tap(find.text(l10n.common.retry));
    await tester.pumpAndSettle();
    expect(drafts.draft('composer-test')!['body'], changed);
    expect(find.byTooltip(l10n.month.draftAutosaved), findsOneWidget);
    expect(repository.attempts, isEmpty);
  });

  testWidgets('failed editor snapshot does not claim the draft was saved', (
    tester,
  ) async {
    final drafts = _DraftStore(db);
    addTearDown(drafts.dispose);
    await drafts.open();
    await mount(tester, drafts: drafts);
    editor.fail = true;
    tester.widget<MoodiaryEditor>(find.byType(MoodiaryEditor)).onChanged!(
      validBody,
    );
    await tester.pump(const Duration(milliseconds: 500));
    await tester.pumpAndSettle();
    expect(find.text(l10n.month.draftAutosaveFailed), findsOneWidget);
    expect(find.byTooltip(l10n.month.draftAutosaved), findsNothing);
    expect(drafts.draft('composer-test'), isNull);
    editor.fail = false;
    await tester.tap(find.text(l10n.common.retry));
    await tester.pumpAndSettle();
    expect(drafts.draft('composer-test')!['body'], validBody);
    expect(find.byTooltip(l10n.month.draftAutosaved), findsOneWidget);
  });

  testWidgets(
    'background snapshots editor changes before their callback arrives',
    (tester) async {
      final drafts = _DraftStore(db);
      addTearDown(drafts.dispose);
      await drafts.open();
      await mount(tester, drafts: drafts);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
      await tester.pump();
      await tester.pumpAndSettle();
      expect(drafts.draft('composer-test')!['body'], validBody);
      expect(repository.attempts, isEmpty);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    },
  );

  testWidgets('formal submit waits for an older draft write before cleanup', (
    tester,
  ) async {
    final drafts = _DraftStore(db);
    addTearDown(drafts.dispose);
    await drafts.open();
    final gate = Completer<void>();
    drafts.blockNext = gate;
    await mount(tester, drafts: drafts);
    tester.widget<MoodiaryEditor>(find.byType(MoodiaryEditor)).onChanged!(
      validBody,
    );
    await tester.pump(const Duration(milliseconds: 500));
    await tester.pump();
    await tester.tap(find.widgetWithText(FilledButton, l10n.common.save));
    await tester.pump();
    expect(repository.attempts, isEmpty);
    gate.complete();
    await tester.pumpAndSettle();
    expect(repository.attempts, hasLength(1));
    expect(drafts.draft('composer-test'), isNull);
  });

  testWidgets(
    'retained uncertain request reopens with identical IDs and clears only after success',
    (tester) async {
      final drafts = DailyNotesStore(db);
      addTearDown(drafts.dispose);
      await drafts.open();
      repository.uncertain = true;
      await mount(tester, drafts: drafts);
      await tester.tap(find.widgetWithText(FilledButton, l10n.common.save));
      await tester.pumpAndSettle();
      final original = repository.attempts.single;
      final persisted = drafts.draft('composer-test')!;
      expect(
        (persisted['attempt'] as Map)['operationId'],
        original.operationId,
      );
      await tester.tap(find.byTooltip(l10n.common.close));
      await tester.pumpAndSettle();
      await tester.tap(find.text(l10n.month.retainAndLeave));
      await tester.pumpAndSettle();
      await mount(
        tester,
        drafts: drafts,
        initialDraft: drafts.draft('composer-test'),
      );
      expect(
        tester
            .widget<MoodiaryEditor>(find.byType(MoodiaryEditor))
            .initialContent,
        validBody,
      );
      repository.uncertain = false;
      await tester.tap(find.widgetWithText(FilledButton, l10n.month.retrySame));
      await tester.pumpAndSettle();
      expect(repository.attempts.last.toJson(), original.toJson());
      expect(drafts.draft('composer-test'), isNull);
    },
  );
}
