import 'package:flutter_test/flutter_test.dart';
import 'package:moodiary_mobile/app/home/mod_monthly_ledger.dart';

const identity = ModMonthIdentity(topicId: 'daily-food', month: '2026-11');
ModMonthRevision rev(String id, String revision, {
  String? parent, String day = '2026-11-07', String clock = '08:10',
  bool deleted = false, bool summary = false, String content = '{"type":"doc","content":[]}',
}) => ModMonthRevision(
  blockId: id, revisionId: revision, parentRevisionId: parent,
  deleted: deleted, summary: summary, eventDay: summary ? '' : day,
  eventClock: summary ? '' : clock, title: id, contentJson: content,
  attachments: const [], editedAtUtc: '2026-11-07T09:00:00Z',
);

void main() {
  test('month ledger serializes deterministically without rewriting original diaries', () {
    final x = ModMonthLedger.empty(identity)
      .add(rev('lunch', 'r2', clock: '12:30'))
      .add(rev('breakfast', 'r1'));
    final y = ModMonthLedger.decode(x.encode());
    expect(y.encode(), x.encode());
    expect(y.timeline.map((r) => r.blockId), ['breakfast', 'lunch']);
    expect(y.preview.length, 2);
  });
  test('two offline devices append distinct blocks; merge is commutative/idempotent', () {
    final base = ModMonthLedger.empty(identity);
    final phone = base.add(rev('lunch', 'a-1', clock: '12:30'));
    final pc = base.add(rev('dinner', 'b-1', clock: '19:10'));
    final both = phone.merge(pc);
    expect(both.timeline.map((r) => r.blockId), ['lunch', 'dinner']);
    expect(phone.merge(pc).encode(), pc.merge(phone).encode());
    expect(both.merge(pc).encode(), both.encode());
  });
  test('concurrent edits of the same block preserve two visible heads', () {
    final base = ModMonthLedger.empty(identity).add(rev('b', 'first'));
    final a = base.add(rev('b', 'edit-a', parent: 'first', content: '{"a":1}'));
    final b = base.add(rev('b', 'edit-b', parent: 'first', content: '{"b":2}'));
    final merged = a.merge(b);
    expect(merged.conflicts.single.blockId, 'b');
    expect(merged.conflicts.single.heads.length, 2);
    expect(merged.timeline, isEmpty); // No silent selection of a winner.
    expect(() => merged.add(rev('b', 'edit-c', parent: 'edit-a')),
      throwsA(isA<ModMonthConflictException>()));
  });
  test('delete/edit collision remains a conflict and never resurrects silently', () {
    final base = ModMonthLedger.empty(identity).add(rev('b', 'first'));
    final deletion = base.add(rev('b', 'deleted', parent: 'first', deleted: true));
    expect(deletion.byId('b')!.deleted, isTrue);
    expect(deletion.timeline, isEmpty);
    final edit = base.add(rev('b', 'edited', parent: 'first'));
    expect(deletion.merge(edit).conflicts.single.heads.length, 2);
  });
  test('same revision ID with different payload is rejected', () {
    final x = ModMonthLedger.empty(identity).add(rev('b', 'r'));
    expect(() => x.merge(ModMonthLedger.empty(identity).add(rev('b','r',clock:'14:00'))),
      throwsA(isA<ModMonthConflictException>()));
    expect(x.add(rev('b','r')).encode(), x.encode());
  });
  test('invalid ancestry and truncated remote payload fail closed', () {
    expect(() => ModMonthLedger.fromRevisions(identity, [rev('b','r',parent:'missing')]),
      throwsA(isA<ModMonthValidationException>()));
    expect(() => ModMonthLedger.decode('{"schema":1,"topicId":"x"}'),
      throwsA(isA<ModMonthValidationException>()));
    expect(() => ModMonthLedger.empty(identity).add(rev('b','r',day:'2026-12-01')),
      throwsA(isA<ModMonthValidationException>()));
  });
  test('summary has independent revisions; not counted as a timeline block', () {
    final x = ModMonthLedger.empty(identity)
      .add(rev(modMonthSummaryId, 'sum-1', summary: true))
      .add(rev('breakfast','r1'));
    expect(x.timeline.length, 1);
    expect(x.byId(modMonthSummaryId)!.resolved!.summary, true);
  });
  test('preview chooses three newest then orders chronologically', () {
    var x = ModMonthLedger.empty(identity);
    for (var i = 1; i <= 5; i++) {
      x = x.add(rev('b$i','r$i', day:'2026-11-0$i',clock:'08:00'));
    }
    expect(x.preview.map((r) => r.blockId), ['b3','b4','b5']);
  });
  test('duplicate root for same block is a hard conflict', () {
    final left = ModMonthLedger.empty(identity).add(rev('block','left'));
    final right = ModMonthLedger.empty(identity).add(rev('block','right'));
    expect(() => left.merge(right), throwsA(isA<ModMonthConflictException>()));
  });
}
