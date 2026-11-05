import 'dart:io';

import 'package:aurora/app/upgrade_resume.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  late Directory dir;
  late File file;
  var build = '1.9.25+50';

  UpgradeResume resume() => UpgradeResume(file, () async => build);

  setUp(() {
    dir = Directory.systemTemp.createTempSync('aurora-resume-');
    file = File('${dir.path}/Aurora/resume-build');
    build = '1.9.25+50';
  });
  tearDown(() => dir.deleteSync(recursive: true));

  test('a tunnel that was up before an upgrade comes back once', () async {
    await resume().tunnelUp();
    build = '1.9.26+51';
    expect(await resume().claim(), (from: '1.9.25+50', to: '1.9.26+51'));
    expect(await resume().claim(), isNull, reason: 'one attempt per upgrade');
  });

  test('a relaunch of the same build never connects by itself', () async {
    await resume().tunnelUp();
    expect(await resume().claim(), isNull);
  });

  test('stopping in the app means an upgrade leaves it stopped', () async {
    await resume().tunnelUp();
    await resume().userStopped();
    build = '1.9.26+51';
    expect(await resume().claim(), isNull);
  });

  test('a fresh install has nothing to resume', () async {
    build = '1.9.26+51';
    expect(await resume().claim(), isNull);
    expect(file.existsSync(), isFalse);
  });

  test('the next upgrade resumes again once the new build was up', () async {
    await resume().tunnelUp();
    build = '1.9.26+51';
    await resume().claim();
    await resume().tunnelUp();
    build = '1.9.27+52';
    expect(await resume().claim(), (from: '1.9.26+51', to: '1.9.27+52'));
  });

  test('an unreadable or unwritable store never throws', () async {
    final blocked = File('${dir.path}/not-a-dir');
    blocked.writeAsStringSync('x');
    final broken = UpgradeResume(
      File('${blocked.path}/resume-build'),
      () async => build,
    );
    await broken.tunnelUp();
    await broken.userStopped();
    expect(await broken.claim(), isNull);
  });
}
