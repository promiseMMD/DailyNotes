/// W4 opt-in LAN writer for *simple Tiptap text documents only*.
///
/// Complex documents and long-term month aggregates remain read-only until
/// their native schema, media references and merge semantics are covered.
import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:moodiary_data/moodiary_data.dart';
import 'package:moodiary_models/moodiary_models.dart';
import 'package:moodiary_utils/moodiary_utils.dart';

class ModLanWriteException implements Exception {
  final int status;
  final String code;
  const ModLanWriteException(this.status, this.code);
  @override
  String toString() => code;
}

class ModLanWriteSafety {
  static final RegExp diaryId = RegExp(
    r'^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$',
  );

  static String title(Object? value) {
    if (value is! String || value.length > 200) {
      throw const ModLanWriteException(422, 'invalid_title');
    }
    return value;
  }

  static String body(Object? value) {
    if (value is! String || utf8.encode(value).length > 200000) {
      throw const ModLanWriteException(422, 'invalid_body');
    }
    return value;
  }

  static String id(Object? value) {
    if (value is! String || !diaryId.hasMatch(value)) {
      throw const ModLanWriteException(422, 'invalid_id');
    }
    return value;
  }

  static String revision(Diary diary) =>
      sha256.convert(utf8.encode(jsonEncode(diary.toJson()))).toString();

  /// Only schema v2 paragraphs of unmarked text can round-trip through the
  /// W4 textarea. Unknown nodes, formatting, links, media and legacy docs
  /// must never be silently flattened or overwritten.
  static bool canEdit(Diary diary) {
    if (!diary.show || diary.type != DiaryType.tiptap.value) return false;
    try {
      final parsed = jsonDecode(diary.content);
      if (parsed is! Map || parsed['type'] != 'doc') return false;
      final attrs = parsed['attrs'];
      if (attrs is! Map || attrs['v'] != 2 ||
          attrs.keys.any((key) => key != 'v')) return false;
      if (parsed.keys.any((key) => key != 'type' && key != 'attrs' && key != 'content')) {
        return false;
      }
      final nodes = parsed['content'];
      if (nodes is! List || nodes.isEmpty) return false;
      for (final node in nodes) {
        if (node is! Map || node['type'] != 'paragraph' ||
            node.keys.any((key) => key != 'type' && key != 'content')) {
          return false;
        }
        final inline = node['content'];
        if (inline == null) continue;
        if (inline is! List) return false;
        for (final part in inline) {
          if (part is! Map || part['type'] != 'text' ||
              part['text'] is! String || part.length != 2) return false;
        }
      }
      return diary.imageName.isEmpty && diary.audioName.isEmpty &&
          diary.videoName.isEmpty && diary.fileName.isEmpty;
    } catch (_) {
      return false;
    }
  }

  static String toDocument(String text) => TiptapContent.wrapPlainText(text);
}

class ModLanWriteService {
  final DiaryRepository repository;
  ModLanWriteService(this.repository);

  /// Caller provides a stable client operation ID. Repository does a
  /// transactional insert-if-absent so retries cannot overwrite older diaries.
  Future<Diary> create(Map<String, dynamic> input) async {
    final id = ModLanWriteSafety.id(input['id']);
    final title = ModLanWriteSafety.title(input['title']);
    final text = ModLanWriteSafety.body(input['text']);
    if (title.trim().isEmpty && text.trim().isEmpty) {
      throw const ModLanWriteException(422, 'blank_diary');
    }
    final content = ModLanWriteSafety.toDocument(text);
    final previous = await repository.getDiaryByBusinessId(id);
    if (previous != null) {
      if (previous.show && previous.title == title && previous.content == content &&
          ModLanWriteSafety.canEdit(previous)) return previous;
      throw const ModLanWriteException(409, 'id_collision');
    }
    final diary = Diary.create(
      title: title,
      content: content,
      contentText: text,
      imageName: const [],
      audioName: const [],
      videoName: const [],
      tags: const [],
      type: DiaryType.tiptap,
    ).copyWith(id: id);
    if (!await repository.insertADiaryIfAbsent(diary)) {
      final existing = await repository.getDiaryByBusinessId(id);
      if (existing != null && existing.show && existing.title == title &&
          existing.content == content && ModLanWriteSafety.canEdit(existing)) {
        return existing;
      }
      throw const ModLanWriteException(409, 'id_collision');
    }
    final canonical = await repository.getDiaryByBusinessId(id);
    if (canonical == null) {
      throw const ModLanWriteException(500, 'write_not_readable');
    }
    return canonical;
  }

  Future<Diary> load(String id) async {
    final item = await repository.getDiaryByBusinessId(ModLanWriteSafety.id(id));
    if (item == null || !item.show) {
      throw const ModLanWriteException(404, 'diary_not_found');
    }
    return item;
  }

  Future<Diary> update(String id, Map<String, dynamic> input) async {
    final title = ModLanWriteSafety.title(input['title']);
    final text = ModLanWriteSafety.body(input['text']);
    final revision = input['revision'];
    if (revision is! String || !RegExp(r'^[0-9a-f]{64}$').hasMatch(revision)) {
      throw const ModLanWriteException(422, 'invalid_revision');
    }
    final previous = await load(id);
    if (!ModLanWriteSafety.canEdit(previous)) {
      throw const ModLanWriteException(409, 'complex_diary_read_only');
    }
    if (ModLanWriteSafety.revision(previous) != revision) {
      throw const ModLanWriteException(409, 'stale_revision');
    }
    final updated = previous.copyWith(
      title: title,
      content: ModLanWriteSafety.toDocument(text),
      contentText: text,
      lastModified: DateTime.now().toUtc(),
    );
    final okay = await repository.updateADiaryIfCurrent(
      newDiary: updated,
      expectedSnapshot: previous,
    );
    if (!okay) throw const ModLanWriteException(409, 'stale_revision');
    final canonical = await repository.getDiaryByBusinessId(id);
    if (canonical == null) {
      throw const ModLanWriteException(500, 'write_not_readable');
    }
    return canonical;
  }
}
