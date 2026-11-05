import 'package:aurora/core/svc_paths.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('the Linux shared directory is machine-level, with no per-user segment', () {
    final paths = LinuxPaths();
    // The service runs as root and the GUI as the logged-in user. Any location
    // derived from $HOME/$XDG_* resolves differently on each side - the Linux form
    // of the Windows %APPDATA% trap.
    expect(paths.sharedDir, '/var/lib/aurora');
    expect(paths.svcTokenPath, '/var/lib/aurora/svc-token');
    expect(paths.singBoxLogPath, '/var/lib/aurora/logs/sing-box.log');
    for (final path in [
      paths.sharedDir,
      paths.svcTokenPath,
      paths.singBoxLogPath,
    ]) {
      expect(path.contains('/home/'), isFalse);
      expect(path.contains(r'$'), isFalse);
    }
  });
}
