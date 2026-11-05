import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:aurora/core/bounded_http.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/io_client.dart';
import 'package:http/testing.dart';

void main() {
  for (final partialBody in [false, true]) {
    test(
      'timeout closes socket while waiting for ${partialBody ? 'body' : 'headers'}',
      () async {
        final server = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
        final sockets = <Socket>[];
        final peerClosed = Completer<void>();
        final received = Completer<void>();
        server.listen((socket) {
          sockets.add(socket);
          var handled = false;
          final hanging = sockets.length == 1;
          socket.listen(
            (bytes) {
              if (handled) return;
              handled = true;
              if (hanging) {
                received.complete();
                if (partialBody) {
                  socket.write(
                    'HTTP/1.1 200 OK\r\nContent-Length: 999\r\n\r\npartial',
                  );
                }
              } else {
                socket.write('HTTP/1.1 200 OK\r\nContent-Length: 2\r\n\r\nok');
              }
            },
            onDone: () {
              if (hanging && !peerClosed.isCompleted) peerClosed.complete();
            },
            onError: (Object _) {},
          );
        });
        final client = IOClient(HttpClient());
        addTearDown(() async {
          client.close();
          for (final socket in sockets) {
            socket.destroy();
          }
          await server.close();
        });
        final url = Uri.parse(
          'http://127.0.0.1:${server.port}/credential-in-url',
        );
        final timedOut = expectLater(
          boundedRequest(
            client,
            http.Request('GET', url),
            const Duration(milliseconds: 300),
          ),
          throwsA(
            isA<TimeoutException>().having(
              (e) => '$e',
              'message',
              isNot(contains('credential-in-url')),
            ),
          ),
        );
        await received.future.timeout(const Duration(seconds: 2));
        await timedOut;
        // This must happen before client.close(), otherwise a Future timeout
        // can pass while leaving the request socket hanging indefinitely.
        await peerClosed.future.timeout(const Duration(seconds: 2));
        final next = await boundedRequest(
          client,
          http.Request('GET', url),
          const Duration(seconds: 2),
        );
        expect(
          next.body,
          'ok',
          reason: 'Cancelling one request keeps its client usable',
        );
      },
    );
  }

  test('forwards request bytes, headers and redirect policy', () async {
    final bytes = utf8.encode('\u4e2d\u6587\u8bf7\u6c42'); // CJK text: non-ASCII request body
    final request = http.Request('POST', Uri.parse('http://localhost/control'))
      ..followRedirects = false
      ..maxRedirects = 2
      ..persistentConnection = false
      ..headers['Authorization'] = 'Bearer current-token'
      ..bodyBytes = bytes;
    final client = MockClient((forwarded) async {
      expect(forwarded.method, 'POST');
      expect(forwarded.url.path, '/control');
      expect(forwarded.headers['Authorization'], 'Bearer current-token');
      expect(forwarded.bodyBytes, bytes);
      expect(forwarded.followRedirects, isFalse);
      expect(forwarded.maxRedirects, 2);
      expect(forwarded.persistentConnection, isFalse);
      return http.Response.bytes(bytes, 200);
    });
    final response = await boundedRequest(
      client,
      request,
      const Duration(seconds: 1),
    );
    expect(response.bodyBytes, bytes);
  });
}
