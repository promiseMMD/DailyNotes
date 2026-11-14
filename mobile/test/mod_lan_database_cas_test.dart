import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:moodiary_data/moodiary_data.dart';
import 'package:moodiary_di/moodiary_di.dart';
import 'package:moodiary_models/moodiary_models.dart';
import 'package:moodiary_storage/moodiary_storage.dart';
import 'package:moodiary_storage/testing.dart';
import 'package:moodiary_utils/moodiary_utils.dart';

void main() {
  setUpAll(() => getIt.registerSingleton<IKVStorage>(MemoryKVStorage()));
  late MoodiaryDatabase database;
  late DiaryRepository repo;
  setUp(() {
    database = MoodiaryDatabase.forTesting(NativeDatabase.memory());
    repo = DiaryRepository(database);
  });
  tearDown(() => database.close());

  Diary create(String id) => Diary.create(
    title: '原始', content: TiptapContent.wrapPlainText('hello'),
    contentText: 'hello', imageName: const [], audioName: const [],
    videoName: const [], tags: const [], type: DiaryType.tiptap,
  ).copyWith(id: id);

  test('atomic insert-if-absent never overwrites existing note', () async {
    final first = create('db-stable-1');
    expect(await repo.insertADiaryIfAbsent(first), isTrue);
    expect(await repo.insertADiaryIfAbsent(first.copyWith(title: '覆盖')), isFalse);
    final saved = await repo.getDiaryByBusinessId(first.id);
    expect(saved!.title, '原始');
  });

  test('retry after tombstone never resurrects deleted note', () async {
    final note = create('db-stable-3');
    await repo.insertADiary(note);
    await repo.tombstoneDiaryForSync(note);
    expect(await repo.insertADiaryIfAbsent(note), isFalse);
    expect(await repo.getDiaryByBusinessId(note.id), isNull);
  });

  test('transaction CAS refuses stale snapshot and keeps winner', () async {
    final first = create('db-stable-2');
    await repo.insertADiary(first);
    final base = (await repo.getDiaryByBusinessId(first.id))!;
    final winner = base.copyWith(title: 'PC保存成功',
      lastModified: base.lastModified.add(const Duration(microseconds: 100)));
    expect(await repo.updateADiaryIfCurrent(newDiary: winner,
      expectedSnapshot: base), isTrue);
    final loser = base.copyWith(title: '旧手机草稿',
      lastModified: base.lastModified.add(const Duration(microseconds: 200)));
    expect(await repo.updateADiaryIfCurrent(newDiary: loser,
      expectedSnapshot: base), isFalse);
    expect((await repo.getDiaryByBusinessId(first.id))!.title, 'PC保存成功');
  });
}
