import 'document_bookmark_rebaser.dart';
import 'document_reading_position.dart';

/// Reports an acknowledged save before an owning page immediately closes.
class DocumentMetadataSaveController {
  DocumentBookmarkRebaser? _bookmarks;
  DocumentReadingPosition? _readingPosition;

  void attach({
    required DocumentBookmarkRebaser bookmarks,
    required DocumentReadingPosition readingPosition,
  }) {
    _bookmarks = bookmarks;
    _readingPosition = readingPosition;
  }

  void detach({
    required DocumentBookmarkRebaser bookmarks,
    required DocumentReadingPosition readingPosition,
  }) {
    if (identical(_bookmarks, bookmarks)) _bookmarks = null;
    if (identical(_readingPosition, readingPosition)) _readingPosition = null;
  }

  void documentSaved() {
    _bookmarks?.documentSaved();
    _readingPosition?.retryPendingWrite();
  }
}
