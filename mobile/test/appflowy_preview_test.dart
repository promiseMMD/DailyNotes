import 'package:appflowy_editor/appflowy_editor.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('an empty AppFlowy document can be created and serialized', () {
    final editor = EditorState.blank(withInitialText: true);
    expect(editor.document.toJson(), isNotEmpty);
    editor.dispose();
  });
}
