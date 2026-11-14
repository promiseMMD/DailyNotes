import 'package:moodiary_i18n/moodiary_i18n.dart';
import 'package:mui/mui.dart';

import '../data/daily_notes_store.dart';
import 'note_editor_page.dart';

class DailyNotesNotesPage extends StatefulWidget {
  const DailyNotesNotesPage({super.key, required this.store});

  final DailyNotesStore store;

  @override
  DailyNotesNotesPageState createState() => DailyNotesNotesPageState();
}

/// A stable page key lets the existing circular shell action create in context.
class DailyNotesNotesPageState extends State<DailyNotesNotesPage>
    with SingleTickerProviderStateMixin {
  late final TabController _tabs;
  String? _folderId;
  bool _allNotes = true;
  final List<String> _topicPath = [];

  bool get isKnowledgeContext => _tabs.index == 1;
  String? get currentTopicId => _topicPath.lastOrNull;

  @override
  void initState() {
    super.initState();
    _tabs = TabController(length: 2, vsync: this);
    _tabs.addListener(_contextChanged);
  }

  void _contextChanged() {
    if (mounted) setState(() {});
  }

  @override
  void dispose() {
    _tabs.removeListener(_contextChanged);
    _tabs.dispose();
    super.dispose();
  }

  Future<void> createInCurrentContext() async {
    if (isKnowledgeContext) {
      await _createTopic();
    } else {
      await _openNote();
    }
  }

  Future<void> _openNote([DailyNote? note]) => Navigator.of(context).push<void>(
    MaterialPageRoute(
      builder: (_) => DailyNoteEditorPage(
        store: widget.store,
        note: note,
        initialFolderId: _folderId,
      ),
    ),
  );

  void _error() {
    if (!mounted) return;
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(SnackBar(content: Text(context.l10n.dailynotes.saveFailed)));
  }

  Future<String?> _askName(String title) async {
    final controller = TextEditingController();
    return showDialog<String>(
      context: context,
      builder: (c) => AlertDialog(
        title: Text(title),
        content: TextField(
          controller: controller,
          autofocus: true,
          maxLength: 120,
          onSubmitted: (name) {
            if (name.trim().isNotEmpty) Navigator.pop(c, name.trim());
          },
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(c),
            child: Text(context.l10n.dailynotes.cancel),
          ),
          TextButton(
            onPressed: () {
              if (controller.text.trim().isNotEmpty)
                Navigator.pop(c, controller.text.trim());
            },
            child: Text(context.l10n.dailynotes.confirm),
          ),
        ],
      ),
    );
  }

  Future<void> _createFolder({String? parentId}) async {
    final name = await _askName(context.l10n.dailynotes.newFolder);
    if (name == null) return;
    try {
      await widget.store.createFolder(name, parentId: parentId);
    } catch (_) {
      _error();
    }
  }

  Future<void> _createTopic() async {
    final name = await _askName(
      currentTopicId == null
          ? context.l10n.dailynotes.newTopic
          : context.l10n.dailynotes.newSubtopic,
    );
    if (name == null) return;
    try {
      await widget.store.createTopic(name, parentId: currentTopicId);
    } catch (_) {
      _error();
    }
  }

  Future<void> _browseFolders() async {
    final selected = await Navigator.of(context).push<String>(
      MaterialPageRoute(
        builder: (_) =>
            _FolderBrowser(store: widget.store, onCreate: _createFolder),
      ),
    );
    if (selected != null && mounted)
      setState(() {
        _folderId = selected.isEmpty ? null : selected;
        _allNotes = false;
      });
  }

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    return ListenableBuilder(
      listenable: widget.store,
      builder: (context, _) {
        // A removed topic must never leave an editable orphan context.
        if (_topicPath.any((id) => !widget.store.topics.any((t) => t.id == id)))
          _topicPath.clear();
        final topic = widget.store.topics
            .where((t) => t.id == currentTopicId)
            .firstOrNull;
        return Scaffold(
          appBar: AppBar(
            leading: isKnowledgeContext && currentTopicId != null
                ? IconButton(
                    onPressed: () => setState(() => _topicPath.removeLast()),
                    icon: const Icon(LucideIcons.arrowLeft),
                  )
                : null,
            title: Text(
              isKnowledgeContext
                  ? topic?.title ?? l10n.dailynotes.knowledgeBase
                  : l10n.dailynotes.notesTitle,
            ),
            actions: [
              if (!isKnowledgeContext)
                IconButton(
                  onPressed: _browseFolders,
                  tooltip: l10n.dailynotes.folderTree,
                  icon: const Icon(LucideIcons.folderTree),
                ),
              if (isKnowledgeContext && topic != null)
                IconButton(
                  onPressed: () => _deleteTopic(topic),
                  tooltip: l10n.dailynotes.deleteTopic,
                  icon: const Icon(LucideIcons.trash2),
                ),
            ],
            bottom: TabBar(
              controller: _tabs,
              tabs: [
                Tab(text: l10n.dailynotes.ordinaryNotes),
                Tab(text: l10n.dailynotes.knowledgeBase),
              ],
            ),
          ),
          body: TabBarView(
            controller: _tabs,
            children: [_notes(context), _knowledge(context)],
          ),
        );
      },
    );
  }

  Widget _notes(BuildContext context) {
    final l10n = context.l10n;
    final folders = widget.store.folders;
    final notes =
        widget.store.notes
            .where((n) => _allNotes || n.folderId == _folderId)
            .toList()
          ..sort((a, b) => b.updatedAt.compareTo(a.updatedAt));
    final folder = folders.where((f) => f.id == _folderId).firstOrNull;
    return ListView(
      padding: EdgeInsets.fromLTRB(
        16,
        8,
        16,
        120 + MediaQuery.paddingOf(context).bottom,
      ),
      children: [
        Row(
          children: [
            Expanded(child: _SectionTitle(l10n.dailynotes.frequentFolders)),
            TextButton(
              onPressed: _browseFolders,
              child: Text(l10n.dailynotes.allFolders),
            ),
          ],
        ),
        if (folders.isEmpty)
          ListTile(
            contentPadding: EdgeInsets.zero,
            leading: const Icon(LucideIcons.folderPlus),
            title: Text(l10n.dailynotes.newFolder),
            subtitle: Text(l10n.dailynotes.noFoldersHint),
            onTap: () => _createFolder(),
          )
        else
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              // Until ranking is confirmed, stable creation order is a preview choice.
              for (final f in folders.take(4))
                ActionChip(
                  avatar: const Icon(LucideIcons.folder, size: 16),
                  label: Text(
                    f.name,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                  onPressed: () => setState(() {
                    _folderId = f.id;
                    _allNotes = false;
                  }),
                ),
            ],
          ),
        const SizedBox(height: 12),
        Row(
          children: [
            Expanded(
              child: _SectionTitle(
                _allNotes
                    ? l10n.dailynotes.recentNotes
                    : folder?.name ?? l10n.dailynotes.uncategorized,
              ),
            ),
            if (!_allNotes)
              TextButton(
                onPressed: () => setState(() {
                  _allNotes = true;
                  _folderId = null;
                }),
                child: Text(l10n.dailynotes.allNotes),
              ),
          ],
        ),
        if (notes.isEmpty)
          DailyNotesEmptyState(
            icon: LucideIcons.notebookPen,
            title: l10n.dailynotes.noNotes,
            message: l10n.dailynotes.noNotesHint,
          )
        else
          for (final note in notes)
            Padding(
              padding: const EdgeInsets.only(bottom: 8),
              child: DailyNoteCard(note: note, onTap: () => _openNote(note)),
            ),
      ],
    );
  }

  Widget _knowledge(BuildContext context) {
    final l10n = context.l10n;
    final topics = widget.store.topics
        .where((t) => t.parentId == currentTopicId)
        .toList();
    final notes = currentTopicId == null
        ? <DailyNote>[]
        : widget.store.notesForTopic(currentTopicId!);
    return ListView(
      padding: EdgeInsets.fromLTRB(
        16,
        8,
        16,
        120 + MediaQuery.paddingOf(context).bottom,
      ),
      children: [
        if (_topicPath.isNotEmpty)
          Padding(
            padding: const EdgeInsets.only(bottom: 8),
            child: Wrap(
              crossAxisAlignment: WrapCrossAlignment.center,
              children: [
                TextButton(
                  onPressed: () => setState(_topicPath.clear),
                  child: Text(l10n.dailynotes.knowledgeBase),
                ),
                for (var i = 0; i < _topicPath.length; i++) ...[
                  const Icon(LucideIcons.chevronRight, size: 14),
                  TextButton(
                    onPressed: () => setState(
                      () => _topicPath.removeRange(i + 1, _topicPath.length),
                    ),
                    child: Text(
                      widget.store.topics
                              .where((t) => t.id == _topicPath[i])
                              .firstOrNull
                              ?.title ??
                          '',
                    ),
                  ),
                ],
              ],
            ),
          ),
        _SectionTitle(
          currentTopicId == null
              ? l10n.dailynotes.rootTopics
              : l10n.dailynotes.subtopics,
        ),
        const SizedBox(height: 8),
        if (topics.isEmpty && currentTopicId == null)
          DailyNotesEmptyState(
            icon: LucideIcons.network,
            title: l10n.dailynotes.noTopics,
            message: l10n.dailynotes.noTopicsHint,
          )
        else
          for (final topic in topics)
            Padding(
              padding: const EdgeInsets.only(bottom: 8),
              child: Card(
                margin: EdgeInsets.zero,
                child: ListTile(
                  leading: const Icon(LucideIcons.network),
                  title: Text(
                    topic.title,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                  trailing: const Icon(LucideIcons.chevronRight, size: 18),
                  onTap: () => setState(() => _topicPath.add(topic.id)),
                ),
              ),
            ),
        if (currentTopicId != null) ...[
          const SizedBox(height: 14),
          Row(
            children: [
              Expanded(child: _SectionTitle(l10n.dailynotes.linkedNotes)),
              TextButton.icon(
                onPressed: _linkNotes,
                icon: const Icon(LucideIcons.link, size: 16),
                label: Text(l10n.dailynotes.linkNotes),
              ),
            ],
          ),
          if (notes.isEmpty)
            DailyNotesEmptyState(
              icon: LucideIcons.link,
              title: l10n.dailynotes.noLinkedNotes,
              message: l10n.dailynotes.linkNotesHint,
            )
          else
            for (final note in notes)
              Padding(
                padding: const EdgeInsets.only(bottom: 8),
                child: DailyNoteCard(
                  note: note,
                  onTap: () => _openNote(note),
                  trailing: IconButton(
                    onPressed: () => _unlink(note),
                    tooltip: l10n.dailynotes.unlink,
                    icon: const Icon(LucideIcons.unlink, size: 18),
                  ),
                ),
              ),
        ],
      ],
    );
  }

  Future<void> _linkNotes() async {
    final topicId = currentTopicId;
    if (topicId == null) return;
    final existing = widget.store
        .notesForTopic(topicId)
        .map((n) => n.id)
        .toSet();
    final selected = <String>{};
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (c) => StatefulBuilder(
        builder: (c, update) => AlertDialog(
          title: Text(context.l10n.dailynotes.selectNotes),
          content: SizedBox(
            width: double.maxFinite,
            child: widget.store.notes.isEmpty
                ? Text(context.l10n.dailynotes.noneAvailable)
                : ListView(
                    shrinkWrap: true,
                    children: [
                      for (final n in widget.store.notes)
                        CheckboxListTile(
                          title: Text(
                            n.title.trim().isEmpty
                                ? context.l10n.dailynotes.untitledNote
                                : n.title,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                          subtitle: existing.contains(n.id)
                              ? Text(context.l10n.dailynotes.linked)
                              : null,
                          value:
                              existing.contains(n.id) ||
                              selected.contains(n.id),
                          onChanged: existing.contains(n.id)
                              ? null
                              : (value) => update(() {
                                  if (value == true) {
                                    selected.add(n.id);
                                  } else {
                                    selected.remove(n.id);
                                  }
                                }),
                        ),
                    ],
                  ),
          ),
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
      ),
    );
    if (confirmed != true) return;
    for (final id in selected) {
      try {
        await widget.store.linkNote(id, topicId);
      } catch (_) {
        _error();
      }
    }
  }

  Future<void> _unlink(DailyNote note) async {
    final topicId = currentTopicId;
    if (topicId == null) return;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (c) => AlertDialog(
        title: Text(context.l10n.dailynotes.unlink),
        content: Text(context.l10n.dailynotes.unlinkConfirm),
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
    if (confirmed == true) {
      try {
        await widget.store.unlinkNote(note.id, topicId);
      } catch (_) {
        _error();
      }
    }
  }

  Future<void> _deleteTopic(KnowledgeTopic topic) async {
    final result = await showDialog<bool>(
      context: context,
      builder: (c) => AlertDialog(
        title: Text(context.l10n.dailynotes.deleteTopic),
        content: Text(context.l10n.dailynotes.deleteTopicHint),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(c),
            child: Text(context.l10n.dailynotes.cancel),
          ),
          TextButton(
            onPressed: () => Navigator.pop(c, false),
            child: Text(context.l10n.dailynotes.deleteTopicOnly),
          ),
          TextButton(
            onPressed: () => Navigator.pop(c, true),
            child: Text(context.l10n.dailynotes.deleteTopicTree),
          ),
        ],
      ),
    );
    if (result == null) return;
    try {
      await widget.store.deleteTopic(topic.id, includeChildren: result);
    } catch (_) {
      _error();
    }
  }
}

