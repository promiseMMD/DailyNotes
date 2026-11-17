// Moodiary Continuous Diary mod — additive UI using native Diary records.
// Legacy topics/children below remain ordinary Diary objects. W9.4's native
// monthly workspace uses the separate W9 revision tables and is local-only.
// AGPL-3.0, derivative work of Moodiary (https://github.com/ZhuJHua/moodiary).
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:moodiary_data/moodiary_data.dart';
import 'package:moodiary_di/moodiary_di.dart';
import 'package:moodiary_files/moodiary_files.dart';
import 'package:moodiary_models/moodiary_models.dart';
import 'package:moodiary_router/moodiary_router.dart';
import 'package:moodiary_utils/moodiary_utils.dart';
import 'mod_lan_page.dart';
import 'mod_monthly_index.dart';
import 'mod_month_page.dart';
import 'mod_month_composer.dart';
import 'package:moodiary_i18n/moodiary_i18n.dart';
import 'mod_month_native.dart';
import 'mod_month_store.dart';
import 'mod_lan_service.dart';

class ModDiary {
  static const topicTag = '__moodiary_mod_topic_v1';
  static const entryPrefix = '__moodiary_mod_entry_v1:';
  static const pinTag = '__moodiary_mod_pin_v1';
  static const rankPrefix = '__moodiary_mod_pin_order_v1:';
  static const creationPrefix = '__moodiary_mod_created_utc_v1:';

  static bool isTopic(Diary d) => d.tags.contains(topicTag);
  static bool isChild(Diary d) => d.tags.any((t) => t.startsWith(entryPrefix));
  static bool isPinned(Diary d) => d.tags.contains(pinTag);
  static String? topicIdOf(Diary d) {
    for (final tag in d.tags) {
      if (tag.startsWith(entryPrefix)) return tag.substring(entryPrefix.length);
    }
    return null;
  }
  static int rank(Diary d) {
    for (final tag in d.tags) {
      if (tag.startsWith(rankPrefix)) {
        return int.tryParse(tag.substring(rankPrefix.length)) ?? 999999;
      }
    }
    return 999999;
  }
  static DateTime? createdAtOf(Diary d) {
    for (final tag in d.tags) {
      if (tag.startsWith(creationPrefix)) {
        return DateTime.tryParse(tag.substring(creationPrefix.length))?.toLocal();
      }
    }
    return null;
  }

  static bool hideFromOrdinaryList(Diary d) => isTopic(d) || isChild(d);

  /// Read-only: never repairs, deletes, or rewrites any diary or cloud data.
  static ModSafetyReport audit(List<Diary> all) {
    final visible = all.where((d) => d.show).toList();
    final topicIds = {for (final d in visible.where(isTopic)) d.id};
    final children = visible.where(isChild).toList();
    final pins = pinned(visible);
    final duplicates = <int, int>{};
    var orphan = 0;
    var invalidRanks = 0;
    var invalidCreation = 0;
    var invalidAssociation = 0;
    for (final child in children) {
      final associations = child.tags.where((t) => t.startsWith(entryPrefix));
      if (associations.length != 1 || topicIdOf(child)?.isEmpty != false) {
        invalidAssociation++;
      } else if (!topicIds.contains(topicIdOf(child))) {
        orphan++;
      }
      for (final tag in child.tags.where((t) => t.startsWith(creationPrefix))) {
        if (DateTime.tryParse(tag.substring(creationPrefix.length)) == null) {
          invalidCreation++;
        }
      }
    }
    for (final pin in pins) {
      final rankTags = pin.tags.where((t) => t.startsWith(rankPrefix)).toList();
      if (rankTags.length != 1 ||
          int.tryParse(rankTags.singleOrNull?.substring(rankPrefix.length) ?? '') == null) {
        invalidRanks++;
        continue;
      }
      duplicates.update(rank(pin), (v) => v + 1, ifAbsent: () => 1);
    }
    final duplicateRanks = duplicates.values.where((count) => count > 1)
        .fold<int>(0, (a, count) => a + count - 1);
    return ModSafetyReport(
      totalDiaries: visible.length,
      topics: topicIds.length,
      entries: children.length,
      pins: pins.length,
      orphanEntries: orphan,
      invalidAssociations: invalidAssociation,
      invalidCreationTimes: invalidCreation,
      invalidPinRanks: invalidRanks,
      duplicatePinRanks: duplicateRanks,
    );
  }

