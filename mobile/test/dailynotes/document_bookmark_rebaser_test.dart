import 'package:appflowy_editor/appflowy_editor.dart' as af;
import 'package:flutter_test/flutter_test.dart';
import 'package:moodiary_mobile/app/dailynotes/editor/document_bookmark_rebaser.dart';
import 'package:moodiary_mobile/app/dailynotes/editor/document_bookmark_store.dart';
import 'package:moodiary_storage/moodiary_storage.dart';

class _Storage extends IKVStorage {
  final data = <String, Object>{};
  bool failBookmarkWrite = false;

  @override
  Future<void> init() async {}
  @override
  T? get<T extends Object>(String key) => data[key] as T?;
  @override
  void set<T extends Object>(String key, T value) {
    if (failBookmarkWrite && key.startsWith('dailynotes.bookmarks.')) {
      throw StateError('write failed');
    }
    data[key] = value;
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

af.EditorState _editor() => af.EditorState(
  document: af.Document(
    root: af.pageNode(
      children: [
        af.paragraphNode(text: '前文'),
        af.paragraphNode(text: '目标'),
        af.paragraphNode(text: '后文'),
      ],
    ),
  ),
);

DocumentBookmark _bookmark(af.EditorState editor, String id, int index) =>
    DocumentBookmark(
      id: id,
      name: id,
      digest: documentBookmarkDigest(editor),
      index: index,
      alignment: 0.2,
    );

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test(
    'a confirmed save follows the same live block after an insertion',
    () async {
      final editor = _editor();
      final store = DocumentBookmarkStore(_Storage(), 'note:1');
      final target = editor.document.root.children[1];
      final original = _bookmark(editor, 'target', 2);
      store.save(store.load(), [original]);
      var saved = true;
      final changes = editor.transactionStream.listen((event) {
        if (event.$1 == af.TransactionTime.after) saved = false;
      });
      final rebaser = DocumentBookmarkRebaser(
        editor: editor,
        store: store,
        canStore: () => saved,
      )..start();
      await editor.apply(
        editor.transaction..insertNode([0], af.paragraphNode(text: '新增')),
      );
      expect(target.path, [2]);
      rebaser.documentSaved();
      expect(store.load().items.single.digest, original.digest);
      saved = true;
      rebaser.documentSaved();
      final result = store.load().items.single;
      expect(result.id, original.id);
      expect(result.index, 3);
      expect(result.alignment, original.alignment);
      expect(documentBookmarkMatches(editor, result), isTrue);
      rebaser.dispose();
      await changes.cancel();
      editor.dispose();
    },
  );

  test(
    'deleted anchors stay stale while surviving anchors are updated',
    () async {
      final editor = _editor();
      final store = DocumentBookmarkStore(_Storage(), 'note:1');
      final deleted = _bookmark(editor, 'deleted', 2);
      final retained = _bookmark(editor, 'retained', 3);
      store.save(store.load(), [deleted, retained]);
      var saved = true;
      final changes = editor.transactionStream.listen((event) {
        if (event.$1 == af.TransactionTime.after) saved = false;
      });
      final rebaser = DocumentBookmarkRebaser(
        editor: editor,
        store: store,
        canStore: () => saved,
      )..start();
      final target = editor.document.root.children[1];
      await editor.apply(editor.transaction..deleteNode(target));
      saved = true;
      rebaser.documentSaved();
      final items = store.load().items;
      expect(items[0].digest, deleted.digest);
      expect(items[0].invalidated, isTrue);
      expect(documentBookmarkMatches(editor, items[0]), isFalse);
      expect(items[1].index, 2);
      expect(documentBookmarkMatches(editor, items[1]), isTrue);
      rebaser.dispose();
      await changes.cancel();
      editor.dispose();
    },
  );

  test(
    'existing stale bookmarks are not silently rebound to nearby blocks',
    () async {
      final editor = _editor();
      final store = DocumentBookmarkStore(_Storage(), 'note:1');
      final previous = _bookmark(editor, 'old', 2);
      store.save(store.load(), [previous]);
      await editor.insertText(0, '外部改动', path: [0]);
      var saved = true;
      final changes = editor.transactionStream.listen((event) {
        if (event.$1 == af.TransactionTime.after) saved = false;
      });
      final rebaser = DocumentBookmarkRebaser(
        editor: editor,
        store: store,
        canStore: () => saved,
      )..start();
      await editor.insertText(0, '后续改动', path: [0]);
      saved = true;
      rebaser.documentSaved();
      final result = store.load().items.single;
      expect(result.digest, previous.digest);
      expect(result.index, previous.index);
      expect(documentBookmarkMatches(editor, result), isFalse);
      rebaser.dispose();
      await changes.cancel();
      editor.dispose();
    },
  );

  test('renames made while a document save is pending are preserved', () async {
    final editor = _editor();
    final store = DocumentBookmarkStore(_Storage(), 'note:1');
    store.save(store.load(), [_bookmark(editor, 'target', 2)]);
    var saved = true;
    final changes = editor.transactionStream.listen((event) {
      if (event.$1 == af.TransactionTime.after) saved = false;
    });
    final rebaser = DocumentBookmarkRebaser(
      editor: editor,
      store: store,
      canStore: () => saved,
    )..start();
    await editor.insertText(0, '编辑', path: [0]);
    final pending = store.load();
    store.save(pending, [pending.items.single.rename('新名称')]);
    saved = true;
    rebaser.documentSaved();
    final result = store.load().items.single;
    expect(result.name, '新名称');
    expect(documentBookmarkMatches(editor, result), isTrue);
    rebaser.dispose();
    await changes.cancel();
    editor.dispose();
  });

  test('a bookmark deleted while a save is pending is not restored', () async {
    final editor = _editor();
    final store = DocumentBookmarkStore(_Storage(), 'note:1');
    store.save(store.load(), [_bookmark(editor, 'target', 2)]);
    var saved = true;
    final changes = editor.transactionStream.listen((event) {
      if (event.$1 == af.TransactionTime.after) saved = false;
    });
    final rebaser = DocumentBookmarkRebaser(
      editor: editor,
      store: store,
      canStore: () => saved,
    )..start();
    await editor.insertText(0, '编辑', path: [0]);
    store.save(store.load(), []);
    saved = true;
    rebaser.documentSaved();
    expect(store.load().items, isEmpty);
    rebaser.dispose();
    await changes.cancel();
    editor.dispose();
  });

  test('a replaced block stays invalid even if the serialized document is identical', () async {
    final editor = _editor();
    final store = DocumentBookmarkStore(_Storage(), 'note:1');
    final original = _bookmark(editor, 'target', 2);
    store.save(store.load(), [original]);
    var saved = true;
    final changes = editor.transactionStream.listen((event) {
      if (event.$1 == af.TransactionTime.after) saved = false;
    });
    final rebaser = DocumentBookmarkRebaser(
      editor: editor,
      store: store,
      canStore: () => saved,
    )..start();
    final target = editor.document.root.children[1];
    final beforeJson = editor.document.toJson().toString();
    await editor.apply(editor.transaction..deleteNode(target));
    await editor.apply(
      editor.transaction..insertNode([1], af.paragraphNode(text: '目标')),
    );
    expect(editor.document.toJson().toString(), beforeJson);
    saved = true;
    rebaser.documentSaved();
    final result = store.load().items.single;
    expect(result.invalidated, isTrue);
    expect(documentBookmarkMatches(editor, result), isFalse);
    rebaser.dispose();
    await changes.cancel();
    editor.dispose();
  });

  test('failed metadata writes keep the old bookmark and can retry', () async {
    final editor = _editor();
    final storage = _Storage();
    final store = DocumentBookmarkStore(storage, 'note:1');
    final original = _bookmark(editor, 'target', 2);
    store.save(store.load(), [original]);
    var saved = true;
    final changes = editor.transactionStream.listen((event) {
      if (event.$1 == af.TransactionTime.after) saved = false;
    });
    final rebaser = DocumentBookmarkRebaser(
      editor: editor,
      store: store,
      canStore: () => saved,
    )..start();
    await editor.insertText(0, '编辑', path: [0]);
    saved = true;
    storage.failBookmarkWrite = true;
    rebaser.documentSaved();
    expect(store.load().items.single.digest, original.digest);
    storage.failBookmarkWrite = false;
    rebaser.documentSaved();
    expect(documentBookmarkMatches(editor, store.load().items.single), isTrue);
    rebaser.dispose();
    await changes.cancel();
    editor.dispose();
  });
}
