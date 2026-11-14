import 'dart:math';

import 'package:material_ui/material_ui.dart';

import 'preview/soft_components.dart';
import 'preview/diary_interaction_widgets.dart';
import 'preview/preview_diary_repository.dart';
import 'experimental/diary_autosave_editor.dart';
import 'experimental/local_journal_spike.dart';

/// Preview UI. Only Android entrypoint injects an isolated test journal.
class DailyNotesApp extends StatelessWidget {
  const DailyNotesApp({
    super.key,
    this.screenshotFontFamily,
    this.previewRepository,
  });

  /// Non-production override used only by deterministic screenshot tests.
  /// Normal Android rendering continues to use the system text font.
  final String? screenshotFontFamily;

  /// Null in pure widget/layout tests. The Android entrypoint explicitly
  /// supplies the isolated local test database, never a production schema.
  final PreviewDiaryRepository? previewRepository;

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'DailyNotes',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        useMaterial3: true,
        fontFamily: screenshotFontFamily,
        colorScheme: ColorScheme.fromSeed(seedColor: previewSage),
        scaffoldBackgroundColor: previewCanvas,
        appBarTheme: const AppBarTheme(
          backgroundColor: previewCanvas,
          foregroundColor: previewInk,
          centerTitle: false,
          elevation: 0,
          scrolledUnderElevation: 0,
          surfaceTintColor: Colors.transparent,
        ),
      ),
      home: DailyNotesShell(previewRepository: previewRepository),
    );
  }
}

class DailyNotesShell extends StatefulWidget {
  const DailyNotesShell({super.key, this.previewRepository});

  final PreviewDiaryRepository? previewRepository;

  @override
  State<DailyNotesShell> createState() => _DailyNotesShellState();
}

class _DailyNotesShellState extends State<DailyNotesShell> {
  static const _tabNames = ['日记', '待办', '笔记', '助手'];
  static const _drawerItems = [
    '我的',
    '数据同步与备份',
    '定制',
    '分类管理',
    '归档管理',
    '日历总览',
    '数据健康检查',
    '最近访问',
    '隐私与安全',
    '导入与导出',
  ];

  final _scaffoldKey = GlobalKey<ScaffoldState>();
  int _selectedTab = 0;
  int _todoSubtab = 0;
  int _noteSubtab = 0;
  List<DiaryVersion> _previewDiaries = const [];
  String? _previewLoadError;
  bool _loadingPreview = false;
  bool _openingDiary = false;
  bool _searchActive = false;
  String _searchTerm = '';
  bool _oldestFirst = false;
  DateTime? _selectedDiaryDate;

  @override
  void initState() {
    super.initState();
    if (widget.previewRepository != null) {
      // The preview-only database never starts in layout test harnesses.
      Future<void>.microtask(_refreshPreviewDiaries);
    }
  }

  @override
  void dispose() {
    final repository = widget.previewRepository;
    if (repository != null) {
      // There is no active editor after the owning shell is disposed.
      repository.close();
    }
    super.dispose();
  }