  static List<Diary> pinned(List<Diary> all) =>
      all.where((d) => d.show && isPinned(d) && !isChild(d)).toList()
        ..sort((a, b) {
          final r = rank(a).compareTo(rank(b));
          return r != 0 ? r : a.time.compareTo(b.time);
        });

  static DiaryRepository get repo => getIt<DiaryRepository>();

  static Future<Diary> createTopic(String title) async {
    final all = await repo.getAllDiaries();
    final rank = pinned(all).length;
    final topic = Diary.create(
      title: title.trim(),
      content: MarkdownToTiptap.convert('长期记录主题：$title') ?? '',
      contentText: '长期记录主题：$title',
      imageName: const [], audioName: const [], videoName: const [],
      tags: [topicTag, pinTag, '$rankPrefix$rank'],
      type: DiaryType.tiptap,
    );
    await repo.insertADiary(topic);
    return topic;
  }

  static Future<Diary> addEntry(
    Diary topic, String text, DateTime eventTime, {
    required String stableEntryId,
    required DateTime createdAt,
  }) async {
    final clean = text.trim();
    if (clean.isEmpty) throw ArgumentError('记录内容不能为空');
    // A removed topic must not silently receive an orphaned child record.
    final freshTopic = await repo.getDiaryByBusinessId(topic.id);
    if (freshTopic == null || !freshTopic.show || !isTopic(freshTopic)) {
      throw StateError('长期主题已经删除或类型已改变，未保存任何新记录');
    }
    // A failed UI acknowledgement or repeated Save must not produce duplicates.
    final existing = await repo.getDiaryByBusinessId(stableEntryId);
    if (existing != null) {
      if (existing.show && topicIdOf(existing) == topic.id &&
          existing.contentText == clean &&
          existing.time.millisecondsSinceEpoch == eventTime.millisecondsSinceEpoch) {
        return existing;
      }
      throw StateError('记录 ID 已存在且内容不同，已停止保存以避免覆盖');
    }
    final rich = MarkdownToTiptap.convert(clean);
    if (rich == null) throw StateError('记录格式转换失败');
    final entry = Diary.create(
      title: '${freshTopic.title} · ${_dateTime(eventTime)}',
      content: rich,
      contentText: clean,
      imageName: const [], audioName: const [], videoName: const [],
      tags: ['$entryPrefix${topic.id}',
        '$creationPrefix${createdAt.toUtc().toIso8601String()}'],
      type: DiaryType.tiptap,
    ).copyWith(id: stableEntryId, time: eventTime);
    // Same object semantics as original Diary: upstream WebDAV already knows
    // how to sync diary/<uuid>.json, ZIP exports and encrypted media metadata.
    await repo.insertADiary(entry);
    return entry;
  }

  static Future<void> togglePin(Diary diary) async {
    final tags = [...diary.tags]..removeWhere((tag) => tag == pinTag || tag.startsWith(rankPrefix));
    if (!isPinned(diary)) {
      final pinnedCount = pinned(await repo.getAllDiaries()).length;
      tags.addAll([pinTag, '$rankPrefix$pinnedCount']);
    }
    await repo.updateADiary(newDiary: diary.copyWith(tags: tags, lastModified: DateTime.timestamp()), index: IndexMode.skip);
  }

  static Future<void> movePinned(Diary diary, int direction) async {
    final pins = pinned(await repo.getAllDiaries());
    final i = pins.indexWhere((p) => p.id == diary.id);
    final j = i + direction;
    if (i < 0 || j < 0 || j >= pins.length) return;
    final moving = pins.removeAt(i);
    pins.insert(j, moving);
    // Different records have separate sync identifiers; deterministic ranks.
    // On errors an existing rank is retained and reordering can be retried.
    for (var n = 0; n < pins.length; n++) {
      final current = pins[n];
      if (rank(current) == n) continue;
      final tags = [...current.tags]..removeWhere((t) => t.startsWith(rankPrefix));
      tags.add('$rankPrefix$n');
      await repo.updateADiary(newDiary: current.copyWith(tags: tags, lastModified: DateTime.timestamp()), index: IndexMode.skip);
    }
  }
}

/// A local-only audit. Cloud consistency requires separate WebDAV validation.
class ModSafetyReport {
  final int totalDiaries, topics, entries, pins, orphanEntries;
  final int invalidAssociations, invalidCreationTimes, invalidPinRanks, duplicatePinRanks;
  const ModSafetyReport({
    required this.totalDiaries, required this.topics, required this.entries,
    required this.pins, required this.orphanEntries,
    required this.invalidAssociations, required this.invalidCreationTimes,
    required this.invalidPinRanks, required this.duplicatePinRanks,
  });
  int get issueCount => orphanEntries + invalidAssociations +
      invalidCreationTimes + invalidPinRanks + duplicatePinRanks;
}

