import 'dart:async';

import 'package:flutter/services.dart';
import 'package:moodiary_i18n/moodiary_i18n.dart';
import 'package:mui/mui.dart';

import '../data/daily_notes_store.dart';

/// The original note is edited in every entry point; a topic never owns a copy.
class DailyNoteEditorPage extends StatefulWidget {
  const DailyNoteEditorPage({
    super.key,
    required this.store,
    this.note,
    this.initialFolderId,
  });

  final DailyNotesStore store;
  final DailyNote? note;
  final String? initialFolderId;

  @override
  State<DailyNoteEditorPage> createState() => _DailyNoteEditorPageState();
}

class _DailyNoteEditorPageState extends State<DailyNoteEditorPage>
    with WidgetsBindingObserver {
  late final _title = TextEditingController(text: widget.note?.title ?? '');
  late final _body = TextEditingController(text: widget.note?.body ?? '');
  late String? _id = widget.note?.id;
  late String? _folderId = widget.note?.folderId ?? widget.initialFolderId;
  late List<String> _tags = List.of(widget.note?.tags ?? <String>[]);
  Timer? _timer;
  Future<void>? _pendingSave;
  int _generation = 0;
  int _savedGeneration = 0;
  bool _failed = false;
  bool _allowPop = false;
  bool _leaving = false;

  bool get _hasContent =>
      _title.text.trim().isNotEmpty || _body.text.trim().isNotEmpty;
  bool get _dirty =>
      _generation != _savedGeneration && (_hasContent || _id != null);

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _title.addListener(_changed);
    _body.addListener(_changed);
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.inactive ||
        state == AppLifecycleState.paused) {
      _timer?.cancel();
      unawaited(_save());
    }
  }

  void _changed() {
    _generation++;
    _timer?.cancel();
    _timer = Timer(const Duration(milliseconds: 450), _save);
    if (mounted) setState(() => _failed = false);
  }

  /// Serialize saves so slower writes cannot overwrite newer editor input.
  Future<void> _save() async {
    if (_pendingSave != null) {
      await _pendingSave;
      if (_dirty && !_failed) await _save();
      return;
    }
    if (!_dirty) return;
    final generation = _generation;
    final title = _title.text;
    final body = _body.text;
    final folderId = _folderId;
    final tags = List<String>.of(_tags);
    final done = Completer<void>();
    _pendingSave = done.future;
    if (mounted) setState(() => _failed = false);
    try {
      final note = await widget.store.saveNote(
        id: _id,
        title: title,
        body: body,
        folderId: folderId,
        tags: tags,
      );
      _id = note.id;
      _savedGeneration = generation;
    } catch (_) {
      _failed = true;
    } finally {
      _pendingSave = null;
      done.complete();
      if (mounted) setState(() {});
    }
    if (_dirty && !_failed) await _save();
  }

  Future<void> _copy() async {
    await Clipboard.setData(
      ClipboardData(
        text: [
          if (_title.text.isNotEmpty) _title.text,
          _body.text,
        ].join('\n\n'),
      ),
    );
    if (mounted) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(context.l10n.dailynotes.copied)));
    }
  }

  Future<void> _leave() async {
    if (_leaving) return;
    _leaving = true;
    _timer?.cancel();
    await _save();
    if (!mounted) return;
    if (_dirty) {
      await showDialog<void>(
        context: context,
        builder: (c) => AlertDialog(
          title: Text(context.l10n.dailynotes.unsavedExitTitle),
          content: Text(context.l10n.dailynotes.unsavedExitHint),
          actions: [
            TextButton(
              onPressed: _copy,
              child: Text(context.l10n.dailynotes.copyContent),
            ),
            TextButton(
              onPressed: () => Navigator.pop(c),
              child: Text(context.l10n.dailynotes.keepEditing),
            ),
          ],
        ),
      );
      _leaving = false;
      return;
    }
    setState(() => _allowPop = true);
    Navigator.of(context).pop();
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
    if (confirmed == true && mounted) {
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
    if (result == null || !mounted) return;
    _tags = result
        .split(RegExp('[,，]'))
        .map((t) => t.trim())
        .where((t) => t.isNotEmpty)
        .toSet()
        .toList();
    _changed();
  }

  Future<void> _delete() async {
    final id = _id;
    if (id == null) return;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (c) => AlertDialog(
        title: Text(context.l10n.dailynotes.deleteNote),
        content: Text(context.l10n.dailynotes.deleteNoteHint),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(c, false),
            child: Text(context.l10n.dailynotes.cancel),
          ),
          TextButton(
            onPressed: () => Navigator.pop(c, true),
            child: Text(context.l10n.dailynotes.delete),
          ),
        ],
      ),
    );
    if (confirmed != true) return;
    _timer?.cancel();
    await _save();
    if (_dirty || !mounted) return;
    try {
      await widget.store.deleteNote(id);
      if (!mounted) return;
      setState(() => _allowPop = true);
      Navigator.pop(context);
    } catch (_) {
      if (mounted) setState(() => _failed = true);
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _timer?.cancel();
    _title.dispose();
    _body.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final folder = widget.store.folders
        .where((f) => f.id == _folderId)
        .firstOrNull;
    final status = _failed
        ? l10n.dailynotes.saveFailed
        : _pendingSave != null || _dirty
        ? l10n.dailynotes.saving
        : _id == null
        ? l10n.dailynotes.unsaved
        : l10n.dailynotes.savedLocally;
    return PopScope(
      canPop: _allowPop,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) unawaited(_leave());
      },
      child: Scaffold(
        appBar: AppBar(
          leading: IconButton(
            onPressed: _leave,
            icon: const Icon(LucideIcons.arrowLeft),
          ),
          title: Text(l10n.dailynotes.notesTitle),
          actions: [
            IconButton(
              onPressed: _chooseFolder,
              tooltip: l10n.dailynotes.chooseFolder,
              icon: const Icon(LucideIcons.folder),
            ),
            IconButton(
              onPressed: _editTags,
              tooltip: l10n.dailynotes.noteTags,
              icon: const Icon(LucideIcons.tags),
            ),
            if (_id != null)
              IconButton(
                onPressed: _delete,
                tooltip: l10n.dailynotes.delete,
                icon: const Icon(LucideIcons.trash2),
              ),
          ],
        ),
        body: SafeArea(
          child: Column(
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(20, 0, 20, 8),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      '$status · ${folder?.name ?? l10n.dailynotes.uncategorized}',
                      style:
                          context.theme.typography.bodySmall.onSurfaceVariant,
                    ),
                    Text(
                      l10n.dailynotes.localOnly,
                      style:
                          context.theme.typography.labelSmall.onSurfaceVariant,
                    ),
                    if (_failed)
                      Wrap(
                        spacing: 8,
                        children: [
                          TextButton(
                            onPressed: _save,
                            child: Text(l10n.dailynotes.retry),
                          ),
                          TextButton(
                            onPressed: _copy,
                            child: Text(l10n.dailynotes.copyContent),
                          ),
                        ],
                      ),
                    if (_tags.isNotEmpty)
                      Padding(
                        padding: const EdgeInsets.only(top: 6),
                        child: Text(
                          _tags.map((t) => '#$t').join('  '),
                          style: context.theme.typography.labelSmall.primary,
                        ),
                      ),
                  ],
                ),
              ),
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 20),
                child: TextField(
                  controller: _title,
                  textCapitalization: TextCapitalization.sentences,
                  style: context.theme.typography.titleLarge.onSurface,
                  decoration: InputDecoration(
                    hintText: l10n.dailynotes.noteTitle,
                    border: InputBorder.none,
                  ),
                ),
              ),
              Expanded(
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(20, 0, 20, 12),
                  child: TextField(
                    controller: _body,
                    autofocus: widget.note == null,
                    expands: true,
                    minLines: null,
                    maxLines: null,
                    textAlignVertical: TextAlignVertical.top,
                    textCapitalization: TextCapitalization.sentences,
                    style: context.theme.typography.bodyLarge.onSurface,
                    decoration: InputDecoration(
                      hintText: l10n.dailynotes.noteBodyHint,
                      border: InputBorder.none,
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
