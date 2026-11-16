import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:fast_zip/fast_zip.dart';

/// Exports the current in-memory plain-text editor snapshot, not a DB version.
/// This format is an emergency extract and does not claim to be a full backup.
class EmergencyNoteSnapshot {
  const EmergencyNoteSnapshot({
    required this.title,
    required this.body,
    this.documentJson,
  });
  final String title;
  final String body;
  final String? documentJson;

  Map<String, List<int>> entries() => {
    'manifest.json': utf8.encode(
      jsonEncode({
        'format': 'dailynotes-emergency-note',
        'version': 1,
        'completeness': 'partial',
        'source': 'current-editor-memory',
        'attachmentsIncluded': false,
        'documentFormat': documentJson == null
            ? 'plain-text'
            : 'appflowy-json-v1',
      }),
    ),
    'note.json': utf8.encode(jsonEncode({'title': title, 'body': body})),
    if (documentJson != null) 'document.json': utf8.encode(documentJson!),
    'note.txt': utf8.encode([if (title.isNotEmpty) title, body].join('\n\n')),
    'note.md': utf8.encode(
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
