import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:moodiary_mobile/app/dailynotes/recovery/emergency_note_export.dart';

void main() {
  test(
    'rescue entries contain current editor text and disclose partial scope',
    () {
      const snapshot = EmergencyNoteSnapshot(title: '当前标题', body: '未保存的最新内容');
      final entries = snapshot.entries();
      final manifest =
          jsonDecode(utf8.decode(entries['manifest.json']!)) as Map;
      final note = jsonDecode(utf8.decode(entries['note.json']!)) as Map;
      expect(manifest['source'], 'current-editor-memory');
      expect(manifest['completeness'], 'partial');
      expect(manifest['attachmentsIncluded'], false);
      expect(note['title'], '当前标题');
      expect(note['body'], '未保存的最新内容');
      expect(utf8.decode(entries['note.txt']!), contains('未保存的最新内容'));
      expect(utf8.decode(entries['note.md']!), contains('未保存的最新内容'));
    },
  );
  test('rich rescue preserves original document JSON in addition to text', () {
    const document =
        '{"document":{"type":"page","children":[{"type":"paragraph","data":{"delta":[{"insert":"bold","attributes":{"bold":true}}]}}]}}';
    const snapshot = EmergencyNoteSnapshot(
      title: 'Title',
      body: 'bold',
      documentJson: document,
    );
    final entries = snapshot.entries();
    expect(utf8.decode(entries['document.json']!), document);
    final manifest = jsonDecode(utf8.decode(entries['manifest.json']!)) as Map;
    expect(manifest['documentFormat'], 'appflowy-json-v1');
    expect(manifest['attachmentsIncluded'], false);
  });
}
