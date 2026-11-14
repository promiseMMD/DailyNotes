import 'package:flutter_test/flutter_test.dart';
import 'package:moodiary_mobile/app/home/mod_lan_service.dart';

void main() {
  test('only private IPv4 and explicit WLAN interfaces are eligible', () {
    expect(ModLanPolicy.isWlanInterfaceName('wlan0'), isTrue);
    expect(ModLanPolicy.isWlanInterfaceName('rmnet_data0'), isFalse);
    expect(ModLanPolicy.isWlanInterfaceName('tun0'), isFalse);
    expect(ModLanPolicy.isPrivateIPv4('192.168.31.4'), isTrue);
    expect(ModLanPolicy.isPrivateIPv4('10.2.3.4'), isTrue);
    expect(ModLanPolicy.isPrivateIPv4('172.20.1.2'), isTrue);
    expect(ModLanPolicy.isPrivateIPv4('172.32.0.1'), isFalse);
    expect(ModLanPolicy.isPrivateIPv4('8.8.8.8'), isFalse);
    expect(ModLanPolicy.isPrivateIPv4('192.168.999.1'), isFalse);
  });
  test('host/origin checks fail closed for mutations', () {
    expect(ModLanPolicy.validSameOrigin(host: '192.168.1.9:11220',
      origin: 'http://192.168.1.9:11220', authority: '192.168.1.9:11220',
      mutation: true), isTrue);
    expect(ModLanPolicy.validSameOrigin(host: 'attacker.example',
      origin: 'http://attacker.example', authority: '192.168.1.9:11220',
      mutation: true), isFalse);
    expect(ModLanPolicy.validSameOrigin(host: '192.168.1.9:11220',
      origin: null, authority: '192.168.1.9:11220', mutation: true), isFalse);
    expect(ModLanPolicy.validSameOrigin(host: '192.168.1.9:11220',
      origin: 'http://evil.invalid', authority: '192.168.1.9:11220',
      mutation: true), isFalse);
  });
  test('secure random session ids have correct size and are distinct', () {
    final a = modLanRandomHex();
    final b = modLanRandomHex();
    expect(a, matches(RegExp(r'^[0-9a-f]{48}$')));
    expect(a, isNot(equals(b)));
  });
}
