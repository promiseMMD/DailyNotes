import 'package:appflowy_editor/appflowy_editor.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

Future<void> onDelete(
  TextEditingDeltaDeletion deletion,
  EditorState editorState, {
  List<CommandShortcutEvent>? commandShortcutEvents,
}) async {
  AppFlowyEditorLog.input.debug('onDelete: $deletion');

  final selection = editorState.selection;
  if (selection == null) {
    return;
  }

  // IME
  if (selection.isSingle) {
    final node = editorState.getNodeAtPath(selection.start.path);
    if (node?.delta != null &&
        (deletion.composing.isValid || !deletion.deletedRange.isCollapsed)) {
      final node = editorState.getNodesInSelection(selection).first;
      final start = deletion.deletedRange.start;
      final length = deletion.deletedRange.end - start;
      final transaction = editorState.transaction;
      final afterSelection = Selection(
        start: Position(
          path: node.path,
          offset: deletion.selection.baseOffset,
        ),
        end: Position(
          path: node.path,
          offset: deletion.selection.extentOffset,
        ),
      );
      transaction
        ..deleteText(node, start, length)
        ..afterSelection = afterSelection;
      await editorState.apply(transaction);
      return;
    }
  }

  // At a block boundary the software keyboard should use the same ordered
  // backspace handlers as the hardware keyboard. Ordinary text deletion and
  // composing updates above must continue through the IME path.
  for (final shortcut in commandShortcutEvents ?? <CommandShortcutEvent>[]) {
    if (!shortcut.command.split(',').any((key) => key.trim() == 'backspace')) {
      continue;
    }
    if (shortcut.execute(editorState) != KeyEventResult.ignored) return;
  }
  // Preserve the existing fallback even for an incomplete custom list.
  if (convertToParagraphCommand.execute(editorState) ==
      KeyEventResult.ignored) {
    backspaceCommand.execute(editorState);
  }
}
