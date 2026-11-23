import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:fast_zip/fast_zip.dart';

enum EmergencyRecordKind { note, diary, longRecord }

/// Exports an in-memory editor snapshot, not a database version or full backup.
class EmergencyNoteSnapshot {
  const EmergencyNoteSnapshot({
    required this.title,
    required this.body,
    this.documentJson,
    this.kind = EmergencyRecordKind.note,
    this.documentFormat,
    this.metadata = const {},
  });
  final String title;
  final String body;
  final String? documentJson;
  final EmergencyRecordKind kind;
  final String? documentFormat;
  final Map<String, Object?> metadata;

  String get _kindName => switch (kind) {
    EmergencyRecordKind.note => 'note',
    EmergencyRecordKind.diary => 'diary',
    EmergencyRecordKind.longRecord => 'long-record',
  };

  /// Includes every exported field so stale archives are never reported as
  /// representing edits made while the password or destination was selected.
  String get fingerprint => jsonEncode({
    'kind': _kindName,
    'title': title,
    'body': body,
    'documentJson': documentJson,
    'documentFormat': documentFormat,
    'metadata': metadata,
  });

  Map<String, List<int>> entries() => {
    'manifest.json': utf8.encode(
      jsonEncode({
        'format': 'dailynotes-emergency-$_kindName',
        'version': 1,
        'completeness': 'partial',
        'source': 'current-editor-memory',
        'attachmentsIncluded': false,
        'documentFormat': documentJson == null
            ? 'plain-text'
            : documentFormat ?? 'appflowy-json-v1',
      }),
    ),
    '$_kindName.json': utf8.encode(
      jsonEncode({
        'title': title,
        'body': body,
        if (metadata.isNotEmpty) 'metadata': metadata,
      }),
    ),
    if (documentJson != null) 'document.json': utf8.encode(documentJson!),
    '$_kindName.txt': utf8.encode(
      [if (title.isNotEmpty) title, body].join('\n\n'),
    ),
    '$_kindName.md': utf8.encode(
      [if (title.isNotEmpty) '# $title', body].join('\n\n'),
    ),
  };
}

/// Writes all entries using WinZip AES-256. Only encrypted bytes touch disk.
/// The password is never persisted. The caller owns destination selection.
Future<Uint8List> createEmergencyNoteZip({
  required EmergencyNoteSnapshot snapshot,
  required String password,
  required Directory temporaryDirectory,
}) async {
  if (password.isEmpty) throw ArgumentError('A password is required');
  final dir = await temporaryDirectory.createTemp('dailynotes-rescue-');
  try {
    await FastZip.ensureInitialized();
    final file = File('${dir.path}/emergency.zip');
    final zip = await Zip.newInstance(filePath: file.path);
    for (final entry in snapshot.entries().entries) {
      await zip.addBytes(
        zipPath: entry.key,
        data: entry.value,
        password: password,
      );
    }
    await zip.finish();
    return await file.readAsBytes();
  } finally {
    await dir.delete(recursive: true);
  }
}
