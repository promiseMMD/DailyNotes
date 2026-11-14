/// Temporary DailyNotes preview boundary until knowledge consent and reviewed
/// writes are implemented. False preserves the upstream application's behavior.
const bool dailyNotesPreview = bool.fromEnvironment('DAILYNOTES_PREVIEW');

/// Keeping this decision in one place also protects non-widget chat callers.
bool assistantToolsAllowed({required bool requested}) =>
    requested && !dailyNotesPreview;

bool assistantAttachmentsAllowed({required bool requested}) =>
    requested && !dailyNotesPreview;
