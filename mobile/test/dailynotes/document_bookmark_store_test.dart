import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:moodiary_mobile/app/dailynotes/editor/document_bookmark_store.dart';
import 'package:moodiary_storage/moodiary_storage.dart';
import 'package:moodiary_storage/testing.dart';

class _UncertainStorage extends IKVStorage {
  final data = <String, Object>{};
  bool failAfterWrite = false;

  @override
  Future<void> init() async {}
  @override
  T? get<T extends Object>(String key) => data[key] as T?;
  @override
  void set<T extends Object>(String key, T value) {
    data[key] = value;
    if (failAfterWrite) throw StateError('acknowledgement lost');
    super.set(key, value);
  }

  @override
  void remove(String key) {
    data.remove(key);
    super.remove(key);
  }

  @override
  void clear() => data.clear();
}

DocumentBookmark _bookmark(String id, {String name = '位置'}) => DocumentBookmark(
  id: id,
  name: name,
  digest: List.filled(64, 'a').join(),
  index: 5,
  alignment: 0.2,
);

void main() {
  test('bookmarks round trip independently for different documents', () {
    final storage = MemoryKVStorage();
    final first = DocumentBookmarkStore(storage, 'note:first');
    final second = DocumentBookmarkStore(storage, 'note:second');
    final original = first.save(first.load(), [_bookmark('one')]);
    expect(second.load().items, isEmpty);
    final renamed = first.save(original, [original.items.single.rename('命名')]);
    final reopened = first.load();
    expect(reopened.items.single.name, '命名');
    expect(reopened.items.single.index, 5);
    expect(reopened.items.single.alignment, 0.2);
    expect(reopened.items.single.digest, _bookmark('one').digest);
    first.save(renamed, []);
    expect(first.load().items, isEmpty);
  });

  test('stale snapshots cannot overwrite another bookmark update', () {
    final storage = MemoryKVStorage();
    final first = DocumentBookmarkStore(storage, 'note:first');
    final second = DocumentBookmarkStore(storage, 'note:first');
    final stale = first.load();
    second.save(second.load(), [_bookmark('existing')]);
    expect(() => first.save(stale, [_bookmark('stale')]), throwsStateError);
    expect(first.load().items.single.id, 'existing');
  });

  test('unknown write outcome cannot be blindly retried from a stale list', () {
    final storage = _UncertainStorage();
    final store = DocumentBookmarkStore(storage, 'note:first');
    final before = store.load();
    storage.failAfterWrite = true;
    expect(() => store.save(before, [_bookmark('one')]), throwsStateError);
    storage.failAfterWrite = false;
    expect(store.load().items.single.id, 'one');
    expect(() => store.save(before, [_bookmark('two')]), throwsStateError);
    expect(store.load().items.single.id, 'one');
  });

  test('corrupt, unsupported or duplicate metadata is preserved', () {
    final storage = MemoryKVStorage();
    final store = DocumentBookmarkStore(storage, 'note:first');
    final key =
        'dailynotes.bookmarks.v1.${base64Url.encode(utf8.encode('note:first'))}';
    final encoded = _bookmark('one').toJson();
    final cases = [
      '{broken',
      jsonEncode({'v': 3, 'items': []}),
      jsonEncode({
        'v': 1,
        'items': [encoded, encoded],
      }),
      jsonEncode({
        'v': 1,
        'items': [
          <String, Object>{...encoded, 'extra': true},
        ],
      }),
    ];
    for (final corrupt in cases) {
      storage.data[key] = corrupt;
      expect(store.load, throwsFormatException);
      expect(storage.data[key], corrupt);
    }
  });

  test('invalid writes are rejected and emoji names round trip', () {
    final storage = MemoryKVStorage();
    final store = DocumentBookmarkStore(storage, 'note:first');
    final emojiName = List.filled(50, '😀').join();
    final snapshot = store.save(store.load(), [
      _bookmark('one', name: emojiName),
    ]);
    expect(store.load().items.single.name, emojiName);
    expect(
      () => store.save(snapshot, [
        _bookmark('duplicate'),
        _bookmark('duplicate'),
      ]),
      throwsFormatException,
    );
    expect(store.load().items.single.name, emojiName);
  });

  test('version 1 remains readable and version 2 persists invalidation', () {
    final storage = MemoryKVStorage();
    const identity = 'note:legacy';
    final key =
        'dailynotes.bookmarks.v1.${base64Url.encode(utf8.encode(identity))}';
    final item = _bookmark('old');
    storage.data[key] = jsonEncode({
      'v': 1,
      'items': [item.toJson()],
    });
    final store = DocumentBookmarkStore(storage, identity);
    final previous = store.load();
    expect(previous.items.single.invalidated, isFalse);
    store.save(previous, [previous.items.single.invalidate()]);
    expect((jsonDecode(storage.data[key] as String) as Map)['v'], 2);
    expect(store.load().items.single.invalidated, isTrue);
    storage.data[key] = jsonEncode({
      'v': 1,
      'items': [item.invalidate().toJson()],
    });
    expect(store.load, throwsFormatException);
  });
}
