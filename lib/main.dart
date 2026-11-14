import 'package:material_ui/material_ui.dart';

import 'src/app.dart';
import 'src/preview/preview_diary_repository.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();

  // Deliberately isolated TEST-data SQLite file, not the final DailyNotes
  // schema and never an import of Moodiary records. A normal widget test
  // without this explicit dependency performs no file I/O.
  runApp(DailyNotesApp(
    previewRepository: SqlitePreviewDiaryRepository(),
  ));
}