class ModDraft {
  final String topicId;
  final String entryId;
  final String text;
  final DateTime eventTime;
  final DateTime createdAt;
  const ModDraft({required this.topicId, required this.entryId,
      required this.text, required this.eventTime, required this.createdAt});

  Map<String, dynamic> toJson() => {
    'schema': 1, 'topicId': topicId, 'entryId': entryId,
    'text': text, 'eventTimeMs': eventTime.millisecondsSinceEpoch,
    'createdAtMs': createdAt.millisecondsSinceEpoch,
  };

  static ModDraft fromJson(Map<String, dynamic> j, String topicId) {
    if (j['schema'] != 1 || j['topicId'] != topicId ||
        j['entryId'] is! String || j['text'] is! String ||
        j['eventTimeMs'] is! int || j['createdAtMs'] is! int) {
      throw const FormatException('草稿格式无效，保留原始文件供恢复');
    }
    return ModDraft(topicId: topicId, entryId: j['entryId'] as String,
      text: j['text'] as String,
      eventTime: DateTime.fromMillisecondsSinceEpoch(j['eventTimeMs'] as int),
      createdAt: DateTime.fromMillisecondsSinceEpoch(j['createdAtMs'] as int));
  }
}

/// One durable draft file per topic, located in app-private database storage.
/// File replacement is atomic on the same volume; writes are serialized.
/// Drafts are NOT part of WebDAV until the user commits them as a Diary.
class ModDraftStore {
  static final Map<String, Future<void>> _pending = {};
  static File _file(String topicId) => File(
    AppFiles.getRealPath('database', 'mod-draft-$topicId.json'));

  static Future<void> _enqueue(String topicId, Future<void> Function() operation) {
    final prev = _pending[topicId] ?? Future<void>.value();
    final next = prev.catchError((Object _) {}).then((_) => operation());
    _pending[topicId] = next;
    next.whenComplete(() {
      if (identical(_pending[topicId], next)) _pending.remove(topicId);
    }).catchError((Object _) {});
    return next;
  }

  static Future<void> save(ModDraft draft) => _enqueue(draft.topicId, () async {
    final target = _file(draft.topicId);
    await target.parent.create(recursive: true);
    final tmp = File('${target.path}.tmp');
    await tmp.writeAsString(jsonEncode(draft.toJson()), flush: true);
    await tmp.rename(target.path);
  });

  static Future<ModDraft?> load(String topicId) async {
    if (_pending[topicId] case final Future<void> writing) await writing;
    final file = _file(topicId);
    if (!await file.exists()) return null;
    final raw = jsonDecode(await file.readAsString());
    if (raw is! Map<String, dynamic>) {
      throw const FormatException('草稿不是有效对象，原文件未被删除');
    }
    return ModDraft.fromJson(raw, topicId);
  }

  static Future<void> preserveUnreadable(String topicId) => _enqueue(topicId, () async {
    final original = _file(topicId);
    if (await original.exists()) {
      final backup = File('${original.path}.unreadable-${DateTime.now().microsecondsSinceEpoch}.bak');
      await original.copy(backup.path);
    }
  });

  static Future<void> clear(String topicId) => _enqueue(topicId, () async {
    final file = _file(topicId);
    if (await file.exists()) await file.delete();
  });
}

String _two(int v) => v.toString().padLeft(2, '0');
String _date(DateTime d) => '${d.year}-${_two(d.month)}-${_two(d.day)}';
String _clock(DateTime d) => '${_two(d.hour)}:${_two(d.minute)}';
String _dateTime(DateTime d) => '${_date(d)} ${_clock(d)}';

/// The home header is intentionally tiny: at most three cards are visible.
class ModPinnedStrip extends StatefulWidget {
  const ModPinnedStrip({super.key});
  @override
  State<ModPinnedStrip> createState() => _ModPinnedStripState();
}

class _ModPinnedStripState extends State<ModPinnedStrip> {
  List<Diary> _pins = const [];
  bool _adding = false;
  StreamSubscription<DiaryEvent>? _sub;
  int _generation = 0;
  @override
  void initState() {
    super.initState();
    _sub = ModDiary.repo.diaryEvents.listen((_) => _reload());
    _reload();
  }
  Future<void> _reload() async {
    final n = ++_generation;
    try {
      final data = ModDiary.pinned(await ModDiary.repo.getAllDiaries());
      if (mounted && n == _generation) setState(() => _pins = data);
    } catch (_) { /* Home remains usable if mod data is unavailable. */ }
  }
  @override
  void dispose() { _sub?.cancel(); super.dispose(); }

