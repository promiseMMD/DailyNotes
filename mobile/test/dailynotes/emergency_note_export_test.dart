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
  test(
    'diary and long-record exports identify their own type and metadata',
    () {
      for (final (kind, label) in [
        (EmergencyRecordKind.diary, 'diary'),
        (EmergencyRecordKind.longRecord, 'long-record'),
      ]) {
        final snapshot = EmergencyNoteSnapshot(
          kind: kind,
          title: '当前记录',
          body: '未保存的正文',
          documentJson: '{"current":true}',
          metadata: const {'recordId': 'original-id', 'draft': true},
        );
        final entries = snapshot.entries();
        final manifest =
            jsonDecode(utf8.decode(entries['manifest.json']!)) as Map;
        final content = jsonDecode(utf8.decode(entries['$label.json']!)) as Map;
        expect(manifest['format'], 'dailynotes-emergency-$label');
        expect(manifest['completeness'], 'partial');
        expect(manifest['source'], 'current-editor-memory');
        expect(content['body'], '未保存的正文');
        expect(content['metadata'], {'recordId': 'original-id', 'draft': true});
        expect(utf8.decode(entries['document.json']!), '{"current":true}');
        expect(entries, isNot(contains('note.json')));
      }
    },
  );

  test('snapshot fingerprint changes with content, type or metadata', () {
    const original = EmergencyNoteSnapshot(
      title: 'a',
      body: 'b',
      metadata: {'day': '17'},
    );
    expect(
      original.fingerprint,
      const EmergencyNoteSnapshot(
        title: 'a',
        body: 'b',
        metadata: {'day': '17'},
      ).fingerprint,
    );
    expect(
      original.fingerprint,
      isNot(
        const EmergencyNoteSnapshot(
          title: 'a',
          body: 'changed',
          metadata: {'day': '17'},
        ).fingerprint,
      ),
    );
    expect(
      original.fingerprint,
      isNot(
        const EmergencyNoteSnapshot(
          kind: EmergencyRecordKind.diary,
          title: 'a',
          body: 'b',
          metadata: {'day': '17'},
        ).fingerprint,
      ),
    );
    expect(
      original.fingerprint,
      isNot(
        const EmergencyNoteSnapshot(
          title: 'a',
          body: 'b',
          metadata: {'day': '18'},
        ).fingerprint,
      ),
    );
  });
}
