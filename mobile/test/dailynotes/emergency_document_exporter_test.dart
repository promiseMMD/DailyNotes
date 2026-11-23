import 'dart:async';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:moodiary_i18n/moodiary_i18n.dart';
import 'package:moodiary_mobile/app/dailynotes/recovery/emergency_document_exporter.dart';
import 'package:moodiary_mobile/app/dailynotes/recovery/emergency_note_export.dart';
import 'package:mui/mui.dart';

void main() {
  setUpAll(() async {
    await setupPluralResolvers();
    await LocaleSettings.setLocale(AppLocale.zh);
  });

  Future<void> showExporter(
    WidgetTester tester, {
    required EmergencyDocumentExporter exporter,
    required FutureOr<EmergencyNoteSnapshot> Function() capture,
    bool Function()? isCurrent,
    void Function(EmergencyExportOutcome)? onComplete,
  }) async {
    await tester.binding.setSurfaceSize(const Size(430, 900));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(
      TranslationProvider(
        child: MaterialApp(
          theme: buildMuiTheme(brightness: Brightness.light),
          home: Scaffold(
            body: Builder(
              builder: (context) => TextButton(
                onPressed: () async {
                  final outcome = await exporter.export(
                    context: context,
                    capture: capture,
                    isCurrent: isCurrent ?? () => context.mounted,
                  );
                  onComplete?.call(outcome);
                },
                child: const Text('open export'),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('open export'));
    await tester.pumpAndSettle();
  }

  Future<void> enterPassword(WidgetTester tester) async {
    await tester.enterText(
      find.byKey(const ValueKey('emergency-password')),
      'secret',
    );
    await tester.enterText(
      find.byKey(const ValueKey('emergency-password-confirmation')),
      'secret',
    );
    await tester.tap(find.text(l10n.dailynotes.confirm).last);
    await tester.pumpAndSettle();
  }

  testWidgets('captures the latest content after password entry', (
    tester,
  ) async {
    var body = 'before password';
    EmergencyNoteSnapshot? archived;
    EmergencyExportOutcome? result;
    final exporter = EmergencyDocumentExporter(
      createArchive: (snapshot, password) async {
        archived = snapshot;
        expect(password, 'secret');
        return Uint8List.fromList([1, 2]);
      },
      saveArchive: (bytes) async {
        expect(bytes, [1, 2]);
        return Uri.parse('content://test/export');
      },
    );
    await showExporter(
      tester,
      exporter: exporter,
      capture: () => EmergencyNoteSnapshot(title: 'Title', body: body),
      onComplete: (value) => result = value,
    );
    await tester.tap(find.text(l10n.dailynotes.confirm).last);
    await tester.pumpAndSettle();
    expect(
      find.text(l10n.dailynotes.emergencyPasswordMismatch),
      findsOneWidget,
    );
    body = 'latest during password';
    await enterPassword(tester);
    expect(archived?.body, 'latest during password');
    expect(result, EmergencyExportOutcome.savedPartial);
    expect(
      find.text(l10n.dailynotes.richEmergencyExportPartial),
      findsOneWidget,
    );
  });

  testWidgets('changed content prevents opening the destination picker', (
    tester,
  ) async {
    var body = 'first';
    var saves = 0;
    final archive = Completer<Uint8List>();
    EmergencyExportOutcome? result;
    final exporter = EmergencyDocumentExporter(
      createArchive: (_, _) => archive.future,
      saveArchive: (_) async {
        saves++;
        return Uri.parse('content://test/saved');
      },
    );
    await showExporter(
      tester,
      exporter: exporter,
      capture: () => EmergencyNoteSnapshot(title: '', body: body),
      onComplete: (value) => result = value,
    );
    await enterPassword(tester);
    body = 'newer';
    archive.complete(Uint8List.fromList([1]));
    await tester.pumpAndSettle();
    expect(saves, 0);
    expect(result, EmergencyExportOutcome.changedBeforeSave);
    expect(find.text(l10n.dailynotes.emergencyExportChanged), findsOneWidget);
  });

  testWidgets('changes while choosing a destination report the older version', (
    tester,
  ) async {
    var body = 'first';
    final destination = Completer<Uri?>();
    EmergencyExportOutcome? result;
    final exporter = EmergencyDocumentExporter(
      createArchive: (_, _) async => Uint8List.fromList([1]),
      saveArchive: (_) => destination.future,
    );
    await showExporter(
      tester,
      exporter: exporter,
      capture: () => EmergencyNoteSnapshot(title: '', body: body),
      onComplete: (value) => result = value,
    );
    await enterPassword(tester);
    body = 'newer';
    destination.complete(Uri.parse('content://test/saved'));
    await tester.pumpAndSettle();
    expect(result, EmergencyExportOutcome.savedOlderVersion);
    expect(
      find.text(l10n.dailynotes.emergencyExportOlderVersion),
      findsOneWidget,
    );
    expect(find.text(l10n.dailynotes.richEmergencyExportPartial), findsNothing);
  });

  for (final scenario in [
    'cancelled',
    'archive_error',
    'picker_error',
    'snapshot_error',
  ]) {
    testWidgets(
      'reports $scenario without claiming current content was saved',
      (tester) async {
        var captures = 0;
        EmergencyExportOutcome? result;
        final exporter = EmergencyDocumentExporter(
          createArchive: (_, _) async {
            if (scenario == 'archive_error') throw StateError('archive failed');
            return Uint8List.fromList([1]);
          },
          saveArchive: (_) async {
            if (scenario == 'picker_error') throw StateError('uncertain write');
            return scenario == 'cancelled'
                ? null
                : Uri.parse('content://test/saved');
          },
        );
        await showExporter(
          tester,
          exporter: exporter,
          capture: () {
            captures++;
            if (scenario == 'snapshot_error' && captures == 3) {
              throw StateError('cannot confirm current editor');
            }
            return const EmergencyNoteSnapshot(title: '', body: 'memory');
          },
          onComplete: (value) => result = value,
        );
        await enterPassword(tester);
        final expected = switch (scenario) {
          'cancelled' => EmergencyExportOutcome.cancelled,
          'archive_error' => EmergencyExportOutcome.failed,
          'picker_error' => EmergencyExportOutcome.saveUnconfirmed,
          _ => EmergencyExportOutcome.savedUnverified,
        };
        final message = switch (scenario) {
          'cancelled' => l10n.dailynotes.emergencyExportCancelled,
          'archive_error' => l10n.dailynotes.emergencyExportFailed,
          'picker_error' => l10n.dailynotes.emergencyExportUnconfirmed,
          _ => l10n.dailynotes.emergencyExportSavedUnverified,
        };
        expect(result, expected);
        expect(find.text(message), findsOneWidget);
        expect(
          find.text(l10n.dailynotes.richEmergencyExportPartial),
          findsNothing,
        );
      },
    );
  }

  testWidgets(
    'closing the editor before archive creation finishes prevents a save',
    (tester) async {
      final archive = Completer<Uint8List>();
      var current = true;
      var saves = 0;
      EmergencyExportOutcome? result;
      await showExporter(
        tester,
        exporter: EmergencyDocumentExporter(
          createArchive: (_, _) => archive.future,
          saveArchive: (_) async {
            saves++;
            return Uri.parse('content://test/saved');
          },
        ),
        capture: () => const EmergencyNoteSnapshot(title: '', body: 'memory'),
        isCurrent: () => current,
        onComplete: (value) => result = value,
      );
      await enterPassword(tester);
      current = false;
      archive.complete(Uint8List.fromList([1]));
      await tester.pumpAndSettle();
      expect(result, EmergencyExportOutcome.cancelled);
      expect(saves, 0);
    },
  );
}