  @override
  Widget build(BuildContext context) {
    if (_pins.isEmpty) return const SizedBox.shrink();
    final visible = _pins.take(3).toList();
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 8, 12, 4),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(children: [
          const Icon(Icons.push_pin_outlined, size: 16),
          const SizedBox(width: 6),
          const Text('常用日记', style: TextStyle(fontWeight: FontWeight.w600)),
          const Spacer(),
          TextButton(onPressed: () => Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => const ModHubPage())), child: const Text('管理')),
        ]),
        ...visible.map((d) => Padding(
          padding: const EdgeInsets.only(bottom: 5),
          child: Material(
            color: Theme.of(context).colorScheme.surfaceContainerLow,
            borderRadius: BorderRadius.circular(12),
            child: InkWell(
              borderRadius: BorderRadius.circular(12),
              onTap: () => _open(context, d),
              child: Padding(padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 7), child: Row(children: [
                Icon(ModDiary.isTopic(d) ? Icons.menu_book_outlined : Icons.note_outlined, size: 19),
                const SizedBox(width: 10),
                Expanded(child: Text(d.title.isEmpty ? '无标题' : d.title, maxLines: 1, overflow: TextOverflow.ellipsis)),
                Text(ModDiary.isTopic(d) ? '长期记录' : '置顶', style: Theme.of(context).textTheme.labelSmall),
                const SizedBox(width: 6),
                IconButton(
                  icon: Icon(ModDiary.isTopic(d) ? Icons.add_circle_outline : Icons.open_in_new, size: 22),
                  tooltip: ModDiary.isTopic(d) ? '追加记录' : '查看日记',
                  constraints: const BoxConstraints(minHeight: 34, minWidth: 34),
                  padding: EdgeInsets.zero,
                  onPressed: () => ModDiary.isTopic(d)
                    ? _quickAppend(context, d.id, d.title)
                    : _open(context, d),
                ),
              ])),
            ),
          ),
        )),
        if (_pins.length > 3) Center(child: TextButton(
          onPressed: () => Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => const ModHubPage())),
          child: Text('查看全部 ${_pins.length} 篇常用日记'),
        )),
        const Divider(height: 10),
      ]),
    );
  }
  Future<void> _quickAppend(BuildContext context, String topicId, String topicTitle) async {
    if (_adding) return;
    _adding = true;
    try {
      final now = DateTime.now();
      final saved = await showModMonthComposer(context: context,
        repository: ModNativeMonthRepository(
          store: ModMonthStore(getIt<MoodiaryDatabase>()),
          diaries: ModDiary.repo,
          onCommitted: ModLanServer.instance.notifyMonthCommitted),
        topicId: topicId, topicTitle: topicTitle, monthKey: modMonthKey(now), initialDayKey: modDayKey(now));
      if (saved != null && mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(context.l10n.month.savedLocal)));
      }
    } finally { _adding = false; }
  }

  void _open(BuildContext context, Diary d) {
    if (ModDiary.isTopic(d)) {
      Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => ModTopicPage(topicId: d.id)));
    } else {
      DiaryRoute(diaryId: d.id).push(context);
    }
  }
}

class ModHubPage extends StatefulWidget {
  const ModHubPage({super.key});
  @override
  State<ModHubPage> createState() => _ModHubPageState();
}

