import 'package:moodiary_data/moodiary_data.dart';
import 'package:moodiary_i18n/moodiary_i18n.dart';
import 'package:moodiary_models/moodiary_models.dart';
import 'package:mui/mui.dart';

import '../../home/mod_continuous.dart' show ModDiary;
import '../editor/document_envelope.dart';
import 'rich_diary_page.dart';

/// Keeps unsupported historical diary formats on their original reader and
/// never sends a native envelope back through the old Tiptap editor.
class DailyNotesDiaryEntryGateway extends StatefulWidget {
  const DailyNotesDiaryEntryGateway({
    super.key,
    required this.repository,
    required this.diaryId,
    required this.legacy,
    this.registry,
  });
  final DiaryRepository repository;
  final String diaryId;
  final WidgetBuilder legacy;
  final OpenDiaryRegistry? registry;

  @override
  State<DailyNotesDiaryEntryGateway> createState() =>
      _DailyNotesDiaryEntryGatewayState();
}

class _DailyNotesDiaryEntryGatewayState
    extends State<DailyNotesDiaryEntryGateway> {
  late Future<Diary?> _diary;

  @override
  void initState() {
    super.initState();
    _diary = widget.repository.getDiaryByBusinessId(widget.diaryId);
  }

  @override
  void didUpdateWidget(covariant DailyNotesDiaryEntryGateway oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.diaryId != widget.diaryId ||
        oldWidget.repository != widget.repository) {
      _diary = widget.repository.getDiaryByBusinessId(widget.diaryId);
    }
  }

  bool _supported(Diary diary) {
    if (DailyNotesDocumentEnvelope.hasNativeDocument(diary.content))
      return true;
    if (diary.type != DiaryType.tiptap.value ||
        ModDiary.isTopic(diary) ||
        ModDiary.isChild(diary) ||
        diary.imageName.isNotEmpty ||
        diary.audioName.isNotEmpty ||
        diary.videoName.isNotEmpty ||
        diary.fileName.isNotEmpty)
      return false;
    try {
      DailyNotesDocumentEnvelope.decode(diary.content);
      return true;
    } catch (_) {
      return false;
    }
  }

  @override
  Widget build(BuildContext context) => FutureBuilder<Diary?>(
    future: _diary,
    builder: (context, snapshot) {
      if (snapshot.connectionState != ConnectionState.done) {
        return const Scaffold(body: Center(child: CircularProgressIndicator()));
      }
      if (snapshot.hasError) {
        return Scaffold(
          body: Center(
            child: Text(context.l10n.dailynotes.richDocumentUnsupported),
          ),
        );
      }
      final diary = snapshot.data;
      if (diary == null || !_supported(diary)) return widget.legacy(context);
      return RichDiaryPage(
        key: ValueKey(diary.id),
        repository: widget.repository,
        diary: diary,
        registry: widget.registry,
      );
    },
  );
}
