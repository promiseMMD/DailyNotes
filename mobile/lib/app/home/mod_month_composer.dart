import 'dart:async';
import 'dart:convert';

import 'package:appflowy_editor/appflowy_editor.dart' as af;
import 'package:flutter/services.dart';
import 'package:moodiary_editor/moodiary_editor.dart';
import 'package:moodiary_i18n/moodiary_i18n.dart';
import 'package:moodiary_utils/moodiary_utils.dart';
import 'package:mui/mui.dart';

import '../dailynotes/data/daily_notes_store.dart';
import '../dailynotes/editor/document_canvas.dart';
import '../dailynotes/editor/document_editor_back_controller.dart';
import '../dailynotes/editor/document_envelope.dart';
import '../dailynotes/editor/document_history_actions.dart';
import '../dailynotes/editor/document_outline_navigation.dart';
import '../dailynotes/notes/document_bookmarks.dart';
import '../dailynotes/notes/rich_note_outline.dart';
import '../dailynotes/recovery/emergency_document_exporter.dart';
import '../dailynotes/recovery/emergency_note_export.dart';
import 'mod_month_document.dart';
import 'mod_month_native.dart';
import 'mod_month_order.dart';
import 'mod_month_store.dart';

const _emptyBody =
    '{"type":"doc","attrs":{"v":2},"content":[{"type":"paragraph"}]}';

String _composerDraftKey({
  required String topicId,
  required String monthKey,
  required bool summary,
  required String action,
  String? blockId,
  String? dayKey,
}) =>
    'long-record:$topicId:$monthKey:${blockId ?? (summary ? "summary" : "append-${uuidV7()}")}:$action';

class ModAppendDraft {
  final String key;
  final String monthKey;
  final String dayKey;
  final String preview;
  final bool pendingRequest;

  const ModAppendDraft({
    required this.key,
    required this.monthKey,
    required this.dayKey,
    required this.preview,
    required this.pendingRequest,
  });
}

String? _appendDraftMonth(String key, String topicId) {
  final parts = key.split(':');
  if (parts.length != 5 ||
      parts[0] != 'long-record' ||
      parts[1] != topicId ||
      parts[4] != 'edit' ||
      !RegExp(r'^[0-9]{4}-(0[1-9]|1[0-2])$').hasMatch(parts[2]) ||
      !(parts[3].startsWith('append-') || modValidArchiveDay(parts[3]))) {
    return null;
  }
  return parts[2];
}

Future<List<ModAppendDraft>> loadModAppendDrafts(
  ModNativeMonthRepository repository,
  String topicId,
) async {
  final store = DailyNotesStore(repository.store.db);
  try {
    await store.open();
    final result = <ModAppendDraft>[];
    for (final entry
        in store.draftsWithPrefix('long-record:$topicId:').entries) {
      final month = _appendDraftMonth(entry.key, topicId);
      if (month == null) continue;
      final payload = entry.value;
      _validateComposerDraft(payload, topicId);
      final day = payload['dayKey'];
      if (day is! String || !modValidArchiveDay(day)) {
        throw const FormatException('invalid_long_record_draft_day');
      }
      result.add(
        ModAppendDraft(
          key: entry.key,
          monthKey: month,
          dayKey: day,
          preview: modBlockText(payload['body'] as String),
          pendingRequest: payload['attempt'] != null,
        ),
      );
    }
    result.sort((a, b) {
      final byDay = b.dayKey.compareTo(a.dayKey);
      return byDay != 0 ? byDay : a.key.compareTo(b.key);
    });
    return List.unmodifiable(result);
  } finally {
    store.dispose();
  }
}

void _validateComposerDraft(Map<String, Object?> draft, String topicId) {
  if (draft['schemaVersion'] != 1 ||
      draft['blockId'] is! String ||
      draft['body'] is! String ||
      draft['occurredAtMs'] is! int ||
      draft['baselineBody'] is! String ||
      draft['baselineEventMs'] is! int) {
    throw const FormatException('invalid_long_record_draft');
  }
  jsonDecode(draft['body'] as String);
  DateTime.fromMillisecondsSinceEpoch(draft['occurredAtMs'] as int);
  if (draft['attempt'] case final Map attempt) {
    for (final key in [
      'operationId',
      'revisionId',
      'blockId',
      'topicId',
      'monthKey',
      'kind',
      'tiptapJson',
    ]) {
      if (attempt[key] is! String) {
        throw const FormatException('invalid_pending_request');
      }
    }
    if (attempt['topicId'] != topicId ||
        attempt['blockId'] != draft['blockId'] ||
        attempt['occurredAtMs'] is! int) {
      throw const FormatException('invalid_pending_request_identity');
    }
    jsonDecode(attempt['tiptapJson'] as String);
  } else if (draft['attempt'] != null) {
    throw const FormatException('invalid_pending_request');
  }
}

bool _isEmptyDraft(String body) {
  bool emptyNode(Object? node) {
    if (node is! Map) return false;
    if (!const [
      'doc',
      'paragraph',
      'text',
      'hardBreak',
    ].contains(node['type'])) {
      return false;
    }
    if (node['text'] case final String text) {
      if (text.trim().isNotEmpty) return false;
    }
    final children = node['content'];
    return children == null || children is List && children.every(emptyNode);
  }

  return emptyNode(jsonDecode(body));
}

