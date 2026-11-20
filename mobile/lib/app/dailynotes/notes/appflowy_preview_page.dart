import 'package:appflowy_editor/appflowy_editor.dart';
import 'package:moodiary_i18n/moodiary_i18n.dart';
import 'package:mui/mui.dart';

import '../editor/document_canvas.dart';
import '../editor/document_history_actions.dart';

/// Isolated preview: never reads or writes the user's saved notes.
class AppFlowyPreviewPage extends StatefulWidget {
  const AppFlowyPreviewPage({super.key});

  @override
  State<AppFlowyPreviewPage> createState() => _AppFlowyPreviewPageState();
}

class _AppFlowyPreviewPageState extends State<AppFlowyPreviewPage> {
  final EditorState _editor = EditorState.blank(withInitialText: true);
  final FocusNode _focus = FocusNode(debugLabel: 'preview-document');
  late final EditorScrollController _scroll = EditorScrollController(
    editorState: _editor,
  );

  @override
  void dispose() {
    _scroll.dispose();
    _editor.dispose();
    _focus.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final text = context.l10n.dailynotes;
    return Scaffold(
      appBar: AppBar(
        title: Text(text.editorPreview),
        actions: [DocumentHistoryActions(editor: _editor, editable: true)],
      ),
      body: SafeArea(
        child: Column(
          children: [
            Padding(
              padding: const EdgeInsets.all(12),
              child: Text(text.editorPreviewNotice),
            ),
            Expanded(
              child: DailyNotesDocumentCanvas(
                editor: _editor,
                focusNode: _focus,
                scrollController: _scroll,
                editable: true,
                showHistoryActionsInToolbar: false,
                autoFocus: true,
              ),
            ),
          ],
        ),
      ),
    );
  }
}
