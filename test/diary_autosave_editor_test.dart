import 'package:dailynotes/src/experimental/diary_autosave_editor.dart';
import 'package:dailynotes/src/experimental/diary_autosave_session.dart';
import 'package:dailynotes/src/experimental/local_journal_spike.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';

/// Widget-only tests intentionally use deterministic in-memory callbacks.
/// SQLite file persistence and faults are tested separately under
/// test/diary_autosave_session_test.dart using real sqflite_common_ffi.
void main() {
  ExperimentalDiarySession? session;
  String? storedBody;
  var storedRevision = 0;
  var failNextWrite = false;

  Future<ExperimentalDiarySession> createSession() =>
      ExperimentalDiarySession.openWithCallbacksForTest(
        entityId: 'widget-diary',
        read: (id) async => storedBody == null
            ? null
            : DiaryVersion(
                entityId: id,
                revision: storedRevision,
                body: storedBody!,
                savedUtc: 'test-only',
              ),
        save: ({
          required String entityId,
          required String body,
          required int expectedRevision,
        }) async {
          if (failNextWrite) throw StateError('scripted failure');
          if (expectedRevision != storedRevision) {
            throw RevisionMismatch(expectedRevision, storedRevision);
          }
          storedRevision++;
          storedBody = body;
          return DiaryVersion(
            entityId: entityId,
            revision: storedRevision,
            body: body,
            savedUtc: 'test-only',
          );
        },
      );

  setUp(() {
    session = null;
    storedBody = null;
    storedRevision = 0;
    failNextWrite = false;
  });

  tearDown(() => session?.dispose());

  testWidgets('body-first editor shows local status only after its save callback',
      (tester) async {
    session = await createSession();
    await tester.pumpWidget(
      MaterialApp(home: ExperimentalDiaryEditor(session: session!)),
    );
    expect(find.byKey(const Key('experimental-warning')), findsOneWidget);
    expect(find.text('本机未创建记录'), findsOneWidget);
    expect(find.textContaining('WebDAV 未同步'), findsOneWidget);

    await tester.enterText(
      find.byKey(const Key('experimental-diary-input')),
      'test text',
    );
    await tester.pumpAndSettle();

    expect(find.text('本机已保存'), findsOneWidget);
    expect(find.textContaining('WebDAV 未同步'), findsOneWidget);
    expect(storedBody, 'test text');
    expect(storedRevision, 1);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('failure offers explicit retry without claiming a save',
      (tester) async {
    failNextWrite = true;
    session = await createSession();
    await tester.pumpWidget(
      MaterialApp(home: ExperimentalDiaryEditor(session: session!)),
    );
    await tester.enterText(
      find.byKey(const Key('experimental-diary-input')),
      'unsaved user typing',
    );
    await tester.pumpAndSettle();

    expect(find.textContaining('本机保存失败'), findsOneWidget);
    expect(find.byKey(const Key('experimental-retry')), findsOneWidget);
    expect(find.byKey(const Key('experimental-copy')), findsOneWidget);
    expect(find.text('本机已保存'), findsNothing);
    expect(storedBody, isNull);
    expect(session!.text, 'unsaved user typing');

    failNextWrite = false;
    await tester.tap(find.byKey(const Key('experimental-retry')));
    await tester.pumpAndSettle();

    expect(find.text('本机已保存'), findsOneWidget);
    expect(storedBody, 'unsaved user typing');
    expect(storedRevision, 1);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('back navigation refuses to discard unsaved draft', (tester) async {
    failNextWrite = true;
    session = await createSession();
    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (context) => Scaffold(
            body: Center(
              child: TextButton(
                onPressed: () => Navigator.of(context).push(
                  MaterialPageRoute<void>(
                    builder: (_) => ExperimentalDiaryEditor(session: session!),
                  ),
                ),
                child: const Text('打开实验编辑器'),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('打开实验编辑器'));
    await tester.pumpAndSettle();
    await tester.enterText(
      find.byKey(const Key('experimental-diary-input')),
      'keep it in the editor',
    );
    await tester.pumpAndSettle();

    await tester.pageBack();
    await tester.pumpAndSettle();
    expect(find.text('存在未完成的本机保存'), findsOneWidget);
    expect(find.byKey(const Key('experimental-diary-input')), findsOneWidget);
    expect(session!.text, 'keep it in the editor');
    expect(storedBody, isNull);

    await tester.tap(find.text('继续编辑'));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('experimental-diary-input')), findsOneWidget);
    await tester.pumpWidget(const SizedBox.shrink());
  });
}