Future<ModStoredBlock?> showModMonthComposer({
  required BuildContext context,
  required ModNativeMonthRepository repository,
  required String topicId,
  String? topicTitle,
  required String monthKey,
  ModStoredBlock? block,
  bool summary = false,
  String action = 'edit',
  String? initialDayKey,
  MoodiaryEditorController? editorController,
  String? resumeDraftKey,
}) async {
  final drafts = DailyNotesStore(repository.store.db);
  try {
    await drafts.open();
    if (!context.mounted) return null;
    if (resumeDraftKey != null &&
        (block != null ||
            summary ||
            action != 'edit' ||
            _appendDraftMonth(resumeDraftKey, topicId) != monthKey)) {
      throw const FormatException('invalid_long_record_draft_identity');
    }
    final key =
        resumeDraftKey ??
        _composerDraftKey(
          topicId: topicId,
          monthKey: monthKey,
          summary: block?.kind == 'summary' || summary,
          action: action,
          blockId: block?.blockId,
          dayKey: initialDayKey,
        );
    final initialDraft = drafts.draft(key);
    if (resumeDraftKey != null && initialDraft == null) {
      throw const FormatException('long_record_draft_missing');
    }
    if (initialDraft != null) _validateComposerDraft(initialDraft, topicId);
    return await Navigator.of(context).push<ModStoredBlock>(
      MaterialPageRoute(
        builder: (_) => ModMonthComposer(
          repository: repository,
          topicId: topicId,
          topicTitle: topicTitle,
          monthKey: monthKey,
          block: block,
          summary: summary,
          action: action,
          initialDayKey: initialDayKey,
          editorController: editorController,
          draftStore: drafts,
          draftKey: key,
          initialDraft: initialDraft,
        ),
      ),
    );
  } catch (_) {
    if (context.mounted) {
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text(l10n.month.draftLoadFailed)));
    }
    return null;
  } finally {
    drafts.dispose();
  }
}

/// Full-screen append editor. A durable pending request is replayed with exactly
/// the same IDs after restart; failed acknowledgement never creates a new append.
class ModMonthComposer extends StatefulWidget {
  final ModNativeMonthRepository repository;
  final String topicId;
  final String? topicTitle;
  final String monthKey;
  final ModStoredBlock? block;
  final bool summary;
  final String action; // edit, delete, restore
  final MoodiaryEditorController? editorController;
  final String? initialDayKey;
  final DailyNotesStore? draftStore;
  final String? draftKey;
  final Map<String, Object?>? initialDraft;
  @visibleForTesting
  final EmergencyDocumentExporter? testEmergencyExporter;
  const ModMonthComposer({
    super.key,
    required this.repository,
    required this.topicId,
    this.topicTitle,
    required this.monthKey,
    this.block,
    this.summary = false,
    this.action = 'edit',
    this.editorController,
    this.initialDayKey,
    this.draftStore,
    this.draftKey,
    this.initialDraft,
    this.testEmergencyExporter,
  });
  @override
  State<ModMonthComposer> createState() => _ModMonthComposerState();
}

enum _ComposerDocumentAction {
  outline,
  bookmarks,
  copyDraft,
  emergencyExport,
  info,
}

