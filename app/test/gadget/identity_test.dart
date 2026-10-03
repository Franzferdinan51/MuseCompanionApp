import 'package:flutter_test/flutter_test.dart';
import 'package:muse_companion/src/gadget/identity.dart';

void main() {
  group('identity', () {
    test('derives the gadget names from the mac', () {
      const identity = Identity('02:aa:bb:cc:dd:ee');
      expect(identity.suffix, 'ccddee');
      expect(identity.nodeId, 'homelink-ccddee');
      expect(identity.deviceId, 'hatch-link:02:aa:bb:cc:dd:ee');
      expect(identity.bleName, 'MuseGadgetCCDDEE');
    });

    test('generates locally administered unicast macs', () {
      for (var i = 0; i < 10; i++) {
        final mac = generateMac();
        expect(isValidIdentityMac(mac), isTrue);
        final first = int.parse(mac.substring(0, 2), radix: 16);
        expect(first & 0x01, 0); // unicast
        expect(first & 0x02, 0x02); // locally administered
      }
    });

    test('validates stored macs strictly', () {
      expect(isValidIdentityMac('02:aa:bb:cc:dd:ee'), isTrue);
      expect(isValidIdentityMac('02:AA:BB:CC:DD:EE'), isFalse);
      expect(isValidIdentityMac('02:aa:bb:cc:dd'), isFalse);
      expect(isValidIdentityMac(''), isFalse);
      expect(isValidIdentityMac('not-a-mac'), isFalse);
    });
  });
}
