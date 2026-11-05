# The Windows half of the journey: the real installer, the real service, a real Wintun adapter,
# and the real window, driven through UI Automation the way a user clicks it. Windows ships no
# command line, so the window is the only way in.
#
# A runner accepts no inbound traffic and install.sh does not run on Windows, so the node here is
# the installer's own server configuration, generated on Linux and run by a second sing-box on
# loopback. Its outbound is bound to the physical adapter, because otherwise its traffic would
# re-enter the tunnel it is serving. Its log is the proof: it can only have seen a connection to
# a probe address if that connection came through the tunnel.
#
#   full-flow-windows.ps1 -Installer <setup.exe> -NodeDir <dir> -OutDir <dir>
param(
  [Parameter(Mandatory)] [string] $Installer,
  [Parameter(Mandatory)] [string] $NodeDir,
  [Parameter(Mandatory)] [string] $OutDir
)
$ErrorActionPreference = "Continue"
New-Item -ItemType Directory -Force -Path $OutDir | Out-Null

$script:Pass = 0
$script:Fail = 0
function Section($name) { Write-Host "`n=== $name" }
function Check($name, [scriptblock] $test) {
  $result = $false
  try { $result = & $test } catch { $result = $false }
  if ($result) { $script:Pass++; Write-Host "ok   $name" } else { $script:Fail++; Write-Host "FAIL $name" }
}

$installDir = Join-Path $env:ProgramFiles "Aurora"
$app = Join-Path $installDir "aurora.exe"

Add-Type -AssemblyName UIAutomationClient, UIAutomationTypes, System.Windows.Forms, System.Drawing
Add-Type @"
using System;
using System.Runtime.InteropServices;
public static class Mouse {
  [DllImport("user32.dll")] public static extern bool SetCursorPos(int x, int y);
  [DllImport("user32.dll")] public static extern void mouse_event(uint flags, uint dx, uint dy, uint data, UIntPtr extra);
  [DllImport("user32.dll")] public static extern bool SetForegroundWindow(IntPtr window);
  [DllImport("user32.dll")] public static extern bool SetProcessDPIAware();
  public static void Click(int x, int y) {
    SetCursorPos(x, y);
    System.Threading.Thread.Sleep(150);
    mouse_event(2, 0, 0, 0, UIntPtr.Zero);
    mouse_event(4, 0, 0, 0, UIntPtr.Zero);
  }
}
"@
[Mouse]::SetProcessDPIAware() | Out-Null

function Shot($name) {
  $bounds = [System.Windows.Forms.Screen]::PrimaryScreen.Bounds
  $bitmap = New-Object System.Drawing.Bitmap $bounds.Width, $bounds.Height
  $graphics = [System.Drawing.Graphics]::FromImage($bitmap)
  $graphics.CopyFromScreen($bounds.Location, [System.Drawing.Point]::Empty, $bounds.Size)
  $bitmap.Save((Join-Path $OutDir "$name.png"), [System.Drawing.Imaging.ImageFormat]::Png)
  $graphics.Dispose()
  $bitmap.Dispose()
}

function App-Window {
  $root = [System.Windows.Automation.AutomationElement]::RootElement
  $byName = New-Object System.Windows.Automation.PropertyCondition ([System.Windows.Automation.AutomationElement]::NameProperty), "Aurora"
  $root.FindFirst([System.Windows.Automation.TreeScope]::Children, $byName)
}

# Matches by exact name, or by prefix when $Prefix is set. Reading the tree is also what
# makes Flutter turn its accessibility bridge on.
function Find-Element($name, [int] $seconds = 30, [switch] $Prefix) {
  $deadline = (Get-Date).AddSeconds($seconds)
  do {
    $window = App-Window
    if ($window) {
      $all = $window.FindAll([System.Windows.Automation.TreeScope]::Descendants, [System.Windows.Automation.Condition]::TrueCondition)
      foreach ($element in $all) {
        $current = $element.Current.Name
        if (($Prefix -and $current -like "$name*") -or ($current -eq $name)) { return $element }
      }
    }
    Start-Sleep -Milliseconds 500
  } while ((Get-Date) -lt $deadline)
  return $null
}

