<#
.SYNOPSIS
    Registers the two Windows Task Scheduler entries that drive UT99 ServerLog Analyzer:
    a daily analysis run and an hourly archive-only run.

.DESCRIPTION
    Creates both scheduled tasks in your current Windows user context (so they have
    access to the saved WinSCP session and the UT99_ANALYZER_API_KEY env var):

      "UT99 ServerLog Analyzer - Daily"           full run: fetch, analyze, write the report
      "UT99 ServerLog Analyzer - Hourly Archive"  -ArchiveOnly: fetch and archive, nothing else

    The hourly task is what makes a session impossible to lose. The live server.log is
    buffered server-side and /System/server-old.log is only sometimes created at a restart,
    so an hourly capture is the only thing guaranteeing that a session which never rotates
    is still archived. The daily run then merges every archived session that opened on the
    report date into one report, so it no longer has to be timed against a restart.

.PARAMETER Time
    Local time of the daily analysis run, in HH:mm 24-hour format. Default 01:30, which
    reports the previous day once its play has finished and stays clear of the 05:00
    'Daily Restart' reboot of this machine. It no longer needs to follow the server's
    nightly restart: the hourly archive task captures sessions as they run, and the daily
    run reports whole days from the archive.

.PARAMETER RetryIntervalMinutes
    If a run fails (no network connection, or the server is unreachable), Task Scheduler
    restarts the task after this many minutes. Default 30.

.PARAMETER RetryCount
    How many times to restart after a failure before giving up until the next
    day's trigger. Default 12 (so 01:30 + 12 x 30 min covers until ~07:30).

.PARAMETER StartDate
    Optional date (yyyy-MM-dd) on which the daily trigger begins. Defaults to today.

.PARAMETER TaskName
    Name of the daily task. Default "UT99 ServerLog Analyzer - Daily".

.PARAMETER HourlyTaskName
    Name of the hourly archive task. Default "UT99 ServerLog Analyzer - Hourly Archive".

.PARAMETER HourlyMinute
    Minute past each hour for the archive run, 0-59. Default 15.

.PARAMETER NoHourly
    Register only the daily task and leave the hourly archive task alone.

.PARAMETER Unregister
    Remove both tasks (or only the daily one with -NoHourly).

.EXAMPLE
    .\Register-DailyTask.ps1
    # Daily analysis at 01:30 plus the hourly archive run at :15.

.EXAMPLE
    .\Register-DailyTask.ps1 -Time 02:00 -HourlyMinute 45
#>
[CmdletBinding()]
param(
    [string] $Time                 = '01:30',
    [int]    $RetryIntervalMinutes = 30,
    [int]    $RetryCount           = 12,
    [string] $StartDate            = '',
    [string] $TaskName             = 'UT99 ServerLog Analyzer - Daily',
    [string] $HourlyTaskName       = 'UT99 ServerLog Analyzer - Hourly Archive',
    [ValidateRange(0,59)]
    [int]    $HourlyMinute         = 15,
    [switch] $NoHourly,
    [switch] $Unregister
)

$ErrorActionPreference = 'Stop'

