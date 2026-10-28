param(
    [string]$PublisherPath = "native-qt/build/bin/game-capture.exe",
    [int]$Port = 8095,
    [string]$Token = "test-minimize-token-777"
)

$ErrorActionPreference = "Stop"

Add-Type -AssemblyName UIAutomationClient
Add-Type -AssemblyName UIAutomationTypes
Add-Type -AssemblyName System.Windows.Forms

Add-Type -TypeDefinition @'
using System;
using System.Text;
using System.Runtime.InteropServices;
public static class MinimizeE2EWin32 {
    public delegate bool Callback(IntPtr hwnd, IntPtr context);
    [DllImport("user32.dll")] public static extern bool EnumWindows(Callback callback, IntPtr context);
    [DllImport("user32.dll")] public static extern uint GetWindowThreadProcessId(IntPtr hwnd, out uint pid);
    [DllImport("user32.dll", CharSet=CharSet.Unicode)] public static extern int GetWindowText(IntPtr hwnd, StringBuilder text, int count);
    [DllImport("user32.dll")] public static extern bool ShowWindow(IntPtr hwnd, int command);
    [DllImport("user32.dll")] public static extern bool SetForegroundWindow(IntPtr hwnd);
    [DllImport("user32.dll")] public static extern bool IsIconic(IntPtr hwnd);
}
'@

function Write-TestStep([string]$Name) {
    Write-Host ""
    Write-Host ">>> [MINIMIZE-RESTORE E2E TEST] $Name <<<" -ForegroundColor Cyan
}

function Get-Diagnostics() {
    $headers = @{ "Authorization" = "Bearer $Token" }
    return (Invoke-RestMethod -Uri "http://127.0.0.1:$Port/diagnostics" -Method Get -Headers $headers)
}

function Find-ControlByClass($Root, [string]$ClassName) {
    $condition = New-Object System.Windows.Automation.PropertyCondition(
        [System.Windows.Automation.AutomationElement]::ClassNameProperty, $ClassName)
    return $Root.FindFirst([System.Windows.Automation.TreeScope]::Descendants, $condition)
}

function Find-ControlByName($Root, [string]$Name) {
    $condition = New-Object System.Windows.Automation.PropertyCondition(
        [System.Windows.Automation.AutomationElement]::NameProperty, $Name)
    return $Root.FindFirst([System.Windows.Automation.TreeScope]::Descendants, $condition)
}

$testStartTime = [DateTime]::Now
# 1. Start Source Window Fixture
Write-TestStep "Starting fixture source window"
$sourceScript = Join-Path $PSScriptRoot "e2e-capture-source.ps1"
$title1 = "Minimize Test Fixture $(Get-Random)"
$fixtureProc = Start-Process powershell.exe -ArgumentList "-NoProfile -ExecutionPolicy Bypass -STA -File `"$sourceScript`" -Title `"$title1`"" -PassThru -WindowStyle Normal
Start-Sleep -Seconds 3

$fixtureHwnd = [IntPtr]::Zero
$deadline = [DateTime]::UtcNow.AddSeconds(10)
while ([DateTime]::UtcNow -lt $deadline -and $fixtureHwnd -eq [IntPtr]::Zero) {
    [void][MinimizeE2EWin32]::EnumWindows({
        param($handle, $context)
        $title = [Text.StringBuilder]::new(256)
        [void][MinimizeE2EWin32]::GetWindowText($handle, $title, 256)
        if ($title.ToString() -eq $title1) {
            $script:fixtureHwnd = $handle
        }
        return $true
    }, [IntPtr]::Zero)
    Start-Sleep -Milliseconds 250
}

if ($fixtureHwnd -eq [IntPtr]::Zero) {
    throw "Failed to locate fixture window handle"
}
Write-Host "Fixture Window HWND: $fixtureHwnd ($($fixtureHwnd.ToInt64()))" -ForegroundColor Green

# 2. Launch GUI Application
Write-TestStep "Launching game-capture.exe GUI"
$streamExpected = "https://vdo.ninja/?push=test_minimize_flow"
$appArgs = @(
    "--local-control",
    "--local-control-port=$Port",
    "--local-control-token=$Token",
    "--stream=$streamExpected"
)
$appProc = Start-Process -FilePath $PublisherPath -ArgumentList $appArgs -PassThru

