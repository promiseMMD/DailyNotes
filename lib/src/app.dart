import 'package:flutter/material.dart';

/// Navigation-only proof of concept. This app deliberately performs NO writes.
class DailyNotesApp extends StatelessWidget {
  const DailyNotesApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'DailyNotes',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        useMaterial3: true,
        colorScheme: ColorScheme.fromSeed(seedColor: const Color(0xFF6D7B69)),
      ),
      home: const DailyNotesShell(),
    );
  }
}

class DailyNotesShell extends StatefulWidget {
  const DailyNotesShell({super.key});

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

  void _notImplemented([String? action]) {
    final label = action == null ? '此功能' : action;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text('$label尚未接入。预览版本不会创建、保存或同步任何真实数据。'),
        duration: const Duration(seconds: 3),
      ),
    );
  }

  void _createForCurrentContext() {
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
      builder: (sheetContext) => const SafeArea(
        child: Padding(
          padding: EdgeInsets.fromLTRB(20, 0, 20, 28),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text('日记排序', style: TextStyle(fontSize: 18, fontWeight: FontWeight.w600)),
              SizedBox(height: 12),
              Text('排序字段与默认顺序尚未确认。此面板仅核对底部弹出结构，不更改记录。'),
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

  void _openDrawerDestination(String title) {
    Navigator.of(context).pop(); // Close the drawer before pushing the page.
    Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) {
          if (title == '我的') return const MyPage();
          if (title == '数据健康检查') return const DataHealthPage();
          return PlaceholderPage(title: title);
        },
      ),
    );
  }

  Widget _buildDrawer() {
    return Drawer(
      width: MediaQuery.sizeOf(context).width * .76,
      child: SafeArea(
        child: Column(
          children: [
            const ListTile(
              title: Text('DailyNotes', style: TextStyle(fontWeight: FontWeight.bold)),
              subtitle: Text('结构预览 · 未接入真实数据'),
            ),
            const Divider(height: 1),
            Expanded(
              child: ListView.builder(
                itemCount: _drawerItems.length,
                itemBuilder: (_, index) {
                  final title = _drawerItems[index];
                  return ListTile(
                    dense: true,
                    title: Text(title),
                    onTap: () => _openDrawerDestination(title),
                  );
                },
              ),
            ),
            const Divider(height: 1),
            ListTile(
              title: const Text('设置'),
              leading: const Icon(Icons.settings_outlined),
              onTap: () => _openDrawerDestination('设置'),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildSubtabs(List<String> titles, int selected, ValueChanged<int> onSelect) {
    return Row(
      children: [
        for (var i = 0; i < titles.length; i++)
          Padding(
            padding: const EdgeInsets.only(right: 12),
            child: TextButton(
              onPressed: () => onSelect(i),
              child: Text(
                titles[i],
                style: TextStyle(
                  fontWeight: selected == i ? FontWeight.bold : FontWeight.normal,
                ),
              ),
            ),
          ),
      ],
    );
  }

  Widget _section(String title, String emptyMessage, {String? subtitle}) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(title, style: Theme.of(context).textTheme.titleMedium),
          if (subtitle != null)
            Padding(
              padding: const EdgeInsets.only(top: 4),
              child: Text(subtitle, style: Theme.of(context).textTheme.bodySmall),
            ),
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 18),
            child: Text(emptyMessage, style: TextStyle(color: Theme.of(context).colorScheme.onSurfaceVariant)),
          ),
          const Divider(height: 1),
        ],
      ),
    );
  }

  Widget _diaryPage() {
    return ListView(
      key: const Key('diary-page'),
      padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 12),
      children: [
        _section('长期记录', '暂无可读取的长期记录', subtitle: '每条长期记录的独立「追加」入口将在数据层完成后出现'),
        _section('最近日记', '暂无可读取的日记', subtitle: '普通日记按主分类筛选；长期记录不参与该筛选'),
      ],
    );
  }

  Widget _todoPage() {
    return ListView(
      key: const Key('todo-page'),
      padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 12),
      children: [
        _buildSubtabs(['当天待办', '分组待办'], _todoSubtab, (value) => setState(() => _todoSubtab = value)),
        if (_todoSubtab == 0)
          _section('当天任务', '暂无可读取的待办记录')
        else
          _section('按时间分组', '任务分组规则仍待确认；不会创建重复任务'),
      ],
    );
  }

  Widget _notePage() {
    return ListView(
      key: const Key('notes-page'),
      padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 12),
      children: [
        _buildSubtabs(['普通笔记', '知识库'], _noteSubtab, (value) => setState(() => _noteSubtab = value)),
        if (_noteSubtab == 0) ...[
          _section('常用文件夹', '暂无可读取的文件夹', subtitle: '正式首页展示最多 4 个常用文件夹，并提供查看全部入口'),
          _section('文件夹目录', '树形导航将在文件夹数据层完成后接入'),
          _section('最近笔记', '暂无可读取的笔记'),
        ] else
          _section('一级知识主题', '暂无可读取的知识主题', subtitle: '按主题逐级进入，不复制关联笔记正文'),
      ],
    );
  }

  Widget _assistantPage() {
    return ListView(
      key: const Key('assistant-page'),
      padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 12),
      children: [
        _section('助手', '尚未接入 AI 服务', subtitle: '目前不会读取或向外部服务发送任何日记和笔记内容'),
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
        title: Text(_tabNames[_selectedTab]),
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
                IconButton(tooltip: '搜索菜单', onPressed: () => _notImplemented('搜索'), icon: const Icon(Icons.search)),
                const IconButton(tooltip: '快捷菜单待确认', onPressed: null, icon: Icon(Icons.more_horiz)),
                IconButton(tooltip: '排序菜单', onPressed: _showSortSheet, icon: const Icon(Icons.sort)),
              ]
            : null,
      ),
      drawer: _selectedTab == 0 ? _buildDrawer() : null,
      body: SafeArea(child: content),
      bottomNavigationBar: NavigationBar(
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
          NavigationDestination(icon: Icon(Icons.add_circle_outline), label: '新建'),
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
        body: const Center(child: Text('尚未实现；不会修改真实数据')),
      );
}

