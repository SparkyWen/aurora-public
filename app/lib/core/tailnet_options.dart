/// Native-owned inputs for the optional mobile Tailnet endpoint.
///
/// This checks lexical form only. The native owner must still verify that the
/// directory belongs to this installation and generation, without symlinks or
/// external state. Contract data must never choose a node's storage directory.
final class TailnetOptions {
  TailnetOptions({required this.stateDirectory, required this.hostname}) {
    final segments = stateDirectory.split('/');
    if (!stateDirectory.startsWith('/') ||
        stateDirectory == '/' ||
        stateDirectory.endsWith('/') ||
        stateDirectory.contains('//') ||
        segments.contains('.') ||
        segments.contains('..') ||
        stateDirectory.contains(r'\') ||
        // sing-box expands environment variables even in absolute paths.
        stateDirectory.contains(r'$') ||
        RegExp(r'[\x00-\x1f\x7f]').hasMatch(stateDirectory) ||
        stateDirectory.trim() != stateDirectory) {
      throw ArgumentError(
        'Tailnet state directory must be canonical absolute POSIX',
      );
    }
    final label = RegExp(
      r'[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?',
    ).matchAsPrefix(hostname);
    if (label == null || label.end != hostname.length) {
      throw ArgumentError(
        'Tailnet hostname must be a lowercase DNS label of 1–63 characters',
      );
    }
  }

  final String stateDirectory;
  final String hostname;
}
