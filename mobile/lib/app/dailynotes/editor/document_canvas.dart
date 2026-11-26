import 'dart:async';

import 'package:appflowy_editor/appflowy_editor.dart' as af;
import 'package:moodiary_data/moodiary_data.dart';
import 'package:moodiary_di/moodiary_di.dart';
import 'package:moodiary_files/moodiary_files.dart';
import 'package:moodiary_logging/moodiary_logging.dart';
import 'package:moodiary_storage/moodiary_storage.dart';
import 'package:moodiary_theme/moodiary_theme.dart';
import 'package:mui/mui.dart';

import '../notes/rich_editor_toolbar.dart';
import 'document_bookmark_rebaser.dart';
import 'document_bookmark_store.dart';
import 'document_editor_back_controller.dart';
import 'document_metadata_save_controller.dart';
import 'document_outline_navigation.dart';
import 'document_reading_position.dart';
import 'document_toggle_block.dart';
import 'document_toggle_model.dart';

/// One mobile document surface for notes, diaries and long-record drafts.
/// The owning page remains responsible for its own persistence lifecycle.
class DailyNotesDocumentCanvas extends StatefulWidget {
  const DailyNotesDocumentCanvas({
    super.key,
    required this.editor,
    required this.focusNode,
    required this.scrollController,
    required this.editable,
    this.autoFocus = false,
    this.showHistoryActionsInToolbar = true,
    this.backController,
    this.header,
    this.readingPositionIdentity,
    this.readingPositionIsSaved = false,
    this.readingPositionCanStore,
    this.metadataSaveController,
    this.outlineNavigation,
  });

  final af.EditorState editor;
  final FocusNode focusNode;
  final af.EditorScrollController scrollController;
  final bool editable;
  final bool autoFocus;
  final bool showHistoryActionsInToolbar;
  final DocumentEditorBackController? backController;
  final Widget? header;

  /// Stable business identity. The serialized reading position is local only.
  final String? readingPositionIdentity;

  /// The current document snapshot has been acknowledged by its owning page.
  final bool readingPositionIsSaved;

  /// Live check also covers the interval before the next widget rebuild.
  final bool Function()? readingPositionCanStore;

  /// Optional explicit save acknowledgement for pages that pop immediately.
  final DocumentMetadataSaveController? metadataSaveController;
  final DocumentOutlineNavigation? outlineNavigation;

  @override
  State<DailyNotesDocumentCanvas> createState() =>
      _DailyNotesDocumentCanvasState();
}

class _DailyNotesDocumentCanvasState extends State<DailyNotesDocumentCanvas> {
  Future<({List<String> families, bool hasUnavailable})>? _loadingFonts;
  DocumentReadingPosition? _readingPosition;
  DocumentBookmarkRebaser? _bookmarkRebaser;
  DocumentToggleController _folds = DocumentToggleController();

  @override
  void initState() {
    super.initState();
    _restoreDocumentFonts();
    _startReadingPosition();
    widget.outlineNavigation?.attachFolds(widget.editor, _folds);
  }

