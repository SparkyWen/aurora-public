// Stop gate shared by install and uninstall. On failure the file write/delete
// phase is never entered.
#ifndef CoreExe
  #define CoreExe "sing-box.exe"
#endif
#ifndef LifecycleStopTimeoutMs
  #define LifecycleStopTimeoutMs 30000
#endif

type
  TLifecycleServiceStatus = record
    ServiceType, CurrentState, ControlsAccepted, Win32ExitCode,
      ServiceSpecificExitCode, CheckPoint, WaitHint: Cardinal;
  end;

function LifecycleOpenProcess(Access: Cardinal; Inherit: Boolean;
  ProcessId: Cardinal): THandle;
  external 'OpenProcess@kernel32.dll stdcall';
function LifecycleProcessImage(Process: THandle; Flags: Cardinal;
  Buffer: String; var Characters: Cardinal): Boolean;
  external 'QueryFullProcessImageNameW@kernel32.dll stdcall';
function LifecycleTerminateProcess(Process: THandle; ExitCode: Cardinal): Boolean;
  external 'TerminateProcess@kernel32.dll stdcall';
function LifecycleWait(Process: THandle; Milliseconds: Cardinal): Cardinal;
  external 'WaitForSingleObject@kernel32.dll stdcall';
function LifecycleCloseHandle(Handle: THandle): Boolean;
  external 'CloseHandle@kernel32.dll stdcall';
function LifecycleClock(): Int64;
  external 'GetTickCount64@kernel32.dll stdcall';
function LifecycleOpenSCManager(Machine, Database: String;
  Access: Cardinal): THandle;
  external 'OpenSCManagerW@advapi32.dll stdcall';
function LifecycleOpenService(Manager: THandle; Name: String;
  Access: Cardinal): THandle;
  external 'OpenServiceW@advapi32.dll stdcall';
function LifecycleQueryService(Service: THandle;
  var Status: TLifecycleServiceStatus): Boolean;
  external 'QueryServiceStatus@advapi32.dll stdcall';
function LifecycleControlService(Service: THandle; Control: Cardinal;
  var Status: TLifecycleServiceStatus): Boolean;
  external 'ControlService@advapi32.dll stdcall';
function LifecycleCloseService(Handle: THandle): Boolean;
  external 'CloseServiceHandle@advapi32.dll stdcall';

// Query and terminate both act on a real process handle that is already held.
// Even if an enumerated PID exits, it cannot be reused by another process while
// the query handle is held.
function LifecycleImageMatches(Process: THandle; ExpectedPath: String;
  var Matches: Boolean): Boolean;
var
  ImagePath: String;
  Characters: Cardinal;