  Future<void> _refreshPreviewDiaries() async {
    final repository = widget.previewRepository;
    if (repository == null || !mounted) return;
    setState(() {
      _loadingPreview = true;
      _previewLoadError = null;
    });
    try {
      final entries = await repository.listDiaries();
      if (!mounted) return;
      setState(() {
        _previewDiaries = entries;
        _loadingPreview = false;
      });
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _loadingPreview = false;
        _previewLoadError = '读取本机测试记录失败，未修改任何已有内容';
      });
    }
  }

  Future<void> _openDiary([String? existingId]) async {
    final repository = widget.previewRepository;
    if (repository == null) {
      _notImplemented('测试日记编辑');
      return;
    }
    if (_openingDiary) return;
    setState(() => _openingDiary = true);
    try {
      // Preview-only identity scheme; the official V2.51 key format is
      // undecided. Never reuse this as a future production entity ID.
      final id = existingId ??
          'preview-${DateTime.now().toUtc().microsecondsSinceEpoch}-'
          '${Random.secure().nextInt(1 << 32)}';
      final session = await repository.openEditor(id);
      if (!mounted) {
        session.dispose();
        return;
      }
      try {
        await Navigator.of(context).push<void>(
          MaterialPageRoute<void>(
            builder: (_) => ExperimentalDiaryEditor(session: session),
          ),
        );
      } finally {
        session.dispose();
      }
      if (mounted) await _refreshPreviewDiaries();
    } catch (_) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('测试日记打开失败，已有记录未被修改')),
        );
      }
    } finally {
      if (mounted) setState(() => _openingDiary = false);
    }
  }

  void _toggleSearch() {
    setState(() {
      _searchActive = !_searchActive;
      if (!_searchActive) _searchTerm = '';
    });
  }

  List<DiaryVersion> get _visibleDiaries {
    final needle = _searchTerm.trim().toLowerCase();
    final matches = _previewDiaries.where((entry) {
      if (needle.isNotEmpty && !entry.body.toLowerCase().contains(needle)) {
        return false;
      }
      final selected = _selectedDiaryDate;
      if (selected != null) {
        final date = previewLocalDate(entry);
        if (date == null || !previewSameDate(date, selected)) return false;
      }
      return true;
    }).toList();
    matches.sort((a, b) {
      final order = a.savedUtc.compareTo(b.savedUtc);
      if (order != 0) return _oldestFirst ? order : -order;
      return _oldestFirst
          ? a.entityId.compareTo(b.entityId)
          : b.entityId.compareTo(a.entityId);
    });
    return matches;
  }

  void _notImplemented([String? action]) {
    final label = action ?? '此功能';
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text('$label尚未接入。预览版本不会创建、保存或同步任何真实数据。'),
        duration: const Duration(seconds: 3),
      ),
    );
  }

  void _createForCurrentContext() {
    if (_selectedTab == 0) {
      _openDiary();
      return;
    }
    const actions = ['新建日记', '新建待办', '新建笔记', '新建对话'];
    if (_selectedTab == 2 && _noteSubtab == 1) {
      _notImplemented('新建一级知识主题');
    } else {
      _notImplemented(actions[_selectedTab]);
    }
  }

  void _showSortSheet() {
    showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      builder: (sheetContext) => SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(20, 0, 20, 25),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text('日记排序', style: TextStyle(
                fontSize: 18, fontWeight: FontWeight.w600,
              )),
              const SizedBox(height: 8),
              const Text('排序字段与默认顺序尚未确认。以下仅为本机测试记录的临时排序。',
                style: TextStyle(fontSize: 12, color: previewMuted)),
              const SizedBox(height: 9),
              for (final ascending in [false, true])
                ListTile(
                  key: Key(ascending ? 'sort-oldest' : 'sort-newest'),
                  dense: true,
                  contentPadding: EdgeInsets.zero,
                  title: Text(ascending ? '较早编辑优先（预览）' : '最近编辑优先（预览）'),
                  trailing: Icon(
                    _oldestFirst == ascending
                        ? Icons.radio_button_checked
                        : Icons.radio_button_unchecked,
                    color: previewSage,
                  ),
                  onTap: () {
                    setState(() => _oldestFirst = ascending);
                    Navigator.of(sheetContext).pop();
                  },
                ),
            ],
          ),
        ),
      ),
    );
  }

  void _showPinnedMenu() {
    showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      builder: (_) => const SafeArea(
        child: Padding(
          padding: EdgeInsets.fromLTRB(20, 0, 20, 24),
          child: ListTile(
            title: Text('局域网 Web 服务'),
            subtitle: Text('仅保留已确认的入口；服务与设备配对尚未实现'),
            trailing: Icon(Icons.power_settings_new_outlined),
          ),
        ),
      ),
    );
  }

  Future<void> _openDrawerDestination(String title) async {
    Navigator.of(context).pop();
    if (title == '日历总览') {
      final date = await Navigator.of(context).push<DateTime>(
        MaterialPageRoute<DateTime>(
          builder: (_) => PreviewDiaryCalendarPage(entries: _previewDiaries),
        ),
      );
      if (mounted && date != null) {
        setState(() {
          _selectedTab = 0;
          _selectedDiaryDate = date;
          _searchActive = false;
          _searchTerm = '';
        });
      }
      return;
    }
    if (!mounted) return;
    await Navigator.of(context).push<void>(
      MaterialPageRoute<void>(
        builder: (_) {
          if (title == '我的') return MyPage(previewDiaryCount: _previewDiaries.length);
          if (title == '数据健康检查') return const DataHealthPage();
          return PlaceholderPage(title: title);
        },
      ),
    );
  }

  Widget _buildDrawer() {
    const menuIcons = [
      Icons.person_outline,
      Icons.cloud_sync_outlined,
      Icons.palette_outlined,
      Icons.category_outlined,
      Icons.inventory_2_outlined,
      Icons.calendar_month_outlined,
      Icons.fact_check_outlined,
      Icons.history_outlined,
      Icons.lock_outline,
      Icons.import_export_outlined,
    ];
    return Drawer(
      width: MediaQuery.sizeOf(context).width * .76,
      backgroundColor: previewCanvas,
      child: SafeArea(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(18, 21, 16, 19),
              child: Row(
                children: [
                  Container(
                    height: 41,
                    width: 41,
                    decoration: BoxDecoration(
                      color: previewSoftSage,
                      borderRadius: BorderRadius.circular(13),
                    ),
                    child: const Icon(Icons.menu_book_outlined, color: previewSage),
                  ),
                  const SizedBox(width: 12),
                  const Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text('DailyNotes', style: TextStyle(
                          fontSize: 17,
                          color: previewInk,
                          fontWeight: FontWeight.w700,
                        )),
                        SizedBox(height: 3),
                        Text('一切都从记录开始', style: TextStyle(
                          fontSize: 11, color: previewMuted,
                        )),
                      ],
                    ),
                  ),
                ],
              ),
            ),
            const PreviewThinDivider(),
            Expanded(
              child: ListView.builder(
                padding: const EdgeInsets.symmetric(vertical: 8),
                itemCount: _drawerItems.length,
                itemBuilder: (_, index) {
                  final name = _drawerItems[index];
                  return Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 7),
                    child: ListTile(
                      dense: true,
                      visualDensity: const VisualDensity(vertical: -2),
                      contentPadding: const EdgeInsets.symmetric(horizontal: 13),
                      minLeadingWidth: 20,
                      horizontalTitleGap: 13,
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(12),
                      ),
                      leading: Icon(menuIcons[index], color: previewSage, size: 19),
                      title: Text(name, style: const TextStyle(
                        color: previewInk, fontSize: 13,
                      )),
                      onTap: () => _openDrawerDestination(name),
                    ),
                  );
                },
              ),
            ),
            const PreviewThinDivider(),
            Padding(
              padding: const EdgeInsets.fromLTRB(7, 4, 7, 5),
              child: ListTile(
                leading: const Icon(Icons.settings_outlined, color: previewSage),
                title: const Text('设置', style: TextStyle(
                  color: previewInk,
                  fontSize: 13,
                  fontWeight: FontWeight.w600,
                )),
                onTap: () => _openDrawerDestination('设置'),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildSubtabs(
    List<String> titles,
    int selected,
    ValueChanged<int> onSelect,
  ) {
    return PreviewTabStrip(
      labels: titles,
      activeIndex: selected,
      onSelect: onSelect,
    );
  }

  Widget _section(String title, String emptyMessage, {String? subtitle}) {
    final icon = switch (title) {
      '常用文件夹' || '文件夹目录' => Icons.folder_open_outlined,
      '最近笔记' => Icons.sticky_note_2_outlined,
      '一级知识主题' => Icons.account_tree_outlined,
      '当天任务' || '按时间分组' => Icons.check_circle_outline,
      '助手' => Icons.auto_awesome_outlined,
      _ => Icons.description_outlined,
    };
    return Padding(
      padding: const EdgeInsets.only(top: 17),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          PreviewSectionHeader(title: title, subtitle: subtitle),
          PreviewEmptyState(
            icon: icon,
            title: emptyMessage,
            description: '当前为结构预览，尚未接入真实内容。',
            compact: true,
          ),
          const PreviewThinDivider(),
        ],
      ),
    );
  }

  Widget _diaryPage() {
    final now = DateTime.now();
    final month = '${now.year}年${now.month}月';
    final entries = _visibleDiaries;
    DateTime? previousDay;
    return ListView(
      key: const Key('diary-page'),
      padding: const EdgeInsets.fromLTRB(21, 0, 21, 28),
      children: [
        PreviewPageIntro(
          kicker: 'DAILYNOTES  ·  $month',
          title: '好好记录，慢慢生活',
          subtitle: '日记是留给自己的时间，不必写得完美。',
        ),
        const PreviewSectionHeader(
          title: '长期记录',
          subtitle: '长期观察独立于普通日记；每条记录保留自己的追加入口',
        ),
        const PreviewEmptyState(
          icon: Icons.auto_stories_outlined,
          title: '暂无可读取的长期记录',
          description: '长期记录的数据结构尚未完成，不会将普通日记冒充长期记录。',
          compact: true,
        ),
        const PreviewThinDivider(),
        const SizedBox(height: 24),
        PreviewSectionHeader(
          title: '最近日记',
          subtitle: '按时间连续阅读 · 本机测试日记，尚未备份同步',
          trailing: IconButton(
            tooltip: '刷新测试日记',
            icon: const Icon(Icons.refresh, size: 19),
            onPressed: _loadingPreview ? null : _refreshPreviewDiaries,
          ),
        ),
        if (_searchActive) ...[
          const SizedBox(height: 8),
          TextField(
            key: const Key('preview-diary-search'),
            autofocus: true,
            decoration: InputDecoration(
              hintText: '搜索本机测试日记正文',
              prefixIcon: const Icon(Icons.search),
              suffixIcon: IconButton(
                tooltip: '清除搜索',
                onPressed: () => setState(() => _searchTerm = ''),
                icon: const Icon(Icons.close),
              ),
            ),
            onChanged: (text) => setState(() => _searchTerm = text),
          ),
        ],
        if (_selectedDiaryDate != null)
          Padding(
            padding: const EdgeInsets.only(top: 8),
            child: Align(
              alignment: Alignment.centerLeft,
              child: InputChip(
                label: Text('日期：${previewDateLabel(_selectedDiaryDate!)}'),
                onDeleted: () => setState(() => _selectedDiaryDate = null),
                deleteIcon: const Icon(Icons.close, size: 17),
              ),
            ),
          ),
        if (_previewLoadError != null)
          PreviewEmptyState(
            icon: Icons.error_outline,
            title: _previewLoadError!,
            description: '点击上方刷新重试，切勿卸载含测试数据的 APK。',
            compact: true,
          )
        else if (_loadingPreview && _previewDiaries.isEmpty)
          const LinearProgressIndicator()
        else if (entries.isEmpty && _previewDiaries.isEmpty)
          const PreviewEmptyState(
            icon: Icons.event_note_outlined,
            title: '暂无可读取的日记',
            description: '点击底栏加号写一篇测试日记，保存后会显示在这里。',
          )
        else if (entries.isEmpty)
          const PreviewEmptyState(
            icon: Icons.search_off_outlined,
            title: '没有匹配的日记',
            description: '可修改搜索词、日期，或者清除筛选。',
          )
        else
          for (final entry in entries) ...[
            if (previewLocalDate(entry) case final DateTime date)
              if (previousDay == null || !previewSameDate(previousDay, date)) ...[
                Padding(
                  padding: const EdgeInsets.only(top: 21, bottom: 4),
                  child: Text(
                    previewDateLabel(date),
                    style: const TextStyle(
                      color: previewSage,
                      fontSize: 12,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ),
                // Note the effective first/last editing date shown is the
                // committed revision timestamp, not the original create date.
                ...[Builder(builder: (_) {
                  previousDay = date;
                  return const SizedBox.shrink();
                })],
              ],
            PreviewDiaryEntryRow(entry: entry, onOpen: () => _openDiary(entry.entityId)),
            const PreviewThinDivider(),
          ],
        const SizedBox(height: 21),
        const Text(
          '测试数据区 · 无 WebDAV 同步与可恢复备份 · 请勿记录重要信息',
          textAlign: TextAlign.center,
          style: TextStyle(color: previewMuted, fontSize: 11),
        ),
      ],
    );
  }

  Widget _todoPage() {
    return ListView(
      key: const Key('todo-page'),
      padding: const EdgeInsets.fromLTRB(21, 0, 21, 28),
      children: [
        const PreviewPageIntro(
          kicker: 'YOUR DAY',
          title: '把今天留给重要的事',
          subtitle: '简洁地查看任务，专注于接下来的一步。',
        ),
        _buildSubtabs(
          ['当天待办', '分组待办'],
          _todoSubtab,
          (value) => setState(() => _todoSubtab = value),
        ),
        if (_todoSubtab == 0)
          _section('当天任务', '暂无可读取的待办记录',
              subtitle: '当天任务集中在这里呈现')
        else
          _section('按时间分组', '尚无可读取的分组任务',
              subtitle: '逾期、今天与未来任务将共享同一数据源'),
      ],
    );
  }

  Widget _notePage() {
    return ListView(
      key: const Key('notes-page'),
      padding: const EdgeInsets.fromLTRB(21, 0, 21, 28),
      children: [
        const PreviewPageIntro(
          kicker: 'THOUGHTS & KNOWLEDGE',
          title: '想法，都有自己的位置',
          subtitle: '笔记留住灵感，知识库负责建立联系。',
        ),
        _buildSubtabs(
          ['普通笔记', '知识库'],
          _noteSubtab,
          (value) => setState(() => _noteSubtab = value),
        ),
        if (_noteSubtab == 0) ...[
          Padding(
            padding: const EdgeInsets.only(top: 17),
            child: PreviewSectionHeader(
              title: '常用文件夹',
              subtitle: '正式版本展示 4 个常用文件夹',
              trailing: TextButton(
                onPressed: () => _notImplemented('查看全部文件夹'),
                child: const Text('查看全部', style: TextStyle(
                  color: previewSage, fontSize: 12,
                )),
              ),
            ),
          ),
          const PreviewEmptyState(
            icon: Icons.folder_open_outlined,
            title: '暂无可读取的文件夹',
            description: '文件夹将按实际使用情况排列，不展示虚构示例。',
            compact: true,
          ),
          const PreviewThinDivider(),
          _section('文件夹目录', '尚未连接文件夹目录',
              subtitle: '保留树形导航入口，按需进入完整目录'),
          _section('最近笔记', '暂无可读取的笔记',
              subtitle: '近期编辑的标题、摘要及标签将在此展示'),
        ] else
          _section('一级知识主题', '暂无可读取的知识主题',
              subtitle: '逐级进入主题，关联原始笔记而不复制正文'),
      ],
    );
  }

  Widget _assistantPage() {
    return ListView(
      key: const Key('assistant-page'),
      padding: const EdgeInsets.fromLTRB(21, 0, 21, 28),
      children: [
        const PreviewPageIntro(
          kicker: 'ASSISTANT',
          title: '整理思绪的另一种方式',
          subtitle: '助手将来可以协助检索与梳理你的记录。',
        ),
        const PreviewSectionHeader(title: '助手'),
        const PreviewEmptyState(
          icon: Icons.auto_awesome_outlined,
          title: '尚未接入 AI 服务',
          description: '目前不会读取、同步或向外部服务发送日记与笔记。',
        ),
        const PreviewThinDivider(),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    final content = switch (_selectedTab) {
      0 => _diaryPage(),
      1 => _todoPage(),
      2 => _notePage(),
      _ => _assistantPage(),
    };

    return Scaffold(
      key: _scaffoldKey,
      appBar: AppBar(
        title: Text(
          _tabNames[_selectedTab],
          style: const TextStyle(
            fontSize: 17,
            color: previewInk,
            fontWeight: FontWeight.w700,
          ),
        ),
        leading: _selectedTab == 0
            ? IconButton(
                tooltip: '打开侧边栏',
                onPressed: () => _scaffoldKey.currentState?.openDrawer(),
                icon: const Icon(Icons.menu),
              )
            : null,
        actions: _selectedTab == 0
            ? [
                IconButton(tooltip: '置顶菜单', onPressed: _showPinnedMenu, icon: const Icon(Icons.push_pin_outlined)),
                IconButton(tooltip: '搜索菜单', onPressed: _toggleSearch, icon: Icon(_searchActive ? Icons.close : Icons.search)),
                const IconButton(tooltip: '快捷菜单待确认', onPressed: null, icon: Icon(Icons.more_horiz)),
                IconButton(tooltip: '排序菜单', onPressed: _showSortSheet, icon: const Icon(Icons.sort)),
              ]
            : null,
      ),
      drawer: _selectedTab == 0 ? _buildDrawer() : null,
      body: SafeArea(child: content),
      bottomNavigationBar: NavigationBar(
        height: 75,
        backgroundColor: previewCanvas,
        indicatorColor: previewSoftSage,
        selectedIndex: _selectedTab,
        onDestinationSelected: (index) {
          if (index == 4) {
            _createForCurrentContext();
          } else {
            setState(() => _selectedTab = index);
          }
        },
        destinations: const [
          NavigationDestination(icon: Icon(Icons.menu_book_outlined), label: '日记'),
          NavigationDestination(icon: Icon(Icons.checklist_outlined), label: '待办'),
          NavigationDestination(icon: Icon(Icons.note_outlined), label: '笔记'),
          NavigationDestination(icon: Icon(Icons.chat_bubble_outline), label: '助手'),
          NavigationDestination(icon: PreviewCreateGlyph(), label: '新建'),
        ],
      ),
    );
  }
}

class PlaceholderPage extends StatelessWidget {
  const PlaceholderPage({required this.title, super.key});

  final String title;

  @override
  Widget build(BuildContext context) => Scaffold(
        appBar: AppBar(title: Text(title)),
        body: Center(
          child: Padding(
            padding: const EdgeInsets.all(30),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Container(
                  width: 64,
                  height: 64,
                  decoration: BoxDecoration(
                    color: previewSoftSage,
                    borderRadius: BorderRadius.circular(19),
                  ),
                  child: const Icon(Icons.construction_outlined,
                      color: previewSage, size: 27),
                ),
                const SizedBox(height: 20),
                Text(
                  title,
                  style: const TextStyle(
                    color: previewInk,
                    fontSize: 20,
                    fontWeight: FontWeight.w700,
                  ),
                ),
                const SizedBox(height: 8),
                const Text(
                  '该页面正在设计中。尚未实现；不会修改真实数据。',
                  textAlign: TextAlign.center,
                  style: TextStyle(
                    color: previewMuted,
                    fontSize: 12,
                    height: 1.5,
                  ),
                ),
              ],
            ),
          ),
        ),
      );
}

class MyPage extends StatelessWidget {
  const MyPage({super.key});

  @override
  Widget build(BuildContext context) => Scaffold(
        appBar: AppBar(title: const Text('我的')),
        body: ListView(
          padding: const EdgeInsets.fromLTRB(21, 0, 21, 28),
          children: [
            const PreviewPageIntro(
              kicker: 'PERSONAL SPACE',
              title: '我的记录生活',
              subtitle: '足迹、回顾与个人数据管理，留在同一个地方。',
            ),
            Container(
              decoration: BoxDecoration(
                color: previewSoftSage,
                borderRadius: BorderRadius.circular(17),
              ),
              child: const ExpansionTile(
                leading: Icon(Icons.edit_note_outlined, color: previewSage),
                title: Text('累计总字数', style: TextStyle(
                  fontSize: 14,
                  color: previewInk,
                  fontWeight: FontWeight.w600,
                )),
                subtitle: Text('未统计', style: TextStyle(
                  color: previewMuted, fontSize: 12,
                )),
                children: [
                  ListTile(title: Text('日记'), trailing: Text('未统计')),
                  ListTile(title: Text('普通笔记'), trailing: Text('未统计')),
                  ListTile(title: Text('长期记录'), trailing: Text('未统计')),
                ],
              ),
            ),
            const SizedBox(height: 24),
            const PreviewSectionHeader(title: '记录足迹'),
            const PreviewEmptyState(
              icon: Icons.calendar_today_outlined,
              title: '记录足迹与热力图',
              description: '未统计；当前版本还没有接入本地记录。',
              compact: true,
            ),
            const PreviewThinDivider(),
            const SizedBox(height: 20),
            const PreviewSectionHeader(title: '个人回顾'),
            const PreviewSoftTile(
              icon: Icons.show_chart_outlined,
              title: '趋势统计',
              subtitle: '写作 / 知识 / 待办 / 使用（未统计）',
            ),
            const PreviewSoftTile(
              icon: Icons.auto_stories_outlined,
              title: '年度回顾',
              subtitle: '尚无可验证统计数据',
            ),
            const PreviewThinDivider(),
            const SizedBox(height: 20),
            const PreviewSectionHeader(title: '个人数据'),
            const PreviewSoftTile(
              icon: Icons.restore_from_trash_outlined,
              title: '回收站',
              subtitle: '入口已预留；恢复逻辑尚未实现',
            ),
          ],
        ),
      );
}

class DataHealthPage extends StatelessWidget {
  const DataHealthPage({super.key});

  static const categories = ['本地数据库', '附件完整性', '备份有效性', '同步一致性'];
  static const categoryIcons = [
    Icons.storage_outlined,
    Icons.attach_file_outlined,
    Icons.backup_outlined,
    Icons.sync_outlined,
  ];

  @override
  Widget build(BuildContext context) => Scaffold(
        appBar: AppBar(title: const Text('数据健康检查')),
        body: ListView(
          padding: const EdgeInsets.fromLTRB(21, 0, 21, 28),
          children: [
            const PreviewPageIntro(
              kicker: 'DATA SAFETY',
              title: '了解数据的实际状态',
              subtitle: '检测仅供查看，绝不自动修复、覆盖或清除内容。',
            ),
            Container(
              padding: const EdgeInsets.all(17),
              decoration: BoxDecoration(
                color: previewSoftSage,
                borderRadius: BorderRadius.circular(15),
              ),
              child: const Row(
                children: [
                  Icon(Icons.info_outline, color: previewSage),
                  SizedBox(width: 13),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text('健康状态：未检查', style: TextStyle(
                          color: previewInk,
                          fontWeight: FontWeight.w700,
                          fontSize: 14,
                        )),
                        SizedBox(height: 4),
                        Text(
                          '尚未执行真实检测，不得视为正常。',
                          style: TextStyle(color: previewMuted, fontSize: 11),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 22),
            const PreviewSectionHeader(
              title: '检查项目',
              subtitle: '只读诊断 · 检测结果尚未产生',
            ),
            const SizedBox(height: 9),
            for (var i = 0; i < categories.length; i++) ...[
              PreviewSoftTile(
                icon: categoryIcons[i],
                title: categories[i],
                subtitle: '未检查',
                trailing: const Icon(
                  Icons.chevron_right, color: previewMuted,
                ),
                onTap: () => Navigator.of(context).push(
                  MaterialPageRoute<void>(
                    builder: (_) => HealthDetailPage(category: categories[i]),
                  ),
                ),
              ),
              const PreviewThinDivider(),
            ],
            const SizedBox(height: 13),
            const Text(
              '检测入口只读，不会自动修复或删除数据。'
              ' 本机持久化与 WebDAV 同步状态分别判断。',
              style: TextStyle(
                color: previewMuted,
                fontSize: 11,
                height: 1.5,
              ),
            ),
          ],
        ),
      );
}

class HealthDetailPage extends StatelessWidget {
  const HealthDetailPage({required this.category, super.key});

  final String category;

  @override
  Widget build(BuildContext context) => Scaffold(
        appBar: AppBar(title: Text(category)),
        body: ListView(
          padding: const EdgeInsets.fromLTRB(21, 0, 21, 25),
          children: [
            PreviewPageIntro(
              kicker: 'READ-ONLY DETAILS',
              title: category,
              subtitle: '目前没有可验证的诊断记录。',
            ),
            const PreviewSoftTile(
              icon: Icons.info_outline,
              title: '未检查',
              subtitle: '没有检查时间、范围或结果。',
            ),
            const PreviewThinDivider(),
            const SizedBox(height: 18),
            const Text(
              '未执行真实检测；当前详情为只读结构预览。'
              ' 不会自动修复、删除或同步任何数据。',
              style: TextStyle(
                color: previewMuted,
                height: 1.6,
                fontSize: 12,
              ),
            ),
          ],
        ),
      );
}
