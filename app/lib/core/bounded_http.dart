import 'dart:async';

import 'package:http/http.dart' as http;

/// Bounds headers and body together and aborts only this request on expiry.
/// A Future timeout alone leaves its socket/body subscription alive. Keep the
/// fallback deadline too: injected clients may not implement Abortable.
Future<http.Response> boundedRequest(
  http.Client client,
  http.Request request,
  Duration timeout,
) async {
  final abort = Completer<void>();
  final pending =
      http.AbortableRequest(
          request.method,
          request.url,
          abortTrigger: abort.future,
        )
        ..followRedirects = request.followRedirects
        ..maxRedirects = request.maxRedirects
        ..persistentConnection = request.persistentConnection
        ..headers.addAll(request.headers)
        ..bodyBytes = request.bodyBytes;
  try {
    return await (() async {
      final response = await client.send(pending);
      return http.Response.fromStream(response);
    })().timeout(
      timeout,
      onTimeout: () {
        abort.complete();
        // Do not include the URI: delivery URLs can contain credentials.
        throw TimeoutException('HTTP request timed out', timeout);
      },
    );
  } finally {
    if (!abort.isCompleted) abort.complete();
  }
}
