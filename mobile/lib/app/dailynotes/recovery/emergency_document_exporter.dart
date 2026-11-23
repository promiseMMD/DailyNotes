import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:file_picker/file_picker.dart';
import 'package:moodiary_i18n/moodiary_i18n.dart';
import 'package:mui/mui.dart';

import 'emergency_note_export.dart';

enum EmergencyExportOutcome {
  savedPartial,
  savedOlderVersion,
  savedUnverified,
  changedBeforeSave,
  saveUnconfirmed,
  cancelled,
  failed,
}

/// Shared export flow for the current in-memory document. Exporting does not
/// commit a note, diary or long-record draft and never dismisses exit guards.
class EmergencyDocumentExporter {
  EmergencyDocumentExporter({
    Future<Uint8List> Function(EmergencyNoteSnapshot, String)? createArchive,
    Future<Uri?> Function(Uint8List)? saveArchive,
  }) : _createArchive = createArchive ?? _defaultCreateArchive,
       _saveArchive = saveArchive ?? _defaultSaveArchive;

  final Future<Uint8List> Function(EmergencyNoteSnapshot, String)
  _createArchive;
  final Future<Uri?> Function(Uint8List) _saveArchive;
  bool _busy = false;

  static Future<Uint8List> _defaultCreateArchive(
    EmergencyNoteSnapshot snapshot,
    String password,
  ) => createEmergencyNoteZip(
    snapshot: snapshot,
    password: password,
    temporaryDirectory: Directory.systemTemp,
  );

  static Future<Uri?> _defaultSaveArchive(Uint8List bytes) =>
      FilePicker.saveFile(
        fileName: 'DailyNotes-emergency.zip',
        bytes: bytes,
        mimeType: 'application/zip',
      );

  Future<EmergencyExportOutcome> export({
    required BuildContext context,
    required FutureOr<EmergencyNoteSnapshot> Function() capture,
    required bool Function() isCurrent,
  }) async {
    if (_busy || !context.mounted || !isCurrent()) {
      return EmergencyExportOutcome.cancelled;
    }
    _busy = true;
    bool current() => context.mounted && isCurrent();
    void message(EmergencyExportOutcome outcome) {
      if (!current()) return;
      final t = context.l10n.dailynotes;
      final text = switch (outcome) {
        EmergencyExportOutcome.savedPartial => t.richEmergencyExportPartial,
        EmergencyExportOutcome.savedOlderVersion =>
          t.emergencyExportOlderVersion,
        EmergencyExportOutcome.savedUnverified =>
          t.emergencyExportSavedUnverified,
        EmergencyExportOutcome.changedBeforeSave => t.emergencyExportChanged,
        EmergencyExportOutcome.saveUnconfirmed => t.emergencyExportUnconfirmed,
        EmergencyExportOutcome.cancelled => t.emergencyExportCancelled,
        EmergencyExportOutcome.failed => t.emergencyExportFailed,
      };
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(text)));
    }

    try {
      final password = await showDialog<String>(
        context: context,
        builder: (_) => const _EmergencyPasswordDialog(),
      );
      if (password == null || !current()) {
        return EmergencyExportOutcome.cancelled;
      }
      // Capture after password entry: keyboard callbacks can arrive while a
      // dialog opens, and exporting an earlier snapshot as current is unsafe.
      final snapshot = await capture();
      if (!current()) return EmergencyExportOutcome.cancelled;
      final fingerprint = snapshot.fingerprint;
      final bytes = await _createArchive(snapshot, password);
      if (!current()) return EmergencyExportOutcome.cancelled;
      if ((await capture()).fingerprint != fingerprint) {
        message(EmergencyExportOutcome.changedBeforeSave);
        return EmergencyExportOutcome.changedBeforeSave;
      }
      if (!current()) return EmergencyExportOutcome.cancelled;
      Uri? destination;
      try {
        destination = await _saveArchive(bytes);
      } catch (_) {
        message(EmergencyExportOutcome.saveUnconfirmed);
        return EmergencyExportOutcome.saveUnconfirmed;
      }
      if (destination == null) {
        message(EmergencyExportOutcome.cancelled);
        return EmergencyExportOutcome.cancelled;
      }
      if (!current()) return EmergencyExportOutcome.savedUnverified;
      try {
        if ((await capture()).fingerprint != fingerprint) {
          message(EmergencyExportOutcome.savedOlderVersion);
          return EmergencyExportOutcome.savedOlderVersion;
        }
      } catch (_) {
        message(EmergencyExportOutcome.savedUnverified);
        return EmergencyExportOutcome.savedUnverified;
      }
      message(EmergencyExportOutcome.savedPartial);
      return EmergencyExportOutcome.savedPartial;
    } catch (_) {
      message(EmergencyExportOutcome.failed);
      return EmergencyExportOutcome.failed;
    } finally {
      _busy = false;
    }
  }
}

class _EmergencyPasswordDialog extends StatefulWidget {
  const _EmergencyPasswordDialog();

  @override
  State<_EmergencyPasswordDialog> createState() =>
      _EmergencyPasswordDialogState();
}

class _EmergencyPasswordDialogState extends State<_EmergencyPasswordDialog> {
  final _password = TextEditingController();
  final _confirmation = TextEditingController();
  bool _mismatch = false;

  @override
  void dispose() {
    _password.dispose();
    _confirmation.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final t = context.l10n.dailynotes;
    return AlertDialog(
      title: Text(t.emergencyExport),
      content: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(t.richEmergencyExportWarning),
            TextField(
              key: const ValueKey('emergency-password'),
              controller: _password,
              obscureText: true,
              decoration: InputDecoration(labelText: t.emergencyPassword),
            ),
            TextField(
              key: const ValueKey('emergency-password-confirmation'),
              controller: _confirmation,
              obscureText: true,
              decoration: InputDecoration(
                labelText: t.emergencyPasswordConfirm,
                errorText: _mismatch ? t.emergencyPasswordMismatch : null,
              ),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: Text(t.cancel),
        ),
        TextButton(
          onPressed: () {
            if (_password.text.isEmpty ||
                _password.text != _confirmation.text) {
              setState(() => _mismatch = true);
            } else {
              Navigator.pop(context, _password.text);
            }
          },
          child: Text(t.confirm),
        ),
      ],
    );
  }
}
