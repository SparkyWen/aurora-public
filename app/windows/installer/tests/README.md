# Windows installer lifecycle regression

These tests actually compile and run the Inno installer and uninstaller, using
the production `lifecycle.iss`. They create a real SCM service and .NET fake
processes with no network capability; they do not merely check source strings.
They need an administrator PowerShell 5.1, Inno Setup 6 and the C# compiler that
ships with Windows .NET Framework.

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File app\windows\installer\tests\run.ps1 -Stage Current -EvidenceDirectory "$env:TEMP\AuroraInstallerEvidence"
```

Scope:

- Start two same-named cores in different temp directories: only the one inside
  the install directory is closed; the outside process survives.
- Installation succeeds only after the GUI/core in the install directory have
  really exited.
- When an independent service stays in `STOP_PENDING` past the budget, the
  upgrade fails and the old payload SHA256 is unchanged.
- The same stop failure also blocks uninstall, and the payload is kept.
- After the service stops normally, installation succeeds and the SCM confirms
  `STOPPED`.

Each run uses a random temp directory, a random AppId and a unique
`AuroraLifecycleTest_*` service. Process names are
`aurora-lifecycle-{ui,core,svc}.exe`, so the test never locates or stops a real
Aurora, `sing-box.exe`, other services or network adapters. The test service only
sleeps; there is no real configuration, credential or network activity. Services
and processes are cleaned up in `finally` by held objects / fixed paths; the Inno
log and results stay in the test temp directory, and passing `-EvidenceDirectory`
copies the results and logs elsewhere.

The production stop budget is 30 seconds; the fixture shortens the same
parameter to 1.5 seconds so the stuck-service regression is quick and bounded.
`CloseApplications=no` stops Restart Manager from closing processes on the
test's behalf, so the assertions really cover the production stop gate.

The fixture verifies the installer's own lifecycle rules. It does not prove that
a real VPN protocol works, and it does not replace connection acceptance testing
after installing a release package.
