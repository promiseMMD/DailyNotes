// Pure Dart check so the privacy boundary can be exercised before native setup.
import '../../lib/src/data/dailynotes_preview_policy.dart';

void main() {
  void expect(bool value, String reason) {
    if (!value) throw StateError(reason);
  }

  expect(!assistantToolsAllowed(requested: false), 'No tools when not requested');
  expect(!assistantAttachmentsAllowed(requested: false), 'No implicit attachment');
  expect(
    assistantToolsAllowed(requested: true) == !dailyNotesPreview,
    'Preview cannot enable tools even if provider supports them',
  );
  expect(
    assistantAttachmentsAllowed(requested: true) == !dailyNotesPreview,
    'Preview cannot enable attachments even if provider supports them',
  );
  print('Privacy policy passed (DailyNotes preview: $dailyNotesPreview)');
}
