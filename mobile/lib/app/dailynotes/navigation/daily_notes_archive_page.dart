import 'package:moodiary_i18n/moodiary_i18n.dart';
import 'package:mui/mui.dart';

import '../data/daily_notes_store.dart';
import '../notes/rich_note_editor_page.dart';

/// Browses the original notes through their existing folder and topic trees.
class DailyNotesArchivePage extends StatefulWidget {
  const DailyNotesArchivePage({super.key, required this.store});

  final DailyNotesStore store;

  @override
  State<DailyNotesArchivePage> createState() => _DailyNotesArchivePageState();
}

class _DailyNotesArchivePageState extends State<DailyNotesArchivePage>
    with TickerProviderStateMixin {
  late final TabController _categories;
  late final TabController _noteViews;
  final List<String> _folderPath = [];
  final List<String> _topicPath = [];
  int _category = 1;
  int _noteView = 0;

  @override
  void initState() {
    super.initState();
    _categories = TabController(
      length: 3,
      initialIndex: _category,
      vsync: this,
    );
    _noteViews = TabController(length: 2, vsync: this);
    widget.store.addListener(_storeChanged);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _refresh();
    });
  }

  @override
  void didUpdateWidget(covariant DailyNotesArchivePage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.store != widget.store) {
      oldWidget.store.removeListener(_storeChanged);
      widget.store.addListener(_storeChanged);
      _folderPath.clear();
      _topicPath.clear();
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _refresh();
      });
    }
  }

  @override
  void dispose() {
    widget.store.removeListener(_storeChanged);
    _categories.dispose();
    _noteViews.dispose();
    super.dispose();
  }

  void _storeChanged() {
    if (!mounted) return;
    setState(() {
      _trimPath(_folderPath, {
        for (final f in widget.store.foldersWithArchivedNotes) f.id: f.parentId,
      });
      _trimPath(_topicPath, {
        for (final t in widget.store.topicsWithArchivedNotes) t.id: t.parentId,
      });
    });
  }

  void _trimPath(List<String> path, Map<String, String?> parents) {
    String? parent;
    var valid = 0;
    for (final id in path) {
      if (!parents.containsKey(id) || parents[id] != parent) break;
      parent = id;
      valid++;
    }
    if (valid < path.length) path.removeRange(valid, path.length);
  }

  Future<void> _refresh() async {
    final store = widget.store;
    try {
      await store.refresh();
    } catch (_) {
      if (mounted &&
          identical(store, widget.store) &&
          ModalRoute.of(context)?.isCurrent == true) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(context.l10n.dailynotesNavigation.archiveLoadFailed),
          ),
        );
      }
    }
  }

  Future<void> _openNote(DailyNote note) async {
    await Navigator.of(context).push<void>(
      MaterialPageRoute(
        builder: (_) => RichNoteEditorPage(store: widget.store, note: note),
      ),
    );
    if (mounted) await _refresh();
  }

  List<String> get _activePath => _noteView == 0 ? _folderPath : _topicPath;

  @override
  Widget build(BuildContext context) {
    final canLeave = _category != 1 || _activePath.isEmpty;
    return PopScope(
      canPop: canLeave,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop && !canLeave) setState(() => _activePath.removeLast());
      },
      child: Scaffold(
        appBar: AppBar(
          title: Text(context.l10n.dailynotesNavigation.archive),
          actions: [
            IconButton(
              tooltip: context.l10n.dailynotesNavigation.refresh,
              onPressed: _refresh,
              icon: const Icon(LucideIcons.refreshCw),
            ),
          ],
          bottom: TabBar(
            controller: _categories,
            onTap: (value) => setState(() => _category = value),
            tabs: [
              Tab(text: context.l10n.dailynotesNavigation.archiveDiary),
              Tab(text: context.l10n.dailynotesNavigation.archiveNotes),
              Tab(text: context.l10n.dailynotesNavigation.archiveLongRecords),
            ],
          ),
        ),
        body: IndexedStack(
          index: _category,
          children: [
            _unavailable(),
            Column(
              children: [
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
                  child: Text(
                    context.l10n.dailynotesNavigation.archiveLocalOnly,
                    style: context.theme.typography.labelSmall.onSurfaceVariant,
                  ),
                ),
                TabBar(
                  controller: _noteViews,
                  onTap: (value) => setState(() => _noteView = value),
                  tabs: [
                    Tab(text: context.l10n.dailynotes.ordinaryNotes),
                    Tab(text: context.l10n.dailynotes.knowledgeBase),
                  ],
                ),
                Expanded(
                  child: IndexedStack(
                    index: _noteView,
                    children: [_folders(), _topics()],
                  ),
                ),
              ],
            ),
            _unavailable(),
          ],
        ),
      ),
    );
  }

  Widget _unavailable() => Center(
    child: Padding(
      padding: const EdgeInsets.all(24),
      child: Text(context.l10n.dailynotesNavigation.archiveUnavailable),
    ),
  );

  Widget _breadcrumbs({
    required String root,
    required List<String> path,
    required Map<String, String> names,
  }) => Wrap(
    crossAxisAlignment: WrapCrossAlignment.center,
    children: [
      TextButton(onPressed: () => setState(path.clear), child: Text(root)),
      for (var i = 0; i < path.length; i++) ...[
        const Icon(LucideIcons.chevronRight, size: 14),
        TextButton(
          onPressed: () => setState(() => path.removeRange(i + 1, path.length)),
          child: Text(names[path[i]] ?? ''),
        ),
      ],
    ],
  );

  Widget _folders() {
    final visible = widget.store.foldersWithArchivedNotes;
    final current = _folderPath.lastOrNull;
    final folders = visible
        .where((folder) => folder.parentId == current)
        .toList();
    final knownIds = widget.store.folders.map((folder) => folder.id).toSet();
    final notes = widget.store.archivedNotes
        .where(
          (note) =>
              note.folderId == current ||
              (current == null &&
                  note.folderId != null &&
                  !knownIds.contains(note.folderId)),
        )
        .toList();
    return ListView(
      key: PageStorageKey('archive-folders-${_folderPath.join('/')}'),
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 32),
      children: [
        if (_folderPath.isNotEmpty)
          _breadcrumbs(
            root: context.l10n.dailynotes.ordinaryNotes,
            path: _folderPath,
            names: {for (final folder in visible) folder.id: folder.name},
          ),
        for (final folder in folders)
          ListTile(
            key: ValueKey('archive-folder-${folder.id}'),
            leading: const Icon(LucideIcons.folder),
            title: Text(folder.name),
            trailing: const Icon(LucideIcons.chevronRight),
            onTap: () => setState(() => _folderPath.add(folder.id)),
          ),
        if (notes.isNotEmpty && current == null)
          ListTile(title: Text(context.l10n.dailynotes.uncategorized)),
        for (final note in notes) _noteTile(note, 'folder'),
        if (folders.isEmpty && notes.isEmpty)
          Padding(
            padding: const EdgeInsets.all(16),
            child: Text(context.l10n.dailynotesNavigation.archiveNotesEmpty),
          ),
      ],
    );
  }

  Widget _topics() {
    final visible = widget.store.topicsWithArchivedNotes;
    final current = _topicPath.lastOrNull;
    final topics = visible.where((topic) => topic.parentId == current).toList();
    final notes = current == null
        ? <DailyNote>[]
        : widget.store.archivedNotesForTopic(current);
    return ListView(
      key: PageStorageKey('archive-topics-${_topicPath.join('/')}'),
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 32),
      children: [
        if (_topicPath.isNotEmpty)
          _breadcrumbs(
            root: context.l10n.dailynotes.knowledgeBase,
            path: _topicPath,
            names: {for (final topic in visible) topic.id: topic.title},
          ),
        for (final topic in topics)
          ListTile(
            key: ValueKey('archive-topic-${topic.id}'),
            leading: const Icon(LucideIcons.folderTree),
            title: Text(topic.title),
            trailing: const Icon(LucideIcons.chevronRight),
            onTap: () => setState(() => _topicPath.add(topic.id)),
          ),
        if (notes.isNotEmpty)
          ListTile(title: Text(context.l10n.dailynotes.linkedNotes)),
        for (final note in notes) _noteTile(note, 'topic'),
        if (topics.isEmpty && notes.isEmpty)
          Padding(
            padding: const EdgeInsets.all(16),
            child: Text(context.l10n.dailynotesNavigation.archiveNotesEmpty),
          ),
      ],
    );
  }

  Widget _noteTile(DailyNote note, String view) => ListTile(
    key: ValueKey('archive-$view-note-${note.id}'),
    leading: const Icon(LucideIcons.fileText),
    title: Text(
      note.title.trim().isEmpty
          ? context.l10n.dailynotes.untitledNote
          : note.title,
    ),
    trailing: const Icon(LucideIcons.chevronRight),
    onTap: () => _openNote(note),
  );
}
