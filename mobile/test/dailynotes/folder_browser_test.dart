import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:moodiary_data/moodiary_data.dart';
import 'package:moodiary_di/moodiary_di.dart';
import 'package:moodiary_i18n/moodiary_i18n.dart';
import 'package:moodiary_mobile/app/dailynotes/data/daily_notes_store.dart';
import 'package:moodiary_mobile/app/dailynotes/notes/notes_page.dart';
import 'package:moodiary_storage/moodiary_storage.dart';
import 'package:moodiary_storage/testing.dart';
import 'package:mui/mui.dart';

void main() {
  late MoodiaryDatabase db;
  late DailyNotesStore store;
  setUpAll(() async {
    getIt.registerSingleton<IKVStorage>(MemoryKVStorage());
    await setupPluralResolvers();
    await LocaleSettings.setLocale(AppLocale.zh);
  });
  tearDownAll(() => getIt.reset());
  setUp(() async {
    db = MoodiaryDatabase.forTesting(NativeDatabase.memory());
    store = DailyNotesStore(db);
    await store.open();
  });
  tearDown(() async {
    store.dispose();
    await db.close();
  });

  Future<void> mountNotes(WidgetTester tester) async {
    tester.view.physicalSize = const Size(430, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(
      TranslationProvider(
        child: MaterialApp(
          theme: buildMuiTheme(brightness: Brightness.light),
          localizationsDelegates: const [
            ...GlobalMaterialLocalizations.delegates,
            GlobalMuiLocalizations.delegate,
          ],
          builder: (context, child) =>
              MaterialUiCompatibilityBridge(child: child!),
          home: DailyNotesNotesPage(store: store),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  Future<void> openFolders(WidgetTester tester) async {
    await mountNotes(tester);
    await tester.tap(find.byTooltip(l10n.dailynotes.folderTree));
    await tester.pumpAndSettle();
  }

  testWidgets(
    'tag search spans folders and restores the previous folder when cleared',
    (tester) async {
      await tester.runAsync(() async {
        final a = await store.createFolder('Alpha');
        final b = await store.createFolder('Beta');
        await store.saveNote(
          title: 'Alpha note',
          body: 'One',
          folderId: a.id,
          tags: ['shared'],
        );
        await store.saveNote(
          title: 'Beta note',
          body: 'Two',
          folderId: b.id,
          tags: ['shared'],
        );
        await store.saveNote(
          title: 'Other',
          body: 'Three',
          folderId: b.id,
          tags: ['different'],
        );
      });
      await mountNotes(tester);
      await tester.tap(find.text('Alpha'));
      await tester.pumpAndSettle();
      expect(find.text('Alpha note'), findsOneWidget);
      expect(find.text('Beta note'), findsNothing);
      await tester.tap(find.byTooltip(l10n.dailynotes.searchNotes));
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(TextField), '#shared');
      await tester.pumpAndSettle();
      expect(find.text('Alpha note'), findsOneWidget);
      expect(find.text('Beta note'), findsOneWidget);
      expect(find.text('Other'), findsNothing);
      await tester.tap(find.byTooltip(l10n.dailynotes.clearFolderSearch));
      await tester.pumpAndSettle();
      expect(find.text('Alpha note'), findsOneWidget);
      expect(find.text('Beta note'), findsNothing);
      await tester.pumpWidget(const SizedBox());
    },
  );

  testWidgets('folder search spans the tree and displays complete paths', (
    tester,
  ) async {
    late DailyFolder exact, partial, nested;
    await tester.runAsync(() async {
      final a = await store.createFolder('Alpha');
      final b = await store.createFolder('Beta');
      exact = await store.createFolder('Project', parentId: a.id);
      partial = await store.createFolder('Project archive', parentId: b.id);
      nested = await store.createFolder('Documents', parentId: partial.id);
    });
    await openFolders(tester);
    await tester.tap(find.byTooltip(l10n.dailynotes.searchFolders));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField), 'Project');
    await tester.pumpAndSettle();
    expect(find.byKey(ValueKey('folder-search-${exact.id}')), findsOneWidget);
    expect(find.byKey(ValueKey('folder-search-${partial.id}')), findsOneWidget);
    expect(find.textContaining('Alpha / Project'), findsOneWidget);
    expect(find.textContaining('Beta / Project archive'), findsNWidgets(2));
    final first = tester
        .getTopLeft(find.byKey(ValueKey('folder-search-${exact.id}')))
        .dy;
    final second = tester
        .getTopLeft(find.byKey(ValueKey('folder-search-${partial.id}')))
        .dy;
    expect(first, lessThan(second));
    await tester.enterText(find.byType(TextField), 'Beta / Project archive');
    await tester.pumpAndSettle();
    expect(find.byKey(ValueKey('folder-search-${partial.id}')), findsOneWidget);
    expect(find.byKey(ValueKey('folder-search-${nested.id}')), findsOneWidget);
    expect(
      tester.getTopLeft(find.byKey(ValueKey('folder-search-${partial.id}'))).dy,
      lessThan(
        tester
            .getTopLeft(find.byKey(ValueKey('folder-search-${nested.id}')))
            .dy,
      ),
    );
    await tester.enterText(find.byType(TextField), 'no such folder');
    await tester.pumpAndSettle();
    expect(find.text(l10n.dailynotes.noFolderMatches), findsOneWidget);
    expect(
      tester.widget<TextField>(find.byType(TextField)).controller!.text,
      'no such folder',
    );
    await tester.tap(find.byTooltip(l10n.dailynotes.clearFolderSearch));
    await tester.pumpAndSettle();
    expect(find.text(l10n.dailynotes.noFolderMatches), findsNothing);
    expect(find.text('Alpha'), findsOneWidget);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets(
    'folder removal previews impact and transfers contents only after confirmation',
    (tester) async {
      late DailyFolder folder, child;
      late DailyNote note;
      await tester.runAsync(() async {
        folder = await store.createFolder('Old');
        child = await store.createFolder('Child', parentId: folder.id);
        note = await store.saveNote(
          title: 'Preserved',
          body: 'Text',
          folderId: folder.id,
        );
      });
      await openFolders(tester);
      Future<void> showRemoval() async {
        await tester.tap(
          find.descendant(
            of: find.byKey(ValueKey(folder.id)),
            matching: find.byTooltip(l10n.dailynotes.folderMore),
          ),
        );
        await tester.pumpAndSettle();
        await tester.tap(find.text(l10n.dailynotes.delete).last);
        await tester.runAsync(() async {
          await Future<void>.delayed(const Duration(milliseconds: 100));
        });
        await tester.pumpAndSettle();
      }

      await showRemoval();
      expect(
        find.text(l10n.dailynotes.removeFolderTitle(name: 'Old')),
        findsOneWidget,
      );
      expect(find.textContaining('1 篇笔记'), findsOneWidget);
      await tester.tap(find.text(l10n.dailynotes.cancel).last);
      await tester.pumpAndSettle();
      expect(store.notes.single.folderId, folder.id);
      await showRemoval();
      await tester.tap(find.text(l10n.dailynotes.delete).last);
      await tester.runAsync(() async {
        await Future<void>.delayed(const Duration(milliseconds: 100));
      });
      await tester.pumpAndSettle();
      expect(store.folders.any((item) => item.id == folder.id), isFalse);
      expect(
        store.folders.singleWhere((item) => item.id == child.id).parentId,
        isNull,
      );
      expect(
        store.notes.singleWhere((item) => item.id == note.id).folderId,
        isNull,
      );
      expect(store.notes.single.body, 'Text');
      await tester.pumpWidget(const SizedBox());
    },
  );

  testWidgets('deep folders use a branch view with clickable ancestors', (
    tester,
  ) async {
    late DailyFolder a, b, c, d;
    await tester.runAsync(() async {
      a = await store.createFolder('A');
      b = await store.createFolder('B', parentId: a.id);
      c = await store.createFolder('C', parentId: b.id);
      d = await store.createFolder('D', parentId: c.id);
      await store.createFolder('E', parentId: d.id);
      await store.saveNote(title: 'Note in D', body: 'Content', folderId: d.id);
    });
    await openFolders(tester);
    for (final folder in [a, b, c]) {
      await tester.tap(
        find
            .descendant(
              of: find.byKey(ValueKey(folder.id)),
              matching: find.byIcon(LucideIcons.folder),
            )
            .first,
      );
      await tester.pumpAndSettle();
    }
    await tester.tap(find.text(l10n.dailynotes.enterFolderBranch));
    await tester.pumpAndSettle();
    expect(find.text('D'), findsOneWidget);
    expect(find.text('A'), findsOneWidget);
    expect(find.text('B'), findsOneWidget);
    expect(find.text('C'), findsOneWidget);
    await tester.tap(find.text('B'));
    await tester.pumpAndSettle();
    expect(find.text('C'), findsOneWidget);
    await tester.pageBack();
    await tester.pumpAndSettle();
    expect(find.text('B'), findsOneWidget);
    for (final folder in [b, c]) {
      await tester.tap(
        find
            .descendant(
              of: find.byKey(ValueKey(folder.id)),
              matching: find.byIcon(LucideIcons.folder),
            )
            .first,
      );
      await tester.pumpAndSettle();
    }
    await tester.tap(find.text('D'));
    await tester.pumpAndSettle();
    expect(find.text('Note in D'), findsOneWidget);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets(
    'collapsed deep path opens an ancestor list for direct navigation',
    (tester) async {
      final folders = <DailyFolder>[];
      await tester.runAsync(() async {
        String? parent;
        for (final name in ['A', 'B', 'C', 'D', 'E', 'F', 'G']) {
          final folder = await store.createFolder(name, parentId: parent);
          folders.add(folder);
          parent = folder.id;
        }
      });
      await openFolders(tester);
      for (final group in [folders.take(3), folders.skip(3).take(3)]) {
        for (final folder in group) {
          await tester.tap(
            find
                .descendant(
                  of: find.byKey(ValueKey(folder.id)),
                  matching: find.byIcon(LucideIcons.folder),
                )
                .first,
          );
          await tester.pumpAndSettle();
        }
        await tester.tap(find.text(l10n.dailynotes.enterFolderBranch));
        await tester.pumpAndSettle();
      }
      await tester.tap(find.text('…'));
      await tester.pumpAndSettle();
      expect(find.text('B'), findsOneWidget);
      await tester.tap(find.text('B'));
      await tester.pumpAndSettle();
      expect(find.byKey(ValueKey(folders[2].id)), findsOneWidget);
      await tester.pumpWidget(const SizedBox());
    },
  );

  testWidgets(
    'collapsed path search covers the tree and navigates to results',
    (tester) async {
      final folders = <DailyFolder>[];
      late DailyFolder other, exact, partial, destination;
      await tester.runAsync(() async {
        String? parent;
        for (final name in ['A', 'B', 'C', 'D', 'E', 'F', 'G']) {
          final folder = await store.createFolder(name, parentId: parent);
          folders.add(folder);
          parent = folder.id;
        }
        other = await store.createFolder('Other');
        exact = await store.createFolder('Project', parentId: other.id);
        destination = await store.createFolder(
          'Destination',
          parentId: exact.id,
        );
        partial = await store.createFolder(
          'Project archive',
          parentId: other.id,
        );
      });
      await openFolders(tester);
      for (final group in [folders.take(3), folders.skip(3).take(3)]) {
        for (final folder in group) {
          await tester.tap(
            find
                .descendant(
                  of: find.byKey(ValueKey(folder.id)),
                  matching: find.byIcon(LucideIcons.folder),
                )
                .first,
          );
          await tester.pumpAndSettle();
        }
        await tester.tap(find.text(l10n.dailynotes.enterFolderBranch));
        await tester.pumpAndSettle();
      }
      await tester.tap(find.text('…'));
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('folder-path-search')), findsNothing);
      expect(
        find.byKey(ValueKey('folder-path-ancestor-${folders[1].id}')),
        findsOneWidget,
      );
      await tester.tap(find.byKey(const ValueKey('folder-path-search-toggle')));
      await tester.pumpAndSettle();
      await tester.enterText(
        find.byKey(const ValueKey('folder-path-search')),
        'Project',
      );
      await tester.pumpAndSettle();
      final exactResult = find.byKey(
        ValueKey('folder-path-result-${exact.id}'),
      );
      final partialResult = find.byKey(
        ValueKey('folder-path-result-${partial.id}'),
      );
      expect(exactResult, findsOneWidget);
      expect(partialResult, findsOneWidget);
      expect(find.textContaining('Other / Project'), findsWidgets);
      expect(
        tester.getTopLeft(exactResult).dy,
        lessThan(tester.getTopLeft(partialResult).dy),
      );
      await tester.enterText(
        find.byKey(const ValueKey('folder-path-search')),
        'missing',
      );
      await tester.pumpAndSettle();
      expect(find.text(l10n.dailynotes.noFolderMatches), findsOneWidget);
      expect(
        tester
            .widget<TextField>(find.byKey(const ValueKey('folder-path-search')))
            .controller!
            .text,
        'missing',
      );
      await tester.tap(find.byTooltip(l10n.dailynotes.clearFolderSearch));
      await tester.pumpAndSettle();
      expect(
        find.byKey(ValueKey('folder-path-ancestor-${folders[1].id}')),
        findsOneWidget,
      );
      await tester.enterText(
        find.byKey(const ValueKey('folder-path-search')),
        'Projecq',
      );
      await tester.pumpAndSettle();
      expect(find.text(l10n.dailynotes.similarFolders), findsOneWidget);
      expect(
        find.byKey(ValueKey('folder-suggestion-${exact.id}')),
        findsNothing,
      );
      await tester.tap(find.text(l10n.dailynotes.similarFolders));
      await tester.pumpAndSettle();
      expect(
        find.byKey(ValueKey('folder-suggestion-${exact.id}')),
        findsOneWidget,
      );
      await tester.enterText(
        find.byKey(const ValueKey('folder-path-search')),
        'Other / Project',
      );
      await tester.pumpAndSettle();
      await tester.tap(exactResult);
      await tester.pumpAndSettle();
      expect(find.byKey(ValueKey(destination.id)), findsOneWidget);
      expect(
        store.folders.singleWhere((folder) => folder.id == exact.id).parentId,
        other.id,
      );
      expect(
        store.folders
            .singleWhere((folder) => folder.id == destination.id)
            .parentId,
        exact.id,
      );
      await tester.pumpWidget(const SizedBox());
    },
  );

  testWidgets('similar folders are folded, limited and preserve tree order', (
    tester,
  ) async {
    final folders = <DailyFolder>[];
    await tester.runAsync(() async {
      for (final name in ['Stage', 'Stagw', 'Stagx', 'Stagy', 'Unrelated']) {
        folders.add(await store.createFolder(name));
      }
      await store.saveNote(
        title: 'Selected folder note',
        body: 'content',
        folderId: folders.first.id,
      );
    });
    await openFolders(tester);
    await tester.tap(find.byTooltip(l10n.dailynotes.searchFolders));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField), 'Stage');
    await tester.pumpAndSettle();
    expect(find.text(l10n.dailynotes.similarFolders), findsNothing);
    await tester.enterText(find.byType(TextField), 'Stagf');
    await tester.pumpAndSettle();
    expect(find.text(l10n.dailynotes.noFolderMatches), findsOneWidget);
    expect(find.text(l10n.dailynotes.similarFolders), findsOneWidget);
    expect(
      find.byKey(ValueKey('folder-suggestion-${folders.first.id}')),
      findsNothing,
    );
    await tester.tap(find.text(l10n.dailynotes.similarFolders));
    await tester.pumpAndSettle();
    for (final folder in folders.take(3)) {
      expect(
        find.byKey(ValueKey('folder-suggestion-${folder.id}')),
        findsOneWidget,
      );
    }
    expect(
      find.byKey(ValueKey('folder-suggestion-${folders[3].id}')),
      findsNothing,
    );
    expect(
      tester
          .getTopLeft(
            find.byKey(ValueKey('folder-suggestion-${folders[0].id}')),
          )
          .dy,
      lessThan(
        tester
            .getTopLeft(
              find.byKey(ValueKey('folder-suggestion-${folders[1].id}')),
            )
            .dy,
      ),
    );
    await tester.tap(
      find.byKey(ValueKey('folder-suggestion-${folders.first.id}')),
    );
    await tester.pumpAndSettle();
    expect(find.text('Selected folder note'), findsOneWidget);
    expect(store.folders, hasLength(5));
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets(
    'similar folder search handles Chinese text without changing it',
    (tester) async {
      late DailyFolder folder;
      await tester.runAsync(() async {
        folder = await store.createFolder('工艺资料');
        await store.createFolder('其他文件');
      });
      await openFolders(tester);
      await tester.tap(find.byTooltip(l10n.dailynotes.searchFolders));
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(TextField), '工艺资枓');
      await tester.pumpAndSettle();
      await tester.tap(find.text(l10n.dailynotes.similarFolders));
      await tester.pumpAndSettle();
      expect(
        find.byKey(ValueKey('folder-suggestion-${folder.id}')),
        findsOneWidget,
      );
      expect(
        store.folders.singleWhere((item) => item.id == folder.id).name,
        '工艺资料',
      );
      await tester.pumpWidget(const SizedBox());
    },
  );
}
