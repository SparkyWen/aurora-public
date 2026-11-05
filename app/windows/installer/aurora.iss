; Aurora Windows installer (Inno Setup 6)
;
; Goal: double-click, install, and it works, like sideloading an APK. The
; installer handles three things the user should not have to care about:
;   1. Install into %ProgramFiles%\Aurora (writable only by administrators). The
;      privileged service runs the sing-box.exe in there; installing it into a
;      user-writable directory would hand out SYSTEM privileges.
;   2. Register and start the AuroraSvc service as administrator, so the user
;      never has to open Settings and click "install service", and everyday
;      connect/disconnect never raises a UAC prompt.
;   3. Stop the app and the service on upgrade/uninstall; otherwise files are in
;      use, or the tunnel is still up after uninstalling.
;
; Usage (as invoked from CI):
;   ISCC.exe /DAppVersion=1.0.0 /DSourceDir=<flutter Release directory> ^
;            /DOutputDir=<output directory> /DOutputBase=aurora-v1.0.0-windows-x64-setup ^
;            app\windows\installer\aurora.iss

#ifndef AppVersion
  #define AppVersion "0.0.0"
#endif
#ifndef SourceDir
  #define SourceDir "..\..\build\windows\x64\runner\Release"
#endif
#ifndef OutputDir
  #define OutputDir "."
#endif
#ifndef OutputBase
  #define OutputBase "aurora-windows-x64-setup"
#endif

#define AppName "Aurora"
#define AppExe "aurora.exe"
#define SvcExe "aurora-svc.exe"
#define ServiceName "AuroraSvc"

[Setup]
; Fixed AppId: an upgrade replaces the same installation instead of installing a
; second copy side by side. Never change it.
AppId={{A5F3E1C7-9B24-4D8E-9F6A-3C1B7D5E2A48}
AppName={#AppName}
AppVersion={#AppVersion}
AppVerName={#AppName} {#AppVersion}
AppPublisher=Aurora
VersionInfoVersion={#AppVersion}
DefaultDirName={autopf}\{#AppName}
DefaultGroupName={#AppName}
DisableProgramGroupPage=yes
; Always install to Program Files: letting the user pick a directory could land
; on a user-writable one, and the SYSTEM service runs the sing-box.exe in this
; directory, which would hand out privilege escalation.
DisableDirPage=yes
MinVersion=10.0
UninstallDisplayName={#AppName}
UninstallDisplayIcon={app}\{#AppExe}
OutputDir={#OutputDir}
OutputBaseFilename={#OutputBase}
SetupIconFile={#SourcePath}..\runner\resources\app_icon.ico
Compression=lzma2/max
SolidCompression=yes
WizardStyle=modern
; Installing the service into Program Files requires elevation; this is also what
; makes it work immediately after install.
PrivilegesRequired=admin
ArchitecturesAllowed=x64
ArchitecturesInstallIn64BitMode=x64
; Before installing, use Restart Manager to deal with processes holding files
; (mainly a running aurora.exe).
CloseApplications=yes
RestartApplications=no
ShowLanguageDialog=no

[Languages]
Name: "en"; MessagesFile: "compiler:Default.isl"

[Tasks]
Name: "desktopicon"; Description: "Create a desktop shortcut"; GroupDescription: "Additional tasks:"

[Files]
; Flutter's Windows output is a whole directory (exe + DLLs + data\), plus the
; three packaged components (sing-box.exe / wintun.dll / aurora-svc.exe). The
; whole directory is installed as-is.
Source: "{#SourceDir}\*"; DestDir: "{app}"; Flags: recursesubdirs createallsubdirs ignoreversion

[Icons]
Name: "{group}\{#AppName}"; Filename: "{app}\{#AppExe}"
Name: "{group}\Uninstall {#AppName}"; Filename: "{uninstallexe}"
Name: "{autodesktop}\{#AppName}"; Filename: "{app}\{#AppExe}"; Tasks: desktopicon

[Run]
; Register and start the privileged service. The installer is already elevated,
; so this step raises no further UAC prompt.
Filename: "{app}\{#SvcExe}"; Parameters: "install"; StatusMsg: "Registering the Aurora service..."; Flags: runhidden waituntilterminated
Filename: "{app}\{#AppExe}"; Description: "Launch {#AppName}"; Flags: nowait postinstall skipifsilent

[UninstallRun]
; Stop the service first (its stop path kills sing-box, taking the tunnel down),
; then remove files.
Filename: "{app}\{#SvcExe}"; Parameters: "uninstall"; Flags: runhidden waituntilterminated; RunOnceId: "auroraSvcUninstall"

[UninstallDelete]
; Machine-wide state: the shared token, the config.json the service writes
; itself, cache.db, logs. `aurora-svc uninstall` also deletes this (see
; cleanup.go in aurora-svc); this entry is the fallback for when the service is
; already broken and that path cannot run.
Type: filesandordirs; Name: "{commonappdata}\{#AppName}"
; Per-user data. It used to be kept on purpose so a reinstall could pick up where
; it left off, but an uninstall that leaves things behind is a bug, and this is
; not just preferences: `%APPDATA%\Aurora\config.json` holds the PLAINTEXT
; contract written by early versions (real UUIDs, passwords, keys), and
; path-events.jsonl is a full connection timeline. None of it should remain on
; disk after uninstall.
;
; Note that in an elevated uninstall {userappdata} expands to the directory of
; the user who ELEVATED. On a personal machine (the user is the administrator)
; that is the right one; when a standard user elevates with an administrator
; password it points at the administrator's profile, where this step is simply
; a no-op and never deletes anyone else's data.
Type: filesandordirs; Name: "{userappdata}\{#AppName}"
Type: filesandordirs; Name: "{userappdata}\com.aurora"

[Code]
#include "lifecycle.iss"

// The autostart entry is written by the APP itself (launch_at_startup -> HKCU
// Run, value name taken from ProductName in the exe's version info, see
// windows/runner/Runner.rc = "aurora"), so Inno's [Registry] uninsdeletevalue
// cannot manage it: the installer never wrote that value. Without this, a
// startup entry pointing at the deleted exe would remain in the registry after
// uninstall.
procedure CurUninstallStepChanged(CurUninstallStep: TUninstallStep);
begin
  if CurUninstallStep = usPostUninstall then
  begin
    RegDeleteValue(HKEY_CURRENT_USER,
                   'Software\Microsoft\Windows\CurrentVersion\Run', 'aurora');
    RegDeleteValue(HKEY_CURRENT_USER,
                   'Software\Microsoft\Windows\CurrentVersion\Run', '{#AppName}');
  end;
end;