begin
  Matches := False;
  Characters := 32768;
  ImagePath := StringOfChar(#0, Characters);
  Result := LifecycleProcessImage(Process, 0, ImagePath, Characters);
  if not Result then
  begin
    // An already-exited stale snapshot entry no longer holds files; any other
    // query failure must not be treated as success.
    Result := LifecycleWait(Process, 0) = 0;
    exit;
  end;
  SetLength(ImagePath, Characters);
  Matches := CompareText(ExpandFileName(ImagePath), ExpectedPath) = 0;
end;

function LifecycleQuiesceExecutable(ExpectedPath: String;
  TerminateOwned: Boolean): Boolean;
var
  Locator, Services, Processes, Item: Variant;
  Index: Integer;
  ProcessId, ErrorCode: Cardinal;
  QueryHandle, StopHandle: THandle;
  Matches: Boolean;
begin
  Result := False;
  ExpectedPath := ExpandFileName(ExpectedPath);
  try
    // WMI only enumerates candidate PIDs. A name is never grounds for killing;
    // the full path must still be verified through the handle.
    Locator := CreateOleObject('WbemScripting.SWbemLocator');
    Services := Locator.ConnectServer('', 'root\CIMV2');
    Processes := Services.ExecQuery('SELECT ProcessId FROM Win32_Process WHERE Name=''' +
      ExtractFileName(ExpectedPath) + '''');
    for Index := 0 to Processes.Count - 1 do
    begin
      Item := Processes.ItemIndex(Index);
      ProcessId := Item.ProcessId;
      // PROCESS_QUERY_LIMITED_INFORMATION | SYNCHRONIZE
      QueryHandle := LifecycleOpenProcess($00101000, False, ProcessId);
      if QueryHandle = 0 then
      begin
        ErrorCode := DLLGetLastError;
        // ERROR_INVALID_PARAMETER: the PID no longer exists after enumeration.
        if ErrorCode <> 87 then exit;
      end
      else
      begin
        try
          if not LifecycleImageMatches(QueryHandle, ExpectedPath, Matches) then exit;
          if Matches then
          begin
            if TerminateOwned and (LifecycleWait(QueryHandle, 0) <> 0) then
            begin
              // Request terminate rights only once the process is confirmed to be in the
              // install directory; the original query handle stays open.
              StopHandle := LifecycleOpenProcess($00101001, False, ProcessId);
              if StopHandle = 0 then
              begin
                if LifecycleWait(QueryHandle, 0) <> 0 then exit;
              end
              else
              begin
                try
                  if not LifecycleImageMatches(StopHandle, ExpectedPath, Matches) then exit;
                  if Matches and not LifecycleTerminateProcess(StopHandle, 0) then
                    if LifecycleWait(StopHandle, 0) <> 0 then exit;
                finally
                  LifecycleCloseHandle(StopHandle);
                end;
              end;
            end;
            if LifecycleWait(QueryHandle, 5000) <> 0 then exit;
          end;
        finally
          LifecycleCloseHandle(QueryHandle);
        end;
      end;
    end;
    Result := True;
  except
    // If WMI, permissions or the process path cannot be confirmed, refuse to
    // continue instead of falling back to a global taskkill.
    Result := False;
  end;
end;

function WaitForServiceStopped(TimeoutMs: Integer): Boolean;
var
  Manager, Service: THandle;
  Status: TLifecycleServiceStatus;
  ErrorCode: Cardinal;
  Started: Int64;
  StopSent: Boolean;
begin
  Result := False;
  Started := LifecycleClock();
  // SC_MANAGER_CONNECT; the service handle needs only QUERY_STATUS | STOP.
  Manager := LifecycleOpenSCManager('', 'ServicesActive', $0001);
  if Manager = 0 then exit;
  try
    Service := LifecycleOpenService(Manager, '{#ServiceName}', $0024);
    if Service = 0 then
    begin
      // Only a definite "does not exist" counts as stopped; access denied and
      // other errors are failures.
      Result := DLLGetLastError = 1060;
      exit;
    end;
    try
      StopSent := False;
      repeat
        if not LifecycleQueryService(Service, Status) then exit;
        if Status.CurrentState = 1 then
        begin
          Result := True;
          exit;
        end;
        // Only Running / Paused get a STOP; StartPending / StopPending keep polling
        // the state.
        if not StopSent and ((Status.CurrentState = 4) or (Status.CurrentState = 7)) then
        begin
          if LifecycleControlService(Service, 1, Status) then
            StopSent := True
          else
          begin
            ErrorCode := DLLGetLastError;
            if (ErrorCode <> 1061) and (ErrorCode <> 1062) then exit;
          end;
        end;
        if LifecycleClock() - Started >= TimeoutMs then exit;
        Sleep(100);
      until False;
    finally
      LifecycleCloseService(Service);
    end;
  finally
    LifecycleCloseService(Manager);
  end;
end;

function StopAurora(): String;
begin
  Result := 'Could not close Aurora in the install directory. Close the app and try again.';
  // Close the GUI first, so its recovery logic does not ask for the core to be
  // started again during the upgrade.
  if not LifecycleQuiesceExecutable(ExpandConstant('{app}\{#AppExe}'), True) then exit;
  Result := 'The Aurora service has not stopped; no installed files were modified. Try again later.';
  if not WaitForServiceStopped({#LifecycleStopTimeoutMs}) then exit;
  Result := 'An Aurora process still holds installed files; install/uninstall was not continued. Try again later.';
  // A normal stop takes the core down with the service; leftover processes from
  // a broken or old install are handled only by full install path, as a fallback.
  if not LifecycleQuiesceExecutable(ExpandConstant('{app}\{#CoreExe}'), True) then exit;
  // There can also be a short gap between the SCM reporting STOPPED and the
  // executable image actually being released.
  if not LifecycleQuiesceExecutable(ExpandConstant('{app}\{#SvcExe}'), False) then exit;
  if not LifecycleQuiesceExecutable(ExpandConstant('{app}\{#AppExe}'), False) then exit;
  Result := '';
end;

function PrepareToInstall(var NeedsRestart: Boolean): String;
begin
  Result := StopAurora();
end;

function InitializeUninstall(): Boolean;
var
  Failure: String;
begin
  Failure := StopAurora();
  Result := Failure = '';
  if not Result then
    SuppressibleMsgBox(Failure, mbError, MB_OK, IDOK);
end;
