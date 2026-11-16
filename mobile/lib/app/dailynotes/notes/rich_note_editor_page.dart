import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:file_picker/file_picker.dart';

import 'package:flutter/services.dart';

import 'package:appflowy_editor/appflowy_editor.dart';
import 'package:moodiary_i18n/moodiary_i18n.dart';
import 'package:mui/mui.dart';

import '../data/daily_notes_store.dart';
import '../recovery/emergency_note_export.dart';

/// AppFlowy document is the source of truth; text is only a list preview.
class RichNoteEditorPage extends StatefulWidget {
  const RichNoteEditorPage({
    super.key,
    required this.store,
    this.note,
    this.folderId,
    this.testEditor,
  });
  final DailyNotesStore store;
  final DailyNote? note;
  final String? folderId;
  @visibleForTesting
  final EditorState? testEditor;

  @override
  State<RichNoteEditorPage> createState() => _RichNoteEditorPageState();
}

class _RichNoteEditorPageState extends State<RichNoteEditorPage>
    with WidgetsBindingObserver {
  late final TextEditingController _title;
  EditorState? _editor;
  StreamSubscription<dynamic>? _changes;
  Timer? _timer;
  Future<void>? _pending;
  String? _id;
  int _revision = 0, _savedRevision = 0;
  bool _failed = false, _allowPop = false, _leaving = false;
  late bool _editing;
  bool _exporting = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _id = widget.note?.id;
    _editing = widget.note == null;
    _title = TextEditingController(text: widget.note?.title ?? '')
      ..addListener(_changed);
    try {
      if (widget.note != null && widget.note!.documentVersion != 1)
        throw StateError('unsupported');
      final json = widget.note?.documentJson;
      _editor = json == null
          ? widget.testEditor ?? EditorState.blank(withInitialText: true)
          : EditorState(
              document: Document.fromJson(
                jsonDecode(json) as Map<String, dynamic>,
              ),
            );
      _editor!.editable = _editing;
      _changes = _editor!.transactionStream.listen((event) {
        if (event.$1 == TransactionTime.after) _changed();
      });
    } catch (_) {
      // Never write back a document we cannot decode safely.
      _editor = null;
    }
  }

  void _changed() {
    _revision++;
    _timer?.cancel();
    _timer = Timer(const Duration(milliseconds: 500), _save);
    if (mounted) setState(() {});
  }

  String _text() =>
      NodeIterator(
            document: _editor!.document,
            startNode: _editor!.document.root,
          )
          .toList()
          .map((node) => node.delta?.toPlainText() ?? '')
          .where((text) => text.isNotEmpty)
          .join('\n');

  Future<void> _save() async {
    if (_editor == null) return;
    if (_pending != null) {
      await _pending;
      if (_revision != _savedRevision && !_failed) await _save();
      return;
    }
    if (_revision == _savedRevision) return;
    final revision = _revision;
    final title = _title.text;
    final body = _text();
    if (_id == null && title.trim().isEmpty && body.trim().isEmpty) {
      _savedRevision = revision;
      if (mounted) setState(() {});
      return;
    }
    final doc = jsonEncode(_editor!.document.toJson());
    final done = Completer<void>();
    _pending = done.future;
    if (mounted) setState(() {});
    var succeeded = false;
    try {
      final note = await widget.store.saveRichNote(
        id: _id,
        title: title,
        plainText: body,
        documentJson: doc,
        documentVersion: 1,
        folderId: widget.note?.folderId ?? widget.folderId,
        tags: widget.note?.tags ?? const [],
      );
      _id = note.id;
      _savedRevision = revision;
      succeeded = true;
      if (_revision == revision) _failed = false;
    } catch (_) {
      _failed = true;
    } finally {
      _pending = null;
      done.complete();
      if (mounted) setState(() {});
    }
    if ((_revision != _savedRevision) && succeeded) await _save();
  }

  Future<void> _emergencyExport() async {
    if (_exporting) return;
    _exporting = true;
    try {
      final snapshot = EmergencyNoteSnapshot(
        title: _title.text,
        body: _text(),
        documentJson: jsonEncode(_editor!.document.toJson()),
      );
      final password = TextEditingController();
      final confirmation = TextEditingController();
      var mismatch = false;
      final selected = await showDialog<String>(
        context: context,
        builder: (dialog) => StatefulBuilder(
          builder: (dialog, setDialogState) => AlertDialog(
            title: Text(context.l10n.dailynotes.emergencyExport),
            content: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(context.l10n.dailynotes.richEmergencyExportWarning),
                TextField(
                  controller: password,
                  obscureText: true,
                  decoration: InputDecoration(
                    labelText: context.l10n.dailynotes.emergencyPassword,
                  ),
                ),
                TextField(
                  controller: confirmation,
                  obscureText: true,
                  decoration: InputDecoration(
                    labelText: context.l10n.dailynotes.emergencyPasswordConfirm,
                    errorText: mismatch
                        ? context.l10n.dailynotes.emergencyPasswordMismatch
                        : null,
                  ),
                ),
              ],
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(dialog),
                child: Text(context.l10n.dailynotes.cancel),
              ),
              TextButton(
                onPressed: () {
                  if (password.text.isEmpty ||
                      password.text != confirmation.text) {
                    setDialogState(() => mismatch = true);
                  } else {
                    Navigator.pop(dialog, password.text);
                  }
                },
                child: Text(context.l10n.dailynotes.confirm),
              ),
            ],
          ),
        ),
      );
      if (selected == null || !mounted) return;
      try {
        final bytes = await createEmergencyNoteZip(
          snapshot: snapshot,
          password: selected,
          temporaryDirectory: Directory.systemTemp,
        );
        final destination = await FilePicker.saveFile(
          fileName: 'DailyNotes-emergency.zip',
          bytes: bytes,
          mimeType: 'application/zip',
        );
        if (!mounted) return;
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              destination == null
                  ? context.l10n.dailynotes.emergencyExportCancelled
                  : context.l10n.dailynotes.richEmergencyExportPartial,
            ),
          ),
        );
      } catch (_) {
        if (mounted)
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text(context.l10n.dailynotes.emergencyExportFailed),
            ),
          );
      }
    } finally {
      _exporting = false;
    }
  }

  Future<void> _leave() async {
    if (_leaving) return;
    _leaving = true;
    _timer?.cancel();
    await _save();
    if (!mounted) return;
    if (_revision != _savedRevision) {
      final discard = await showDialog<bool>(
        context: context,
        builder: (dialog) => AlertDialog(
          title: Text(context.l10n.dailynotes.unsavedExitTitle),
          content: Text(context.l10n.dailynotes.unsavedExitHint),
          actions: [
            TextButton(
              onPressed: _emergencyExport,
              child: Text(context.l10n.dailynotes.emergencyExport),
            ),
            TextButton(
              onPressed: () async {
                final editor = _editor;
                if (editor == null) return;
                await Clipboard.setData(
                  ClipboardData(
                    text: jsonEncode({
                      'format': 'dailynotes-appflowy-document',
                      'version': 1,
                      'title': _title.text,
                      'document': editor.document.toJson(),
                    }),
                  ),
                );
                if (mounted)
                  ScaffoldMessenger.of(context).showSnackBar(
                    SnackBar(content: Text(context.l10n.dailynotes.copied)),
                  );
              },
              child: Text(context.l10n.dailynotes.copyRichJson),
            ),
            TextButton(
              onPressed: () async {
                await _save();
                if (dialog.mounted && _revision == _savedRevision)
                  Navigator.pop(dialog, false);
              },
              child: Text(context.l10n.dailynotes.retry),
            ),
            TextButton(
              onPressed: () => Navigator.pop(dialog, false),
              child: Text(context.l10n.dailynotes.keepEditing),
            ),
            TextButton(
              onPressed: () async {
                final confirmed = await showDialog<bool>(
                  context: dialog,
                  builder: (confirmation) => AlertDialog(
                    title: Text(context.l10n.dailynotes.discardUnsavedTitle),
                    content: Text(
                      context.l10n.dailynotes.discardUnsavedWarning,
                    ),
                    actions: [
                      TextButton(
                        onPressed: () => Navigator.pop(confirmation, false),
                        child: Text(context.l10n.dailynotes.cancel),
                      ),
                      TextButton(
                        onPressed: () => Navigator.pop(confirmation, true),
                        child: Text(
                          context.l10n.dailynotes.discardUnsavedConfirm,
                        ),
                      ),
                    ],
                  ),
                );
                if (confirmed == true && dialog.mounted)
                  Navigator.pop(dialog, true);
              },
              child: Text(context.l10n.dailynotes.discardUnsavedAction),
            ),
          ],
        ),
      );
      if (discard != true || !mounted) {
        _leaving = false;
        return;
      }
    }
    setState(() => _allowPop = true);
    Navigator.pop(context);
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.inactive ||
        state == AppLifecycleState.paused) {
      _timer?.cancel();
      unawaited(_save());
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _timer?.cancel();
    _changes?.cancel();
    _title.dispose();
    _editor?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final t = context.l10n.dailynotes;
    final editor = _editor;
    return PopScope(
      canPop: _allowPop,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) unawaited(_leave());
      },
      child: Scaffold(
        appBar: AppBar(
          title: Text(t.notesTitle),
          leading: IconButton(
            icon: const Icon(LucideIcons.arrowLeft),
            onPressed: _leave,
          ),
          actions: [
            if (editor != null)
              IconButton(
                tooltip: _editing ? t.lockEditing : t.unlockEditing,
                icon: Icon(_editing ? LucideIcons.lock : LucideIcons.lockOpen),
                onPressed: () {
                  if (_editing) {
                    FocusScope.of(context).unfocus();
                    _timer?.cancel();
                    unawaited(_save());
                  }
                  setState(() {
                    _editing = !_editing;
                    editor.editable = _editing;
                  });
                },
              ),
          ],
        ),
        body: editor == null
            ? Center(
                child: Padding(
                  padding: const EdgeInsets.all(24),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(t.richDocumentUnsupported),
                      if (widget.note?.documentJson != null)
                        TextButton(
                          onPressed: () async {
                            await Clipboard.setData(
                              ClipboardData(text: widget.note!.documentJson!),
                            );
                            if (context.mounted) {
                              ScaffoldMessenger.of(
                                context,
                              ).showSnackBar(SnackBar(content: Text(t.copied)));
                            }
                          },
                          child: Text(t.copyOriginalJson),
                        ),
                    ],
                  ),
                ),
              )
            : SafeArea(
                child: Column(
                  children: [
                    Padding(
                      padding: const EdgeInsets.all(8),
                      child: Row(
                        children: [
                          Expanded(
                            child: Text(
                              _failed
                                  ? t.saveFailed
                                  : _revision != _savedRevision
                                  ? t.saving
                                  : _id == null
                                  ? t.unsaved
                                  : t.savedLocally,
                            ),
                          ),
                          if (_failed)
                            TextButton(onPressed: _save, child: Text(t.retry)),
                        ],
                      ),
                    ),
                    Text(t.localOnly),
                    Expanded(
                      child: MobileToolbarV2(
                        editorState: editor,
                        toolbarHeight: 48,
                        toolbarItems: _editing
                            ? [textDecorationMobileToolbarItemV2]
                            : [],
                        child: AppFlowyEditor(
                          editorState: editor,
                          editable: _editing,
                          autoFocus: widget.note == null,
                          header: TextField(
                            controller: _title,
                            readOnly: !_editing,
                            decoration: InputDecoration(
                              hintText: t.noteTitle,
                              border: InputBorder.none,
                            ),
                          ),
                        ),
                      ),
                    ),
                  ],
                ),
              ),
      ),
    );
  }
}
