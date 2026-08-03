<#
.SYNOPSIS
    Registers a Windows Task Scheduler entry that runs UT99 ServerLog Analyzer daily.

.DESCRIPTION
    Creates a scheduled task named "UT99 ServerLog Analyzer - Daily" that runs at the
    chosen local time, every day, in your current Windows user context (so it has
    access to the saved WinSCP session and the ANTHROPIC_API_KEY env var).

    Pick a time AFTER the server's nightly log rotation produces server-old.log.

.PARAMETER Time
    Local time to run, in HH:mm 24-hour format. Default 05:00 (the FMJ server
    normally boots between 02:00 and 05:00, creating the log).

.PARAMETER RetryIntervalMinutes
    If a run fails (the log doesn't exist yet because the server hasn't booted,
    or there is no network connection), Task Scheduler restarts the task after
    this many minutes. Default 30.

.PARAMETER RetryCount
    How many times to restart after a failure before giving up until the next
    day's trigger. Default 12 (so 05:00 + 12 x 30 min covers until ~11:00).

.PARAMETER StartDate
    Optional date (yyyy-MM-dd) on which the daily trigger begins. Defaults to today.

.PARAMETER TaskName
    Name of the scheduled task. Default "UT99 ServerLog Analyzer - Daily".

.PARAMETER Unregister
    Remove an existing task with this name.

.EXAMPLE
    .\Register-DailyTask.ps1 -Time 05:00
#>
[CmdletBinding()]
param(
    [string] $Time                 = '05:00',
    [int]    $RetryIntervalMinutes = 30,
    [int]    $RetryCount           = 12,
    [string] $StartDate            = '',
    [string] $TaskName             = 'UT99 ServerLog Analyzer - Daily',
    [switch] $Unregister
)

$ErrorActionPreference = 'Stop'

if ($Unregister) {
    if (Get-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue) {
        Unregister-ScheduledTask -TaskName $TaskName -Confirm:$false
        Write-Host "Task '$TaskName' removed." -ForegroundColor Green
    } else {
        Write-Host "No task named '$TaskName' found." -ForegroundColor Yellow
    }
    return
}

# Resolve script paths
$BinDir     = $PSScriptRoot
$MainScript = Join-Path $BinDir 'UT99 ServerLog Analyzer.ps1'
if (-not (Test-Path $MainScript)) { throw "Cannot find $MainScript" }

# Prefer the real pwsh.exe from known install locations; the Get-Command result
# can be a Windows Store app stub (AppData\Local\Microsoft\WindowsApps\pwsh.exe)
# that does not work in non-interactive Task Scheduler sessions.
$pwshCandidates = @(
    'C:\Program Files\PowerShell\7\pwsh.exe',
    'C:\Program Files\PowerShell\7-preview\pwsh.exe'
)
$pwsh = $pwshCandidates | Where-Object { Test-Path $_ } | Select-Object -First 1
if (-not $pwsh) {
    $pwshCmd = Get-Command pwsh -ErrorAction SilentlyContinue
    $pwsh = if ($pwshCmd -and $pwshCmd.Source -notlike '*WindowsApps*') { $pwshCmd.Source } else { 'powershell.exe' }
}

$argString = '-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File "{0}"' -f $MainScript

$action    = New-ScheduledTaskAction  -Execute $pwsh -Argument $argString -WorkingDirectory $BinDir
$startDT   = if ($StartDate) {
    [datetime]::ParseExact("$StartDate $Time", 'yyyy-MM-dd HH:mm', $null)
} else {
    [datetime]::ParseExact($Time, 'HH:mm', $null)
}
$trigger   = New-ScheduledTaskTrigger -Daily -At $startDT
# Restart-on-failure gives the "retry every 30 min until it downloads" behavior:
# the main script exits non-zero when the remote log is missing (server not yet
# booted) OR the server is unreachable (no network), which triggers the restart.
# RunOnlyIfNetworkAvailable is deliberately NOT set, so a no-network start still
# runs, fails fast, and is restarted on the same 30-minute cadence.
$settings  = New-ScheduledTaskSettingsSet `
                -StartWhenAvailable `
                -DontStopIfGoingOnBatteries `
                -AllowStartIfOnBatteries `
                -RestartInterval (New-TimeSpan -Minutes $RetryIntervalMinutes) `
                -RestartCount $RetryCount `
                -ExecutionTimeLimit (New-TimeSpan -Minutes 20)

# Run as current user WHETHER OR NOT logged on (S4U logon, no stored password),
# with highest privileges - matches the working "UT99 Chat Monitor - Daily" task
# ("Run whether user is logged on or not" + "Run with highest privileges").
# S4U loads the user's registry hive (HKCU) and profile, so the WinSCP saved
# session and the ANTHROPIC_API_KEY User env var remain available.
# NOTE: registering an S4U / highest-privileges task requires an ELEVATED
# (Run as Administrator) PowerShell session, or this call returns "Access is denied".
$principal = New-ScheduledTaskPrincipal -UserId "$env:USERDOMAIN\$env:USERNAME" -LogonType S4U -RunLevel Highest

$task = New-ScheduledTask -Action $action -Trigger $trigger -Settings $settings -Principal $principal `
        -Description "Downloads the FMJ server's server-old.log via WinSCP, analyzes it with Claude, and writes a daily Obsidian markdown report."

# Replace existing
if (Get-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue) {
    Unregister-ScheduledTask -TaskName $TaskName -Confirm:$false
}

Register-ScheduledTask -TaskName $TaskName -InputObject $task | Out-Null

Write-Host ""
Write-Host "Task '$TaskName' registered." -ForegroundColor Green
Write-Host "  First run: $($startDT.ToString('yyyy-MM-dd')) at $Time"
Write-Host "  Runs daily thereafter at $Time"
Write-Host "  On failure (log not created yet / no network): retries every $RetryIntervalMinutes min, up to $RetryCount times"
Write-Host "  Uses: $pwsh"
Write-Host "  Script: $MainScript"
Write-Host ""
Write-Host "To run it manually right now:"              -ForegroundColor Cyan
Write-Host "  Start-ScheduledTask -TaskName '$TaskName'" -ForegroundColor Gray
Write-Host ""
Write-Host "To remove it later:" -ForegroundColor Cyan
Write-Host "  .\Register-DailyTask.ps1 -Unregister"   -ForegroundColor Gray