try {
    Start-Sleep -Seconds 3
    if ($appProc.HasExited) {
        throw "game-capture.exe exited immediately"
    }

    # Find Main Window HWND
    $script:mainHandle = [IntPtr]::Zero
    $deadline = [DateTime]::UtcNow.AddSeconds(15)
    while ([DateTime]::UtcNow -lt $deadline -and $script:mainHandle -eq [IntPtr]::Zero) {
        [void][MinimizeE2EWin32]::EnumWindows({
            param($handle, $context)
            $owner = 0
            [void][MinimizeE2EWin32]::GetWindowThreadProcessId($handle, [ref]$owner)
            if ($owner -eq $appProc.Id) {
                $title = [Text.StringBuilder]::new(256)
                [void][MinimizeE2EWin32]::GetWindowText($handle, $title, 256)
                if ($title.ToString().StartsWith('Game Capture')) {
                    $script:mainHandle = $handle
                }
            }
            return $true
        }, [IntPtr]::Zero)
        Start-Sleep -Milliseconds 250
    }

    if ($script:mainHandle -eq [IntPtr]::Zero) {
        throw "Failed to locate Game Capture main window"
    }

    [void][MinimizeE2EWin32]::ShowWindow($script:mainHandle, 9)
    [void][MinimizeE2EWin32]::SetForegroundWindow($script:mainHandle)
    Start-Sleep -Milliseconds 500

    $root = [System.Windows.Automation.AutomationElement]::FromHandle($script:mainHandle)
    $list = Find-ControlByClass $root "QListWidget"
    $itemCondition = New-Object System.Windows.Automation.PropertyCondition(
        [System.Windows.Automation.AutomationElement]::ControlTypeProperty, [System.Windows.Automation.ControlType]::ListItem)
    $items = $list.FindAll([System.Windows.Automation.TreeScope]::Children, $itemCondition)
    Write-Host "Found $($items.Count) window items in list"

    # Find the fixture item
    $fixtureItem = $null
    for ($i = 0; $i -lt $items.Count; $i++) {
        if ($items[$i].Current.Name -like "*$title1*") {
            $fixtureItem = $items[$i]
            break
        }
    }
    if (-not $fixtureItem) {
        throw "Could not find fixture window in UI list!"
    }

    Write-TestStep "Selecting fixture window in UI list"
    $selPattern = [System.Windows.Automation.SelectionItemPattern]$fixtureItem.GetCurrentPattern([System.Windows.Automation.SelectionItemPattern]::Pattern)
    $selPattern.Select()
    Start-Sleep -Milliseconds 500

    Write-TestStep "Clicking GO LIVE button"
    $goLiveBtn = Find-ControlByName $root "Go live"
    if (-not $goLiveBtn) {
        $goLiveBtn = Find-ControlByName $root "GO LIVE"
    }
    $invokePattern = [System.Windows.Automation.InvokePattern]$goLiveBtn.GetCurrentPattern([System.Windows.Automation.InvokePattern]::Pattern)
    $invokePattern.Invoke()
    
    # Wait for stream to become live
    $liveDeadline = [DateTime]::UtcNow.AddSeconds(15)
    $diagLive = $null
    while ([DateTime]::UtcNow -lt $liveDeadline) {
        try {
            $diagLive = Get-Diagnostics
            if ($diagLive.app.live -and $diagLive.source.capturing) {
                break
            }
        } catch {}
        Start-Sleep -Milliseconds 500
    }

    Write-Host "Diagnostics after GO LIVE:"
    Write-Host "  app.live: $($diagLive.app.live)"
    Write-Host "  source.capturing: $($diagLive.source.capturing)"
    Write-Host "  source.source_id: $($diagLive.source.source_id)"
    if (-not $diagLive.app.live -or -not $diagLive.source.capturing) {
        throw "Expected stream to be live and capturing!"
    }

    # Step 1: Minimize the captured window
    Write-TestStep "Step 1: MINIMIZING the captured window (SW_MINIMIZE = 6)"
    [void][MinimizeE2EWin32]::ShowWindow($fixtureHwnd, 6)
    
    # Wait 4 seconds so that auto-refresh timer (3s) and video maintenance thread tick
    Start-Sleep -Seconds 4
    $diagMin = Get-Diagnostics
    Write-Host "Diagnostics while window is MINIMIZED:"
    Write-Host "  app.live: $($diagMin.app.live)"
    Write-Host "  source.source_id: $($diagMin.source.source_id)"
    Write-Host "  source.capturing: $($diagMin.source.capturing)"

    if ($diagMin.source.source_id -ne [string]$fixtureHwnd.ToInt64()) {
        throw "FAILURE: source_id was cleared or changed while window was minimized! Got '$($diagMin.source.source_id)'"
    }

    # Step 2: Restore the captured window
    Write-TestStep "Step 2: RESTORING the captured window (SW_RESTORE = 9)"
    [void][MinimizeE2EWin32]::ShowWindow($fixtureHwnd, 9)
    [void][MinimizeE2EWin32]::SetForegroundWindow($fixtureHwnd)
    
    # Wait 4 seconds for window to restore and deliver new frames
    Start-Sleep -Seconds 4
    $diagRestored = Get-Diagnostics
    Write-Host "Diagnostics after window is RESTORED:"
    Write-Host "  app.live: $($diagRestored.app.live)"
    Write-Host "  source.capturing: $($diagRestored.source.capturing)"
    Write-Host "  source.source_id: $($diagRestored.source.source_id)"

    if (-not $diagRestored.app.live) {
        throw "FAILURE: Application is no longer live after restore!"
    }
    if ($diagRestored.source.source_id -ne [string]$fixtureHwnd.ToInt64()) {
        throw "FAILURE: Captured source_id does not match target window after restore! Expected $($fixtureHwnd.ToInt64()), got $($diagRestored.source.source_id)"
    }
    if (-not $diagRestored.source.capturing) {
        throw "FAILURE: Capture was LOST after restore! source.capturing is false"
    }

    Write-Host ""
    Write-Host "Waiting another 2 seconds to check video encoding continuity..."
    Start-Sleep -Seconds 2
    $diagFinal = Get-Diagnostics
    Write-Host "Final check:"
    Write-Host "  source.capturing: $($diagFinal.source.capturing)"
    Write-Host "  source.source_id: $($diagFinal.source.source_id)"

    if (-not $diagFinal.source.capturing) {
        throw "FAILURE: Capture stopped after restore!"
    }

    # Check for crash dumps
    $crashDir = "$env:LOCALAPPDATA\GameCapture\crashes"
    if (Test-Path $crashDir) {
        $recentDumps = Get-ChildItem -Path $crashDir -Filter "*.dmp" | Where-Object { $_.CreationTime -gt $testStartTime }
        if ($recentDumps) {
            throw "Found crash dump generated during test: $($recentDumps.Name)"
        }
    }

    # Stop stream
    Write-TestStep "Clicking STOP STREAM button"
    $stopBtn = Find-ControlByName $root "Stop stream"
    if (-not $stopBtn) {
        $stopBtn = Find-ControlByName $root "STOP STREAM"
    }
    if ($stopBtn) {
        $stopInvoke = [System.Windows.Automation.InvokePattern]$stopBtn.GetCurrentPattern([System.Windows.Automation.InvokePattern]::Pattern)
        $stopInvoke.Invoke()
        Start-Sleep -Seconds 1
    }

    Write-Host ""
    Write-Host "==========================================================================" -ForegroundColor Green
    Write-Host "  SUCCESS: WINDOW CAPTURE PERSISTS THROUGH MINIMIZE AND RESTORE CYCLES!    " -ForegroundColor Green
    Write-Host "==========================================================================" -ForegroundColor Green
}
finally {
    if ($fixtureProc -and -not $fixtureProc.HasExited) {
        Stop-Process -Id $fixtureProc.Id -Force -ErrorAction SilentlyContinue
    }
    if ($appProc -and -not $appProc.HasExited) {
        Stop-Process -Id $appProc.Id -Force -ErrorAction SilentlyContinue
    }
}
