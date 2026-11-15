import 'package:appflowy_editor/appflowy_editor.dart';
import 'package:moodiary_i18n/moodiary_i18n.dart';
import 'package:mui/mui.dart';

/// Isolated preview: never reads or writes the user's saved notes.
class AppFlowyPreviewPage extends StatefulWidget {
  const AppFlowyPreviewPage({super.key});

  @override
  State<AppFlowyPreviewPage> createState() => _AppFlowyPreviewPageState();
}

class _AppFlowyPreviewPageState extends State<AppFlowyPreviewPage> {
  final EditorState _editor = EditorState.blank(withInitialText: true);

  @override
  void dispose() {
    _editor.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final text = context.l10n.dailynotes;
    return Scaffold(
      appBar: AppBar(title: Text(text.editorPreview)),
      body: SafeArea(
        child: Column(
          children: [
            Padding(
              padding: const EdgeInsets.all(12),
              child: Text(text.editorPreviewNotice),
            ),
            Expanded(
              child: MobileToolbarV2(
                editorState: _editor,
                toolbarHeight: 48,
                toolbarItems: [
                  textDecorationMobileToolbarItemV2,
                  blocksMobileToolbarItem,
                  linkMobileToolbarItem,
                ],
                child: AppFlowyEditor(editorState: _editor),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
