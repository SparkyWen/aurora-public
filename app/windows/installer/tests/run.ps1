#Requires -Version 5.1
#Requires -RunAsAdministrator
<##
Real Inno/SCM/process tests. Only unique fixture services and temporary files
are modified; no VPN, network adapter, real Aurora service or app is touched.
Legacy source is namespaced before execution: its hard-coded image name and
30-second budget become fixture names/1.5 seconds, with behavior unchanged.
Expected baseline result: exit 1, three failed safety assertions. Current: 0.
##>
param(
    [ValidateSet('Current', 'Legacy')][string]$Stage = 'Current',
    [string]$LegacyInstallerSource,
    [string]$IsccPath = "${env:ProgramFiles(x86)}\Inno Setup 6\ISCC.exe",
    [string]$EvidenceDirectory = ''
)
$ErrorActionPreference = 'Stop'
$fixtureRoot = Join-Path ([IO.Path]::GetTempPath()) ('AuroraLifecycleTest_' + [Guid]::NewGuid().ToString('N'))
$fixtureApp = Join-Path $fixtureRoot 'app'
$fixtureOutside = Join-Path $fixtureRoot 'unrelated'
$fixturePayload = Join-Path $fixtureRoot 'payload'
$fixtureService = Split-Path $fixtureRoot -Leaf
$fixtureActors = New-Object Collections.Generic.List[object]
$results = New-Object Collections.Generic.List[object]
$installer = Join-Path $fixtureRoot 'lifecycle-fixture.exe'
$svcExecutable = Join-Path $fixtureApp 'aurora-lifecycle-svc.exe'
$legacy = $Stage -eq 'Legacy'
$failure = $null

function Assert-Case([string]$Name, [bool]$Passed, $Detail) {
    [void]$results.Add([pscustomobject]@{ Case = $Name; Passed = $Passed; Detail = $Detail })
}
function Invoke-Fixture([string]$Path, [string]$Label) {
    $log = Join-Path $fixtureRoot ($Label + '.log')
    $p = Start-Process -FilePath $Path -ArgumentList @('/VERYSILENT', '/SUPPRESSMSGBOXES', '/NORESTART', '/SP-', ('/LOG="' + $log + '"')) -PassThru
    try {
        if (-not $p.WaitForExit(20000)) { $p.Kill(); [void]$p.WaitForExit(3000); throw 'fixture exceeded its 20-second bound' }
        return $p.ExitCode
    } finally { $p.Dispose() }
}
function Start-Actor([string]$Directory, [string]$Name) {
    $path = Join-Path $Directory $Name
    Copy-Item -LiteralPath (Join-Path $fixtureRoot 'actor.exe') -Destination $path
    $p = Start-Process -FilePath $path -PassThru
    $held = $p.Handle
    [void]$fixtureActors.Add($p)
    return $p
}
function Start-FixtureService([int]$DelayMs) {
    if (Get-Service -Name $fixtureService -ErrorAction SilentlyContinue) { throw 'fixture service already exists' }
    $binary = '"' + $svcExecutable + '" ' + $fixtureService + ' ' + $DelayMs
    New-Service -Name $fixtureService -BinaryPathName $binary -StartupType Manual | Out-Null
    Start-Service -Name $fixtureService
    $controller = Get-Service -Name $fixtureService
    $controller.WaitForStatus([ServiceProcess.ServiceControllerStatus]::Running, [TimeSpan]::FromSeconds(5))
    $controller.Dispose()
}
function Remove-FixtureService {
    $s = Get-CimInstance Win32_Service -Filter ("Name='" + $fixtureService + "'") -ErrorAction SilentlyContinue
    if (-not $s) { return }
    if ($s.PathName -notlike ('"' + $svcExecutable + '" *')) { throw 'refusing cleanup of a different service executable' }
    if ($s.ProcessId -ne 0) {
        $p = Get-Process -Id $s.ProcessId -ErrorAction SilentlyContinue
        if ($p) {
            try {
                $held = $p.Handle
                if ($p.MainModule.FileName -ine $svcExecutable) { throw 'fixture process path changed' }
                if (-not $p.HasExited) { $p.Kill(); [void]$p.WaitForExit(5000) }
            } finally { $p.Dispose() }
        }
    }
    & "$env:SystemRoot\System32\sc.exe" delete $fixtureService | Out-Null
    if ($LASTEXITCODE -ne 0) { throw 'fixture service delete failed' }
    $deadline = [DateTime]::UtcNow.AddSeconds(5)
    do {
        if (-not (Get-Service -Name $fixtureService -ErrorAction SilentlyContinue)) { return }
        Start-Sleep -Milliseconds 100
    } while ([DateTime]::UtcNow -lt $deadline)
    throw 'fixture service deletion did not finish'
}