class _ModHubPageState extends State<ModHubPage> {
  List<Diary> _all = const [];
  StreamSubscription<DiaryEvent>? _sub;
  bool _busy = false;
  @override
  void initState() {
    super.initState();
    _sub = ModDiary.repo.diaryEvents.listen((_) => _reload());
    _reload();
  }
  Future<void> _reload() async {
    try {
      final items = await ModDiary.repo.getAllDiaries();
      if (mounted) setState(() => _all = items.where((e) => e.show).toList());
    } catch (e) { if (mounted) _error('$e'); }
  }
  @override
  void dispose() { _sub?.cancel(); super.dispose(); }
  void _error(String message) => ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(message)));

  Future<void> _auditLocal() async {
    try {
      final report = ModDiary.audit(await ModDiary.repo.getAllDiaries());
      if (!mounted) return;
      await showDialog<void>(context: context, builder: (c) => AlertDialog(
        title: const Text('本机数据健康检查（只读）'),
        content: SingleChildScrollView(child: Text(
          '普通与扩展日记总数：${report.totalDiaries}\n'
          '长期主题：${report.topics}\n'
          '独立子记录：${report.entries}\n'
          '置顶日记：${report.pins}\n\n'
          '失去主题关联的记录：${report.orphanEntries}\n'
          '主题关联格式异常：${report.invalidAssociations}\n'
          '创建时间格式异常：${report.invalidCreationTimes}\n'
          '置顶顺序格式异常：${report.invalidPinRanks}\n'
          '重复置顶序号：${report.duplicatePinRanks}\n\n'
          '${report.issueCount == 0 ? '本机结构检查无异常。' : '检测到异常，请先备份；本功能不会自动修改数据。'}\n\n'
          '注意：这是本机结构检查，不代表 WebDAV 远端完整性验证，也不代替换机恢复测试。'
        )),
        actions: [TextButton(onPressed: () => Navigator.of(c).pop(), child: const Text('关闭'))],
      ));
    } catch (e) {
      if (mounted) _error('本机检查未完成：$e');
    }
  }

  Future<void> _newTopic() async {
    final input = TextEditingController();
    try {
      final name = await showDialog<String>(context: context, builder: (c) => AlertDialog(
        title: const Text('新增长期记录主题'),
        content: TextField(controller: input, autofocus: true, maxLength: 50, decoration: const InputDecoration(hintText: '例如：身体状况、每日饮食')),
        actions: [TextButton(onPressed: () => Navigator.pop(c), child: const Text('取消')),
          FilledButton(onPressed: () => Navigator.pop(c, input.text.trim()), child: const Text('创建'))],
      ));
      if (name == null || name.isEmpty || !mounted) return;
      setState(() => _busy = true);
      final diary = await ModDiary.createTopic(name);
      if (!mounted) return;
      Navigator.push(context, MaterialPageRoute<void>(builder: (_) => ModTopicPage(topicId: diary.id)));
    } catch (e) { if (mounted) _error('创建失败：$e'); }
    finally { input.dispose(); if (mounted) setState(() => _busy = false); }
  }

  Future<void> _toggle(Diary d) async {
    setState(() => _busy = true);
    try { await ModDiary.togglePin(d); }
    catch (e) { if (mounted) _error('置顶修改失败：$e'); }
    finally { if (mounted) setState(() => _busy = false); }
  }
  Future<void> _move(Diary d, int delta) async {
    setState(() => _busy = true);
    try { await ModDiary.movePinned(d, delta); }
    catch (e) { if (mounted) _error('排序失败：$e'); }
    finally { if (mounted) setState(() => _busy = false); }
  }

  @override
  Widget build(BuildContext context) {
    final pins = ModDiary.pinned(_all);
    final ordinary = _all.where((d) => !ModDiary.isChild(d) && !ModDiary.isTopic(d) && !ModDiary.isPinned(d)).toList()
      ..sort((a, b) => b.time.compareTo(a.time));
    final topics = _all.where(ModDiary.isTopic).toList()..sort((a,b) => b.time.compareTo(a.time));
    return Scaffold(
      appBar: AppBar(title: const Text('常用日记与长期记录'), actions: [
        IconButton(tooltip: '检查本机数据完整性', icon: const Icon(Icons.health_and_safety_outlined),
          onPressed: _auditLocal),
      ]),
      floatingActionButton: FloatingActionButton.extended(onPressed: _busy ? null : _newTopic, icon: const Icon(Icons.add), label: const Text('长期主题')),
      body: ListView(children: [
        ListTile(leading: const Icon(Icons.computer),
          title: const Text('局域网 Web 工作台 · W1'),
          subtitle: const Text('手机确认配对 · 锁屏前台服务 · 当前只读'),
          trailing: const Icon(Icons.chevron_right),
          onTap: () => Navigator.push(context, MaterialPageRoute<void>(
            builder: (_) => const ModLanWebPage())),
        ),
        const ListTile(title: Text('长期记录 · 月度视图'),
          subtitle: Text('按月份显示旧独立记录；真实月度日记迁移尚未启用')),
        ...topics.map((t) => ListTile(
          leading: const Icon(Icons.auto_stories_outlined), title: Text(t.title),
          subtitle: const Text('点击查看按日期分组的记录'),
          trailing: const Icon(Icons.chevron_right),
          onTap: () => Navigator.push(context, MaterialPageRoute<void>(builder: (_) => ModTopicPage(topicId: t.id))),
        )),
        const Divider(),
        const ListTile(title: Text('置顶顺序'), subtitle: Text('上下移动调整常用卡片显示顺序')),
        ...pins.asMap().entries.map((item) {
          final i = item.key; final d = item.value;
          return ListTile(
            title: Text(d.title), subtitle: Text(ModDiary.isTopic(d) ? '长期主题' : '普通日记'),
            trailing: Row(mainAxisSize: MainAxisSize.min, children: [
              IconButton(tooltip: '上移', onPressed: _busy || i==0 ? null : () => _move(d, -1), icon: const Icon(Icons.arrow_upward, size: 20)),
              IconButton(tooltip: '下移', onPressed: _busy || i==pins.length-1 ? null : () => _move(d, 1), icon: const Icon(Icons.arrow_downward, size: 20)),
              IconButton(tooltip: '取消置顶', onPressed: _busy ? null : () => _toggle(d), icon: const Icon(Icons.push_pin, size: 20)),
            ]),
          );
        }),
        const Divider(),
        const ListTile(title: Text('置顶普通日记'), subtitle: Text('下方显示最近的非置顶日记')),
        ...ordinary.take(200).map((d) => ListTile(
          title: Text(d.title.isEmpty ? '无标题' : d.title, maxLines: 1),
          subtitle: Text(_date(d.time)),
          trailing: IconButton(tooltip: '设为置顶', onPressed: _busy ? null : () => _toggle(d), icon: const Icon(Icons.push_pin_outlined)),
        )),
        const SizedBox(height: 88),
      ]),
    );
  }
}