  @override
  void didUpdateWidget(covariant DailyNotesDocumentCanvas oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!identical(oldWidget.editor, widget.editor)) {
      oldWidget.outlineNavigation?.detachFolds(oldWidget.editor, _folds);
      _folds.dispose();
      _folds = DocumentToggleController();
      widget.outlineNavigation?.attachFolds(widget.editor, _folds);
      _restoreDocumentFonts();
    } else if (!identical(
      oldWidget.outlineNavigation,
      widget.outlineNavigation,
    )) {
      oldWidget.outlineNavigation?.detachFolds(oldWidget.editor, _folds);
      widget.outlineNavigation?.attachFolds(widget.editor, _folds);
    }
    if (!identical(oldWidget.editor, widget.editor) ||
        !identical(oldWidget.scrollController, widget.scrollController) ||
        oldWidget.readingPositionIdentity != widget.readingPositionIdentity) {
      _readingPosition?.dispose();
      _detachController(oldWidget.metadataSaveController);
      _bookmarkRebaser?.dispose();
      _startReadingPosition();
    } else {
      if (!identical(
        oldWidget.metadataSaveController,
        widget.metadataSaveController,
      )) {
        _detachController(oldWidget.metadataSaveController);
        _attachController(widget.metadataSaveController);
      }
      if (widget.readingPositionIsSaved) {
        _readingPosition?.retryPendingWrite();
      }
      if (widget.readingPositionIsSaved) _bookmarkRebaser?.documentSaved();
    }
  }

  void _startReadingPosition() {
    final identity = widget.readingPositionIdentity;
    final storage = getIt.maybeGet<IKVStorage>();
    if (identity == null || storage == null || widget.header == null) {
      _readingPosition = null;
      _bookmarkRebaser = null;
      return;
    }
    final editor = widget.editor;
    bool canStore() =>
        mounted &&
        identical(widget.editor, editor) &&
        widget.readingPositionIdentity == identity &&
        (widget.readingPositionCanStore?.call() ??
            widget.readingPositionIsSaved);
    _readingPosition = DocumentReadingPosition(
      editor: editor,
      scroll: widget.scrollController,
      storage: storage,
      identity: identity,
      restoreOnOpen: !widget.autoFocus && !widget.editable,
      canRestore: () =>
          mounted &&
          identical(widget.editor, editor) &&
          widget.readingPositionIdentity == identity &&
          !widget.editable &&
          !editor.editable &&
          !widget.focusNode.hasFocus &&
          ModalRoute.of(context)?.isCurrent == true,
      canStore: canStore,
    )..start();
    _bookmarkRebaser = DocumentBookmarkRebaser(
      editor: editor,
      store: DocumentBookmarkStore(storage, identity),
      canStore: canStore,
    )..start();
    _attachController(widget.metadataSaveController);
  }

  void _attachController(DocumentMetadataSaveController? controller) {
    final bookmarks = _bookmarkRebaser;
    final readingPosition = _readingPosition;
    if (bookmarks != null && readingPosition != null) {
      controller?.attach(
        bookmarks: bookmarks,
        readingPosition: readingPosition,
      );
    }
  }

  void _detachController(DocumentMetadataSaveController? controller) {
    final bookmarks = _bookmarkRebaser;
    final readingPosition = _readingPosition;
    if (bookmarks != null && readingPosition != null) {
      controller?.detach(
        bookmarks: bookmarks,
        readingPosition: readingPosition,
      );
    }
  }

  @override
  void dispose() {
    widget.outlineNavigation?.detachFolds(widget.editor, _folds);
    _folds.dispose();
    _readingPosition?.dispose();
    _detachController(widget.metadataSaveController);
    _bookmarkRebaser?.dispose();
    super.dispose();
  }

  Future<({List<String> families, bool hasUnavailable})> _loadFonts() =>
      _loadingFonts ??= _readFonts().whenComplete(() => _loadingFonts = null);

  Future<({List<String> families, bool hasUnavailable})> _readFonts() async {
    final repository = getIt.maybeGet<FontRepository>();
    if (repository == null) {
      return (families: <String>[], hasUnavailable: false);
    }
    final fonts = await repository.getAllFonts();
    final available = <String>[];
    var hasUnavailable = false;
    for (final font in fonts) {
      final loaded = await FontManager.loadFont(
        fontName: font.fontFamily,
        fontPath: AppFiles.getRealPath('font', font.fontFileName),
      );
      if (loaded) {
        available.add(font.fontFamily);
      } else {
        hasUnavailable = true;
      }
    }
    return (families: available, hasUnavailable: hasUnavailable);
  }

  void _restoreDocumentFonts() {
    final editor = widget.editor;
    unawaited(
      _loadFonts()
          .then((catalog) {
            if (mounted &&
                identical(widget.editor, editor) &&
                !editor.isDisposed &&
                catalog.families.isNotEmpty) {
              editor.reload();
            }
          })
          .catchError((Object error, StackTrace stack) {
            logger.e(
              'Unable to load document fonts',
              error: error,
              stackTrace: stack,
            );
          }),
    );
  }

  @override
  Widget build(BuildContext context) {
    final colors = context.theme.colors;
    const horizontalPadding = 20.0;
    return RichEditorToolbar(
      editor: widget.editor,
      focusNode: widget.focusNode,
      editable: widget.editable,
      showHistoryActionsInToolbar: widget.showHistoryActionsInToolbar,
      backController: widget.backController,
      loadFonts: _loadFonts,
      scrollController: widget.scrollController,
      child: NotificationListener<ScrollStartNotification>(
        onNotification: (notification) {
          if (notification.depth == 0) {
            _readingPosition?.scrollStarted(
              userDrag: notification.dragDetails != null,
            );
          }
          return false;
        },
        child: af.AppFlowyEditor(
          editorState: widget.editor,
          blockComponentBuilders: {
            ...af.standardBlockComponentBuilderMap,
            DocumentToggleKeys.type: DocumentToggleBuilder(_folds),
          },
          characterShortcutEvents: [
            documentToggleEnter(_folds),
            ...af.standardCharacterShortcutEvents,
          ],
          commandShortcutEvents: [
            documentToggleHeadingBackspace,
            ...af.standardCommandShortcutEvents,
          ],
          focusNode: widget.focusNode,
          editorScrollController: widget.scrollController,
          editable: widget.editable,
          autoFocus: widget.autoFocus,
          // The SDK defaults to desktop styling, including 100 px margins and
          // no mobile selection handles. Use its mobile configuration explicitly.
          editorStyle: af.EditorStyle.mobile(
            padding: const EdgeInsets.symmetric(horizontal: horizontalPadding),
            cursorColor: colors.primary,
            dragHandleColor: colors.primary,
            selectionColor: colors.primary.withValues(alpha: 0.25),
            textStyleConfiguration: af.TextStyleConfiguration(
              text: context.theme.typography.bodyLarge.onSurface,
            ),
          ),
          header: widget.header == null
              ? null
              : Padding(
                  padding: const EdgeInsets.symmetric(
                    horizontal: horizontalPadding,
                  ),
                  child: widget.header!,
                ),
        ),
      ),
    );
  }
}
