import 'package:flutter/services.dart';
import 'package:material_ui/material_ui.dart';

import 'diary_autosave_session.dart';
import '../preview/soft_components.dart';

/// Unrouted experiment: deliberately NOT accessible from the real '+ 日记'
/// action. Intended for test-harness verification only until data durability,
/// UX, draft recovery and schema decisions pass formal acceptance.
class ExperimentalDiaryEditor extends StatefulWidget {
  const ExperimentalDiaryEditor({required this.session, super.key});

  final ExperimentalDiarySession session;

  @override
  State<ExperimentalDiaryEditor> createState() =>
      _ExperimentalDiaryEditorState();
}

class _ExperimentalDiaryEditorState extends State<ExperimentalDiaryEditor> {
  late final TextEditingController _textController;

  @override
  void initState() {
    super.initState();
    _textController = TextEditingController(text: widget.session.text);
  }

  @override
  void dispose() {
    _textController.dispose();
    super.dispose();
  }

  Future<void> _copyUnsavedText() async {
    await Clipboard.setData(ClipboardData(text: widget.session.text));
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(
          widget.session.hasUncommittedText
              ? '已复制未全部保存的文本（复制不等于备份）'
              : '已复制当前日记文本',
        )),
      );
    }
  }

  void _warnOnUnsafeLeave() {
    if (!mounted) return;
    showDialog<void>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('存在未完成的本机保存'),
        content: const Text(
          '当前内容尚未全部成功写入本机。为避免丢失，本实验版本不允许直接退出；请重试或复制文本后继续编辑。',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(),
            child: const Text('继续编辑'),
          ),
          TextButton(
            onPressed: () async {
              await _copyUnsavedText();
              if (dialogContext.mounted) {
                Navigator.of(dialogContext).pop();
              }
            },
            child: const Text('复制当前文本'),
          ),
        ],
      ),
    );
  }

  String _localStatus(ExperimentalSavePhase phase) {
    return switch (phase) {
      ExperimentalSavePhase.untouched => '本机未创建记录',
      ExperimentalSavePhase.writing => '正在保存至本机（尚未完成）',
      ExperimentalSavePhase.savedLocally => '本机已保存',
      ExperimentalSavePhase.failed => '本机保存失败；当前文本尚未全部保存',
    };
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: widget.session,
      builder: (context, _) {
        final session = widget.session;
        final failed = session.phase == ExperimentalSavePhase.failed;

        return PopScope<void>(
          canPop: session.canLeaveSafely,
          onPopInvokedWithResult: (didPop, result) {
            if (!didPop) _warnOnUnsafeLeave();
          },
          child: Scaffold(
            appBar: AppBar(
              title: const Text('写日记 · 测试'),
              actions: [
                IconButton(
                  tooltip: '复制当前文本',
                  onPressed: _copyUnsavedText,
                  icon: const Icon(Icons.copy_outlined),
                ),
              ],
            ),
            body: SafeArea(
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Container(
                      key: const Key('experimental-warning'),
                      padding: const EdgeInsets.symmetric(
                        horizontal: 13, vertical: 11,
                      ),
                      decoration: BoxDecoration(
                        color: previewSoftSage,
                        borderRadius: BorderRadius.circular(12),
                      ),
                      child: const Row(
                        children: [
                          Icon(Icons.info_outline, color: previewSage, size: 18),
                          SizedBox(width: 10),
                          Expanded(
                            child: Text(
                              '当前是独立测试日记，未通过备份与真机验收，'
                              '请勿记录重要个人信息。',
                              style: TextStyle(
                                fontSize: 11,
                                height: 1.5,
                                color: previewInk,
                              ),
                            ),
                          ),
                        ],
                      ),
                    ),
                    const SizedBox(height: 16),
                    Row(
                      children: [
                        Icon(
                          switch (session.phase) {
                            ExperimentalSavePhase.savedLocally =>
                              Icons.check_circle_outline,
                            ExperimentalSavePhase.failed =>
                              Icons.error_outline,
                            ExperimentalSavePhase.writing =>
                              Icons.sync_outlined,
                            ExperimentalSavePhase.untouched =>
                              Icons.radio_button_unchecked,
                          },
                          color: session.phase == ExperimentalSavePhase.failed
                              ? Theme.of(context).colorScheme.error
                              : previewSage,
                          size: 18,
                        ),
                        const SizedBox(width: 7),
                        Expanded(
                          child: Text(
                            _localStatus(session.phase),
                            key: const Key('experimental-local-save-status'),
                            style: const TextStyle(
                              color: previewInk,
                              fontSize: 12,
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 4),
                    const Text(
                      'WebDAV 未同步（同步功能未实现）',
                      style: TextStyle(color: previewMuted, fontSize: 11),
                    ),
                    const SizedBox(height: 8),
                    if (failed) ...[
                      const SizedBox(height: 8),
                      Row(
                        children: [
                          TextButton(
                            key: const Key('experimental-retry'),
                            onPressed: () => session.retry(),
                            child: const Text('重试保存'),
                          ),
                          TextButton(
                            key: const Key('experimental-copy'),
                            onPressed: _copyUnsavedText,
                            child: const Text('复制未保存内容'),
                          ),
                        ],
                      ),
                    ],
                    const Divider(height: 24),
                    const Text(
                      '正文',
                      style: TextStyle(
                        color: previewSage,
                        fontWeight: FontWeight.w700,
                        fontSize: 11,
                        letterSpacing: 1,
                      ),
                    ),
                    const SizedBox(height: 10),
                    Expanded(
                      child: TextField(
                        key: const Key('experimental-diary-input'),
                        autofocus: true,
                        controller: _textController,
                        onChanged: session.changeText,
                        maxLines: null,
                        expands: true,
                        textAlignVertical: TextAlignVertical.top,
                        decoration: const InputDecoration(
                          border: InputBorder.none,
                          hintText: '直接输入正文（测试内容）',
                        ),
                      ),
                    ),
                    const SizedBox(height: 8),
                    Text(
                      '测试编辑 · ${session.text.runes.length} 字符'
                      ' · 复制按钮可随时导出当前文本',
                      style: const TextStyle(
                        color: previewMuted, fontSize: 11,
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        );
      },
    );
  }
}
