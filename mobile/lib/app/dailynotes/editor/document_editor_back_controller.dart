/// Lets an owning record page consume back before its save-and-leave flow.
///
/// The editor registers only while it is mounted; callers must still handle
/// persistence and navigation when [handleBack] returns false.
class DocumentEditorBackController {
  bool Function()? _handler;

  void attach(bool Function() handler) => _handler = handler;

  void detach(bool Function() handler) {
    if (identical(_handler, handler)) _handler = null;
  }

  bool handleBack() => _handler?.call() ?? false;
}