class _ModMonthComposerState extends State<ModMonthComposer>
    with WidgetsBindingObserver {
  final _editorBack = DocumentEditorBackController();
  final _outlineNavigation = DocumentOutlineNavigation();
  late final _editor = widget.editorController ?? MoodiaryEditorController();
  final FocusNode _documentFocus = FocusNode(
    debugLabel: 'long-record-document',
  );
  af.EditorState? _documentEditor;
  af.EditorScrollController? _documentScroll;
  StreamSubscription<dynamic>? _documentChanges;
  String? _initialNativeDocument;
  late bool _documentUnlocked;
  late final String _blockId;
  late final String? _parentRevisionId;
  late final String _initialBody;
  late final String _baselineBody;
  late final String? _baselineDay;
  late final int _baselineEventMs;
  late String _body;
  late DateTime _event;
  late String? _day;
  ModMonthMutation? _attempt;
  String? _error;
  bool _busy = false;
  bool _conflict = false;
  bool _allowExit = false;
  bool _leaving = false;
  Timer? _draftTimer;
  Future<void> _draftWrites = Future.value();
  int _draftRevision = 0;
  int _persistedDraftRevision = 0;
  int _draftWritesInFlight = 0;
  bool _draftWriteFailed = false;
  bool _snapshotUncertain = false;
  late final _exporter =
      widget.testEmergencyExporter ?? EmergencyDocumentExporter();
  bool get _autoDraft =>
      widget.block == null &&
      !_summary &&
      _editing &&
      widget.draftStore != null &&
      widget.draftKey != null;
  bool get _summary => widget.block?.kind == 'summary' || widget.summary;
  bool get _editing => widget.action == 'edit';
  bool get _locked => _busy || _leaving || _attempt != null;
  bool get _documentEditable => _editing && _documentUnlocked && !_locked;
  bool get _readingPositionSaved =>
      widget.block != null &&
      _body == widget.block!.tiptapJson &&
      !_snapshotUncertain &&
      _attempt == null;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    final block = widget.block;
    _documentUnlocked = block == null || widget.editorController != null;
    final draft = widget.initialDraft;
    _blockId = draft?['blockId'] as String? ?? block?.blockId ?? uuidV7();
    _parentRevisionId = draft != null
        ? draft['parentRevisionId'] as String?
        : block?.revisionId;
    _body = block?.tiptapJson ?? _emptyBody;
    final now = DateTime.now();
    _event = block == null
        ? modInitialBlockTime(
            monthKey: widget.monthKey,
            dayKey: _summary ? null : widget.initialDayKey,
            now: now,
          )
        : DateTime.fromMillisecondsSinceEpoch(block.occurredAtMs);
    _day = _summary
        ? null
        : block?.dayKey ?? widget.initialDayKey ?? modDayKey(_event);
    _baselineBody = draft?['baselineBody'] as String? ?? _body;
    _baselineDay = draft != null ? draft['baselineDay'] as String? : _day;
    _baselineEventMs =
        draft?['baselineEventMs'] as int? ?? _event.millisecondsSinceEpoch;
    if (draft != null) {
      _body = draft['body'] as String;
      _event = DateTime.fromMillisecondsSinceEpoch(
        draft['occurredAtMs'] as int,
      );
      _day = draft['dayKey'] as String?;
      final pending = draft['attempt'];
      if (pending is Map) {
        _attempt = _restoreAttempt(pending.cast<String, Object?>());
        _body = _attempt!.tiptapJson;
        _event = DateTime.fromMillisecondsSinceEpoch(_attempt!.occurredAtMs);
        _day = _attempt!.dayKey;
      }
    }
    _initialBody = _body;
    if (_editing && widget.editorController == null) {
      try {
        _documentEditor = af.EditorState(
          document: DailyNotesDocumentEnvelope.decode(_body),
        );
        _initialNativeDocument = jsonEncode(_documentEditor!.document.toJson());
        _documentScroll = af.EditorScrollController(
          editorState: _documentEditor!,
        );
        _documentChanges = _documentEditor!.transactionStream.listen((event) {
          if (event.$1 != af.TransactionTime.after || _locked) return;
          try {
            _body = DailyNotesDocumentEnvelope.encode(
              _documentEditor!.document,
            );
            _snapshotUncertain = false;
            _draftChanged();
          } catch (_) {
            _snapshotUncertain = true;
            _draftWriteFailed = true;
            if (mounted) setState(() {});
          }
        });
      } catch (_) {
        // Keep unsupported previous content intact and fail closed.
        _documentEditor = null;
      }
    }
  }

  @override
  void dispose() {
    _outlineNavigation.dispose();
    _draftTimer?.cancel();
    _documentChanges?.cancel();
    _documentScroll?.dispose();
    _documentEditor?.dispose();
    _documentFocus.dispose();
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  Future<String> _snapshot() async {
    if (widget.editorController != null) return _editor.snapshot();
    final editor = _documentEditor;
    if (editor == null) throw const FormatException('unsupported_document');
    return DailyNotesDocumentEnvelope.encode(editor.document);
  }

  Future<void> _blur() async {
    if (widget.editorController != null) {
      await _editor.blur();
    } else {
      _documentFocus.unfocus();
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.inactive ||
        state == AppLifecycleState.paused ||
        state == AppLifecycleState.hidden) {
      unawaited(_flushDraftOnBackground());
    }
  }

  void _draftChanged() {
    if (!_autoDraft || _attempt != null) return;
    _draftRevision++;
    _draftTimer?.cancel();
    _draftTimer = Timer(
      const Duration(milliseconds: 500),
      () => unawaited(_flushDraftOnBackground()),
    );
    if (mounted) setState(() {});
  }

  void _queueDraftSave() {
    if (!_autoDraft || _locked) return;
    _draftTimer?.cancel();
    final revision = _draftRevision;
    final payload = _draftPayload();
    _draftWritesInFlight++;
    if (mounted) setState(() {});
    _draftWrites = _draftWrites.then((_) async {
      var success = false;
      try {
        await widget.draftStore!.saveDraft(widget.draftKey!, payload);
        success = true;
      } catch (_) {
        // Keep the editor and its newest in-memory contents available.
      }
      _draftWritesInFlight--;
      if (success) {
        if (revision > _persistedDraftRevision) {
          _persistedDraftRevision = revision;
        }
        if (revision == _draftRevision && !_snapshotUncertain) {
          _draftWriteFailed = false;
        }
      } else {
        _draftWriteFailed = true;
      }
      if (mounted) setState(() {});
    });
  }

  Future<void> _flushDraftOnBackground() async {
    if (!_autoDraft || _locked) return;
    final before = _draftRevision;
    try {
      final snapshot = await _snapshot();
      jsonDecode(snapshot);
      if (!mounted || _locked) return;
      // A newer editor callback supersedes an older asynchronous snapshot.
      if (before == _draftRevision && snapshot != _body) {
        _body = snapshot;
        _draftRevision++;
      }
      jsonDecode(_body);
      _snapshotUncertain = false;
      if (_draftRevision == 0) return;
      _queueDraftSave();
    } catch (_) {
      if (mounted) {
        setState(() {
          _snapshotUncertain = true;
          _draftWriteFailed = true;
        });
      }
    }
  }

  void _message(String message) {
    if (mounted) {
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text(message)));
    }
  }

  Future<void> _details(String message) => showDialog<void>(
    context: context,
    builder: (c) => AlertDialog(
      title: Text(l10n.month.title),
      content: SingleChildScrollView(child: SelectableText(message)),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(c),
          child: Text(l10n.common.close),
        ),
      ],
    ),
  );

  Future<void> _date() async {
    if (_locked || _summary) return;
    final initial = DateTime.parse(_day!);
    final date = await showDatePicker(
      context: context,
      initialDate: initial,
      firstDate: DateTime(1),
      lastDate: DateTime(9999, 12, 31),
    );
    if (!mounted || date == null || _locked) return;
    setState(() {
      _day = modDayKey(date);
      _event = DateTime(
        date.year,
        date.month,
        date.day,
        _event.hour,
        _event.minute,
        _event.second,
        _event.millisecond,
        _event.microsecond,
      );
    });
    _draftChanged();
  }

  Future<void> _time() async {
    if (_locked || _summary) return;
    final time = await showTimePicker(
      context: context,
      initialTime: TimeOfDay.fromDateTime(_event),
    );
    if (!mounted || time == null || _locked) return;
    final day = DateTime.parse(_day!);
    setState(
      () => _event = DateTime(
        day.year,
        day.month,
        day.day,
        time.hour,
        time.minute,
      ),
    );
    _draftChanged();
  }

  Future<void> _copyDraft() async {
    try {
      if (_editing && _attempt == null && !_busy) {
        // Copy uses the same acknowledged read as Save; never claims an older
        // debounced value is the complete current draft.
        _body = await _snapshot();
      }
      final payload =
          _attempt?.toJson() ??
          {
            'schemaVersion': 1,
            'topicId': widget.topicId,
            'monthKey': _summary ? widget.monthKey : _day!.substring(0, 7),
            'blockId': _blockId,
            'parentRevisionId': _parentRevisionId,
            'kind': _summary ? 'summary' : 'entry',
            'dayKey': _day,
            'occurredAtMs': _event.millisecondsSinceEpoch,
            'document': jsonDecode(_body),
            'draft': true,
          };
      await Clipboard.setData(
        ClipboardData(
          text: const JsonEncoder.withIndent('  ').convert(payload),
        ),
      );
      _message(l10n.common.copied);
    } catch (_) {
      _message(l10n.month.snapshotFailed);
    }
  }

  ModMonthMutation _restoreAttempt(Map<String, Object?> value) =>
      ModMonthMutation(
        operationId: value['operationId'] as String,
        revisionId: value['revisionId'] as String,
        blockId: value['blockId'] as String,
        topicId: value['topicId'] as String,
        monthKey: value['monthKey'] as String,
        kind: value['kind'] as String,
        parentRevisionId: value['parentRevisionId'] as String?,
        dayKey: value['dayKey'] as String?,
        occurredAtMs: value['occurredAtMs'] as int,
        tiptapJson: value['tiptapJson'] as String,
        deleted: value['deleted'] as bool? ?? false,
      );

  Map<String, Object?> _draftPayload() => {
    'schemaVersion': 1,
    'blockId': _blockId,
    'parentRevisionId': _parentRevisionId,
    'body': _body,
    'dayKey': _day,
    'occurredAtMs': _event.millisecondsSinceEpoch,
    'baselineBody': _baselineBody,
    'baselineDay': _baselineDay,
    'baselineEventMs': _baselineEventMs,
    if (_attempt != null)
      'attempt': {..._attempt!.toJson(), 'tiptapJson': _attempt!.tiptapJson},
  };

  Future<void> _persistDraft() async {
    final drafts = widget.draftStore;
    final key = widget.draftKey;
    if (drafts == null || key == null) {
      throw StateError('draft_storage_unavailable');
    }
    await _draftWrites;
    await drafts.saveDraft(key, _draftPayload());
  }

  Future<void> _finishExit() async {
    if (!mounted) return;
    setState(() => _allowExit = true);
    Navigator.of(context).pop();
  }

  Future<void> _openOutline(af.EditorState editor) async {
    if (!mounted ||
        _busy ||
        _leaving ||
        _allowExit ||
        editor.isDisposed ||
        !identical(_documentEditor, editor) ||
        ModalRoute.of(context)?.isCurrent != true) {
      return;
    }
    final result = await showDocumentOutline(
      context: context,
      editor: editor,
      editorFocus: _documentFocus,
      canReturn: _outlineNavigation.hasPrevious(editor),
      isCurrent: () =>
          mounted &&
          !_busy &&
          !_leaving &&
          !_allowExit &&
          identical(_documentEditor, editor) &&
          ModalRoute.of(context)?.isCurrent == true,
    );
    if (result != null &&
        mounted &&
        !_busy &&
        !_leaving &&
        !_allowExit &&
        !editor.isDisposed &&
        identical(_documentEditor, editor) &&
        ModalRoute.of(context)?.isCurrent == true) {
      await _navigateOutline(result.previous ? null : result.target);
    }
  }

  Future<void> _navigateOutline(af.Node? target) async {
    final editor = _documentEditor;
    final scroll = _documentScroll;
    if (editor == null || scroll == null) return;
    bool isCurrent() =>
        mounted &&
        !_busy &&
        !_leaving &&
        !_allowExit &&
        ModalRoute.of(context)?.isCurrent == true &&
        identical(_documentEditor, editor) &&
        identical(_documentScroll, scroll);
    final reached = target == null
        ? await _outlineNavigation.returnToPrevious(
            editor: editor,
            scroll: scroll,
            isCurrent: isCurrent,
          )
        : await _outlineNavigation.jump(
            target: target,
            editor: editor,
            scroll: scroll,
            isCurrent: isCurrent,
          );
    if (reached == false && mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            target == null
                ? context.l10n.dailynotes.outlinePreviousUnavailable
                : context.l10n.dailynotes.outlineUnavailable,
          ),
        ),
      );
    }
  }

  Future<void> _showDocumentActions() async {
    final editor = _documentEditor;
    final action = await showDialog<_ComposerDocumentAction>(
      context: context,
      requestFocus: false,
      builder: (dialog) => SimpleDialog(
        title: Text(context.l10n.dailynotes.documentActions),
        children: [
          if (editor != null)
            SimpleDialogOption(
              key: const ValueKey('long-document-outline'),
              onPressed: () =>
                  Navigator.pop(dialog, _ComposerDocumentAction.outline),
              child: Text(context.l10n.dailynotes.documentOutline),
            ),
          if (editor != null)
            SimpleDialogOption(
              key: const ValueKey('long-document-bookmarks'),
              onPressed: () =>
                  Navigator.pop(dialog, _ComposerDocumentAction.bookmarks),
              child: Text(context.l10n.dailynotes.documentBookmarks),
            ),
          SimpleDialogOption(
            key: const ValueKey('long-document-copy'),
            onPressed: _busy
                ? null
                : () =>
                      Navigator.pop(dialog, _ComposerDocumentAction.copyDraft),
            child: Text(context.l10n.month.copyDraft),
          ),
          if (_editing && (editor != null || widget.editorController != null))
            SimpleDialogOption(
              key: const ValueKey('long-document-emergency-export'),
              onPressed: _busy
                  ? null
                  : () => Navigator.pop(
                      dialog,
                      _ComposerDocumentAction.emergencyExport,
                    ),
              child: Text(context.l10n.dailynotes.emergencyExport),
            ),
          SimpleDialogOption(
            key: const ValueKey('long-document-info'),
            onPressed: () =>
                Navigator.pop(dialog, _ComposerDocumentAction.info),
            child: Text(context.l10n.month.localOnly),
          ),
        ],
      ),
    );
    if (!mounted ||
        _leaving ||
        _allowExit ||
        !identical(editor, _documentEditor) ||
        ModalRoute.of(context)?.isCurrent != true ||
        action == null) {
      return;
    }
    switch (action) {
      case _ComposerDocumentAction.outline:
        if (editor != null) await _openOutline(editor);
      case _ComposerDocumentAction.bookmarks:
        if (editor != null) await _openBookmarks(editor);
      case _ComposerDocumentAction.copyDraft:
        if (!_busy) await _copyDraft();
      case _ComposerDocumentAction.emergencyExport:
        if (!_busy) await _emergencyExport();
      case _ComposerDocumentAction.info:
        await _details(
          '${context.l10n.month.localOnly}\n\n${context.l10n.month.timezone}',
        );
    }
  }

  Future<void> _openBookmarks(af.EditorState editor) async {
    final scroll = _documentScroll;
    if (scroll == null) return;
    bool alive() =>
        mounted &&
        !_busy &&
        !_leaving &&
        !_allowExit &&
        !editor.isDisposed &&
        identical(_documentEditor, editor) &&
        identical(_documentScroll, scroll);
    bool current() => alive() && ModalRoute.of(context)?.isCurrent == true;
    if (!current()) return;
    await openDocumentBookmarks(
      context: context,
      editor: editor,
      scroll: scroll,
      editorFocus: _documentFocus,
      identity: widget.block == null
          ? null
          : 'long:${jsonEncode([widget.topicId, widget.block!.blockId])}',
      canStore: () => _readingPositionSaved,
      isAlive: alive,
      isCurrent: current,
      navigation: _outlineNavigation,
    );
  }

  Future<void> _emergencyExport() async {
    final editor = _documentEditor;
    if (!_editing || (editor == null && widget.editorController == null)) {
      return;
    }
    await _exporter.export(
      context: context,
      isCurrent: () =>
          mounted &&
          !_allowExit &&
          (editor == null ||
              (!editor.isDisposed && identical(_documentEditor, editor))),
      capture: () async {
        final String document;
        final String plainText;
        final String documentFormat;
        if (editor != null) {
          document = jsonEncode(editor.document.toJson());
          plainText = DailyNotesDocumentEnvelope.plainText(editor.document);
          documentFormat = 'appflowy-json-v1';
        } else {
          document = await _snapshot();
          jsonDecode(document);
          plainText = modBlockText(document);
          documentFormat = 'tiptap-json-v2';
        }
        return EmergencyNoteSnapshot(
          kind: EmergencyRecordKind.longRecord,
          title: widget.topicTitle ?? '',
          body: plainText,
          documentJson: document,
          documentFormat: documentFormat,
          metadata: {
            'topicId': widget.topicId,
            'monthKey': _day?.substring(0, 7) ?? widget.monthKey,
            'blockId': _blockId,
            'parentRevisionId': _parentRevisionId,
            'kind': _summary ? 'summary' : 'entry',
            'dayKey': _day,
            'occurredAtMs': _event.millisecondsSinceEpoch,
            'draft': true,
            if (_attempt != null) 'pendingRequest': _attempt!.toJson(),
          },
        );
      },
    );
  }

  Future<void> _leave() async {
    if (_busy || _allowExit || _leaving) return;
    if (_editorBack.handleBack()) return;
    setState(() => _leaving = true);
    _draftTimer?.cancel();
    try {
      await _draftWrites;
      if (_editing && _attempt == null) {
        // An acknowledged snapshot includes the final keystroke, even when the
        // WebView's debounced onChanged callback has not reached Flutter yet.
        await _blur();
        _body = await _snapshot();
      }
      final unchanged =
          _attempt == null &&
          ((!_editing) ||
              (widget.editorController == null &&
                  widget.block != null &&
                  _documentEditor != null &&
                  jsonEncode(_documentEditor!.document.toJson()) ==
                      _initialNativeDocument &&
                  _day == _baselineDay &&
                  _event.millisecondsSinceEpoch == _baselineEventMs) ||
              (_body == _baselineBody &&
                  _day == _baselineDay &&
                  _event.millisecondsSinceEpoch == _baselineEventMs) ||
              (widget.block == null && _isEmptyDraft(_body)));
      if (unchanged) {
        if (widget.draftStore != null && widget.draftKey != null) {
          await widget.draftStore!.removeDraft(widget.draftKey!);
        }
        await _finishExit();
        return;
      }
      if (!mounted) return;
      final retain = await showDialog<bool>(
        context: context,
        builder: (c) => AlertDialog(
          title: Text(l10n.month.leaveTitle),
          content: Text(
            _attempt != null
                ? l10n.month.retainUncertain
                : l10n.month.retainDraftMessage,
          ),
          actions: [
            if (_editing &&
                (_documentEditor != null || widget.editorController != null))
              TextButton(
                onPressed: _emergencyExport,
                child: Text(context.l10n.dailynotes.emergencyExport),
              ),
            TextButton(
              onPressed: () => Navigator.pop(c, false),
              child: Text(l10n.month.keepEditing),
            ),
            TextButton(
              onPressed: () => Navigator.pop(c, true),
              child: Text(l10n.month.retainAndLeave),
            ),
          ],
        ),
      );
      if (retain != true || !mounted) return;
      await _persistDraft();
      await _finishExit();
    } catch (_) {
      if (mounted) setState(() => _error = l10n.month.draftSaveFailed);
    } finally {
      if (mounted) setState(() => _leaving = false);
    }
  }

  Future<void> _save() async {
    if (_busy || _leaving || _conflict) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    _draftTimer?.cancel();
    try {
      await _draftWrites;
      if (_attempt == null) {
        if (_editing) {
          await _blur();
          final current = await _snapshot();
          // Keep unsupported pasted nodes in the editor and fail closed. No
          // flattening, normalization, or temporary Diary can lose that draft.
          validateModMonthDocument(current);
          if (modBlockText(current).isEmpty) {
            if (mounted) {
              setState(() {
                _error = l10n.month.emptyBody;
                _busy = false;
              });
            }
            return;
          }
          _body = current;
          _attempt = ModMonthMutation(
            operationId: uuidV7(),
            revisionId: uuidV7(),
            blockId: _blockId,
            topicId: widget.topicId,
            monthKey: _summary ? widget.monthKey : _day!.substring(0, 7),
            kind: _summary ? 'summary' : 'entry',
            parentRevisionId: _parentRevisionId,
            dayKey: _day,
            occurredAtMs: _event.millisecondsSinceEpoch,
            tiptapJson: _body,
          );
        } else {
          _attempt = ModMonthMutation.fromBlock(
            widget.block!,
            operationId: uuidV7(),
            revisionId: uuidV7(),
            deleted: widget.action == 'delete',
          );
        }
      }
      // Write-ahead of the exact operation makes success-with-lost-ack and a
      // crash before cleanup safe: the store deduplicates the same operation.
      if (widget.draftStore != null) await _persistDraft();
      final saved = await widget.repository.commit(_attempt!);
      if (widget.draftStore != null && widget.draftKey != null) {
        await widget.draftStore!.removeDraft(widget.draftKey!);
      }
      if (!mounted) return;
      setState(() {
        _allowExit = true;
        _busy = false;
      });
      Navigator.of(context).pop(saved);
    } on ModMonthStoreException catch (e) {
      if (!mounted) return;
      // Domain rejections are final for this immutable parent/payload. Never
      // automatically rebase to a PC edit, deletion, or existing summary.
      setState(() {
        _busy = false;
        _conflict = _attempt != null;
        _error = e.code == 'topic_not_available'
            ? l10n.month.topicUnavailable
            : l10n.month.conflict;
      });
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _busy = false;
        _error = _attempt == null
            ? l10n.month.snapshotFailed
            : l10n.month.uncertain;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final title = !_editing
        ? (widget.action == 'delete'
              ? l10n.month.deleteTitle
              : l10n.diary.recycleRestore)
        : (_summary ? l10n.month.summary : l10n.month.record);
    final showDraftStatus =
        _autoDraft &&
        (_draftRevision > 0 ||
            widget.initialDraft != null ||
            _draftWriteFailed);
    final draftStatus = _draftWriteFailed
        ? l10n.month.draftAutosaveFailed
        : _draftWritesInFlight > 0
        ? l10n.month.draftAutosaving
        : _persistedDraftRevision < _draftRevision
        ? l10n.month.draftAutosavePending
        : l10n.month.draftAutosaved;
    return PopScope(
      canPop: _allowExit,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) _leave();
      },
      child: Scaffold(
        appBar: AppBar(
          title: MediaQuery.sizeOf(context).width >= 400 ? Text(title) : null,
          leading: IconButton(
            onPressed: _busy ? null : _leave,
            tooltip: l10n.common.close,
            icon: const Icon(LucideIcons.x),
          ),
          actions: [
            if (_documentEditor != null)
              DocumentHistoryActions(
                editor: _documentEditor,
                editable: _documentEditable,
                canEdit: () =>
                    mounted &&
                    _documentEditable &&
                    _documentEditor != null &&
                    _documentEditor!.editable,
              ),
            if (_editing &&
                widget.block != null &&
                widget.editorController == null &&
                _documentEditor != null &&
                _attempt == null)
              IconButton(
                tooltip: _documentUnlocked
                    ? l10n.dailynotes.lockEditing
                    : l10n.dailynotes.unlockEditing,
                icon: Icon(
                  _documentUnlocked ? LucideIcons.lock : LucideIcons.lockOpen,
                ),
                onPressed: _locked
                    ? null
                    : () {
                        if (_documentUnlocked) _documentFocus.unfocus();
                        setState(() => _documentUnlocked = !_documentUnlocked);
                      },
              ),
            if (showDraftStatus)
              IconButton(
                tooltip: draftStatus,
                onPressed: () => _details(draftStatus),
                icon: Icon(
                  _draftWriteFailed
                      ? LucideIcons.circleAlert
                      : _draftWritesInFlight > 0 ||
                            _persistedDraftRevision < _draftRevision
                      ? LucideIcons.clock
                      : LucideIcons.circleCheck,
                ),
              ),
            if (_documentEditor case final editor?)
              SizedBox(
                width: 40,
                child: IconButton(
                  key: const ValueKey('long-document-outline-button'),
                  onPressed: _busy
                      ? null
                      : () => unawaited(_openOutline(editor)),
                  tooltip: l10n.dailynotes.documentOutline,
                  icon: const Icon(LucideIcons.listTree),
                ),
              ),
            SizedBox(
              width: 40,
              child: IconButton(
                key: const ValueKey('long-document-more'),
                onPressed: _busy ? null : _showDocumentActions,
                tooltip: l10n.dailynotes.documentActions,
                icon: const Icon(LucideIcons.ellipsis),
              ),
            ),
          ],
        ),
        body: SafeArea(
          child: Column(
            children: [
              if (_editing && widget.editorController != null && !_summary)
                Wrap(
                  spacing: 8,
                  children: [
                    TextButton.icon(
                      onPressed: _locked ? null : _date,
                      icon: const Icon(LucideIcons.calendar),
                      label: Text(_day!),
                    ),
                    TextButton.icon(
                      onPressed: _locked ? null : _time,
                      icon: const Icon(LucideIcons.clock),
                      label: Text(
                        TimeOfDay.fromDateTime(_event).format(context),
                      ),
                    ),
                  ],
                ),
              if (_error != null)
                Padding(
                  padding: const EdgeInsets.all(12),
                  child: Row(
                    children: [
                      Expanded(
                        child: Text(
                          _error!,
                          maxLines: 3,
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                      if (_editing &&
                          (_documentEditor != null ||
                              widget.editorController != null))
                        IconButton(
                          key: const ValueKey('long-error-emergency-export'),
                          tooltip: l10n.dailynotes.emergencyExport,
                          onPressed: _busy ? null : _emergencyExport,
                          icon: const Icon(LucideIcons.download),
                        ),
                      IconButton(
                        onPressed: () => _details(_error!),
                        tooltip: l10n.common.more,
                        icon: const Icon(LucideIcons.info),
                      ),
                    ],
                  ),
                ),
              if (_autoDraft && _draftWriteFailed)
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 12),
                  child: Row(
                    children: [
                      Expanded(child: Text(l10n.month.draftAutosaveFailed)),
                      TextButton(
                        onPressed: _locked
                            ? null
                            : () => unawaited(_flushDraftOnBackground()),
                        child: Text(l10n.common.retry),
                      ),
                      IconButton(
                        key: const ValueKey('long-draft-emergency-export'),
                        tooltip: l10n.dailynotes.emergencyExport,
                        onPressed: _busy ? null : _emergencyExport,
                        icon: const Icon(LucideIcons.download),
                      ),
                    ],
                  ),
                ),
              Expanded(
                child: _editing
                    ? widget.editorController != null
                          ? AbsorbPointer(
                              absorbing: _locked,
                              child: MoodiaryEditor(
                                controller: _editor,
                                bodyOnly: true,
                                initialContent: _initialBody,
                                onChanged: (value) {
                                  if (!_locked && value != _body) {
                                    _body = value;
                                    _draftChanged();
                                  }
                                },
                              ),
                            )
                          : _documentEditor == null
                          ? Center(
                              child: Text(
                                l10n.dailynotes.richDocumentUnsupported,
                              ),
                            )
                          : AbsorbPointer(
                              absorbing: _locked,
                              child: DailyNotesDocumentCanvas(
                                backController: _editorBack,
                                editor: _documentEditor!,
                                focusNode: _documentFocus,
                                scrollController: _documentScroll!,
                                readingPositionIdentity: widget.block == null
                                    ? null
                                    : 'long:${jsonEncode([widget.topicId, widget.block!.blockId])}',
                                readingPositionIsSaved: _readingPositionSaved,
                                readingPositionCanStore: () =>
                                    _readingPositionSaved,
                                editable: _documentEditable,
                                showHistoryActionsInToolbar: false,
                                autoFocus:
                                    widget.block == null && _attempt == null,
                                header: Column(
                                  key: const ValueKey('long-document-header'),
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    if (widget.topicTitle case final name?)
                                      Text(
                                        name,
                                        style: Theme.of(context)
                                            .textTheme
                                            .titleLarge,
                                      ),
                                    if (!_summary)
                                      Wrap(
                                        spacing: 8,
                                        children: [
                                          TextButton.icon(
                                            onPressed: _documentEditable
                                                ? _date
                                                : null,
                                            icon: const Icon(
                                              LucideIcons.calendar,
                                            ),
                                            label: Text(_day!),
                                          ),
                                          TextButton.icon(
                                            onPressed: _documentEditable
                                                ? _time
                                                : null,
                                            icon: const Icon(LucideIcons.clock),
                                            label: Text(
                                              TimeOfDay.fromDateTime(_event)
                                                  .format(context),
                                            ),
                                          ),
                                        ],
                                      ),
                                  ],
                                ),
                              ),
                            )
                    : SingleChildScrollView(
                        padding: const EdgeInsets.all(16),
                        child: SelectableText(modBlockText(_body)),
                      ),
              ),
              if (_editing && widget.editorController != null)
                SingleChildScrollView(
                  scrollDirection: Axis.horizontal,
                  child: Row(
                    children: [
                      for (final item in <(EditorCommand, IconData, String)>[
                        (
                          EditorCommand.toggleBold,
                          LucideIcons.bold,
                          l10n.editor.toolbar.bold,
                        ),
                        (
                          EditorCommand.toggleItalic,
                          LucideIcons.italic,
                          l10n.editor.toolbar.italic,
                        ),
                        (
                          EditorCommand.toggleUnderline,
                          LucideIcons.underline,
                          l10n.editor.toolbar.underline,
                        ),
                        (
                          EditorCommand.toggleStrike,
                          LucideIcons.strikethrough,
                          l10n.editor.toolbar.strike,
                        ),
                        (
                          EditorCommand.toggleCode,
                          LucideIcons.code,
                          l10n.editor.toolbar.inlineCode,
                        ),
                        (
                          EditorCommand.setHeading,
                          LucideIcons.heading2,
                          l10n.month.heading,
                        ),
                        (
                          EditorCommand.setParagraph,
                          LucideIcons.type,
                          l10n.month.paragraph,
                        ),
                        (
                          EditorCommand.undo,
                          LucideIcons.undo2,
                          l10n.editor.toolbar.undo,
                        ),
                        (
                          EditorCommand.redo,
                          LucideIcons.redo2,
                          l10n.editor.toolbar.redo,
                        ),
                      ])
                        IconButton(
                          onPressed: _locked
                              ? null
                              : () => _editor.exec(
                                  item.$1,
                                  item.$1 == EditorCommand.setHeading
                                      ? {'level': 2}
                                      : null,
                                ),
                          tooltip: item.$3,
                          icon: Icon(item.$2),
                        ),
                    ],
                  ),
                ),
              Padding(
                padding: const EdgeInsets.all(12),
                child: SizedBox(
                  width: double.infinity,
                  child: FilledButton(
                    onPressed:
                        _busy ||
                            _leaving ||
                            _conflict ||
                            (_editing &&
                                widget.block != null &&
                                widget.editorController == null &&
                                !_documentUnlocked &&
                                _attempt == null)
                        ? null
                        : _save,
                    child: Text(
                      _busy
                          ? l10n.diary.saving
                          : _attempt != null
                          ? l10n.month.retrySame
                          : _editing
                          ? l10n.common.save
                          : widget.action == 'delete'
                          ? l10n.common.delete
                          : l10n.diary.recycleRestore,
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
