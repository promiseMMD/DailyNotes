import 'dart:io';

import 'package:dailynotes/src/experimental/diary_autosave_editor.dart';
import 'package:dailynotes/src/experimental/diary_autosave_session.dart';
import 'package:dailynotes/src/experimental/local_journal_spike.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

void main() {
  setUpAll(sqfliteFfiInit);

  late Directory directory;
  late String path;
  late LocalJournalSpike journal;
  ExperimentalDiarySession? session;

  Future<LocalJournalSpike> openJournal({
    Future<void> Function()? fault,
  }) =>
      LocalJournalSpike.open(
        factory: databaseFactoryFfi,
        path: path,
        singleInstance: false,
        afterRevisionWrittenForTest: fault,
      );

  Future<ExperimentalDiarySession> openSession() =>
      ExperimentalDiarySession.open(
        journal: journal,
        entityId: 'widget-diary',
      );

  setUp(() async {
    directory = await Directory.systemTemp.createTemp('daily-editor-widget-');
    path = '${directory.path}/journal.db';
    journal = await openJournal();
  });

  tearDown(() async {
    session?.dispose();
    session = null;
    await journal.close();
    await directory.delete(recursive: true);
  });

  testWidgets('body-first editor shows local state only after commit',
      (tester) async {
    session = await openSession();
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
    await tester.pump();
    await tester.runAsync(() => session!.waitForIdle());
    await tester.pump();

    expect(find.text('本机已保存'), findsOneWidget);
    expect(find.textContaining('WebDAV 未同步'), findsOneWidget);
    expect((await tester.runAsync(() => journal.readDiary('widget-diary')))?.body, 'test text');
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('failed saving surfaces retry and never labels data saved',
      (tester) async {
    var failing = true;
    await journal.close();
    journal = await openJournal(fault: () async {
      if (failing) throw StateError('injected SQLite failure');
    });
    session = await openSession();
    await tester.pumpWidget(
      MaterialApp(home: ExperimentalDiaryEditor(session: session!)),
    );
    await tester.enterText(
      find.byKey(const Key('experimental-diary-input')),
      'unsaved user typing',
    );
    await tester.pump();
    await tester.runAsync(() => session!.waitForIdle());
    await tester.pump();

    expect(find.textContaining('本机保存失败'), findsOneWidget);
    expect(find.byKey(const Key('experimental-retry')), findsOneWidget);
    expect(find.byKey(const Key('experimental-copy')), findsOneWidget);
    expect(find.text('本机已保存'), findsNothing);
    expect(await tester.runAsync(() => journal.readDiary('widget-diary')), isNull);

    failing = false;
    await tester.tap(find.byKey(const Key('experimental-retry')));
    await tester.pump();
    await tester.runAsync(() => session!.waitForIdle());
    await tester.pump();

    expect(find.text('本机已保存'), findsOneWidget);
    expect((await tester.runAsync(() => journal.readDiary('widget-diary')))?.body,
        'unsaved user typing');
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('back navigation refuses to discard unsaved text', (tester) async {
    await journal.close();
    journal = await openJournal(fault: () async {
      throw StateError('injected failure');
    });
    session = await openSession();

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
    await tester.pump();
    await tester.runAsync(() => session!.waitForIdle());
    await tester.pump();

    await tester.pageBack();
    await tester.pumpAndSettle();
    expect(find.text('存在未完成的本机保存'), findsOneWidget);
    expect(find.byKey(const Key('experimental-diary-input')), findsOneWidget);
    expect(session!.text, 'keep it in the editor');
    expect(await tester.runAsync(() => journal.readDiary('widget-diary')), isNull);

    await tester.tap(find.text('继续编辑'));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('experimental-diary-input')), findsOneWidget);
    await tester.pumpWidget(const SizedBox.shrink());
  });
}
