import 'dart:convert';

import 'package:appflowy_editor/appflowy_editor.dart' as af;
import 'package:flutter_test/flutter_test.dart';
import 'package:moodiary_mobile/app/dailynotes/editor/document_envelope.dart';

void main() {
  test('local native documents are not limited by the LAN request budget', () {
    final text = List.filled(40000, '长').join();
    final document = af.Document(
      root: af.pageNode(children: [af.paragraphNode(text: text)]),
    );
    final encoded = DailyNotesDocumentEnvelope.encode(document);
    expect(utf8.encode(encoded).length, greaterThan(200000));
    expect(
      DailyNotesDocumentEnvelope.plainText(
        DailyNotesDocumentEnvelope.decode(encoded),
      ),
      text,
    );
  });
  test(
    'native blocks and rich marks round trip with a readable projection',
    () {
      final document = af.Document(
        root: af.pageNode(
          children: [
            af.headingNode(level: 2, text: 'Title'),
            af.bulletedListNode(
              delta: af.Delta()
                ..insert(
                  'word',
                  attributes: {'bold': true, 'textColor': '0xffd32f2f'},
                ),
            ),
            af.dividerNode(),
            af.paragraphNode(text: 'Last'),
          ],
        ),
      );
      final raw = DailyNotesDocumentEnvelope.encode(document);
      final copy = DailyNotesDocumentEnvelope.decode(raw);
      expect(jsonEncode(copy.toJson()), jsonEncode(document.toJson()));
      expect(DailyNotesDocumentEnvelope.plainText(copy), 'Title\nword\nLast');
      expect(DailyNotesDocumentEnvelope.hasNativeDocument(raw), isTrue);
    },
  );

  test(
    'stale projection and unknown legacy structures never overwrite content',
    () {
      final document = af.Document(
        root: af.pageNode(children: [af.paragraphNode(text: 'one')]),
      );
      final value = jsonDecode(
        DailyNotesDocumentEnvelope.encode(document),
      ) as Map<String, dynamic>;
      value['content'] = [
        {
          'type': 'paragraph',
          'content': [
            {'type': 'text', 'text': 'changed externally'},
          ],
        },
      ];
      expect(
        () => DailyNotesDocumentEnvelope.decode(jsonEncode(value)),
        throwsFormatException,
      );
      expect(
        () => DailyNotesDocumentEnvelope.decode(
          jsonEncode({
            'type': 'doc',
            'attrs': {'v': 2},
            'content': [
              {'type': 'image'},
            ],
          }),
        ),
        throwsFormatException,
      );
    },
  );

  test('supported legacy text and heading preserve their formatting', () {
    final document = DailyNotesDocumentEnvelope.decode(
      jsonEncode({
        'type': 'doc',
        'attrs': {'v': 2},
        'content': [
          {
            'type': 'heading',
            'attrs': {'level': 2},
            'content': [
              {
                'type': 'text',
                'text': 'hello',
                'marks': [
                  {'type': 'bold'},
                  {'type': 'italic'},
                ],
              },
            ],
          },
          {
            'type': 'paragraph',
            'content': [
              {'type': 'text', 'text': 'world'},
            ],
          },
        ],
      }),
    );
    expect(document.root.children.first.type, af.HeadingBlockKeys.type);
    final serialized = jsonEncode(document.toJson());
    expect(serialized, contains('"bold":true'));
    expect(serialized, contains('"italic":true'));
    expect(DailyNotesDocumentEnvelope.plainText(document), 'hello\nworld');
  });
}
