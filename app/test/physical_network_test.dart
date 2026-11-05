import 'dart:io';

import 'package:aurora/core/physical_network.dart';
import 'package:fake_async/fake_async.dart';
import 'package:flutter_test/flutter_test.dart';

class _Iface implements NetworkInterface {
  _Iface(this.name, this.addresses);

  @override
  final String name;
  @override
  final List<InternetAddress> addresses;
  @override
  int get index => 0;
}

void main() {
  group('physicalNetworkSignature', () {
    test('encodes physical interface addresses and ignores tunnels', () {
      final signature = physicalNetworkSignature([
        _Iface('en0', [InternetAddress('10.0.0.5')]),
        _Iface('utun7', [InternetAddress('10.111.222.1')]),
        _Iface('utun3', [InternetAddress('100.64.0.4')]),
        _Iface('aurora0', [InternetAddress('172.19.0.1')]),
        _Iface('tailscale0', [InternetAddress('100.64.0.5')]),
        _Iface('lo0', [InternetAddress('127.0.0.1')]),
      ]);
      expect(signature, 'en0:IPv4:10.0.0.5');
      expect(isPhysicalNetworkOnline(signature), isTrue);
    });

    test(
      'a TUN address on a physical-looking name is still not physical',
      () {
        // Windows names the wintun adapter after the user's choice, Android
        // hands the VPN interface a generic name: the address is the only
        // reliable tell.
        final signature = physicalNetworkSignature([
          _Iface('Ethernet 3', [InternetAddress('172.19.0.1')]),
          _Iface('eth9', [InternetAddress('10.111.222.1')]),
          _Iface('eth10', [InternetAddress('fdfe:dcba:9876::1')]),
        ]);
        expect(signature, physicalNetworkOffline);
      },
    );

    test('a LAN in the TUN\'s /24 is still a physical network', () {
      // Only the TUN's own host address is excluded, never its subnet:
      // 172.19.0.0/24 is a common private LAN and a Docker bridge range.
      final signature = physicalNetworkSignature([
        _Iface('en0', [InternetAddress('172.19.0.57')]),
        _Iface('en1', [InternetAddress('10.111.222.9')]),
      ]);
      expect(signature, 'en0:IPv4:172.19.0.57|en1:IPv4:10.111.222.9');
    });

    test('local virtual bridges do not count as physical', () {
      final signature = physicalNetworkSignature([
        _Iface('vEthernet (WSL)', [InternetAddress('172.30.0.1')]),
        _Iface('bridge100', [InternetAddress('192.168.64.1')]),
        _Iface('docker0', [InternetAddress('172.17.0.1')]),
        _Iface('vmnet8', [InternetAddress('192.168.128.1')]),
      ]);
      expect(signature, physicalNetworkOffline);
    });

    test('no physical address at all is the distinct offline state', () {
      // A Wi-Fi association that dropped leaves en0 present with no address.
      // This is the state the old signature reader returned as an empty
      // string and its callers then ignored — a drop-and-return with the same
      // DHCP lease was invisible to every consumer.
      final signature = physicalNetworkSignature([
        _Iface('en0', const []),
        _Iface('utun7', [InternetAddress('10.111.222.1')]),
      ]);
      expect(signature, physicalNetworkOffline);
      expect(isPhysicalNetworkOnline(signature), isFalse);
      expect(physicalNetworkSignature(const []), physicalNetworkOffline);
    });

    test('is order-independent', () {
      final a = physicalNetworkSignature([
        _Iface('en0', [InternetAddress('10.0.0.2')]),
        _Iface('en5', [InternetAddress('192.168.1.9')]),
      ]);
      final b = physicalNetworkSignature([
        _Iface('en5', [InternetAddress('192.168.1.9')]),
        _Iface('en0', [InternetAddress('10.0.0.2')]),
      ]);
      expect(a, b);
    });
  });

  group('PhysicalNetworkMonitor', () {
    test('reports online/offline transitions once each', () {
      fakeAsync((clock) {
        var signature = 'en0:IPv4:10.0.0.2';
        final monitor = PhysicalNetworkMonitor(
          read: () async => signature,
          interval: const Duration(seconds: 5),
        );
        final transitions = <bool>[];
        monitor.onlineChanges.listen(transitions.add);
        monitor.start();
        clock.flushMicrotasks();
        expect(monitor.isOnline, isTrue);
        // The first observation is a baseline, not a transition.
        expect(transitions, isEmpty);

        signature = physicalNetworkOffline;
        clock.elapse(const Duration(seconds: 5));
        expect(monitor.isOnline, isFalse);
        expect(transitions, [false]);

        // Still offline: no repeat.
        clock.elapse(const Duration(seconds: 10));
        expect(transitions, [false]);

        signature = 'en0:IPv4:10.0.0.2';
        clock.elapse(const Duration(seconds: 5));
        expect(monitor.isOnline, isTrue);
        expect(transitions, [false, true]);
        monitor.dispose();
      });
    });

    test('a different network while online is a signature change', () {
      fakeAsync((clock) {
        var signature = 'en0:IPv4:10.0.0.2';
        final monitor = PhysicalNetworkMonitor(
          read: () async => signature,
          interval: const Duration(seconds: 5),
        );
        final changes = <String>[];
        monitor.signatureChanges.listen(changes.add);
        monitor.start();
        clock.flushMicrotasks();
        signature = 'en0:IPv4:192.168.4.7';
        clock.elapse(const Duration(seconds: 5));
        expect(changes, ['en0:IPv4:192.168.4.7']);
        monitor.dispose();
      });
    });

    test('a reader failure leaves the last verdict untouched', () {
      fakeAsync((clock) {
        var fail = false;
        final monitor = PhysicalNetworkMonitor(
          read: () async {
            if (fail) throw const SocketException('enumeration failed');
            return 'en0:IPv4:10.0.0.2';
          },
          interval: const Duration(seconds: 5),
        );
        final transitions = <bool>[];
        monitor.onlineChanges.listen(transitions.add);
        monitor.start();
        clock.flushMicrotasks();
        fail = true;
        clock.elapse(const Duration(seconds: 20));
        expect(monitor.isOnline, isTrue);
        expect(transitions, isEmpty);
        monitor.dispose();
      });
    });
  });
}
