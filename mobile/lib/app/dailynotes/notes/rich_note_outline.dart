import 'dart:async';

import 'package:appflowy_editor/appflowy_editor.dart';
import 'package:moodiary_i18n/moodiary_i18n.dart';
import 'package:mui/mui.dart';

/// This view refers to live nodes only. The editor's node IDs are not stored
/// in its document JSON, so they must not be presented as durable bookmarks.
class RichNoteOutline extends StatefulWidget {
  const RichNoteOutline({
    super.key,
    required this.editor,
    required this.onSelect,
  });

  final EditorState editor;
  final ValueChanged<Node> onSelect;

  @override
  State<RichNoteOutline> createState() => _RichNoteOutlineState();
}

class _RichNoteOutlineState extends State<RichNoteOutline> {
  late StreamSubscription<dynamic> _changes;
  String _query = '';

  @override
  void initState() {
    super.initState();
    _listen(widget.editor);
  }

  void _listen(EditorState editor) {
    _changes = editor.transactionStream.listen((event) {
      if (event.$1 == TransactionTime.after &&
          mounted &&
          identical(editor, widget.editor)) {
        setState(() {});
      }
    });
  }

  @override
  void didUpdateWidget(covariant RichNoteOutline oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!identical(oldWidget.editor, widget.editor)) {
      unawaited(_changes.cancel());
      _query = '';
      _listen(widget.editor);
    }
  }

  @override
  void dispose() {
    _changes.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final t = context.l10n.dailynotes;
    final headings = NodeIterator(
      document: widget.editor.document,
      startNode: widget.editor.document.root,
    ).toList().where((node) => node.type == HeadingBlockKeys.type).toList();
    String label(Node node) {
      final text = node.delta?.toPlainText().trim() ?? '';
      return text.isEmpty ? t.untitledHeading : text;
    }

    final filtered = headings
        .where(
          (node) =>
              label(node).toLowerCase().contains(_query.trim().toLowerCase()),
        )
        .toList();
    return Drawer(
      width: MediaQuery.sizeOf(context).width * 0.85,
      child: SafeArea(
        child: Column(
          children: [
            ListTile(
              title: Text(t.documentOutline),
              trailing: IconButton(
                tooltip: context.l10n.common.close,
                icon: const Icon(LucideIcons.x),
                onPressed: () => Navigator.of(context).pop(),
              ),
            ),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16),
              child: TextField(
                key: ObjectKey(widget.editor),
                onChanged: (value) => setState(() => _query = value),
                decoration: InputDecoration(
                  labelText: t.searchOutline,
                  prefixIcon: const Icon(LucideIcons.search),
                ),
              ),
            ),
            Expanded(
              child: filtered.isEmpty
                  ? Center(
                      child: Text(
                        headings.isEmpty ? t.outlineEmpty : t.outlineNoMatch,
                      ),
                    )
                  : ListView.builder(
                      itemCount: filtered.length,
                      itemBuilder: (context, index) {
                        final node = filtered[index];
                        final rawLevel =
                            node.attributes[HeadingBlockKeys.level];
                        final level = rawLevel is int
                            ? rawLevel.clamp(1, 6)
                            : 1;
                        return ListTile(
                          key: ValueKey('outline-${node.id}'),
                          contentPadding: EdgeInsets.only(
                            left: 16.0 + (level - 1) * 16,
                            right: 16,
                          ),
                          title: Text(
                            label(node),
                            maxLines: 2,
                            overflow: TextOverflow.ellipsis,
                          ),
                          onTap: () => widget.onSelect(node),
                        );
                      },
                    ),
            ),
          ],
        ),
      ),
    );
  }
}
