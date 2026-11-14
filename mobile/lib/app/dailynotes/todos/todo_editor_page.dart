import 'package:moodiary_i18n/moodiary_i18n.dart';
import 'package:mui/mui.dart';

import '../data/daily_notes_store.dart';

/// Planned dates are metadata only; this editor never enables notifications.
class DailyNotesTodoEditorPage extends StatefulWidget {
  final DailyNotesStore store;
  final DailyTask? task;
  final DateTime? initialDueDate;

  const DailyNotesTodoEditorPage({
    super.key,
    required this.store,
    this.task,
    this.initialDueDate,
  });

  @override
  State<DailyNotesTodoEditorPage> createState() => _TodoEditorState();
}

class _TodoEditorState extends State<DailyNotesTodoEditorPage> {
  late final TextEditingController _title;
  late final TextEditingController _body;
  DateTime? _dueAt;
  bool _busy = false;
  bool _changed = false;
  bool _allowPop = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    _title = TextEditingController(text: widget.task?.title ?? '');
    _body = TextEditingController(text: widget.task?.body ?? '');
    _dueAt = widget.task?.dueAt ?? widget.initialDueDate;
    _title.addListener(_onChanged);
    _body.addListener(_onChanged);
  }

  void _onChanged() {
    if (mounted) setState(() => _changed = true);
  }

  @override
  void dispose() {
    _title.dispose();
    _body.dispose();
    super.dispose();
  }

  Future<void> _chooseDate() async {
    final date = await showDatePicker(
      context: context,
      initialDate: _dueAt ?? DateTime.now(),
      firstDate: DateTime(2000),
      lastDate: DateTime(2100, 12, 31),
    );
    if (date != null && mounted) {
      setState(() {
        _dueAt = date;
        _changed = true;
      });
    }
  }

  Future<void> _save() async {
    if (_busy) return;
    if (_title.text.trim().isEmpty) {
      setState(() => _error = context.l10n.dailynotes.titleRequired);
      return;
    }
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await widget.store.saveTask(
        id: widget.task?.id,
        title: _title.text.trim(),
        body: _body.text,
        dueAt: _dueAt,
        listName:
            widget.task?.listName ?? context.l10n.dailynotes.defaultTaskList,
        completed: widget.task?.completed ?? false,
      );
      if (!mounted) return;
      setState(() {
        _allowPop = true;
        _changed = false;
      });
      // The acknowledgement appears only after the store transaction commits.
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(context.l10n.dailynotes.savedLocally)),
      );
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) Navigator.of(context).pop();
      });
    } catch (_) {
      if (mounted) {
        setState(() => _error = context.l10n.dailynotes.saveFailed);
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _delete() async {
    final task = widget.task;
    if (task == null || _busy) return;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: Text(context.l10n.dailynotes.deleteTodo),
        content: Text(context.l10n.dailynotes.deleteTodoHint),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(false),
            child: Text(context.l10n.dailynotes.cancel),
          ),
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(true),
            child: Text(context.l10n.dailynotes.delete),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await widget.store.deleteTask(task.id);
      if (!mounted) return;
      setState(() => _allowPop = true);
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) Navigator.of(context).pop();
      });
    } catch (_) {
      if (mounted) {
        setState(() => _error = context.l10n.dailynotes.saveFailed);
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _requestBack() async {
    if (_busy) return;
    if (!_changed) {
      Navigator.of(context).pop();
      return;
    }
    final discard = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: Text(context.l10n.dailynotes.unsavedChanges),
        content: Text(context.l10n.dailynotes.unsavedChangesHint),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(false),
            child: Text(context.l10n.dailynotes.keepEditing),
          ),
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(true),
            child: Text(context.l10n.dailynotes.discardChanges),
          ),
        ],
      ),
    );
    if (discard != true || !mounted) return;
    setState(() => _allowPop = true);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) Navigator.of(context).pop();
    });
  }

  @override
  Widget build(BuildContext context) => PopScope(
    canPop: _allowPop || (!_busy && !_changed),
    onPopInvokedWithResult: (didPop, _) {
      if (!didPop) _requestBack();
    },
    child: Scaffold(
      appBar: AppBar(
        leading: BackButton(onPressed: _requestBack),
        title: Text(
          widget.task == null
              ? context.l10n.dailynotes.newTodo
              : context.l10n.dailynotes.editTodo,
        ),
        actions: [
          if (widget.task != null)
            IconButton(
              tooltip: context.l10n.dailynotes.delete,
              onPressed: _busy ? null : _delete,
              icon: const Icon(LucideIcons.trash2),
            ),
          TextButton(
            onPressed: _busy ? null : _save,
            child: _busy
                ? const SizedBox.square(
                    dimension: 18,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : Text(context.l10n.dailynotes.save),
          ),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.all(20),
        children: [
          TextField(
            controller: _title,
            autofocus: widget.task == null,
            enabled: !_busy,
            textCapitalization: TextCapitalization.sentences,
            minLines: 1,
            maxLines: 4,
            style: context.theme.typography.titleLarge.onSurface,
            decoration: InputDecoration(
              hintText: context.l10n.dailynotes.todoTitle,
              border: InputBorder.none,
            ),
          ),
          const SizedBox(height: 10),
          TextField(
            controller: _body,
            enabled: !_busy,
            textCapitalization: TextCapitalization.sentences,
            minLines: 3,
            maxLines: null,
            decoration: InputDecoration(
              hintText: context.l10n.dailynotes.todoDetails,
              border: InputBorder.none,
            ),
          ),
          const SizedBox(height: 12),
          const Divider(),
          ListTile(
            contentPadding: EdgeInsets.zero,
            leading: const Icon(LucideIcons.calendarDays),
            title: Text(context.l10n.dailynotes.dueDate),
            subtitle: Text(
              _dueAt == null
                  ? context.l10n.dailynotes.noDate
                  : MaterialLocalizations.of(context).formatFullDate(_dueAt!),
            ),
            onTap: _busy ? null : _chooseDate,
            trailing: _dueAt == null
                ? const Icon(LucideIcons.chevronRight)
                : IconButton(
                    tooltip: context.l10n.dailynotes.clearDate,
                    onPressed: _busy
                        ? null
                        : () => setState(() {
                            _dueAt = null;
                            _changed = true;
                          }),
                    icon: const Icon(LucideIcons.x),
                  ),
          ),
          ListTile(
            contentPadding: EdgeInsets.zero,
            leading: const Icon(LucideIcons.bellOff),
            title: Text(context.l10n.dailynotes.notificationsOff),
            subtitle: Text(context.l10n.dailynotes.localOnly),
          ),
          if (_error != null) ...[
            const SizedBox(height: 16),
            Text(_error!, style: context.theme.typography.bodyMedium.error),
            Align(
              alignment: Alignment.centerLeft,
              child: TextButton(
                onPressed: _busy ? null : _save,
                child: Text(context.l10n.dailynotes.save),
              ),
            ),
          ],
        ],
      ),
    ),
  );
}
