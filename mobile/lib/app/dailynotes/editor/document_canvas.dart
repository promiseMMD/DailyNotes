import 'package:appflowy_editor/appflowy_editor.dart' as af;
import 'package:mui/mui.dart';

import '../notes/rich_editor_toolbar.dart';

/// One mobile document surface for notes, diaries and long-record drafts.
/// The owning page remains responsible for its own persistence lifecycle.
class DailyNotesDocumentCanvas extends StatelessWidget {
  const DailyNotesDocumentCanvas({
    super.key,
    required this.editor,
    required this.focusNode,
    required this.scrollController,
    required this.editable,
    this.autoFocus = false,
    this.header,
  });

  final af.EditorState editor;
  final FocusNode focusNode;
  final af.EditorScrollController scrollController;
  final bool editable;
  final bool autoFocus;
  final Widget? header;

  @override
  Widget build(BuildContext context) {
    final colors = context.theme.colors;
    const horizontalPadding = 20.0;
    return RichEditorToolbar(
      editor: editor,
      focusNode: focusNode,
      editable: editable,
      child: af.AppFlowyEditor(
        editorState: editor,
        focusNode: focusNode,
        editorScrollController: scrollController,
        editable: editable,
        autoFocus: autoFocus,
        // The SDK defaults to desktop styling, including 100 px margins and
        // no mobile selection handles. Use its mobile configuration explicitly.
        editorStyle: af.EditorStyle.mobile(
          padding: const EdgeInsets.symmetric(horizontal: horizontalPadding),
          cursorColor: colors.primary,
          dragHandleColor: colors.primary,
          selectionColor: colors.primary.withValues(alpha: 0.25),
          textStyleConfiguration: af.TextStyleConfiguration(
            text: context.theme.typography.bodyLarge.onSurface,
          ),
        ),
        header: header == null
            ? null
            : Padding(
                padding: const EdgeInsets.symmetric(
                  horizontal: horizontalPadding,
                ),
                child: header!,
              ),
      ),
    );
  }
}