function Dump-Names($file) {
  $window = App-Window
  if (-not $window) { "no Aurora window" | Set-Content (Join-Path $OutDir $file); return }
  $all = $window.FindAll([System.Windows.Automation.TreeScope]::Descendants, [System.Windows.Automation.Condition]::TrueCondition)
  $all | ForEach-Object { "$($_.Current.ControlType.ProgrammaticName) | $($_.Current.Name)" } | Set-Content (Join-Path $OutDir $file)
}

function Click-Element($name, [int] $seconds = 30) {
  $element = Find-Element $name $seconds
  if (-not $element) { Write-Host "(nothing named '$name')"; return $false }
  $window = App-Window
  if ($window) { [Mouse]::SetForegroundWindow([IntPtr]$window.Current.NativeWindowHandle) | Out-Null }
  Start-Sleep -Milliseconds 300
  $box = $element.Current.BoundingRectangle
  [Mouse]::Click([int]($box.X + $box.Width / 2), [int]($box.Y + $box.Height / 2))
  return $true
}

function Adapter-Present { $null -ne (Get-NetAdapter -Name aurora0 -ErrorAction SilentlyContinue) }

function Adapter-Gone-Within([int] $seconds) {
  $deadline = (Get-Date).AddSeconds($seconds)
  do {
    if (-not (Adapter-Present)) { return $true }
    Start-Sleep -Seconds 1
  } while ((Get-Date) -lt $deadline)
  return $false
}

Section "The installer on a clean machine"
$setup = Start-Process -FilePath $Installer -ArgumentList "/VERYSILENT", "/SUPPRESSMSGBOXES", "/NORESTART", "/LOG=$OutDir\setup.log" -Wait -PassThru
Check "the installer exits 0" { $setup.ExitCode -eq 0 }
Check "the app is installed" { Test-Path $app }
Check "the bundle is complete" { (Test-Path "$installDir\sing-box.exe") -and (Test-Path "$installDir\wintun.dll") -and (Test-Path "$installDir\aurora-svc.exe") }
Check "the service runs" { (Get-Service AuroraSvc).Status -eq "Running" }

