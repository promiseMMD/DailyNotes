import 'dart:convert';

import 'package:flutter/services.dart';
import 'package:moodiary_editor/moodiary_editor.dart';
import 'package:moodiary_i18n/moodiary_i18n.dart';
import 'package:moodiary_utils/moodiary_utils.dart';
import 'package:mui/mui.dart';

import 'mod_lan_rich.dart';
import 'mod_month_native.dart';
import 'mod_month_store.dart';
import 'mod_month_order.dart';
import '../dailynotes/data/daily_notes_store.dart';

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
      if (attempt[key] is! String)
        throw const FormatException('invalid_pending_request');
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
    if (!const ['doc', 'paragraph', 'text', 'hardBreak'].contains(node['type']))
      return false;
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
    if (context.mounted)
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text(l10n.month.draftLoadFailed)));
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
  final String monthKey;
  final ModStoredBlock? block;
  final bool summary;
  final String action; // edit, delete, restore
  final MoodiaryEditorController? editorController;
  final String? initialDayKey;
  final DailyNotesStore? draftStore;
  final String? draftKey;
  final Map<String, Object?>? initialDraft;
  const ModMonthComposer({
    super.key,
    required this.repository,
    required this.topicId,
    required this.monthKey,
    this.block,
    this.summary = false,
    this.action = 'edit',
    this.editorController,
    this.initialDayKey,
    this.draftStore,
    this.draftKey,
    this.initialDraft,
  });
  @override
  State<ModMonthComposer> createState() => _ModMonthComposerState();
}

class _ModMonthComposerState extends State<ModMonthComposer> {
  late final _editor = widget.editorController ?? MoodiaryEditorController();
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
  bool get _summary => widget.block?.kind == 'summary' || widget.summary;
  bool get _editing => widget.action == 'edit';
  bool get _locked => _busy || _leaving || _attempt != null;

  @override
  void initState() {
    super.initState();
    final block = widget.block;
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
  }

  void _message(String message) {
    if (mounted)
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text(message)));
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
  }

  Future<void> _copyDraft() async {
    try {
      if (_editing && _attempt == null && !_busy) {
        // Copy uses the same acknowledged read as Save; never claims an older
        // debounced value is the complete current draft.
        _body = await _editor.snapshot();
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
    if (drafts == null || key == null)
      throw StateError('draft_storage_unavailable');
    await drafts.saveDraft(key, _draftPayload());
  }

  Future<void> _finishExit() async {
    if (!mounted) return;
    setState(() => _allowExit = true);
    Navigator.of(context).pop();
  }

  Future<void> _leave() async {
    if (_busy || _allowExit || _leaving) return;
    setState(() => _leaving = true);
    try {
      if (_editing && _attempt == null) {
        // An acknowledged snapshot includes the final keystroke, even when the
        // WebView's debounced onChanged callback has not reached Flutter yet.
        await _editor.blur();
        _body = await _editor.snapshot();
      }
      final unchanged =
          _attempt == null &&
          ((!_editing) ||
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
    try {
      if (_attempt == null) {
        if (_editing) {
          await _editor.blur();
          final current = await _editor.snapshot();
          // Keep unsupported pasted nodes in the editor and fail closed. No
          // flattening, normalization, or temporary Diary can lose that draft.
          ModLanRichDocument.validate(jsonDecode(current));
          if (modBlockText(current).isEmpty) {
            if (mounted)
              setState(() {
                _error = l10n.month.emptyBody;
                _busy = false;
              });
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
    return PopScope(
      canPop: _allowExit,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) _leave();
      },
      child: Scaffold(
        appBar: AppBar(
          title: Text(title),
          leading: IconButton(
            onPressed: _busy ? null : _leave,
            tooltip: l10n.common.close,
            icon: const Icon(LucideIcons.x),
          ),
          actions: [
            IconButton(
              onPressed: _busy ? null : _copyDraft,
              tooltip: l10n.month.copyDraft,
              icon: const Icon(LucideIcons.copy),
            ),
            IconButton(
              onPressed: () =>
                  _details('${l10n.month.localOnly}\n\n${l10n.month.timezone}'),
              tooltip: l10n.common.more,
              icon: const Icon(LucideIcons.info),
            ),
          ],
        ),
        body: SafeArea(
          child: Column(
            children: [
              Padding(
                padding: const EdgeInsets.all(12),
                child: Text(
                  l10n.month.localOnly,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: context.theme.typography.bodySmall.secondary,
                ),
              ),
              if (_editing && !_summary)
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
                      IconButton(
                        onPressed: () => _details(_error!),
                        tooltip: l10n.common.more,
                        icon: const Icon(LucideIcons.info),
                      ),
                    ],
                  ),
                ),
              Expanded(
                child: _editing
                    ? AbsorbPointer(
                        absorbing: _locked,
                        child: MoodiaryEditor(
                          controller: _editor,
                          bodyOnly: true,
                          initialContent: _initialBody,
                          onChanged: (value) {
                            if (!_locked) _body = value;
                          },
                        ),
                      )
                    : SingleChildScrollView(
                        padding: const EdgeInsets.all(16),
                        child: SelectableText(modBlockText(_body)),
                      ),
              ),
              if (_editing)
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
                    onPressed: _busy || _leaving || _conflict ? null : _save,
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
