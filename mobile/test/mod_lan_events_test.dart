import 'package:flutter_test/flutter_test.dart';
import 'package:moodiary_mobile/app/home/mod_lan_events.dart';

void main() {
  test('sequenced invalidations are ordered, contain no diary content', () {
    final hub = ModLanEventHub(epoch: 'server-1', capacity: 3);
    final a = hub.publish(kind: 'created', id: 'd-1');
    final b = hub.publish(kind: 'updated', id: 'd-1', source: 'cloud');
    expect(a.sequence, 1);
    expect(b.sequence, 2);
    expect(hub.replayAfter(0)!.map((e) => e.sequence), [1, 2]);
    expect(b.toJson()['source'], 'cloud');
    expect(b.toJson().containsKey('content'), isFalse);
  });

  test('lost replay window fails closed and demands a full refresh', () {
    final hub = ModLanEventHub(epoch: 'server-1', capacity: 2);
    for (var i = 0; i < 4; i++) {
      hub.publish(kind: 'created', id: '$i');
    }
    expect(hub.replayAfter(0), isNull);
    expect(hub.replayAfter(1), isNull);
    expect(hub.replayAfter(2)!.map((e) => e.sequence), [3, 4]);
    expect(hub.replayAfter(4), isEmpty);
    expect(hub.replayAfter(5), isNull);
    expect(hub.replayAfter(-1), isNull);
  });

  test('subscribers receive changes and cancellation prevents later delivery', () async {
    final hub = ModLanEventHub(epoch: 'server-2');
    final seen = <int>[];
    final sub = hub.changes.listen((e) => seen.add(e.sequence));
    hub.publish(kind: 'created', id: 'one');
    await sub.cancel();
    hub.publish(kind: 'deleted', id: 'one');
    expect(seen, [1]);
    await hub.close();
    expect(() => hub.publish(kind: 'created', id: 'two'), throwsStateError);
  });

  test('invalid change types and IDs are not broadcast', () {
    final hub = ModLanEventHub(epoch: 'server-3');
    expect(() => hub.publish(kind: 'contents', id: 'one'), throwsArgumentError);
    expect(() => hub.publish(kind: 'created', id: ''), throwsArgumentError);
    expect(hub.sequence, 0);
  });
}
