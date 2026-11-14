import 'package:flutter/services.dart';
import 'package:material_ui/material_ui.dart';

import 'diary_autosave_session.dart';

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
        const SnackBar(content: Text('已复制编辑器当前文本；本机保存仍未确认')),
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
            appBar: AppBar(title: const Text('实验性日记编辑器')),
            body: SafeArea(
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Text(
                      '仅供验证自动保存流程；尚未通过真实数据安全验收，请勿输入重要内容。',
                      key: Key('experimental-warning'),
                    ),
                    const SizedBox(height: 12),
                    Text(
                      _localStatus(session.phase),
                      key: const Key('experimental-local-save-status'),
                    ),
                    const Text('WebDAV 未同步（同步功能未实现）'),
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