class _SectionTitle extends StatelessWidget {
  const _SectionTitle(this.text);
  final String text;
  @override
  Widget build(BuildContext context) => Text(
    text,
    style: context.theme.typography.titleSmall.emphasized.onSurface,
  );
}

class DailyNoteCard extends StatelessWidget {
  const DailyNoteCard({
    super.key,
    required this.note,
    required this.onTap,
    this.trailing,
  });
  final DailyNote note;
  final VoidCallback onTap;
  final Widget? trailing;

  @override
  Widget build(BuildContext context) {
    final date = note.updatedAt;
    final time =
        '${date.month.toString().padLeft(2, '0')}/${date.day.toString().padLeft(2, '0')}';
    return Card(
      margin: EdgeInsets.zero,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(12),
        child: Padding(
          padding: const EdgeInsets.all(12),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Expanded(
                    child: Text(
                      note.title.trim().isEmpty
                          ? context.l10n.dailynotes.untitledNote
                          : note.title,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: context.theme.typography.titleSmall.onSurface,
                    ),
                  ),
                  const SizedBox(width: 8),
                  Text(
                    time,
                    style: context.theme.typography.labelSmall.onSurfaceVariant,
                  ),
                  if (trailing != null) trailing!,
                ],
              ),
              if (note.body.trim().isNotEmpty) ...[
                const SizedBox(height: 5),
                Text(
                  note.body.replaceAll(RegExp(r'\s+'), ' '),
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: context.theme.typography.bodyMedium.onSurfaceVariant,
                ),
              ],
              if (note.tags.isNotEmpty) ...[
                const SizedBox(height: 7),
                Text(
                  [
                    for (final tag in note.tags.take(2)) '#$tag',
                    if (note.tags.length > 2) '+${note.tags.length - 2}',
                  ].join('  '),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: context.theme.typography.labelSmall.primary,
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}

class DailyNotesEmptyState extends StatelessWidget {
  const DailyNotesEmptyState({
    super.key,
    required this.icon,
    required this.title,
    required this.message,
  });
  final IconData icon;
  final String title;
  final String message;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 34),
    child: Column(
      children: [
        Icon(icon, size: 34, color: context.theme.colors.onSurfaceVariant),
        const SizedBox(height: 12),
        Text(title, style: context.theme.typography.titleMedium.onSurface),
        const SizedBox(height: 8),
        Text(
          message,
          textAlign: TextAlign.center,
          style: context.theme.typography.bodyMedium.onSurfaceVariant,
        ),
      ],
    ),
  );
}

class _FolderBrowser extends StatelessWidget {
  const _FolderBrowser({required this.store, required this.onCreate});
  final DailyNotesStore store;
  final Future<void> Function({String? parentId}) onCreate;

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(
      title: Text(context.l10n.dailynotes.folderTree),
      actions: [
        IconButton(
          onPressed: () => onCreate(),
          tooltip: context.l10n.dailynotes.newFolder,
          icon: const Icon(LucideIcons.folderPlus),
        ),
      ],
    ),
    body: ListenableBuilder(
      listenable: store,
      builder: (context, _) => ListView(
        padding: const EdgeInsets.fromLTRB(12, 8, 12, 24),
        children: [
          ListTile(
            title: Text(context.l10n.dailynotes.uncategorized),
            leading: const Icon(LucideIcons.folder),
            onTap: () => Navigator.pop(context, ''),
          ),
          ..._children(context, null, <String>{}),
        ],
      ),
    ),
  );