class ModTopicPage extends StatelessWidget {
  const ModTopicPage({super.key, required this.topicId, this.append = false});
  final String topicId;
  final bool append;
  @override
  Widget build(BuildContext context) => ModMonthPage(
    topicId: topicId,
    appendOnOpen: append,
    repository: ModNativeMonthRepository(
      store: ModMonthStore(getIt<MoodiaryDatabase>()),
      diaries: ModDiary.repo,
      onCommitted: ModLanServer.instance.notifyMonthCommitted,
    ),
    openLegacy: () => Navigator.of(context).push(MaterialPageRoute<void>(
      builder: (_) => ModLegacyTopicPage(topicId: topicId))),
  );
}

class ModLegacyTopicPage extends StatefulWidget {
  const ModLegacyTopicPage({super.key, required this.topicId});
  final String topicId;
  @override
  State<ModLegacyTopicPage> createState() => _ModTopicPageState();
}

class _ModTopicPageState extends State<ModLegacyTopicPage> {
  Diary? _topic;
  List<Diary> _entries = const [];
  StreamSubscription<DiaryEvent>? _sub;
  @override
  void initState() {
    super.initState();
    _sub = ModDiary.repo.diaryEvents.listen((_) => _reload());
    _reload();
  }
  Future<void> _reload() async {
    try {
      final all = await ModDiary.repo.getAllDiaries();
      final matches = all.where((d) => d.id == widget.topicId && d.show).toList();
      final entries = all.where((d) => d.show && ModDiary.topicIdOf(d) == widget.topicId).toList()
        ..sort((a, b) => b.time.compareTo(a.time));
      if (mounted) setState(() { _topic = matches.isEmpty ? null : matches.first; _entries = entries; });
    } catch (_) { /* Display previous data on transient errors. */ }
  }
  @override
  void dispose() { _sub?.cancel(); super.dispose(); }

