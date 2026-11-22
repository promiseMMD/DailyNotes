import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

abstract class TextInputService {
  TextInputService({
    required this.onInsert,
    required this.onDelete,
    required this.onReplace,
    required this.onNonTextUpdate,
    required this.onPerformAction,
    this.onFloatingCursor,
    this.contentInsertionConfiguration,
  });

  Future<bool> Function(TextEditingDeltaInsertion insertion) onInsert;
  Future<bool> Function(TextEditingDeltaDeletion deletion) onDelete;
  Future<bool> Function(TextEditingDeltaReplacement replacement) onReplace;
  Future<bool> Function(TextEditingDeltaNonTextUpdate nonTextUpdate)
      onNonTextUpdate;
  Future<void> Function(TextInputAction action) onPerformAction;
  Future<void> Function(RawFloatingCursorPoint point)? onFloatingCursor;

  final ContentInsertionConfiguration? contentInsertionConfiguration;

  TextRange? get composingTextRange;
  bool get attached;

  /// Whether observed text-update callbacks are settled. This is deliberately
  /// conservative: implementations that cannot observe queued and in-flight
  /// callbacks must not report a safe state. Platform messages not delivered
  /// yet and other input commands are not covered; this is not a complete
  /// safety gate for mutating a document.
  bool get isInputSettled => false;

  /// Changes whenever observed input state changes, including transitions that
  /// later return to the same value. A snapshot can invalidate async work.
  int get inputRevision => 0;

  void clearComposingTextRange();

  void updateCaretPosition(Size size, Matrix4 transform, Rect rect);

  /// Updates the [TextEditingValue] of the text currently being edited.
  ///
  /// Note that if there are IME-related requirements,
  /// please config `composing` value within [TextEditingValue]
  ///
  /// [BuildContext] is used to get current keyboard appearance(light or dark)
  void attach(
    TextEditingValue textEditingValue,
    TextInputConfiguration configuration,
  );

  /// Applies insertion, deletion and replacement
  ///   to the text currently being edited.
  ///   return false means will not apply
  ///
  /// For more information, please check [TextEditingDelta].
  Future<bool> apply(List<TextEditingDelta> deltas);

  /// Closes the editing state of the text currently being edited.
  void close();
}