Section "The node"
$gateway = Get-NetRoute -DestinationPrefix "0.0.0.0/0" | Sort-Object RouteMetric | Select-Object -First 1
$uplink = (Get-NetAdapter -InterfaceIndex $gateway.ifIndex).Name
Write-Host "physical adapter: $uplink"
$serverLog = Join-Path $OutDir "node.log"
$config = Get-Content (Join-Path $NodeDir "sing-box.json") -Raw | ConvertFrom-Json
$config.log = [pscustomobject]@{ level = "info"; output = $serverLog; timestamp = $true }
# For every dial it makes, including the REALITY handshake, which is not an outbound.
$config.route | Add-Member -NotePropertyName default_interface -NotePropertyValue $uplink -Force
# Paths in the generated config are from the Linux machine that made it.
foreach ($inbound in $config.inbounds) {
  if ($inbound.tls -and $inbound.tls.certificate_path) {
    $inbound.tls.certificate_path = Join-Path $NodeDir "hy2.crt"
    $inbound.tls.key_path = Join-Path $NodeDir "hy2.key"
  }
}
# A plain resolver on Windows: the node's `local` DNS goes through the tunnel otherwise.
$config.dns = [pscustomobject]@{
  servers = @([pscustomobject]@{ type = "udp"; tag = "dns-local"; server = "1.1.1.1" })
  strategy = "ipv4_only"
}
$nodeConfig = Join-Path $OutDir "node.json"
[System.IO.File]::WriteAllText($nodeConfig, ($config | ConvertTo-Json -Depth 30))
$node = Start-Process -FilePath "$installDir\sing-box.exe" -ArgumentList "run", "-c", $nodeConfig -PassThru -WindowStyle Hidden `
  -RedirectStandardError "$OutDir\node-stderr.log" -RedirectStandardOutput "$OutDir\node-stdout.log"
Start-Sleep -Seconds 3
Check "the node is running" { -not $node.HasExited }

Section "First run, in the real window"
$before = (Invoke-WebRequest -UseBasicParsing -TimeoutSec 20 https://api.ipify.org).Content.Trim()
Write-Host "direct egress: $before"
$gui = Start-Process -FilePath $app -PassThru
Check "the window shows the first-run screen" { $null -ne (Find-Element "Add your first server" 60) }
Dump-Names "ui-first-run.txt"
Shot "01-first-run"

Section "Add the server, as a desktop user does"
Set-Clipboard -Value (Get-Content (Join-Path $NodeDir "link.txt") -Raw).Trim()
Check "Add a server opens the page" { (Click-Element "Add a server") -and ($null -ne (Find-Element "Paste" 15)) }
Dump-Names "ui-add-server.txt"
Shot "02-add-server"
Check "Paste takes the link from the clipboard" { Click-Element "Paste" 5 }
Start-Sleep -Seconds 1
Shot "03-pasted"
Check "Add server accepts it" { Click-Element "Add server" 5 }
Start-Sleep -Seconds 2
Dump-Names "ui-added.txt"
Shot "04-added"

function Node-Saw($name) {
  (Test-Path $serverLog) -and (Select-String -Path $serverLog -Pattern ([regex]::Escape($name)) -Quiet)
}

# An address the node can only have heard about from the tunnel. A name would not do: the
# tunnel carries it as whichever IP the system resolved.
$probe = "1.0.0.1"

Section "Connect"
Check "the node has seen nothing yet" { -not (Node-Saw "${probe}:") }
# The desktop apps connect as soon as they have a server, without being asked.
Check "the app reports connected" { $null -ne (Find-Element "Connected" 90) }
Start-Sleep -Seconds 2
Dump-Names "ui-connected.txt"
Shot "05-connected"
Check "the Wintun adapter exists" { Adapter-Present }
$got = ""
for ($attempt = 0; $attempt -lt 20 -and -not $got; $attempt++) {
  try { $got = (Invoke-WebRequest -UseBasicParsing -TimeoutSec 8 https://api.ipify.org).Content.Trim() } catch { Start-Sleep -Seconds 2 }
}
Write-Host "egress through the tunnel: $got"
Check "real HTTPS succeeds through the tunnel" { $got -eq $before }
try { Invoke-WebRequest -UseBasicParsing -TimeoutSec 10 "http://$probe/" | Out-Null } catch { }
Start-Sleep -Seconds 1
Check "the node saw the probe, so it crossed the tunnel" { Node-Saw "${probe}:" }

Section "Disconnect"
Check "Disconnect can be clicked" { Click-Element "Disconnect" 10 }
Check "the app reports disconnected" { $null -ne (Find-Element "Disconnected" 30) }
Shot "06-disconnected"
Check "the adapter goes away" { Adapter-Gone-Within 20 }

Section "The tunnel does not outlive the app"
Check "Connect can be clicked again" { Click-Element "Connect" 10 }
Check "it reconnects" { $null -ne (Find-Element "Connected" 90) }
Check "the adapter is back" { Adapter-Present }
Stop-Process -Id $gui.Id -Force -ErrorAction SilentlyContinue
Check "killing the app takes the tunnel with it" { Adapter-Gone-Within 30 }
$after = ""
for ($attempt = 0; $attempt -lt 10 -and -not $after; $attempt++) {
  try { $after = (Invoke-WebRequest -UseBasicParsing -TimeoutSec 8 https://api.ipify.org).Content.Trim() } catch { Start-Sleep -Seconds 2 }
}
Check "the machine is online afterwards" { $after -eq $before }

Section "The server survives a restart"
$gui = Start-Process -FilePath $app -PassThru
Check "the app remembers the server and connects" { $null -ne (Find-Element "Connected" 90) }
Check "and is not back on first run" { $null -eq (Find-Element "Add your first server" 2) }
Shot "07-restarted"
Stop-Process -Id $gui.Id -Force -ErrorAction SilentlyContinue
Start-Sleep -Seconds 2
Stop-Process -Id $node.Id -Force -ErrorAction SilentlyContinue

Section "Uninstalling"
$uninstaller = Get-ChildItem -Path $installDir -Filter "unins*.exe" | Select-Object -First 1
$removed = Start-Process -FilePath $uninstaller.FullName -ArgumentList "/VERYSILENT", "/SUPPRESSMSGBOXES", "/NORESTART" -Wait -PassThru
Check "the uninstaller exits 0" { $removed.ExitCode -eq 0 }
Start-Sleep -Seconds 3
Check "the service is gone" { $null -eq (Get-Service AuroraSvc -ErrorAction SilentlyContinue) }

Section "Result"
Write-Host "$script:Pass passed, $script:Fail failed"
exit ([int]($script:Fail -ne 0))