  @override
  Widget build(BuildContext context) {
    final topic = _topic;
    return Scaffold(
      appBar: AppBar(title: Text(topic?.title ?? '长期记录'), actions: [
        if (topic != null) IconButton(icon: const Icon(Icons.edit_note), tooltip: '编辑主题说明', onPressed: () => DiaryRoute(diaryId: topic.id).push(context)),
      ]),
      floatingActionButton: topic == null ? null : FloatingActionButton.extended(
        onPressed: () => ModEntrySheet.show(context, topic), icon: const Icon(Icons.add), label: const Text('追加记录'),
      ),
      body: topic == null ? const Center(child: Text('主题不存在或已删除'))
          : _entries.isEmpty ? const Center(child: Text('还没有记录，点击“追加记录”开始。'))
          : Builder(builder: (context) {
              final months = ModMonthlyIndex.fromChildDiaries(_entries);
              return ListView(padding: const EdgeInsets.fromLTRB(12, 8, 12, 100), children: [
                const Padding(padding: EdgeInsets.all(12), child: Text(
                  '3.0 月度浏览（只读索引）：目前旧记录仍独立保存，尚未执行真实月度日记合并。',
                  style: TextStyle(fontSize: 12))),
                for (var m = 0; m < months.length; m++)
                  Card(child: ExpansionTile(
                    key: PageStorageKey('mod-month-${months[m].key}'),
                    initiallyExpanded: m == 0,
                    title: Text(months[m].key),
                    subtitle: Text('${months[m].recordedDays} 天 · ${months[m].recordCount} 条记录'),
                    children: [
                      for (var i = 0; i < months[m].days.length; i++)
                        ExpansionTile(
                          key: PageStorageKey('mod-day-${months[m].key}-${i}'),
                          initiallyExpanded: i == 0,
                          title: Text(_date(months[m].days[i].date)),
                          subtitle: Text('${months[m].days[i].records.length} 条'),
                          children: [
                            for (final entry in months[m].days[i].records)
                              ListTile(
                                title: Text(entry.contentText, maxLines: 3,
                                  overflow: TextOverflow.ellipsis),
                                subtitle: Text('${_clock(entry.time.toLocal())} · ${entry.lastModified.toLocal()}'),
                                onTap: () => DiaryRoute(diaryId: entry.id).push(context),
                              ),
                          ],
                        ),
                    ],
                  )),
              ]);
            }),
    );
  }
}

class ModEntrySheet extends StatefulWidget {
  const ModEntrySheet({super.key, required this.topic});
  final Diary topic;
  static Future<void> show(BuildContext context, Diary topic) async {
    await showModalBottomSheet<void>(
      context: context, isScrollControlled: true, useSafeArea: true,
      builder: (context) => ModEntrySheet(topic: topic),
    );
  }
  @override
  State<ModEntrySheet> createState() => _ModEntrySheetState();
}

class _ModEntrySheetState extends State<ModEntrySheet> with WidgetsBindingObserver {
  final _controller = TextEditingController();
  DateTime _eventTime = DateTime.now();
  late final DateTime _createdAt = DateTime.now();
  late String _stableEntryId = uuidV7();
  DateTime? _restoredCreatedAt;
  bool _saving = false;
  bool _restoring = true;
  bool _touchedByUser = false;
  bool _saveCommitted = false;
  Timer? _debounce;
  String? _draftError;

