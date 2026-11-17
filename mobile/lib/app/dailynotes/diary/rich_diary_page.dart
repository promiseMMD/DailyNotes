import 'dart:async';
import 'dart:convert';

import 'package:appflowy_editor/appflowy_editor.dart' as af;
import 'package:flutter/services.dart';
import 'package:moodiary_data/moodiary_data.dart';
import 'package:moodiary_i18n/moodiary_i18n.dart';
import 'package:moodiary_models/moodiary_models.dart';
import 'package:mui/mui.dart';

import '../editor/document_canvas.dart';
import '../editor/document_envelope.dart';

/// A diary's AppFlowy document autosaves as the actual diary, not as a draft.
class RichDiaryPage extends StatefulWidget {
  const RichDiaryPage({
    super.key,
    required this.repository,
    this.diary,
    this.categoryId,
    this.registry,
  });
  final DiaryRepository repository;
  final Diary? diary;
  final String? categoryId;
  final OpenDiaryRegistry? registry;

  @override
  State<RichDiaryPage> createState() => _RichDiaryPageState();
}

class _RichDiaryPageState extends State<RichDiaryPage>
    with WidgetsBindingObserver {
  late Diary _base;
  Diary? _saved;
  Diary? _unconfirmed;
  int? _unconfirmedRevision;
  late final TextEditingController _title;
  final FocusNode _focus = FocusNode(debugLabel: 'daily-diary-document');
  af.EditorState? _editor;
  af.EditorScrollController? _scroll;
  StreamSubscription<dynamic>? _changes;
  Timer? _timer;
  Future<void>? _pending;
  int _revision = 0;
  int _savedRevision = 0;
  bool _failed = false;
  bool _allowPop = false;
  bool _leaving = false;
  bool _registered = false;
  late bool _editing;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _saved = widget.diary;
    _base =
        widget.diary ??
        Diary.empty(type: DiaryType.tiptap)
            .copyWith(categoryId: widget.categoryId);
    _editing = widget.diary == null;
    _title = TextEditingController(text: _base.title)..addListener(_changed);
    try {
      final content = _base.content;
      _editor = content.isEmpty
          ? af.EditorState.blank(withInitialText: true)
          : af.EditorState(
              document: DailyNotesDocumentEnvelope.decode(content),
            );
      _editor!.editable = _editing;
      _scroll = af.EditorScrollController(editorState: _editor!);
      _changes = _editor!.transactionStream.listen((event) {
        if (event.$1 == af.TransactionTime.after) _changed();
      });
      widget.registry?.open(_base.id);
      widget.registry?.setEditing(_base.id, editing: _editing);
      _registered = widget.registry != null;
    } catch (_) {
      // Unsupported or changed legacy content must never be overwritten.
      _editor = null;
    }
  }

  void _changed() {
    _revision++;
    _timer?.cancel();
    _timer = Timer(const Duration(milliseconds: 500), () => unawaited(_save()));
    if (mounted) setState(() {});
  }

  Future<void> _save() async {
    final editor = _editor;
    if (editor == null) return;
    if (_pending != null) {
      await _pending;
      if (_revision != _savedRevision && !_failed) await _save();
      return;
    }
    if (_revision == _savedRevision) return;
    final revision = _revision;
    final done = Completer<void>();
    _pending = done.future;
    if (mounted) setState(() {});
    var succeeded = false;
    try {
      final pendingWrite = _unconfirmed;
      if (pendingWrite != null) {
        final observed = await widget.repository.getDiaryByBusinessId(
          pendingWrite.id,
        );
        if (observed != null &&
            observed.copyWith(
                  lastModified: pendingWrite.lastModified,
                  contentText: pendingWrite.contentText,
                ) ==
                pendingWrite) {
          _saved = observed;
          _base = observed;
          _savedRevision = _unconfirmedRevision!;
          _unconfirmed = null;
          _unconfirmedRevision = null;
          if (_revision == _savedRevision) {
            _failed = false;
            return;
          }
        } else if ((_saved == null && observed == null) ||
            (_saved != null && observed == _saved)) {
          // The attempted write did not take effect; retry against the same
          // identity and verified previous snapshot.
          _unconfirmed = null;
          _unconfirmedRevision = null;
        } else {
          throw StateError('diary_conflict');
        }
      }
      final title = _title.text;
      final content = DailyNotesDocumentEnvelope.encode(editor.document);
      final text = DailyNotesDocumentEnvelope.plainText(editor.document);
      if (_saved == null && title.trim().isEmpty && text.trim().isEmpty) {
        _savedRevision = revision;
        return;
      }
      final previous = _saved;
      final next = _base.copyWith(
        title: title,
        content: content,
        contentText: text,
        lastModified: DateTime.now().toUtc(),
      );
      _unconfirmed = next;
      _unconfirmedRevision = revision;
      final written = previous == null
          ? await widget.repository.insertADiaryIfAbsent(next)
          : await widget.repository.updateADiaryIfCurrent(
              newDiary: next,
              expectedSnapshot: previous,
            );
      if (!written) throw StateError('diary_conflict');
      final stored = await widget.repository.getDiaryByBusinessId(next.id);
      if (stored == null) throw StateError('diary_not_readable');
      _saved = stored;
      _base = stored;
      _savedRevision = revision;
      _unconfirmed = null;
      _unconfirmedRevision = null;
      succeeded = true;
      if (_revision == revision) _failed = false;
    } catch (_) {
      _failed = true;
    } finally {
      _pending = null;
      done.complete();
      if (mounted) setState(() {});
    }
    if (_revision != _savedRevision && succeeded) await _save();
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
              onPressed: () async {
                final editor = _editor;
                if (editor != null) {
                  await Clipboard.setData(
                    ClipboardData(
                      text: jsonEncode({
                        'title': _title.text,
                        'document': editor.document.toJson(),
                      }),
                    ),
                  );
                }
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
                final confirm = await showDialog<bool>(
                  context: dialog,
                  builder: (context) => AlertDialog(
                    title: Text(context.l10n.dailynotes.discardUnsavedTitle),
                    content: Text(
                      context.l10n.dailynotes.discardUnsavedWarning,
                    ),
                    actions: [
                      TextButton(
                        onPressed: () => Navigator.pop(context, false),
                        child: Text(context.l10n.dailynotes.cancel),
                      ),
                      TextButton(
                        onPressed: () => Navigator.pop(context, true),
                        child: Text(
                          context.l10n.dailynotes.discardUnsavedConfirm,
                        ),
                      ),
                    ],
                  ),
                );
                if (confirm == true && dialog.mounted)
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
        state == AppLifecycleState.paused ||
        state == AppLifecycleState.hidden) {
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
    _scroll?.dispose();
    _editor?.dispose();
    _focus.dispose();
    if (_registered) {
      widget.registry!.setEditing(_base.id, editing: false);
      widget.registry!.close(_base.id);
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final t = context.l10n.dailynotes;
    final editor = _editor;
    final status = _failed
        ? t.saveFailed
        : _pending != null || _revision != _savedRevision
        ? context.l10n.diary.saving
        : _saved == null
        ? t.unsaved
        : t.savedLocally;
    return PopScope(
      canPop: _allowPop,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) unawaited(_leave());
      },
      child: Scaffold(
        appBar: AppBar(
          leading: IconButton(
            icon: const Icon(LucideIcons.arrowLeft),
            onPressed: _leave,
            tooltip: context.l10n.common.close,
          ),
          actions: [
            if (editor != null)
              IconButton(
                tooltip: status,
                icon: Icon(
                  _failed
                      ? LucideIcons.circleAlert
                      : _pending != null || _revision != _savedRevision
                      ? LucideIcons.clock
                      : _saved == null
                      ? LucideIcons.circle
                      : LucideIcons.circleCheck,
                ),
                onPressed: () =>
                    ScaffoldMessenger.of(context)
                        .showSnackBar(SnackBar(content: Text(status))),
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
                    widget.registry?.setEditing(_base.id, editing: _editing);
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
                      TextButton(
                        onPressed: () => Clipboard.setData(
                          ClipboardData(text: _base.content),
                        ),
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
                    Expanded(
                      child: DailyNotesDocumentCanvas(
                        editor: editor,
                        focusNode: _focus,
                        scrollController: _scroll!,
                        editable: _editing,
                        autoFocus: widget.diary == null,
                        header: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              MaterialLocalizations.of(context)
                                  .formatFullDate(_base.time.toLocal()),
                              style:
                                  context.theme.typography.bodyMedium.onSurface,
                            ),
                            TextField(
                              controller: _title,
                              readOnly: !_editing,
                              style: context
                                  .theme
                                  .typography
                                  .headlineSmall
                                  .onSurface,
                              decoration: InputDecoration(
                                hintText: t.noteTitle,
                                border: InputBorder.none,
                                filled: false,
                                contentPadding: const EdgeInsets.symmetric(
                                  vertical: 12,
                                ),
                              ),
                            ),
                          ],
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
