import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:appflowy_editor/appflowy_editor.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/services.dart';
import 'package:moodiary_i18n/moodiary_i18n.dart';
import 'package:mui/mui.dart';

import '../data/daily_notes_store.dart';
import '../data/rich_document_guard.dart';
import '../editor/document_canvas.dart';
import '../editor/document_editor_back_controller.dart';
import '../editor/document_history_actions.dart';
import '../editor/document_outline_navigation.dart';
import '../recovery/emergency_note_export.dart';
import 'rich_note_outline.dart';

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

enum _NoteDocumentAction { outline, folder, tags, archive, unarchive, delete }

class _RichNoteEditorPageState extends State<RichNoteEditorPage>
    with WidgetsBindingObserver {
  final _editorBack = DocumentEditorBackController();
  final _outlineNavigation = DocumentOutlineNavigation();
  late final TextEditingController _title;
  final FocusNode _editorFocus = FocusNode(debugLabel: 'daily-note-editor');
  EditorState? _editor;
  EditorScrollController? _scrollController;
  StreamSubscription<dynamic>? _changes;
  Timer? _timer;
  Future<void>? _pending;
  String? _id;
  late String? _folderId;
  late List<String> _tags;
  int _revision = 0, _savedRevision = 0;
  bool _failed = false, _allowPop = false, _leaving = false;
  late bool _editing;
  bool _exporting = false;
  bool _deleting = false;
  bool _archiving = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _id = widget.note?.id;
    _folderId = widget.note?.folderId ?? widget.folderId;
    _tags = List.of(widget.note?.tags ?? const []);
    _editing = widget.note == null;
    _title = TextEditingController(text: widget.note?.title ?? '')
      ..addListener(_changed);
    try {
      if (widget.note != null &&
          ((widget.note!.documentJson == null &&
                  widget.note!.documentVersion != null) ||
              (widget.note!.documentJson != null &&
                  widget.note!.documentVersion != 1)))
        throw StateError('unsupported');
      final json = widget.note?.documentJson;
      _editor = json == null
          ? widget.testEditor ??
                (widget.note == null
                    ? EditorState.blank(withInitialText: true)
                    : EditorState(
                        document: Document(
                          root: pageNode(
                            children: widget.note!.body
                                .split('\n')
                                .map((line) => paragraphNode(text: line))
                                .toList(),
                          ),
                        ),
                      ))
          : EditorState(
              document: Document.fromJson(validateRichDocument(json)),
            );
      _editor!.editable = _editing;
      _scrollController = EditorScrollController(editorState: _editor!);
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
          .map((node) => node.delta?.toPlainText())
          .whereType<String>()
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
    final folderId = _folderId;
    final tags = List<String>.of(_tags);
    final done = Completer<void>();
    _pending = done.future;
    if (mounted) setState(() {});
    var succeeded = false;
    try {
      final doc = jsonEncode(_editor!.document.toJson());
      validateRichDocument(doc);
      final body = _text();
      if (_id == null && title.trim().isEmpty && body.trim().isEmpty) {
        _savedRevision = revision;
        return;
      }
      final note = await widget.store.saveRichNote(
        id: _id,
        title: title,
        plainText: body,
        documentJson: doc,
        documentVersion: 1,
        folderId: folderId,
        tags: tags,
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
    if (_editorBack.handleBack()) return;
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

  Future<void> _openOutline(EditorState editor) async {
    if (!mounted ||
        _leaving ||
        _allowPop ||
        editor.isDisposed ||
        !identical(_editor, editor) ||
        ModalRoute.of(context)?.isCurrent != true) {
      return;
    }
    final target = await showDocumentOutline(
      context: context,
      editor: editor,
      editorFocus: _editorFocus,
      isCurrent: () =>
          mounted &&
          !_leaving &&
          !_allowPop &&
          identical(_editor, editor) &&
          ModalRoute.of(context)?.isCurrent == true,
    );
    if (target != null &&
        mounted &&
        !_leaving &&
        !_allowPop &&
        !editor.isDisposed &&
        identical(_editor, editor) &&
        ModalRoute.of(context)?.isCurrent == true) {
      await _jumpToOutline(target);
    }
  }

  Future<void> _showDocumentActions(EditorState editor) async {
    final action = await showDialog<_NoteDocumentAction>(
      context: context,
      requestFocus: false,
      builder: (dialog) => ListenableBuilder(
        listenable: widget.store,
        builder: (dialog, _) => SimpleDialog(
          title: Text(context.l10n.dailynotes.documentActions),
          children: [
            SimpleDialogOption(
              key: const ValueKey('note-document-outline'),
              onPressed: () =>
                  Navigator.pop(dialog, _NoteDocumentAction.outline),
              child: Text(context.l10n.dailynotes.documentOutline),
            ),
            SimpleDialogOption(
              key: const ValueKey('note-document-folder'),
              onPressed: _editing
                  ? () => Navigator.pop(dialog, _NoteDocumentAction.folder)
                  : null,
              child: Text(context.l10n.dailynotes.chooseFolder),
            ),
            SimpleDialogOption(
              key: const ValueKey('note-document-tags'),
              onPressed: _editing
                  ? () => Navigator.pop(dialog, _NoteDocumentAction.tags)
                  : null,
              child: Text(context.l10n.dailynotes.noteTags),
            ),
            if (_id != null)
              SimpleDialogOption(
                key: const ValueKey('note-document-archive'),
                onPressed: _editing && editor.editable && !_archiving
                    ? () => Navigator.pop(
                        dialog,
                        widget.store.isNoteArchived(_id!)
                            ? _NoteDocumentAction.unarchive
                            : _NoteDocumentAction.archive,
                      )
                    : null,
                child: Text(
                  widget.store.isNoteArchived(_id!)
                      ? context.l10n.dailynotes.unarchiveNote
                      : context.l10n.dailynotes.archiveNote,
                ),
              ),
            if (_id != null)
              SimpleDialogOption(
                key: const ValueKey('note-document-delete'),
                onPressed: _editing && editor.editable
                    ? () => Navigator.pop(dialog, _NoteDocumentAction.delete)
                    : null,
                child: Text(context.l10n.dailynotes.delete),
              ),
          ],
        ),
      ),
    );
    if (!mounted ||
        action == null ||
        !identical(_editor, editor) ||
        editor.isDisposed ||
        _leaving ||
        _allowPop ||
        ModalRoute.of(context)?.isCurrent != true) {
      return;
    }
    switch (action) {
      case _NoteDocumentAction.outline:
        await _openOutline(editor);
      case _NoteDocumentAction.folder:
        if (_editing && editor.editable) await _chooseFolder();
      case _NoteDocumentAction.tags:
        if (_editing && editor.editable) await _editTags();
      case _NoteDocumentAction.archive:
        await _setArchived(editor, archived: true);
      case _NoteDocumentAction.unarchive:
        await _setArchived(editor, archived: false);
      case _NoteDocumentAction.delete:
        if (_editing && editor.editable) await _delete();
    }
  }

  Future<void> _setArchived(
    EditorState editor, {
    required bool archived,
  }) async {
    final id = _id;
    if (_archiving ||
        id == null ||
        !_editing ||
        !editor.editable ||
        editor.isDisposed ||
        _leaving ||
        _allowPop ||
        !identical(_editor, editor) ||
        ModalRoute.of(context)?.isCurrent != true) {
      return;
    }
    setState(() => _archiving = true);
    try {
      await widget.store.setNoteArchived(id, archived: archived);
      if (mounted && !_leaving && ModalRoute.of(context)?.isCurrent == true) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              archived
                  ? context.l10n.dailynotes.archiveSucceeded
                  : context.l10n.dailynotes.unarchiveSucceeded,
            ),
          ),
        );
      }
    } catch (_) {
      if (mounted && !_leaving && ModalRoute.of(context)?.isCurrent == true) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              archived
                  ? context.l10n.dailynotes.archiveFailed
                  : context.l10n.dailynotes.unarchiveFailed,
            ),
          ),
        );
      }
    } finally {
      if (mounted) setState(() => _archiving = false);
    }
  }

  Future<void> _chooseFolder() async {
    final result = await showDialog<String>(
      context: context,
      builder: (c) => SimpleDialog(
        title: Text(context.l10n.dailynotes.chooseFolder),
        children: [
          SimpleDialogOption(
            onPressed: () => Navigator.pop(c, ''),
            child: Text(context.l10n.dailynotes.uncategorized),
          ),
          for (final folder in widget.store.folders)
            SimpleDialogOption(
              onPressed: () => Navigator.pop(c, folder.id),
              child: Text(folder.name),
            ),
        ],
      ),
    );
    if (result == null || !mounted || result == (_folderId ?? '')) return;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (c) => AlertDialog(
        title: Text(context.l10n.dailynotes.moveNote),
        content: Text(context.l10n.dailynotes.moveConfirm),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(c, false),
            child: Text(context.l10n.dailynotes.cancel),
          ),
          TextButton(
            onPressed: () => Navigator.pop(c, true),
            child: Text(context.l10n.dailynotes.confirm),
          ),
        ],
      ),
    );
    if (confirmed == true && mounted && _editing) {
      _folderId = result.isEmpty ? null : result;
      _changed();
    }
  }

  Future<void> _editTags() async {
    final text = TextEditingController(text: _tags.join(', '));
    final result = await showDialog<String>(
      context: context,
      builder: (c) => AlertDialog(
        title: Text(context.l10n.dailynotes.noteTags),
        content: TextField(
          controller: text,
          autofocus: true,
          decoration: InputDecoration(
            hintText: context.l10n.dailynotes.tagsHint,
          ),
          onSubmitted: (value) => Navigator.pop(c, value),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(c),
            child: Text(context.l10n.dailynotes.cancel),
          ),
          TextButton(
            onPressed: () => Navigator.pop(c, text.text),
            child: Text(context.l10n.dailynotes.confirm),
          ),
        ],
      ),
    );
    // A dialog route may still be animating after its result completes.
    if (result == null || !mounted || !_editing) return;
    _tags = result
        .split(RegExp('[,，]'))
        .map((t) => t.trim())
        .where((t) => t.isNotEmpty)
        .toSet()
        .toList();
    _changed();
  }

  Future<void> _delete() async {
    final editor = _editor;
    final id = _id;
    bool canDelete() =>
        mounted &&
        !_leaving &&
        !_allowPop &&
        _editing &&
        editor != null &&
        !editor.isDisposed &&
        editor.editable &&
        identical(_editor, editor) &&
        id != null &&
        _id == id &&
        ModalRoute.of(context)?.isCurrent == true;
    if (_deleting || !canDelete()) return;
    _deleting = true;
    try {
      final confirmed = await showDialog<bool>(
        context: context,
        builder: (dialog) => AlertDialog(
          title: Text(context.l10n.dailynotes.deleteNote),
          content: Text(context.l10n.dailynotes.deleteNoteHint),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(dialog, false),
              child: Text(context.l10n.dailynotes.cancel),
            ),
            TextButton(
              onPressed: () => Navigator.pop(dialog, true),
              child: Text(context.l10n.dailynotes.delete),
            ),
          ],
        ),
      );
      if (confirmed != true || !mounted || !canDelete()) return;
      _timer?.cancel();
      await _save();
      if (!mounted || !canDelete()) return;
      if (_revision != _savedRevision) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(context.l10n.dailynotes.saveFailed)),
        );
        return;
      }
      try {
        await widget.store.deleteNote(id!);
        if (!mounted) return;
        setState(() => _allowPop = true);
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (mounted) Navigator.pop(context);
        });
      } catch (_) {
        if (mounted)
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text(context.l10n.dailynotes.saveFailed)),
          );
      }
    } finally {
      _deleting = false;
    }
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
    _scrollController?.dispose();
    _editor?.dispose();
    _editorFocus.dispose();
    super.dispose();
  }

  Future<void> _jumpToOutline(Node target) async {
    final editor = _editor;
    final scroll = _scrollController;
    if (editor == null || scroll == null) return;
    final reached = await _outlineNavigation.jump(
      target: target,
      editor: editor,
      scroll: scroll,
      isCurrent: () =>
          mounted &&
          !_leaving &&
          !_allowPop &&
          ModalRoute.of(context)?.isCurrent == true &&
          identical(_editor, editor) &&
          identical(_scrollController, scroll),
    );
    if (reached == false) _outlineUnavailable();
  }

  void _outlineUnavailable() {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(context.l10n.dailynotes.outlineUnavailable)),
    );
  }

  @override
  Widget build(BuildContext context) {
    final t = context.l10n.dailynotes;
    final editor = _editor;
    final status = _failed
        ? t.saveFailed
        : _pending != null
        ? t.saving
        : _revision != _savedRevision
        ? t.saveQueued
        : _id == null
        ? t.unsaved
        : t.savedLocally;
    final folder = widget.store.folders
        .where((f) => f.id == _folderId)
        .firstOrNull;
    return PopScope(
      canPop: _allowPop,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) unawaited(_leave());
      },
      child: Scaffold(
        appBar: AppBar(
          title: MediaQuery.sizeOf(context).width >= 400
              ? Text(t.notesTitle)
              : null,
          leading: IconButton(
            icon: const Icon(LucideIcons.arrowLeft),
            onPressed: _leave,
          ),
          actions: [
            if (editor != null)
              IconButton(
                tooltip: status,
                icon: Icon(
                  _failed
                      ? LucideIcons.circleAlert
                      : _revision != _savedRevision || _pending != null
                      ? LucideIcons.clock
                      : _id == null
                      ? LucideIcons.circle
                      : LucideIcons.circleCheck,
                ),
                onPressed: () => showDialog<void>(
                  context: context,
                  builder: (dialog) => AlertDialog(
                    title: Text(status),
                    content: Text(t.noteSyncUnavailable),
                    actions: [
                      TextButton(
                        onPressed: () => Navigator.pop(dialog),
                        child: Text(t.confirm),
                      ),
                    ],
                  ),
                ),
              ),
            if (editor != null)
              DocumentHistoryActions(
                editor: editor,
                editable: _editing,
                canEdit: () =>
                    mounted &&
                    _editing &&
                    !_leaving &&
                    !_allowPop &&
                    identical(_editor, editor),
              ),
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
            if (editor != null)
              SizedBox(
                width: 40,
                child: IconButton(
                  key: const ValueKey('note-document-outline-button'),
                  tooltip: t.documentOutline,
                  icon: const Icon(LucideIcons.listTree),
                  onPressed: () => unawaited(_openOutline(editor)),
                ),
              ),
            if (editor != null)
              SizedBox(
                width: 40,
                child: IconButton(
                  key: const ValueKey('note-document-more'),
                  tooltip: t.documentActions,
                  icon: const Icon(LucideIcons.ellipsis),
                  onPressed: () => _showDocumentActions(editor),
                ),
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
                    if (_failed)
                      Padding(
                        padding: const EdgeInsets.all(8),
                        child: Row(
                          children: [
                            Expanded(child: Text(t.saveFailed)),
                            TextButton(onPressed: _save, child: Text(t.retry)),
                          ],
                        ),
                      ),
                    Text(folder?.name ?? t.uncategorized),
                    if (_tags.isNotEmpty)
                      Text(_tags.map((tag) => '#$tag').join('  ')),
                    Expanded(
                      child: DailyNotesDocumentCanvas(
                        backController: _editorBack,
                        editor: editor,
                        focusNode: _editorFocus,
                        scrollController: _scrollController!,
                        editable: _editing,
                        showHistoryActionsInToolbar: false,
                        autoFocus: widget.note == null,
                        header: TextField(
                          controller: _title,
                          readOnly: !_editing,
                          style:
                              context.theme.typography.headlineSmall.onSurface,
                          decoration: InputDecoration(
                            hintText: t.noteTitle,
                            border: InputBorder.none,
                            filled: false,
                            contentPadding: const EdgeInsets.symmetric(
                              vertical: 12,
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
