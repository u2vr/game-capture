param(
    [string]$PublisherPath = "native-qt/build/bin/game-capture.exe",
    [int]$Port = 8090,
    [string]$Token = "test-gui-token-98765"
)

$ErrorActionPreference = "Stop"

Add-Type -AssemblyName UIAutomationClient
Add-Type -AssemblyName UIAutomationTypes
Add-Type -AssemblyName System.Windows.Forms

Add-Type -TypeDefinition @'
using System;
using System.Text;
using System.Runtime.InteropServices;
public static class GuiTestWin32 {
    public delegate bool Callback(IntPtr hwnd, IntPtr context);
    [DllImport("user32.dll")] public static extern bool EnumWindows(Callback callback, IntPtr context);
    [DllImport("user32.dll")] public static extern uint GetWindowThreadProcessId(IntPtr hwnd, out uint pid);
    [DllImport("user32.dll", CharSet=CharSet.Unicode)] public static extern int GetWindowText(IntPtr hwnd, StringBuilder text, int count);
    [DllImport("user32.dll")] public static extern bool ShowWindow(IntPtr hwnd, int command);
    [DllImport("user32.dll")] public static extern bool SetForegroundWindow(IntPtr hwnd);
}
'@

function Write-TestStep([string]$Name) {
    Write-Host ""
    Write-Host ">>> [GUI E2E TEST] $Name <<<" -ForegroundColor Cyan
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

# 1. Start two Test Source Windows
Write-TestStep "Starting two fixture windows to list in UI"
$sourceScript = Join-Path $PSScriptRoot "e2e-capture-source.ps1"
$title1 = "GUI Fixture Source 1 $(Get-Random)"
$title2 = "GUI Fixture Source 2 $(Get-Random)"
$fixtureProc1 = Start-Process powershell.exe -ArgumentList "-NoProfile -ExecutionPolicy Bypass -STA -File `"$sourceScript`" -Title `"$title1`"" -PassThru -WindowStyle Normal
$fixtureProc2 = Start-Process powershell.exe -ArgumentList "-NoProfile -ExecutionPolicy Bypass -STA -File `"$sourceScript`" -Title `"$title2`"" -PassThru -WindowStyle Normal
Start-Sleep -Seconds 3

# 2. Launch GUI Application
Write-TestStep "Launching game-capture.exe GUI"
$streamExpected = "https://vdo.ninja/?push=test_gui_hotswap_stream"
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
        throw "game-capture.exe GUI exited immediately with code $($appProc.ExitCode)"
    }

    # Find Main Window HWND
    $script:mainHandle = [IntPtr]::Zero
    $deadline = [DateTime]::UtcNow.AddSeconds(15)
    while ([DateTime]::UtcNow -lt $deadline -and $script:mainHandle -eq [IntPtr]::Zero) {
        [void][GuiTestWin32]::EnumWindows({
            param($handle, $context)
            $owner = 0
            [void][GuiTestWin32]::GetWindowThreadProcessId($handle, [ref]$owner)
            if ($owner -eq $appProc.Id) {
                $title = [Text.StringBuilder]::new(256)
                [void][GuiTestWin32]::GetWindowText($handle, $title, 256)
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

    [void][GuiTestWin32]::ShowWindow($script:mainHandle, 9)
    [void][GuiTestWin32]::SetForegroundWindow($script:mainHandle)
    Start-Sleep -Milliseconds 500

    $root = [System.Windows.Automation.AutomationElement]::FromHandle($script:mainHandle)
    Write-Host "Connected to GUI Automation Root: $($root.Current.Name)"

    # Find the QListWidget
    Write-TestStep "Finding window list items in QListWidget"
    $list = Find-ControlByClass $root "QListWidget"
    if (-not $list) {
        throw "Could not find QListWidget"
    }
    $itemCondition = New-Object System.Windows.Automation.PropertyCondition(
        [System.Windows.Automation.AutomationElement]::ControlTypeProperty, [System.Windows.Automation.ControlType]::ListItem)
    $items = $list.FindAll([System.Windows.Automation.TreeScope]::Children, $itemCondition)
    Write-Host "Found $($items.Count) window items in list"
    if ($items.Count -lt 2) {
        throw "Need at least 2 items in list to test hot-swap"
    }

    # Select item 0
    Write-TestStep "Selecting first window item in UI"
    $item0 = [System.Windows.Automation.SelectionItemPattern]$items[0].GetCurrentPattern([System.Windows.Automation.SelectionItemPattern]::Pattern)
    $item0.Select()
    Start-Sleep -Milliseconds 500

    # Click Go Live
    Write-TestStep "Clicking GO LIVE button"
    $goLiveBtn = Find-ControlByName $root "Go live"
    if (-not $goLiveBtn) {
        $goLiveBtn = Find-ControlByName $root "GO LIVE"
    }
    if (-not $goLiveBtn -or -not $goLiveBtn.Current.IsEnabled) {
        throw "Expected Go Live button to be enabled"
    }

    $invokePattern = [System.Windows.Automation.InvokePattern]$goLiveBtn.GetCurrentPattern([System.Windows.Automation.InvokePattern]::Pattern)
    $invokePattern.Invoke()
    Start-Sleep -Seconds 3

    if ($appProc.HasExited) {
        throw "game-capture.exe crashed after clicking Go Live!"
    }

    # Verify stream is live
    $diagLive = Get-Diagnostics
    Write-Host "Diagnostics after Go Live: live=$($diagLive.app.live), capturing=$($diagLive.source.capturing), source_id=$($diagLive.source.source_id)"
    if (-not $diagLive.app.live) {
        throw "Expected app to be live!"
    }
    Write-Host "Stream is LIVE!" -ForegroundColor Green

    # Perform Hot-Swap in GUI: Click item 1
    Write-TestStep "HOT-SWAP: User clicks second window in list while LIVE"
    $item1 = [System.Windows.Automation.SelectionItemPattern]$items[1].GetCurrentPattern([System.Windows.Automation.SelectionItemPattern]::Pattern)
    $item1.Select()
    Start-Sleep -Seconds 2

    if ($appProc.HasExited) {
        throw "game-capture.exe CRASHED when switching to item 1!"
    }

    $diagAfterSwap1 = Get-Diagnostics
    Write-Host "Diagnostics after switching to item 1: live=$($diagAfterSwap1.app.live), capturing=$($diagAfterSwap1.source.capturing), source_id=$($diagAfterSwap1.source.source_id)"
    if (-not $diagAfterSwap1.app.live) {
        throw "App is no longer live after switching source!"
    }
    Write-Host "Successfully switched to item 1 without crashing! Stream remains live!" -ForegroundColor Green

    # Perform Hot-Swap in GUI: Click item 0 again
    Write-TestStep "HOT-SWAP: User clicks first window in list while LIVE"
    $item0.Select()
    Start-Sleep -Seconds 2

    if ($appProc.HasExited) {
        throw "game-capture.exe CRASHED when switching back to item 0!"
    }

    $diagAfterSwap0 = Get-Diagnostics
    Write-Host "Diagnostics after switching back to item 0: live=$($diagAfterSwap0.app.live), capturing=$($diagAfterSwap0.source.capturing), source_id=$($diagAfterSwap0.source.source_id)"
    if (-not $diagAfterSwap0.app.live) {
        throw "App is no longer live after switching back!"
    }
    Write-Host "Successfully switched back to item 0 without crashing! Stream remains live!" -ForegroundColor Green

    # Rapid switching across several items
    Write-TestStep "Stress test: Rapidly switching across multiple window list items while live"
    for ($i = 0; $i -lt [Math]::Min(5, $items.Count); $i++) {
        $item = [System.Windows.Automation.SelectionItemPattern]$items[$i].GetCurrentPattern([System.Windows.Automation.SelectionItemPattern]::Pattern)
        $item.Select()
        Start-Sleep -Milliseconds 300
        if ($appProc.HasExited) {
            throw "game-capture.exe crashed during rapid source selection at index $i!"
        }
    }
    Write-Host "Rapid window switching passed without any crash!" -ForegroundColor Green

    # Check crash directory to be 100% sure no dumps were created during this run
    $crashDir = "$env:LOCALAPPDATA\GameCapture\crashes"
    if (Test-Path $crashDir) {
        $recentDumps = Get-ChildItem -Path $crashDir -Filter "*.dmp" | Where-Object { $_.CreationTime -gt (Get-Date).AddMinutes(-2) }
        if ($recentDumps) {
            throw "Found crash dump generated during test: $($recentDumps.Name)"
        }
    }

    # Click Stop
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
    Write-Host "==========================================================" -ForegroundColor Green
    Write-Host "  GUI WINDOW HOT-SWAPPING VERIFIED - ZERO CRASHES!        " -ForegroundColor Green
    Write-Host "==========================================================" -ForegroundColor Green
}
finally {
    if ($fixtureProc1 -and -not $fixtureProc1.HasExited) {
        Stop-Process -Id $fixtureProc1.Id -Force -ErrorAction SilentlyContinue
    }
    if ($fixtureProc2 -and -not $fixtureProc2.HasExited) {
        Stop-Process -Id $fixtureProc2.Id -Force -ErrorAction SilentlyContinue
    }
    if ($appProc -and -not $appProc.HasExited) {
        Stop-Process -Id $appProc.Id -Force -ErrorAction SilentlyContinue
    }
}
