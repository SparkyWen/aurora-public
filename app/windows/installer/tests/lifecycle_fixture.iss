; Executes the production lifecycle include against isolated, harmless actors.
; Every identifying value is supplied by run.ps1; no real Aurora is addressed.
#define AppExe "aurora-lifecycle-ui.exe"
#define CoreExe "aurora-lifecycle-core.exe"
#define SvcExe "aurora-lifecycle-svc.exe"
#define LifecycleStopTimeoutMs 1500

[Setup]
AppId={#FixtureAppId}
AppName=Aurora lifecycle test fixture
AppVersion=1.0.0
DefaultDirName={#FixtureAppDir}
DisableDirPage=yes
UsePreviousAppDir=no
DisableProgramGroupPage=yes
PrivilegesRequired=admin
ArchitecturesAllowed=x64
ArchitecturesInstallIn64BitMode=x64
CloseApplications=no
RestartApplications=no
Uninstallable=yes
CreateAppDir=yes
OutputDir={#FixtureOutputDir}
OutputBaseFilename=lifecycle-fixture
SetupLogging=yes

[Files]
Source: "{#FixturePayloadDir}\marker.txt"; DestDir: "{app}"; Flags: ignoreversion

[Code]
#include LifecycleInclude
