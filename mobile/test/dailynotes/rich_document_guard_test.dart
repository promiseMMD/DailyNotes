import 'dart:convert';

import 'package:appflowy_editor/appflowy_editor.dart' as af;
import 'package:flutter_test/flutter_test.dart';
import 'package:moodiary_mobile/app/dailynotes/data/rich_document_guard.dart';

void main() {
  test('supported document is accepted without discarding text attributes', () {
    const raw =
        '{"document":{"type":"page","children":[{"type":"paragraph","data":{"delta":[{"insert":"hello","attributes":{"bold":true}}]}}]}}';
    expect(validateRichDocument(raw)['document'], isA<Map>());
  });
  test('unsupported block type and unrecognised fields fail closed', () {
    expect(
      () => validateRichDocument(
        '{"document":{"type":"page","children":[{"type":"future-block"}]}}',
      ),
      throwsFormatException,
    );
    expect(
      () =>
          validateRichDocument('{"document":{"type":"page","future":"data"}}'),
      throwsFormatException,
    );
    expect(
      () => validateRichDocument('{"document":{"type":"page"},"extra":"data"}'),
      throwsFormatException,
    );
  });
  test('malformed node data and children fail closed', () {
    expect(
      () => validateRichDocument('{"document":{"type":"page","data":42}}'),
      throwsFormatException,
    );
    expect(
      () => validateRichDocument('{"document":{"type":"page","children":{}}}'),
      throwsFormatException,
    );
  });
  test(
    'unknown delta operation fields would be discarded by a text edit',
    () async {
      const raw =
          '{"document":{"type":"page","children":['
          '{"type":"paragraph","data":{"delta":['
          '{"insert":"hello","future_metadata":{"id":"keep"}}]}}]}}';
      expect(() => validateRichDocument(raw), throwsFormatException);
      // Demonstrates the SDK behavior that makes the guard necessary.
      final editor = af.EditorState(
        document: af.Document.fromJson(jsonDecode(raw)),
      );
      final selection = af.Selection.single(
        path: [0],
        startOffset: 0,
        endOffset: 2,
      );
      editor.selection = selection;
      await editor.formatDelta(selection, {af.AppFlowyRichTextKeys.bold: true});
      expect(
        jsonEncode(editor.document.toJson()),
        isNot(contains('future_metadata')),
      );
      editor.dispose();
    },
  );

  test('unknown delta operations and embedded inserts fail closed', () {
    for (final operation in [
      {
        'future_operation': {'text': 'keep'},
      },
      {
        'insert': {'image': 'asset-id'},
      },
      {'retain': 3},
      {'delete': 2},
      {'insert': 'abc', 'attributes': 'invalid'},
    ]) {
      final raw = jsonEncode({
        'document': {
          'type': 'page',
          'children': [
            {
              'type': 'paragraph',
              'data': {
                'delta': [operation],
              },
            },
          ],
        },
      });
      expect(() => validateRichDocument(raw), throwsFormatException);
    }
  });

  test('rich attributes and nested block structure remain accepted', () {
    final raw = jsonEncode({
      'document': {
        'type': 'page',
        'children': [
          {
            'type': 'bulleted_list',
            'data': {
              'delta': [
                {
                  'insert': 'rich',
                  'attributes': {
                    'bold': true,
                    'italic': true,
                    'underline': true,
                    'strikethrough': true,
                    'font_color': '0xff123456',
                    'bg_color': '0xffabcdef',
                    'font_family': 'serif',
                    'href': 'https://example.com',
                    'custom_attribute': {'v': 1},
                  },
                },
                {
                  'insert': 'default',
                  'attributes': {'font_family': null},
                },
                {'insert': 'plain', 'attributes': null},
              ],
            },
            'children': [
              {
                'type': 'paragraph',
                'data': {
                  'delta': [
                    {'insert': 'nested'},
                  ],
                },
              },
            ],
          },
        ],
      },
    });
    expect(validateRichDocument(raw)['document'], isA<Map>());
  });
}