try {
    if (-not (Test-Path -LiteralPath $IsccPath -PathType Leaf)) { throw 'Inno Setup compiler required' }
    New-Item -ItemType Directory -Path $fixtureRoot, $fixtureApp, $fixtureOutside, $fixturePayload | Out-Null
    [IO.File]::WriteAllText((Join-Path $fixturePayload 'marker.txt'), 'new payload')
    $csc = Join-Path $env:SystemRoot 'Microsoft.NET\Framework64\v4.0.30319\csc.exe'
    & $csc /nologo /target:exe ('/out:' + (Join-Path $fixtureRoot 'actor.exe')) /reference:System.ServiceProcess.dll (Join-Path $PSScriptRoot 'actor.cs')
    if ($LASTEXITCODE -ne 0) { throw 'fixture actor compilation failed' }
    Copy-Item -LiteralPath (Join-Path $fixtureRoot 'actor.exe') -Destination $svcExecutable

    $include = Join-Path (Split-Path $PSScriptRoot -Parent) 'lifecycle.iss'
    if ($legacy) {
        if (-not $LegacyInstallerSource) { throw 'Legacy requires the unmodified baseline aurora.iss path' }
        $source = [IO.File]::ReadAllText((Resolve-Path -LiteralPath $LegacyInstallerSource))
        $from = $source.IndexOf('function WaitForServiceStopped(')
        $last = $source.IndexOf('function InitializeUninstall(): Boolean;', $from)
        $to = $source.IndexOf('end;', $last) + 4
        if ($from -lt 0 -or $last -lt 0 -or $to -lt 4) { throw 'baseline lifecycle source not recognized' }
        $source = $source.Substring($from, $to - $from)
        if (-not $source.Contains('/IM sing-box.exe /F') -or -not $source.Contains('WaitForServiceStopped(30000)')) { throw 'baseline safety normalization not recognized' }
        $source = $source.Replace('/IM sing-box.exe /F', '/IM {#CoreExe} /F').Replace('WaitForServiceStopped(30000)', 'WaitForServiceStopped({#LifecycleStopTimeoutMs})')
        $include = Join-Path $fixtureRoot 'legacy-lifecycle.iss'
        [IO.File]::WriteAllText($include, $source, (New-Object Text.UTF8Encoding($true)))
    }
    $compileArgs = @('/Qp', ('/DFixtureAppId={' + [Guid]::NewGuid().ToString('B')), ('/DFixtureAppDir=' + $fixtureApp), ('/DFixtureOutputDir=' + $fixtureRoot), ('/DFixturePayloadDir=' + $fixturePayload), ('/DServiceName=' + $fixtureService), ('/DLifecycleInclude=' + '"' + $include + '"'), (Join-Path $PSScriptRoot 'lifecycle_fixture.iss'))
    & $IsccPath @compileArgs
    if ($LASTEXITCODE -ne 0) { throw 'fixture installer compilation failed' }

    # Real processes with the same basename but different paths. Only app's dies.
    $outside = Start-Actor $fixtureOutside 'aurora-lifecycle-core.exe'
    $inside = Start-Actor $fixtureApp 'aurora-lifecycle-core.exe'
    $gui = Start-Actor $fixtureApp 'aurora-lifecycle-ui.exe'
    $exitCode = Invoke-Fixture $installer 'scoped-processes'
    Assert-Case 'unrelated_same_name_survives' (-not $outside.HasExited) @{ InstallerExit = $exitCode; OutsideExited = $outside.HasExited }
    Assert-Case 'owned_processes_close_before_install' ($exitCode -eq 0 -and $inside.HasExited -and $gui.HasExited) @{ InstallerExit = $exitCode; CoreExited = $inside.HasExited; GuiExited = $gui.HasExited }

    # True SCM STOP_PENDING past the budget: no marker may be replaced.
    $marker = Join-Path $fixtureApp 'marker.txt'
    [IO.File]::WriteAllText($marker, 'old payload')
    $before = (Get-FileHash -LiteralPath $marker -Algorithm SHA256).Hash
    Start-FixtureService 15000
    $exitCode = Invoke-Fixture $installer 'stop-timeout-upgrade'
    $after = (Get-FileHash -LiteralPath $marker -Algorithm SHA256).Hash
    Assert-Case 'stop_timeout_blocks_upgrade' ($exitCode -ne 0 -and $before -eq $after) @{ InstallerExit = $exitCode; PayloadUnchanged = $before -eq $after }
    Remove-FixtureService

    # The exact same gate must prevent uninstallation from deleting payload.
    Start-FixtureService 15000
    $uninstaller = Join-Path $fixtureApp 'unins000.exe'
    $exitCode = Invoke-Fixture $uninstaller 'stop-timeout-uninstall'
    Assert-Case 'stop_timeout_blocks_uninstall' ($exitCode -ne 0 -and (Test-Path -LiteralPath $marker)) @{ UninstallerExit = $exitCode; PayloadRetained = Test-Path -LiteralPath $marker }
    Remove-FixtureService

    # Ordinary stop really completes and then the package can be installed.
    Start-FixtureService 300
    $exitCode = Invoke-Fixture $installer 'normal-service-stop'
    $stopped = (Get-Service -Name $fixtureService).Status -eq 'Stopped'
    Assert-Case 'normal_service_stop_allows_install' ($exitCode -eq 0 -and $stopped -and [IO.File]::ReadAllText($marker) -eq 'new payload') @{ InstallerExit = $exitCode; ServiceStopped = $stopped }
    Remove-FixtureService
} catch {
    $failure = $_.Exception.Message
} finally {
    try { Remove-FixtureService } catch { if (-not $failure) { $failure = $_.Exception.Message } }
    foreach ($p in $fixtureActors) {
        try { if (-not $p.HasExited) { $p.Kill(); [void]$p.WaitForExit(3000) } } finally { $p.Dispose() }
    }
    $uninstaller = Join-Path $fixtureApp 'unins000.exe'
    if (Test-Path -LiteralPath $uninstaller) { try { [void](Invoke-Fixture $uninstaller 'cleanup-uninstall') } catch { if (-not $failure) { $failure = $_.Exception.Message } } }
}
$summary = [pscustomobject]@{ Stage = $Stage; FixtureRoot = $fixtureRoot; FixtureService = $fixtureService; Error = $failure; Cases = @($results.ToArray()); Passed = (-not $failure -and @($results | Where-Object { -not $_.Passed }).Count -eq 0) }
if ($EvidenceDirectory) {
    New-Item -ItemType Directory -Path $EvidenceDirectory -Force | Out-Null
    $summary | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath (Join-Path $EvidenceDirectory ('installer-lifecycle-' + $Stage.ToLower() + '.json')) -Encoding UTF8
    Copy-Item -Path (Join-Path $fixtureRoot '*.log') -Destination $EvidenceDirectory -ErrorAction SilentlyContinue
}
$summary | ConvertTo-Json -Depth 6
if ($failure -or -not $summary.Passed) { exit 1 }
exit 0
