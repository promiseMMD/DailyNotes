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
}
