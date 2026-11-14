import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:moodiary_assistant/moodiary_assistant.dart'
    show AssistantSessionListPage;
import 'package:moodiary_diary/moodiary_diary.dart'
    show diarySelectionProvider, homeDiaryFilterProvider;
import 'package:moodiary_i18n/moodiary_i18n.dart';
import 'package:moodiary_data/moodiary_data.dart';
import 'package:moodiary_di/moodiary_di.dart';

import '../dailynotes/data/daily_notes_store.dart';
import '../dailynotes/notes/notes_page.dart';
import '../dailynotes/todos/todos_page.dart';
import '../dailynotes/navigation/daily_notes_drawer.dart';

import 'package:moodiary_mobile/app/home/diary_home_page.dart'
    show DiaryHomePage;
import 'package:moodiary_router/moodiary_router.dart';
import 'package:mui/mui.dart';

import 'mood_upgrade_notice.dart';

enum _ShellTab { diary, todos, notes, assistant }

List<MNavDestination> _navDestinations(BuildContext context) {
  final l10n = context.l10n;
  return [
    MNavDestination(
      icon: const Icon(LucideIcons.bookText),
      label: l10n.app.homeNavigatorDiary,
    ),
    MNavDestination(
      icon: const Icon(LucideIcons.listTodo),
      label: l10n.dailynotes.todosTitle,
    ),
    MNavDestination(
      icon: const Icon(LucideIcons.notebookPen),
      label: l10n.dailynotes.notesTitle,
    ),
    MNavDestination(
      icon: const Icon(LucideIcons.astroid),
      label: l10n.app.homeNavigatorAssistant,
    ),
  ];
}

class MobileRootShell extends ConsumerStatefulWidget {
  const MobileRootShell({super.key});

  @override
  ConsumerState<MobileRootShell> createState() => _MobileRootShellState();
}

class _MobileRootShellState extends ConsumerState<MobileRootShell> {
  _ShellTab _tab = .diary;

  @override
  void initState() {
    super.initState();
    _storeFuture = _openStore();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) showPendingMoodNotice(context);
    });
  }

  final _scaffoldKey = GlobalKey<ScaffoldState>();

  final _notesKey = GlobalKey<DailyNotesNotesPageState>();
  final _todosKey = GlobalKey<DailyNotesTodosPageState>();
  late Future<DailyNotesStore> _storeFuture;
  DailyNotesStore? _store;
  List<Widget>? _pages;

  Future<DailyNotesStore> _openStore() async {
    final store = DailyNotesStore(getIt<MoodiaryDatabase>());
    await store.open();
    if (mounted) {
      _store = store;
    } else {
      store.dispose();
    }
    return store;
  }

  List<Widget> _pagesFor(DailyNotesStore store) => _pages ??= [
    DiaryHomePage(onOpenDrawer: () => _scaffoldKey.currentState?.openDrawer()),
    DailyNotesTodosPage(key: _todosKey, store: store),
    DailyNotesNotesPage(key: _notesKey, store: store),
    const AssistantSessionListPage(),
  ];

  @override
  void dispose() {
    _store?.dispose();
    super.dispose();
  }

  Future<void> _newDiary() async {
    final categoryId = _tab == .diary
        ? ref.read(homeDiaryFilterProvider).categoryId
        : null;
    await NewDiaryRoute(categoryId: categoryId).push(context);
  }

  MNavAction _navAction(BuildContext context) {
    final l10n = context.l10n;
    return switch (_tab) {
      .diary => MNavAction(
        icon: const Icon(LucideIcons.pencilLine),
        tooltip: l10n.app.homePageAddDiaryButton,
        onPressed: _newDiary,
      ),
      .assistant => MNavAction(
        icon: const Icon(LucideIcons.messageCirclePlus),
        tooltip: l10n.assistant.newChat,
        onPressed: () => const AssistantConversationRoute().push(context),
      ),
      .todos => MNavAction(
        icon: const Icon(LucideIcons.plus),
        tooltip: l10n.dailynotes.addTask,
        onPressed: () => _todosKey.currentState?.createTodo(),
      ),
      .notes => MNavAction(
        icon: const Icon(LucideIcons.plus),
        tooltip: l10n.dailynotes.create,
        onPressed: () => _notesKey.currentState?.createInCurrentContext(),
      ),
    };
  }

  @override
  Widget build(BuildContext context) {
    final selecting = ref.watch(diarySelectionProvider).isNotEmpty;
    final drawerUsable = _tab == .diary && !selecting;
    return FutureBuilder<DailyNotesStore>(
      future: _storeFuture,
      builder: (context, snapshot) {
        if (snapshot.hasError) {
          return Scaffold(
            appBar: AppBar(title: const Text('DailyNotes')),
            body: Center(
              child: Padding(
                padding: const EdgeInsets.all(24),
                child: Text(context.l10n.dailynotes.storeOpenFailed),
              ),
            ),
          );
        }
        final store = snapshot.data;
        if (store == null) {
          return const Scaffold(
            body: Center(child: CircularProgressIndicator()),
          );
        }
        return Scaffold(
          key: _scaffoldKey,
          extendBody: true,
          drawer: drawerUsable ? DailyNotesDrawer(store: store) : null,
          drawerEnableOpenDragGesture: drawerUsable,
          body: MLazyIndexedStack(
            index: _tab.index,
            children: _pagesFor(store),
          ),
          bottomNavigationBar: MNavBar(
            selectedIndex: _tab.index,
            onDestinationSelected: (i) =>
                setState(() => _tab = _ShellTab.values[i]),
            destinations: _navDestinations(context),
            action: _navAction(context),
          ),
        );
      },
    );
  }
}