  DateTime get _effectiveCreatedAt => _restoredCreatedAt ?? _createdAt;
  ModDraft get _draft => ModDraft(
    topicId: widget.topic.id, entryId: _stableEntryId,
    text: _controller.text, eventTime: _eventTime,
    createdAt: _effectiveCreatedAt,
  );

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _controller.addListener(_onChanged);
    _restoreDraft();
  }

  Future<void> _restoreDraft() async {
    try {
      final draft = await ModDraftStore.load(widget.topic.id);
      if (draft != null) {
        final alreadyCommitted = await ModDiary.repo.getDiaryByBusinessId(draft.entryId);
        if (alreadyCommitted != null) {
          if (alreadyCommitted.show &&
              ModDiary.topicIdOf(alreadyCommitted) == widget.topic.id &&
              alreadyCommitted.contentText == draft.text.trim() &&
              alreadyCommitted.time.millisecondsSinceEpoch ==
                  draft.eventTime.millisecondsSinceEpoch) {
            await ModDraftStore.clear(widget.topic.id);
          } else {
            throw const FormatException('草稿记录 ID 已被不同内容占用，草稿原件未删除');
          }
        } else if (mounted && !_touchedByUser) {
          _stableEntryId = draft.entryId;
          _restoredCreatedAt = draft.createdAt;
          _eventTime = draft.eventTime;
          _controller.text = draft.text;
        }
      }
    } catch (e) {
      // Never delete or overwrite an unreadable draft.
      if (mounted) setState(() => _draftError = '草稿读取失败，旧草稿文件已保留：$e');
    } finally {
      if (mounted) setState(() => _restoring = false);
    }
  }

  void _onChanged() {
    if (_restoring || _saveCommitted || _draftError != null) return;
    _touchedByUser = true;
    _scheduleDraft();
  }

  void _scheduleDraft() {
    if (_restoring || _saveCommitted) return;
    _debounce?.cancel();
    _debounce = Timer(const Duration(milliseconds: 250), () {
      unawaited(_writeDraft());
    });
  }

  Future<void> _writeDraft() async {
    if (_restoring || _saveCommitted || _draftError != null) return;
    final snapshot = _draft;
    try {
      await ModDraftStore.save(snapshot);
      if (mounted && _draftError != null) setState(() => _draftError = null);
    } catch (e) {
      if (mounted) setState(() => _draftError = '草稿写入失败：$e');
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.inactive || state == AppLifecycleState.paused) {
      _debounce?.cancel();
      unawaited(_writeDraft());
    }
  }

  @override
  void dispose() {
    _debounce?.cancel();
    // Async flush is best-effort; each edit has already scheduled persistence.
    if (!_saveCommitted && !_restoring && _controller.text.isNotEmpty) {
      unawaited(_writeDraft());
    }
    WidgetsBinding.instance.removeObserver(this);
    _controller.dispose();
    super.dispose();
  }

  Future<void> _pickDate() async {
    final day = await showDatePicker(context: context, initialDate: _eventTime,
      firstDate: DateTime(1970), lastDate: DateTime(2100));
    if (day == null || !mounted) return;
    setState(() => _eventTime = DateTime(day.year, day.month, day.day,
      _eventTime.hour, _eventTime.minute));
    _scheduleDraft();
  }
  Future<void> _pickTime() async {
    final time = await showTimePicker(context: context,
      initialTime: TimeOfDay.fromDateTime(_eventTime));
    if (time == null || !mounted) return;
    setState(() => _eventTime = DateTime(_eventTime.year,
      _eventTime.month, _eventTime.day, time.hour, time.minute));
    _scheduleDraft();
  }
  Future<void> _save() async {
    if (_saving || _restoring || _draftError != null ||
        _controller.text.trim().isEmpty) return;
    setState(() => _saving = true);
    try {
      _debounce?.cancel();
      // Durable local draft first; if the transaction or process fails,
      // reopening the sheet recovers the SAME stable record ID.
      await ModDraftStore.save(_draft);
      await ModDiary.addEntry(widget.topic, _controller.text, _eventTime,
        stableEntryId: _stableEntryId, createdAt: _effectiveCreatedAt);
      _saveCommitted = true;
      try { await ModDraftStore.clear(widget.topic.id); } catch (_) {
        // On next open, _restoreDraft sees the committed ID and clears stale draft.
      }
      if (mounted) Navigator.of(context).pop();
    } catch (e) {
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('保存未完成，草稿保留，可安全重试：$e')));
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  @override
  Widget build(BuildContext context) => Padding(
    padding: EdgeInsets.only(left: 16, right: 16, top: 12,
      bottom: MediaQuery.viewInsetsOf(context).bottom + 16),
    child: SingleChildScrollView(child: Column(
      mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
      Text('追加到 · ${widget.topic.title}', style: Theme.of(context).textTheme.titleMedium),
      const SizedBox(height: 10),
      Wrap(spacing: 8, children: [
        ActionChip(label: Text(_date(_eventTime)),
          avatar: const Icon(Icons.calendar_today, size: 16),
          onPressed: _saving || _restoring ? null : _pickDate),
        ActionChip(label: Text(_clock(_eventTime)),
          avatar: const Icon(Icons.schedule, size: 16),
          onPressed: _saving || _restoring ? null : _pickTime),
      ]),
      const SizedBox(height: 8),
      TextField(controller: _controller, maxLines: 5, minLines: 3,
        enabled: !_saving && !_restoring, autofocus: true, maxLength: 30000,
        decoration: const InputDecoration(border: OutlineInputBorder(),
          hintText: '今天记录什么？直接写下即可……')),
      if (_draftError != null) ...[
        Text(_draftError!, style: TextStyle(color: Theme.of(context).colorScheme.error)),
        TextButton(onPressed: _saving ? null : () async {
          try {
            await ModDraftStore.preserveUnreadable(widget.topic.id);
            if (!mounted) return;
            setState(() => _draftError = null);
            await _writeDraft();
          } catch (e) {
            if (mounted) setState(() => _draftError = '备份原始草稿失败：$e');
          }
        }, child: const Text('先备份异常草稿，再重试')),
      ],
      const SizedBox(height: 8),
      FilledButton.icon(onPressed: _saving || _restoring || _draftError != null ? null : _save,
        icon: const Icon(Icons.check),
        label: Text(_saving ? '正在安全保存到本机…' : '保存独立记录')),
      const SizedBox(height: 4),
      const Text('未提交草稿仅保存在本机私有目录，不上传 WebDAV。正式保存后由原版同步引擎上传。',
        style: TextStyle(fontSize: 12)),
    ])),
  );
}
