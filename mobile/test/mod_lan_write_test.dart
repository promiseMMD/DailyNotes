import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:moodiary_models/moodiary_models.dart';
import 'package:moodiary_utils/moodiary_utils.dart';
import 'package:moodiary_mobile/app/home/mod_lan_write.dart';

Diary diaryWith(String content, {List<String> images = const []}) =>
    Diary.create(title: '测试', content: content, contentText: '',
      imageName: images, audioName: const [], videoName: const [],
      tags: const [], type: DiaryType.tiptap);

void main() {
  test('W4 accepts only simple v2 paragraph text', () {
    final d = diaryWith(TiptapContent.wrapPlainText('第一行\n第二行'));
    expect(ModLanWriteSafety.canEdit(d), isTrue);
    expect(ModLanWriteSafety.revision(d), hasLength(64));
  });
  test('W4 refuses overwriting images, marks, headings, links and future schema', () {
    for (final content in [
      jsonEncode({'type':'doc','attrs':{'v':2},'content':[{'type':'heading','attrs':{'level':2},'content':[{'type':'text','text':'hello'}]}]}),
      jsonEncode({'type':'doc','attrs':{'v':2},'content':[{'type':'paragraph','content':[{'type':'text','text':'hello','marks':[{'type':'bold'}]}]}]}),
      jsonEncode({'type':'doc','attrs':{'v':2},'content':[{'type':'paragraph','content':[{'type':'image','attrs':{'src':'image-a'}}]}]}),
      jsonEncode({'type':'doc','attrs':{'v':3},'content':[{'type':'paragraph'}]}),
      '{broken',
    ]) {
      expect(ModLanWriteSafety.canEdit(diaryWith(content)), isFalse);
    }
    expect(ModLanWriteSafety.canEdit(
      diaryWith(TiptapContent.wrapPlainText('hi'), images: ['photo.jpg'])), isFalse);
  });
  test('W4 validates client id and bounds inputs', () {
    expect(ModLanWriteSafety.id('16c5aefe-8aa9-47f6-b607-333c003112ab'), isNotEmpty);
    expect(() => ModLanWriteSafety.id('../other'), throwsA(isA<ModLanWriteException>()));
    expect(() => ModLanWriteSafety.title(List.filled(201, 'a').join()), throwsA(isA<ModLanWriteException>()));
    expect(() => ModLanWriteSafety.body(List.filled(200001, 'a').join()), throwsA(isA<ModLanWriteException>()));
  });
  test('W4 revision changes with title, document and labels', () {
    final d = diaryWith(TiptapContent.wrapPlainText('hello'));
    final base = ModLanWriteSafety.revision(d);
    expect(ModLanWriteSafety.revision(d.copyWith(title: 'different')), isNot(base));
    expect(ModLanWriteSafety.revision(d.copyWith(content: TiptapContent.wrapPlainText('bye'))), isNot(base));
    expect(ModLanWriteSafety.revision(d.copyWith(tags: ['new'])), isNot(base));
  });
}