  List<Widget> _children(
    BuildContext context,
    String? parentId,
    Set<String> ancestors,
  ) => [
    for (final folder in store.folders.where((f) => f.parentId == parentId))
      if (!ancestors.contains(folder.id))
        _FolderTreeRow(
          folder: folder,
          childRows: _children(context, folder.id, {...ancestors, folder.id}),
          onOpen: () => Navigator.pop(context, folder.id),
          onAdd: () => onCreate(parentId: folder.id),
        ),
  ];
}

class _FolderTreeRow extends StatelessWidget {
  const _FolderTreeRow({
    required this.folder,
    required this.childRows,
    required this.onOpen,
    required this.onAdd,
  });
  final DailyFolder folder;
  final List<Widget> childRows;
  final VoidCallback onOpen;
  final VoidCallback onAdd;

  @override
  Widget build(BuildContext context) => ExpansionTile(
    leading: const Icon(LucideIcons.folder),
    title: InkWell(
      onTap: onOpen,
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 12),
        child: Text(folder.name),
      ),
    ),
    trailing: IconButton(
      onPressed: onAdd,
      tooltip: context.l10n.dailynotes.newFolder,
      icon: const Icon(LucideIcons.folderPlus, size: 18),
    ),
    childrenPadding: const EdgeInsets.only(left: 16),
    children: childRows.isEmpty
        ? [ListTile(title: Text(context.l10n.dailynotes.folder), onTap: onOpen)]
        : childRows,
  );
}