if ($Unregister) {
    $targets = @($TaskName)
    if (-not $NoHourly) { $targets += $HourlyTaskName }
    foreach ($t in $targets) {
        if (Get-ScheduledTask -TaskName $t -ErrorAction SilentlyContinue) {
            Unregister-ScheduledTask -TaskName $t -Confirm:$false
            Write-Host "Task '$t' removed." -ForegroundColor Green
        } else {
            Write-Host "No task named '$t' found." -ForegroundColor Yellow
        }
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
# New-ScheduledTaskTrigger serializes -At as UTC ("...Z"), pinning the task to a fixed UTC time
# that drifts an hour at every DST change. Overwrite with an offset-free local time.
$trigger.StartBoundary = $startDT.ToString('yyyy-MM-ddTHH:mm:ss')
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
# session and the UT99_ANALYZER_API_KEY User env var remain available.
# NOTE: registering an S4U / highest-privileges task requires an ELEVATED
# (Run as Administrator) PowerShell session, or this call returns "Access is denied".
$principal = New-ScheduledTaskPrincipal -UserId "$env:USERDOMAIN\$env:USERNAME" -LogonType S4U -RunLevel Highest

$task = New-ScheduledTask -Action $action -Trigger $trigger -Settings $settings -Principal $principal `
        -Description "Fetches the FMJ server's session logs via WinSCP, merges every archived session that opened on the report date, analyzes them with Claude, and writes an Obsidian markdown report."

# Replace existing
if (Get-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue) {
    Unregister-ScheduledTask -TaskName $TaskName -Confirm:$false
}

Register-ScheduledTask -TaskName $TaskName -InputObject $task | Out-Null

Write-Host ""
Write-Host "Task '$TaskName' registered." -ForegroundColor Green
Write-Host "  First run: $($startDT.ToString('yyyy-MM-dd')) at $Time"
Write-Host "  Runs daily thereafter at $Time"
Write-Host "  On failure (no network / server unreachable): retries every $RetryIntervalMinutes min, up to $RetryCount times"
Write-Host "  Uses: $pwsh"
Write-Host "  Script: $MainScript"

# ------------------------------------------------------------------------- #
#  Hourly archive-only task                                                  #
# ------------------------------------------------------------------------- #
# -ArchiveOnly fetches both session logs and archives them under their own
# "Log file open" names, then exits - no digest, no API call, no report, so an
# hourly cadence costs nothing but bandwidth. This is what guarantees a session
# is captured even when /System/server-old.log is never created for it.
if (-not $NoHourly) {
    $hourlyArgs    = '-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File "{0}" -ArchiveOnly' -f $MainScript
    $hourlyAction  = New-ScheduledTaskAction -Execute $pwsh -Argument $hourlyArgs -WorkingDirectory $BinDir

    # A -Once trigger with a repetition interval and no duration repeats indefinitely.
    $hourlyStart   = (Get-Date -Minute $HourlyMinute -Second 0 -Millisecond 0)
    $hourlyTrigger = New-ScheduledTaskTrigger -Once -At $hourlyStart -RepetitionInterval (New-TimeSpan -Hours 1)
    $hourlyTrigger.StartBoundary = $hourlyStart.ToString('yyyy-MM-ddTHH:mm:ss')   # local time, not UTC (see daily trigger)

    # No restart-on-failure: the next hour's run is the retry. Shorter time limit than the
    # daily task because there is no API call to wait on.
    $hourlySettings = New-ScheduledTaskSettingsSet `
                        -StartWhenAvailable `
                        -DontStopIfGoingOnBatteries `
                        -AllowStartIfOnBatteries `
                        -ExecutionTimeLimit (New-TimeSpan -Minutes 10)

    $hourlyTask = New-ScheduledTask -Action $hourlyAction -Trigger $hourlyTrigger -Settings $hourlySettings `
                    -Principal $principal `
                    -Description "Hourly -ArchiveOnly run: downloads /System/server-old.log and the live /System/server.log and archives both under their session-open names. No analysis, no API call."

    if (Get-ScheduledTask -TaskName $HourlyTaskName -ErrorAction SilentlyContinue) {
        Unregister-ScheduledTask -TaskName $HourlyTaskName -Confirm:$false
    }
    Register-ScheduledTask -TaskName $HourlyTaskName -InputObject $hourlyTask | Out-Null

    Write-Host ""
    Write-Host "Task '$HourlyTaskName' registered." -ForegroundColor Green
    Write-Host "  Runs every hour at :$('{0:00}' -f $HourlyMinute), archive-only (no API call)"
    Write-Host "  First run: $($hourlyStart.ToString('yyyy-MM-dd HH:mm'))"
}

Write-Host ""
Write-Host "To run them manually right now:"            -ForegroundColor Cyan
Write-Host "  Start-ScheduledTask -TaskName '$TaskName'" -ForegroundColor Gray
if (-not $NoHourly) {
    Write-Host "  Start-ScheduledTask -TaskName '$HourlyTaskName'" -ForegroundColor Gray
}
Write-Host ""
Write-Host "To remove them later:" -ForegroundColor Cyan
Write-Host "  .\Register-DailyTask.ps1 -Unregister"   -ForegroundColor Gray