class MyPage extends StatelessWidget {
  const MyPage({super.key});

  @override
  Widget build(BuildContext context) => Scaffold(
        appBar: AppBar(title: const Text('我的')),
        body: ListView(
          padding: const EdgeInsets.all(20),
          children: const [
            ListTile(title: Text('记录足迹与热力图'), subtitle: Text('未统计；当前版本没有接入本地记录')),
            ExpansionTile(
              title: Text('累计总字数'),
              subtitle: Text('未统计'),
              children: [
                ListTile(title: Text('日记'), trailing: Text('未统计')),
                ListTile(title: Text('普通笔记'), trailing: Text('未统计')),
                ListTile(title: Text('长期记录'), trailing: Text('未统计')),
              ],
            ),
            ListTile(title: Text('趋势统计'), subtitle: Text('写作 / 知识 / 待办 / 使用（未统计）')),
            ListTile(title: Text('年度回顾'), subtitle: Text('尚无可验证统计数据')),
            ListTile(title: Text('回收站'), subtitle: Text('入口已预留；恢复逻辑尚未实现')),
          ],
        ),
      );
}

class DataHealthPage extends StatelessWidget {
  const DataHealthPage({super.key});

  static const categories = ['本地数据库', '附件完整性', '备份有效性', '同步一致性'];

  @override
  Widget build(BuildContext context) => Scaffold(
        appBar: AppBar(title: const Text('数据健康检查')),
        body: ListView(
          padding: const EdgeInsets.all(16),
          children: [
            const ListTile(
              title: Text('健康状态：未检查'),
              subtitle: Text('未执行真实检测，不得视为正常。检查入口只读，不自动修复或删除数据。'),
            ),
            for (final category in categories)
              ListTile(
                title: Text(category),
                subtitle: const Text('未检查'),
                trailing: const Icon(Icons.chevron_right),
                onTap: () => Navigator.of(context).push(
                  MaterialPageRoute<void>(builder: (_) => HealthDetailPage(category: category)),
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
        body: const Padding(
          padding: EdgeInsets.all(20),
          child: Text('未执行真实检测；没有检查时间、范围或结果。当前详情为只读结构预览。'),
        ),
      );
}
