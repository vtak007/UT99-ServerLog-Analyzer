<#
.SYNOPSIS
    UT99 ServerLog Analyzer - downloads the FMJ server's rotated log
    (server-old.log) via WinSCP, analyzes it with Claude, and writes a
    professional Obsidian-flavored markdown report.

.DESCRIPTION
    Designed to run unattended on a daily schedule via Windows Task Scheduler,
    or interactively from a PowerShell prompt.

    Workflow:
        1. Connect to the server via WinSCP using the saved session and
           download /System/server-old.log.
        2. Deterministically pre-scan the log (regex) into a bounded digest:
           header facts, tag histogram, and deduped issue signatures with
           counts (errors, warnings, Accessed None script warnings, network,
           anti-cheat/integrity, package/version).
        3. Send only the digest to Claude for interpretation, severity rating,
           root-cause and proposed solutions.
        4. Render a clean Obsidian markdown report to the log folder.

.PARAMETER ConfigPath
    Path to config.ps1. Defaults to ..\config.ps1 next to this script.

.PARAMETER NoFetch
    Skip the server download. Use with -LogFile to reprocess a local log.

.PARAMETER NoAnalysis
    Skip the Claude API call. Produces a report from deterministic data only
    (no findings/solutions). Useful for testing parsing without API cost.

.PARAMETER LogFile
    Analyze a specific local log file instead of the freshly downloaded one.

.PARAMETER Date
    Force the report date (yyyy-MM-dd). Default: the log's own session date,
    else today.

.EXAMPLE
    .\UT99 ServerLog Analyzer.ps1
    # Normal run: download server-old.log, analyze, write report.

.EXAMPLE
    .\UT99 ServerLog Analyzer.ps1 -NoFetch -NoAnalysis -LogFile "D:\Dropbox\Gaming\UTLogs\ServerLogs\FMJ Server Log 2026-08-02.log"
    # Offline parse test: no download, no API call.
#>
[CmdletBinding()]
param(
    [string]   $ConfigPath = (Join-Path (Split-Path $PSScriptRoot -Parent) 'config.ps1'),
    [switch]   $NoFetch,
    [switch]   $NoAnalysis,
    [string]   $LogFile,
    [datetime] $Date
)

$ErrorActionPreference = 'Stop'
$ProgressPreference    = 'SilentlyContinue'

# ========================================================================== #
#  Bootstrap                                                                  #
# ========================================================================== #

if (-not (Test-Path $ConfigPath)) {
    throw "Config file not found at $ConfigPath. Run Setup.ps1 or edit config.ps1 first."
}
$Config = & $ConfigPath

$LogFolder    = $Config.LocalLogFolder
$SystemFolder = $Config.SystemFolder
$StateFolder  = Join-Path $SystemFolder 'State'
$RunLogFolder = Join-Path $SystemFolder 'Runlogs'

foreach ($p in @($LogFolder, $SystemFolder, $StateFolder, $RunLogFolder)) {
    if (-not (Test-Path $p)) { $null = New-Item -ItemType Directory -Force -Path $p }
}

$RunStarted = Get-Date
$RunLogFile = Join-Path $RunLogFolder ("run-" + $RunStarted.ToString('yyyy-MM-dd-HHmmss') + ".log")

function Write-RunLog {
    param([string]$Level = 'INFO', [string]$Message)
    $ts = (Get-Date).ToString('yyyy-MM-dd HH:mm:ss')
    $line = "[$ts] [$Level] $Message"
    Add-Content -Path $RunLogFile -Value $line
    if ($Level -eq 'ERROR')     { Write-Host $line -ForegroundColor Red }
    elseif ($Level -eq 'WARN')  { Write-Host $line -ForegroundColor Yellow }
    else { Write-Host $line }
}

Write-RunLog INFO "UT99 ServerLog Analyzer starting (PID $PID)"
Write-RunLog INFO "Config: $ConfigPath"
Write-RunLog INFO "Log/report folder: $LogFolder"

# ========================================================================== #
#  Step 1 - Fetch server-old.log via WinSCP                                   #
# ========================================================================== #

function Invoke-ServerFetch {
    <#
        Downloads the single named remote log to a staging file. Returns the
        staging path, or $null if fetch was skipped.
    #>
    if ($NoFetch) {
        Write-RunLog INFO "Skipping fetch (-NoFetch)."
        return $null
    }
    if (-not (Test-Path $Config.WinSCPcomPath)) {
        throw "WinSCP.com not found at $($Config.WinSCPcomPath). Install WinSCP 6.5+ or update WinSCPcomPath in config.ps1."
    }

    $remoteFolder = $Config.RemoteLogFolder
    if (-not $remoteFolder.EndsWith('/')) { $remoteFolder += '/' }
    $remoteMask = $remoteFolder + $Config.RemoteLogMask

    # The remote name carries a rotation timestamp (server.yyyymmdd_hhmm.log),
    # so it isn't known ahead of time - stage into a folder and resolve after.
    $stageFolder = Join-Path $LogFolder '_incoming'
    if (Test-Path $stageFolder) { Remove-Item $stageFolder -Recurse -Force -ErrorAction SilentlyContinue }
    New-Item -ItemType Directory -Path $stageFolder -Force | Out-Null

    $deleteFlag = if ($Config.DeleteAfterDownload) { '-delete ' } else { '' }

    $wscpLines = @(
        'option batch abort'
        'option confirm off'
        'option transfer binary'
        'option reconnecttime 30'
        ('open "{0}"' -f $Config.WinSCPSessionName)
        ('get -latest {0}"{1}" "{2}\"' -f $deleteFlag, $remoteMask, $stageFolder)
        'exit'
    )
    $wscpScript = $wscpLines -join "`r`n"

    $tempScript = Join-Path $env:TEMP ("ut99srvfetch-{0}.wscp" -f (Get-Date -Format 'yyyyMMddHHmmss'))
    $wscpXmlLog = Join-Path $StateFolder ("winscp-{0}.xml" -f (Get-Date -Format 'yyyy-MM-dd-HHmmss'))
    Set-Content -Path $tempScript -Value $wscpScript -Encoding ASCII

    Write-RunLog INFO ("Fetching newest {0} from server..." -f $remoteMask)

    $stdout = & $Config.WinSCPcomPath /script=$tempScript /xmllog=$wscpXmlLog /xmlgroups 2>&1 | Out-String
    $exit = $LASTEXITCODE
    Remove-Item $tempScript -Force -ErrorAction SilentlyContinue

    Add-Content -Path $RunLogFile -Value "----- WinSCP stdout -----"
    Add-Content -Path $RunLogFile -Value $stdout
    Add-Content -Path $RunLogFile -Value "----- end WinSCP stdout -----"

    if ($exit -ne 0) {
        Write-RunLog ERROR "WinSCP exit code $exit. See $wscpXmlLog and run log for details."
        Write-RunLog WARN  ("No log matching {0} yet (server not booted since the last rotation), or the server is unreachable (no network). If run by the scheduled task, it will retry in 30 minutes." -f $remoteMask)
        throw "WinSCP fetch failed (exit $exit)."
    }

    $staged = @(Get-ChildItem -LiteralPath $stageFolder -File | Sort-Object Name -Descending)
    if ($staged.Count -eq 0) {
        throw ("WinSCP reported success but no file matching {0} was downloaded to {1}." -f $remoteMask, $stageFolder)
    }
    if ($staged.Count -gt 1) {
        Write-RunLog WARN ("{0} files staged; using the newest by name ({1})." -f $staged.Count, $staged[0].Name)
    }
    $stagePath = $staged[0].FullName
    Write-RunLog INFO ("Fetch completed: {0} ({1:N0} bytes)" -f $staged[0].Name, $staged[0].Length)
    return $stagePath
}

# ========================================================================== #
#  Step 2 - Deterministic pre-scan into a bounded digest                      #
# ========================================================================== #

function Get-LogSessionDate {
    param([Parameter(Mandatory)][string]$Path)
    $inv = [System.Globalization.CultureInfo]::InvariantCulture
    $head = Get-Content -LiteralPath $Path -TotalCount 60 -Encoding UTF8
    foreach ($l in $head) {
        if ($l -match 'Log file open,\s+(\d{1,2}/\d{1,2}/\d{2,4})\s+(\d{2}:\d{2}:\d{2})') {
            foreach ($fmt in @('MM/dd/yy HH:mm:ss','MM/dd/yyyy HH:mm:ss','M/d/yy HH:mm:ss','M/d/yyyy HH:mm:ss')) {
                try { return [datetime]::ParseExact(($matches[1] + ' ' + $matches[2]), $fmt, $inv) } catch {}
            }
        }
    }
    return $null
}

function Add-Signature {
    param([hashtable]$Dict, [string]$Sig, [string]$Example, [string]$Map)
    if ([string]::IsNullOrWhiteSpace($Sig)) { return }
    if ($Dict.ContainsKey($Sig)) {
        $o = $Dict[$Sig]; $o.Count++
    } else {
        $o = [pscustomobject]@{ Signature = $Sig; Count = 1; Example = $Example; Maps = @{} }
        $Dict[$Sig] = $o
    }
    if ($Map) {
        if ($o.Maps.ContainsKey($Map)) { $o.Maps[$Map]++ } else { $o.Maps[$Map] = 1 }
    }
}

function Get-WarningSignature {
    param([string]$Msg)
    $s = $Msg
    $s = $s -replace '"[^"]*"', '"<x>"'
    $s = $s -replace "'[^']*'", "'<x>'"
    $s = $s -replace '\bDM-[A-Za-z0-9_]+', '<map>'
    $s = $s -replace '-?\d+(\.\d+)?', '<n>'
    return ($s -replace '\s+', ' ').Trim()
}

function Get-ServerLogDigest {
    param([Parameter(Mandatory)][string]$Path, [int]$TopN = 25)

    $lines = Get-Content -LiteralPath $Path -Encoding UTF8
    $lineCount = $lines.Count

    $tagHist = [ordered]@{}
    $warnDict = @{}; $swDict = @{}; $errDict = @{}; $acDict = @{}; $pkgDict = @{}
    $failLoadDict = @{}   # verbatim 'Failed to load "<name>": ...' messages, real names kept, counted
    $maps = [System.Collections.Generic.List[string]]::new()
    $mapSet = [System.Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    $mutators = [System.Collections.Generic.List[string]]::new()
    $serverPackages = [System.Collections.Generic.List[string]]::new()
    $ipSet = [System.Collections.Generic.HashSet[string]]::new()
    $engineVersion = ''; $commandLine = ''; $baseDir = ''
    $logOpen = ''; $logClosed = ''
    $restarts = 0
    $netOpens = 0; $netCloses = 0; $disconnects = 0; $timeouts = 0
    $currentMap = '(startup)'; $mapRounds = 0

    # Connection/player analytics collectors (Feature 3).
    $opens       = [System.Collections.Generic.List[object]]::new()   # ordered; index i == TcpipConnection i
    $closesByIdx = @{}                                                 # TcpipConnection index -> close datetime
    $playerByKey = @{}                                                 # "ip:port" -> player name
    $inv = [System.Globalization.CultureInfo]::InvariantCulture
    $parseTs = {
        param($s)
        foreach ($fmt in @('MM/dd/yy HH:mm:ss','M/d/yy HH:mm:ss','MM/dd/yyyy HH:mm:ss','M/d/yyyy HH:mm:ss')) {
            try { return [datetime]::ParseExact($s, $fmt, $inv) } catch {}
        }
        return $null
    }

    # Log coverage window. The engine stamps no per-line time, and a rotated log
    # has no 'Log file closed' marker, so the window is derived from every
    # timestamp format that does appear, and min/max'd.
    #   Log file open, MM/dd/yy HH:mm:ss
    #   NetComeGo Open/Close       MM/dd/yy HH:mm:ss
    #   MapVote  ... yyyy/MM/dd Time > HH:mm:ss.fff
    #   ACE      ... [TIME] dd-MM-yyyy / HH:mm:ss   (day first)
    $firstTs = $null; $lastTs = $null
    $parseAnyTs = {
        param($b)
        if ($b -match '\b(\d{4}/\d{2}/\d{2})\s+Time\s*>\s*(\d{2}:\d{2}:\d{2})') {
            try { return [datetime]::ParseExact(($matches[1] + ' ' + $matches[2]), 'yyyy/MM/dd HH:mm:ss', $inv) } catch { return $null }
        }
        if ($b -match '\[TIME\]\s+(\d{2}-\d{2}-\d{4})\s*/\s*(\d{2}:\d{2}:\d{2})') {
            try { return [datetime]::ParseExact(($matches[1] + ' ' + $matches[2]), 'dd-MM-yyyy HH:mm:ss', $inv) } catch { return $null }
        }
        if ($b -match '\b(\d{1,2}/\d{1,2}/\d{2,4}\s+\d{2}:\d{2}:\d{2})\b') {
            return (& $parseTs $matches[1])
        }
        return $null
    }

    foreach ($line in $lines) {
        if ($line -match '^(\w+):\s?(.*)$') {
            $tag = $matches[1]; $body = $matches[2]
        } else { continue }

        if ($tagHist.Contains($tag)) { $tagHist[$tag]++ } else { $tagHist[$tag] = 1 }

        switch -Regex ($tag) {
            '^Init$' {
                if ($body -match '^Revision:\s+(\S+)')      { $rev = $matches[1] }
                if ($body -match '^Version:\s+(\S+)')       { $engineVersion = $matches[1] }
                if ($body -match '^Command line:\s+(.*)$')  { $commandLine = $matches[1] }
                if ($body -match '^Base directory:\s+(.*)$'){ $baseDir = $matches[1] }
            }
            '^Log$' {
                if ($body -match '^Log file open,\s+(.*)$')   { if (-not $logOpen) { $logOpen = $matches[1] }; $restarts++ }
                if ($body -match '^Log file closed,\s+(.*)$') { $logClosed = $matches[1] }
                if ($body -match '^Server Package:\s+(\S+)') {
                    $sp = $matches[1]; if (-not $serverPackages.Contains($sp)) { $serverPackages.Add($sp) }
                }
                if ($body -match '^LoadMap:\s+([A-Za-z0-9_\-]+\.unr)') {
                    $mp = $matches[1]; if ($mapSet.Add($mp)) { $maps.Add($mp) }
                    $currentMap = $mp                       # track active map for attribution
                    $mapRounds++                            # counts repeats (each map load = a round)
                }
                elseif ($body -match '^Browse:\s+([A-Za-z0-9_\-]+\.unr)') {
                    $mp = $matches[1]; if ($mapSet.Add($mp)) { $maps.Add($mp) }
                    $currentMap = $mp
                }
            }
            '^Warning$'       { Add-Signature $warnDict (Get-WarningSignature $body) $body $currentMap }
            '^ScriptWarning$' {
                $sig = $null
                if ($body -match '\(Function\s+([^)]+?):[0-9A-Fa-f]+\)\s+(.*)$') {
                    # Keep the offending variable name (e.g. 'Weapon', 'Receiver') - it's diagnostic.
                    $sig = ($matches[1] + '  ' + $matches[2]).Trim()
                } else {
                    $sig = Get-WarningSignature $body
                }
                Add-Signature $swDict $sig $body $currentMap
            }
            '^(UTPure|IGPlus|NSC)$' {
                if ($body -match '(?i)\b(kick|ban|cheat|exploit|violation|mismatch|illegal|reject|fail)') {
                    Add-Signature $acDict ($tag + ': ' + (Get-WarningSignature $body)) $body $currentMap
                }
            }
            '^ScriptLog$' {
                # NPLoader emits: [NPLoaderv24] Player Join: <name> (<ip>:<port>) - pairs name<->ip:port.
                if ($body -match 'Player Join:\s+(.+?)\s+\((\d{1,3}(?:\.\d{1,3}){3}):(\d+)\)') {
                    $playerByKey[("{0}:{1}" -f $matches[2], $matches[3])] = $matches[1]
                }
            }
            '^NetComeGo$' {
                if ($body -match '^Open\s+\S+\s+(\d{1,2}/\d{1,2}/\d{2,4}\s+\d{2}:\d{2}:\d{2})\s+(\d{1,3}(?:\.\d{1,3}){3}):(\d+)') {
                    $netOpens++
                    $null = $ipSet.Add($matches[2])
                    $opens.Add([pscustomobject]@{ Index = $opens.Count; TS = (& $parseTs $matches[1]); IP = $matches[2]; Key = ("{0}:{1}" -f $matches[2], $matches[3]) })
                }
                elseif ($body -match '^Close\s+TcpipConnection(\d+)\s+(\d{1,2}/\d{1,2}/\d{2,4}\s+\d{2}:\d{2}:\d{2})') {
                    $netCloses++
                    $closesByIdx[[int]$matches[1]] = (& $parseTs $matches[2])
                }
                elseif ($body -match '^Open') { $netOpens++; if ($body -match '(\d{1,3}(?:\.\d{1,3}){3}):\d+') { $null = $ipSet.Add($matches[1]) } }
                elseif ($body -match '^Close') { $netCloses++ }
            }
        }

        # Log coverage window (independent of tag; any recognised timestamp counts)
        if ($body -match '\d{2}:\d{2}:\d{2}') {
            $ts = & $parseAnyTs $body
            if ($ts) {
                if (-not $firstTs -or $ts -lt $firstTs) { $firstTs = $ts }
                if (-not $lastTs  -or $ts -gt $lastTs)  { $lastTs  = $ts }
            }
        }

        # Cross-tag detectors (independent of tag)
        if ($body -match '(?i)(assertion failed|appError|Critical:|=== Critical|\bFatal\b|General protection fault|Runaway loop|Failed to enter)') {
            Add-Signature $errDict (Get-WarningSignature $body) $body $currentMap
        }
        if ($body -match '(?i)(version mismatch|package mismatch|wrong version|failed to load package|guid mismatch)') {
            Add-Signature $pkgDict (Get-WarningSignature $body) $body $currentMap
        }
        # Verbatim failed-to-load offenders: keep the real package/object name (NOT '<x>')
        # and count identical messages. Anchored '"' excludes ScriptLog '...so load...' fallbacks.
        if ($body -match '^Failed to load "') {
            $flMsg = ($body -replace '\s+', ' ').Trim()
            Add-Signature $failLoadDict $flMsg $flMsg $currentMap
        }
        if ($body -match '(?i)\b(timeout|timed out)\b') { $timeouts++ }
        if ($body -match '(?i)\b(connection failed|net error|disconnect)\b') { $disconnects++ }

        # Mutators from command line
        if ($commandLine -and $mutators.Count -eq 0 -and $commandLine -match '(?i)mutator=([^\s?]+)') {
            foreach ($m in ($matches[1] -split ',')) { if ($m) { $mutators.Add($m.Trim()) } }
        }
    }

    $topSig = {
        param($dict)
        @($dict.Values | Sort-Object -Property Count -Descending | Select-Object -First $TopN)
    }

    # --- Per-map issue aggregation (Feature 2): sum each signature's Maps counts. ---
    $mapIssues = @{}   # map -> [pscustomobject]{ Map; Warnings; ScriptWarnings; Errors }
    $bumpMap = {
        param($dict, $field)
        foreach ($sigObj in $dict.Values) {
            foreach ($mk in $sigObj.Maps.Keys) {
                if (-not $mapIssues.ContainsKey($mk)) {
                    $mapIssues[$mk] = [pscustomobject]@{ Map = $mk; Warnings = 0; ScriptWarnings = 0; Errors = 0 }
                }
                $mapIssues[$mk].$field += $sigObj.Maps[$mk]
            }
        }
    }
    & $bumpMap $warnDict 'Warnings'
    & $bumpMap $swDict   'ScriptWarnings'
    & $bumpMap $errDict  'Errors'
    $mapIssuesList = @($mapIssues.Values | Sort-Object -Property @{ Expression = { $_.Warnings + $_.ScriptWarnings + $_.Errors } } -Descending)

    # --- Connection pairing + player analytics (Feature 3). ---
    $endFallback = $null
    if ($closesByIdx.Count -gt 0) { $endFallback = ($closesByIdx.Values | Where-Object { $_ } | Measure-Object -Maximum).Maximum }
    if (-not $endFallback -and $opens.Count -gt 0) { $endFallback = ($opens | Where-Object { $_.TS } | ForEach-Object TS | Measure-Object -Maximum).Maximum }

    $playerAgg    = @{}
    $concEvents   = [System.Collections.Generic.List[object]]::new()
    $playerSessions = 0
    foreach ($o in $opens) {
        $name = $playerByKey[$o.Key]
        if (-not $name) { continue }                 # only named player sessions
        $playerSessions++
        $endTs = if ($closesByIdx.ContainsKey($o.Index)) { $closesByIdx[$o.Index] } else { $endFallback }
        $dur = if ($o.TS -and $endTs -and $endTs -ge $o.TS) { ($endTs - $o.TS).TotalSeconds } else { $null }
        if (-not $playerAgg.ContainsKey($name)) {
            $playerAgg[$name] = [pscustomobject]@{ Name = $name; Joins = 0; TotalSec = 0.0; First = $o.TS; IPs = [System.Collections.Generic.HashSet[string]]::new() }
        }
        $a = $playerAgg[$name]
        $a.Joins++
        if ($null -ne $dur) { $a.TotalSec += $dur }
        if ($o.TS -and (-not $a.First -or $o.TS -lt $a.First)) { $a.First = $o.TS }
        $null = $a.IPs.Add($o.IP)
        if ($o.TS)  { $concEvents.Add([pscustomobject]@{ TS = $o.TS;  D = 1 }) }
        if ($endTs) { $concEvents.Add([pscustomobject]@{ TS = $endTs; D = -1 }) }
    }

    # Peak concurrent players from +1/-1 event timeline.
    $peak = 0; $run = 0
    foreach ($e in ($concEvents | Sort-Object @{ Expression = { $_.TS } }, @{ Expression = { $_.D } })) {
        $run += $e.D; if ($run -gt $peak) { $peak = $run }
    }

    $players = @(
        $playerAgg.Values | Sort-Object -Property @{ Expression = 'Joins'; Descending = $true }, @{ Expression = 'TotalSec'; Descending = $true } |
        ForEach-Object {
            [pscustomobject]@{
                Name    = $_.Name
                Joins   = $_.Joins
                IPs     = $_.IPs.Count
                First   = $_.First
                AvgSec  = if ($_.Joins -gt 0) { [math]::Round($_.TotalSec / $_.Joins) } else { 0 }
                TotalSec= [math]::Round($_.TotalSec)
            }
        }
    )

    $spanText = if ($firstTs -and $lastTs) {
        $d = $lastTs - $firstTs
        if ($d.TotalHours -ge 1) { '{0}h {1}m' -f [int]$d.TotalHours, $d.Minutes } else { '{0}m' -f [int]$d.TotalMinutes }
    } else { '' }

    [pscustomobject]@{
        LogPath        = $Path
        LineCount      = $lineCount
        FirstEntry     = $firstTs
        LastEntry      = $lastTs
        FirstEntryText = if ($firstTs) { $firstTs.ToString('yyyy-MM-dd HH:mm:ss') } else { '' }
        LastEntryText  = if ($lastTs)  { $lastTs.ToString('yyyy-MM-dd HH:mm:ss') }  else { '' }
        SpanText       = $spanText
        EngineVersion  = if ($rev) { "$engineVersion$rev" } else { $engineVersion }
        CommandLine    = $commandLine
        BaseDir        = $baseDir
        LogOpen        = $logOpen
        LogClosed      = $logClosed
        Restarts       = $restarts
        Maps           = @($maps)
        MapRounds      = $mapRounds
        Mutators       = @($mutators)
        ServerPackages = @($serverPackages)
        TagHistogram   = $tagHist
        Warnings       = & $topSig $warnDict
        FailedLoads    = @($failLoadDict.Values | Sort-Object -Property Count -Descending)   # all offenders, uncapped
        ScriptWarnings = & $topSig $swDict
        Errors         = & $topSig $errDict
        AntiCheat      = & $topSig $acDict
        PackageIssues  = & $topSig $pkgDict
        WarningTotal   = ($warnDict.Values  | Measure-Object -Property Count -Sum).Sum
        SWTotal        = ($swDict.Values    | Measure-Object -Property Count -Sum).Sum
        ErrorTotal     = ($errDict.Values   | Measure-Object -Property Count -Sum).Sum
        MapIssues      = $mapIssuesList
        Players        = $players
        Network        = [pscustomobject]@{
            Opens = $netOpens; Closes = $netCloses; UniqueIPs = $ipSet.Count
            Disconnects = $disconnects; Timeouts = $timeouts
            PlayerSessions = $playerSessions; UniquePlayers = $players.Count; PeakConcurrent = $peak
        }
    }
}

# ========================================================================== #
#  Step 2.5 - Trend / history (Feature 1)                                     #
# ========================================================================== #

function Get-DigestSignatureMap {
    # Flatten the digest's top-N buckets into a "bucket|signature" -> count map.
    param($Digest)
    $m = [ordered]@{}
    $add = { param($bucket, $list) foreach ($s in @($list)) { $m["$bucket|$($s.Signature)"] = [int]$s.Count } }
    & $add 'err'  $Digest.Errors
    & $add 'sw'   $Digest.ScriptWarnings
    & $add 'warn' $Digest.Warnings
    & $add 'ac'   $Digest.AntiCheat
    & $add 'pkg'  $Digest.PackageIssues
    return $m
}

function Get-Trend {
    <#
        Loads State\digest-history.json, compares the current digest to the most
        recent PRIOR-dated entry, and returns deltas + brand-new signatures
        (never seen in any prior entry) + resolved signatures.
    #>
    param($Digest, [string]$HistoryPath, [datetime]$ReportDate)

    $curSigs = Get-DigestSignatureMap $Digest
    $curDateStr = $ReportDate.ToString('yyyy-MM-dd')

    $history = @()
    if (Test-Path $HistoryPath) {
        try { $history = @(Get-Content $HistoryPath -Raw -Encoding UTF8 | ConvertFrom-Json) } catch { $history = @() }
    }

    # Union of all signatures seen in prior-dated entries -> for NEW detection.
    $seen = [System.Collections.Generic.HashSet[string]]::new()
    $prior = @($history | Where-Object { $_.date -ne $curDateStr })
    foreach ($h in $prior) {
        if ($h.signatures) { foreach ($p in $h.signatures.PSObject.Properties) { $null = $seen.Add($p.Name) } }
    }
    $prev = $prior | Sort-Object date | Select-Object -Last 1

    $newSigs = @($curSigs.Keys | Where-Object { -not $seen.Contains($_) })
    $resolved = @()
    if ($prev -and $prev.signatures) {
        foreach ($p in $prev.signatures.PSObject.Properties) { if (-not $curSigs.Contains($p.Name)) { $resolved += $p.Name } }
    }

    $delta = {
        param($cur, $prevVal)
        if ($null -eq $prevVal) { return $null }
        return ([int]$cur - [int]$prevVal)
    }

    [pscustomobject]@{
        HasHistory  = [bool]$prev
        PrevDate    = if ($prev) { [string]$prev.date } else { '' }
        Deltas      = [pscustomobject]@{
            Warnings       = if ($prev) { & $delta $Digest.WarningTotal $prev.warningTotal } else { $null }
            ScriptWarnings = if ($prev) { & $delta $Digest.SWTotal      $prev.swTotal }      else { $null }
            Errors         = if ($prev) { & $delta $Digest.ErrorTotal   $prev.errorTotal }   else { $null }
            UniqueIPs      = if ($prev) { & $delta $Digest.Network.UniqueIPs $prev.uniqueIPs } else { $null }
            PlayerSessions = if ($prev) { & $delta $Digest.Network.PlayerSessions $prev.playerSessions } else { $null }
        }
        NewSignatures      = $newSigs
        ResolvedSignatures = $resolved
        CurrentSignatures  = $curSigs
    }
}

function Save-DigestHistory {
    param($Digest, $Trend, [string]$HistoryPath, [datetime]$ReportDate, [int]$MaxEntries = 90)

    $history = @()
    if (Test-Path $HistoryPath) {
        try { $history = @(Get-Content $HistoryPath -Raw -Encoding UTF8 | ConvertFrom-Json) } catch { $history = @() }
    }
    $curDateStr = $ReportDate.ToString('yyyy-MM-dd')
    $history = @($history | Where-Object { $_.date -ne $curDateStr })   # replace same-date entry

    $sigObj = [pscustomobject]@{}
    foreach ($k in $Trend.CurrentSignatures.Keys) {
        Add-Member -InputObject $sigObj -NotePropertyName $k -NotePropertyValue $Trend.CurrentSignatures[$k] -Force
    }

    $entry = [pscustomobject]@{
        date           = $curDateStr
        warningTotal   = [int]$Digest.WarningTotal
        swTotal        = [int]$Digest.SWTotal
        errorTotal     = [int]$Digest.ErrorTotal
        restarts       = [int]$Digest.Restarts
        uniqueIPs      = [int]$Digest.Network.UniqueIPs
        playerSessions = [int]$Digest.Network.PlayerSessions
        peakConcurrent = [int]$Digest.Network.PeakConcurrent
        signatures     = $sigObj
    }
    $history += $entry
    $history = @($history | Sort-Object date | Select-Object -Last $MaxEntries)
    $history | ConvertTo-Json -Depth 6 | Set-Content -Path $HistoryPath -Encoding UTF8
}

# ========================================================================== #
#  Step 3 - Claude API analysis                                               #
# ========================================================================== #

function ConvertTo-DigestText {
    param($Digest, $Trend)
    $sb = [System.Text.StringBuilder]::new()
    $null = $sb.AppendLine("ENGINE: $($Digest.EngineVersion)")
    $null = $sb.AppendLine("SESSION OPEN: $($Digest.LogOpen)   CLOSED: $($Digest.LogClosed)   RESTARTS(open-events): $($Digest.Restarts)")
    $null = $sb.AppendLine("LOG COVERS: $($Digest.FirstEntryText) -> $($Digest.LastEntryText)  ($($Digest.SpanText))")
    $null = $sb.AppendLine("COMMAND LINE: $($Digest.CommandLine)")
    $null = $sb.AppendLine("MAPS PLAYED ($($Digest.Maps.Count)): $($Digest.Maps -join ', ')")
    $null = $sb.AppendLine("MUTATORS: $($Digest.Mutators -join ', ')")
    $null = $sb.AppendLine("SERVER PACKAGES: $($Digest.ServerPackages -join ', ')")
    $n = $Digest.Network
    $null = $sb.AppendLine("NETWORK: connectionOpens=$($n.Opens) closes=$($n.Closes) uniqueIPs=$($n.UniqueIPs) playerConnects=$($n.PlayerSessions) uniquePlayers=$($n.UniquePlayers) mapRounds=$($Digest.MapRounds) peakConcurrentPlayers=$($n.PeakConcurrent) disconnect-lines=$($n.Disconnects) timeout-lines=$($n.Timeouts)")
    $null = $sb.AppendLine("(NOTE: playerConnects counts every (re)join including UT map-travel reconnects, so it scales with mapRounds; peakConcurrentPlayers and uniquePlayers are the true population measures.)")
    $null = $sb.AppendLine("TOTALS: warnings=$($Digest.WarningTotal) scriptWarnings=$($Digest.SWTotal) hardErrors=$($Digest.ErrorTotal)")
    $null = $sb.AppendLine("TAG HISTOGRAM: " + (($Digest.TagHistogram.GetEnumerator() | ForEach-Object { "$($_.Key)=$($_.Value)" }) -join ' '))

    # Per-map issue attribution (Feature 2).
    if (@($Digest.MapIssues).Count -gt 0) {
        $null = $sb.AppendLine("")
        $null = $sb.AppendLine("ISSUES BY MAP (warnings/scriptWarnings/errors):")
        foreach ($m in $Digest.MapIssues) {
            $null = $sb.AppendLine(("  {0}: W={1} SW={2} E={3}" -f $m.Map, $m.Warnings, $m.ScriptWarnings, $m.Errors))
        }
    }

    # Trend context (Feature 1) so the model can comment on what changed.
    if ($Trend -and $Trend.HasHistory) {
        $d = $Trend.Deltas
        $fmtD = { param($v) if ($null -eq $v) { 'n/a' } elseif ($v -ge 0) { "+$v" } else { "$v" } }
        $null = $sb.AppendLine("")
        $null = $sb.AppendLine("TREND vs previous run ($($Trend.PrevDate)): warnings=$(& $fmtD $d.Warnings) scriptWarnings=$(& $fmtD $d.ScriptWarnings) hardErrors=$(& $fmtD $d.Errors) uniqueIPs=$(& $fmtD $d.UniqueIPs) playerSessions=$(& $fmtD $d.PlayerSessions)")
        if (@($Trend.NewSignatures).Count -gt 0) {
            $null = $sb.AppendLine("NEW SIGNATURES this run (not seen before): " + ((@($Trend.NewSignatures) | Select-Object -First 20) -join ' ; '))
        } else {
            $null = $sb.AppendLine("NEW SIGNATURES this run: none")
        }
    }

    $emit = {
        param($title, $list)
        $null = $sb.AppendLine("")
        $null = $sb.AppendLine("$title (unique signatures x count):")
        if (@($list).Count -eq 0) { $null = $sb.AppendLine("  (none)") }
        foreach ($s in $list) {
            $mapTop = ''
            if ($s.PSObject.Properties['Maps'] -and $s.Maps.Count -gt 0) {
                $mk = ($s.Maps.GetEnumerator() | Sort-Object Value -Descending | Select-Object -First 1)
                $mapTop = "  {on $($mk.Key)}"
            }
            $null = $sb.AppendLine(("  [{0,4}x] {1}{2}" -f $s.Count, $s.Signature, $mapTop))
        }
    }
    & $emit 'HARD ERRORS'                 $Digest.Errors
    & $emit 'SCRIPT WARNINGS (AccessedNone etc.)' $Digest.ScriptWarnings
    & $emit 'WARNINGS'                    $Digest.Warnings
    & $emit 'ANTI-CHEAT / INTEGRITY'      $Digest.AntiCheat
    & $emit 'PACKAGE / VERSION'           $Digest.PackageIssues
    return $sb.ToString()
}

function Invoke-ServerLogAnalysis {
    param(
        [Parameter(Mandatory)] $Digest,
        [Parameter(Mandatory)] [string] $ApiKey,
        [AllowNull()] $Trend,
        [string] $Model     = 'claude-sonnet-4-6',
        [int]    $MaxTokens = 8192
    )

    $digestText = ConvertTo-DigestText $Digest $Trend

    $systemPrompt = @"
You are a senior Unreal Tournament 1999 (UT99, v469/469e) dedicated-server administrator
and UnrealScript engineer. You are reviewing a DIGEST of a server log from an FMJ
all-weapons DeathMatch server running OldUnreal 469e with InstaGibPlus (IG+), ACE
anti-cheat, Nexgen, and related mutators.

The digest already contains deduplicated issue signatures with occurrence counts, a tag
histogram, session facts, and network counters. Your job: interpret it for the admin.

For EACH distinct problem, anomaly, or noteworthy pattern, produce a finding with:
- severity: one of Critical, High, Medium, Low
- category: short label (e.g. "Script Error", "Missing Content", "Network", "Anti-Cheat",
  "Map Issue", "Config", "Performance")
- title: concise problem statement
- evidence: the signature(s)/counts it is based on
- count: total occurrences (int, 0 if unknown)
- root_cause: the most likely underlying cause, in UT99/OldUnreal terms
- solution: a concrete, actionable fix the admin can apply

Guidance specific to this stack:
- "Accessed None" ScriptWarnings are usually benign per-frame null-deref noise from a
  specific mutator/class; identify the offending package.class.function and say whether it
  is cosmetic or a real bug, and how to reduce it.
- "Failed to load Texture/Object not found" for skins are missing client/player content
  (custom skins) - harmless to the server but note them.
- Broken movers / FixUpMoversBoundingBox are map-authoring issues in specific maps. The
  digest includes ISSUES BY MAP and a {on <map>} tag per signature - name the specific
  offending map(s) in your finding when the attribution is available.
- Interpret network counters for connection stability. Note the distinction between raw
  connectionOpens (includes server-browser pings) and playerSessions (actual joined players);
  comment on peakConcurrentPlayers and any reconnect churn.
- Flag any genuine anti-cheat/integrity events (ACE/IG+ kicks, mismatches) as High+.
- If a TREND section is present, comment on notable changes vs the previous run and call out
  any NEW SIGNATURES explicitly (a brand-new error type after an update deserves attention).
- Do NOT invent problems that are not supported by the digest. If the log is healthy, say so.

Rate overall severity conservatively. Order findings most-severe first.

Output ONLY a single JSON object, no prose, no markdown fences. Schema:
{
  "summary": "3-5 sentence plain-English overview of server health this session",
  "overall_status": "Healthy | Minor Issues | Needs Attention | Critical",
  "findings": [
    {"severity":"Medium","category":"Script Error","title":"...","evidence":"...",
     "count":0,"root_cause":"...","solution":"..."}
  ],
  "network_assessment": "1-3 sentences on connection stability",
  "anticheat_assessment": "1-3 sentences on ACE/IG+/integrity",
  "recommendations": ["actionable item", "actionable item"]
}
If a section has nothing, use an empty array or a short 'nothing notable' string.
"@

    $userPrompt = "Analyze this UT99 server-log digest and return only the JSON.`n`n$digestText"

    $body = @{
        model      = $Model
        max_tokens = $MaxTokens
        system     = $systemPrompt
        messages   = @(@{ role = 'user'; content = $userPrompt })
    } | ConvertTo-Json -Depth 12 -Compress

    Write-RunLog INFO ("Calling Anthropic API ({0})..." -f $Model)

    $headers = @{ 'x-api-key' = $ApiKey; 'anthropic-version' = '2023-06-01' }
    $response = Invoke-RestMethod -Uri 'https://api.anthropic.com/v1/messages' `
        -Method Post -Headers $headers -Body $body -ContentType 'application/json; charset=utf-8'

    $text = $response.content[0].text
    $text = $text -replace '(?s)^\s*```(?:json)?\s*', '' -replace '(?s)\s*```\s*$', ''
    try {
        return ($text | ConvertFrom-Json)
    } catch {
        Write-RunLog ERROR "Failed to parse Claude response as JSON. Raw text saved to State."
        $rawPath = Join-Path $StateFolder ("api-raw-{0}.txt" -f (Get-Date -Format 'yyyy-MM-dd-HHmmss'))
        Set-Content -Path $rawPath -Value $text -Encoding UTF8
        throw
    }
}

# ========================================================================== #
#  Step 4 - Obsidian markdown report                                          #
# ========================================================================== #

function Format-MdCell { param([string]$Text)
    if ($null -eq $Text) { return '' }
    return ($Text -replace '\r?\n', ' ' -replace '\|', '\|').Trim()
}

function New-ServerLogReport {
    param(
        [Parameter(Mandatory)] $Analysis,
        [Parameter(Mandatory)] $Digest,
        [Parameter(Mandatory)] [datetime] $ReportDate,
        [Parameter(Mandatory)] [string] $OutPath,
        [AllowNull()] $Trend
    )

    $sevOrder = @{ Critical = 0; High = 1; Medium = 2; Low = 3 }
    $sevCallout = @{ Critical = 'danger'; High = 'bug'; Medium = 'warning'; Low = 'note' }

    # Render a trend delta as a compact arrow suffix, e.g. "  (▲ +12 vs 08-01)".
    $deltaTag = {
        param($v)
        if ($null -eq $v) { return '' }
        $iv = [int]$v
        if ($iv -gt 0)     { return " (▲ +$iv)" }
        elseif ($iv -lt 0) { return " (▼ $iv)" }
        else               { return ' (– 0)' }
    }

    $sb = [System.Text.StringBuilder]::new()
    $A = "`n"

    # --- YAML frontmatter ---
    $status = if ($Analysis.overall_status) { $Analysis.overall_status } else { 'Unknown' }
    $null = $sb.Append('---'+$A)
    $null = $sb.Append('title: "FMJ Server Log Analysis ' + $ReportDate.ToString('yyyy-MM-dd') + '"'+$A)
    $null = $sb.Append('server: FMJ'+$A)
    $null = $sb.Append('date: ' + $ReportDate.ToString('yyyy-MM-dd') + $A)
    $null = $sb.Append('engine: "' + $Digest.EngineVersion + '"'+$A)
    $null = $sb.Append('source_log: "' + (Split-Path $Digest.LogPath -Leaf) + '"'+$A)
    $null = $sb.Append('log_first_entry: "' + $Digest.FirstEntryText + '"'+$A)
    $null = $sb.Append('log_last_entry: "' + $Digest.LastEntryText + '"'+$A)
    $null = $sb.Append('generated: ' + (Get-Date).ToString('yyyy-MM-dd HH:mm') + $A)
    $null = $sb.Append('overall_status: "' + $status + '"'+$A)
    $null = $sb.Append('tags: [ut99, server-log, fmj]'+$A)
    $null = $sb.Append('---'+$A+$A)

    $null = $sb.Append('# FMJ Server Log Analysis — ' + $ReportDate.ToString('dddd, dd MMMM yyyy') + $A+$A)

    # --- Log coverage window (first/last timestamped entry in the log) ---
    if ($Digest.FirstEntry -and $Digest.LastEntry) {
        $null = $sb.Append('**Log covers:** ' + $Digest.FirstEntry.ToString('ddd dd MMM yyyy HH:mm:ss') +
                           '  →  ' + $Digest.LastEntry.ToString('ddd dd MMM yyyy HH:mm:ss') +
                           '   (' + $Digest.SpanText + ')' + $A+$A)
    } else {
        $null = $sb.Append('**Log covers:** _no timestamped entries found_' + $A+$A)
    }

    # --- Executive summary callout ---
    $statusCallout = switch ($status) {
        'Healthy'        { 'success' }
        'Minor Issues'   { 'info' }
        'Needs Attention'{ 'warning' }
        'Critical'       { 'danger' }
        default          { 'info' }
    }
    $summary = if ($Analysis.summary) { $Analysis.summary } else { '(no summary)' }
    $null = $sb.Append('> [!' + $statusCallout + '] Overall status: ' + $status + $A)
    foreach ($ln in ($summary -split '\r?\n')) { $null = $sb.Append('> ' + $ln + $A) }
    $null = $sb.Append($A)

    # --- Health dashboard ---
    $n = $Digest.Network
    $td = if ($Trend -and $Trend.HasHistory) { $Trend.Deltas } else { $null }
    $vsLabel = if ($td) { ' (Δ vs ' + $Trend.PrevDate + ')' } else { '' }
    $null = $sb.Append('## Health Dashboard'+$A+$A)
    $null = $sb.Append('| Metric | Value' + $vsLabel + ' |'+$A+'|---|---|'+$A)
    $null = $sb.Append('| Log session opened | ' + (Format-MdCell $Digest.LogOpen) + ' |'+$A)
    $null = $sb.Append('| Log session closed | ' + (Format-MdCell $Digest.LogClosed) + ' |'+$A)
    $null = $sb.Append('| First log entry | ' + (Format-MdCell $Digest.FirstEntryText) + ' |'+$A)
    $null = $sb.Append('| Last log entry | ' + (Format-MdCell $Digest.LastEntryText) + ' |'+$A)
    $null = $sb.Append('| Log covers | ' + (Format-MdCell $Digest.SpanText) + ' |'+$A)
    $null = $sb.Append('| Log lines | ' + $Digest.LineCount + ' |'+$A)
    $null = $sb.Append('| Maps played | ' + $Digest.Maps.Count + ' |'+$A)
    $null = $sb.Append('| Connection attempts (open / close) | ' + $n.Opens + ' / ' + $n.Closes + ' |'+$A)
    $null = $sb.Append('| Player connects (incl. map reloads) | ' + $n.PlayerSessions + (& $deltaTag ($td ? $td.PlayerSessions : $null)) + ' |'+$A)
    $null = $sb.Append('| Unique players | ' + $n.UniquePlayers + ' |'+$A)
    $null = $sb.Append('| Peak concurrent players | ' + $n.PeakConcurrent + ' |'+$A)
    $null = $sb.Append('| Unique client IPs | ' + $n.UniqueIPs + (& $deltaTag ($td ? $td.UniqueIPs : $null)) + ' |'+$A)
    $null = $sb.Append('| Hard errors | ' + ([int]$Digest.ErrorTotal) + (& $deltaTag ($td ? $td.Errors : $null)) + ' |'+$A)
    $null = $sb.Append('| Warnings | ' + ([int]$Digest.WarningTotal) + (& $deltaTag ($td ? $td.Warnings : $null)) + ' |'+$A)
    $null = $sb.Append('| Script warnings (Accessed None etc.) | ' + ([int]$Digest.SWTotal) + (& $deltaTag ($td ? $td.ScriptWarnings : $null)) + ' |'+$A)
    $null = $sb.Append($A)

    # --- Changes since last run (Feature 1) ---
    $null = $sb.Append('## Changes Since Last Run'+$A+$A)
    if (-not ($Trend -and $Trend.HasHistory)) {
        $null = $sb.Append('> [!note] No prior run on record — this is the first analyzed session, so there is nothing to compare yet.'+$A+$A)
    } else {
        $newS = @($Trend.NewSignatures); $resS = @($Trend.ResolvedSignatures)
        if ($newS.Count -eq 0 -and $resS.Count -eq 0) {
            $null = $sb.Append('> [!success] No new or resolved issue signatures since **' + $Trend.PrevDate + '** — the issue profile is stable.'+$A+$A)
        }
        if ($newS.Count -gt 0) {
            $null = $sb.Append('> [!warning] **' + $newS.Count + ' new issue signature(s)** not seen in prior runs:'+$A)
            foreach ($s in $newS) { $null = $sb.Append('> - `' + (Format-MdCell $s) + '`'+$A) }
            $null = $sb.Append($A)
        }
        if ($resS.Count -gt 0) {
            $null = $sb.Append('> [!success] **' + $resS.Count + ' signature(s) resolved** since ' + $Trend.PrevDate + ' (present then, absent now):'+$A)
            foreach ($s in $resS) { $null = $sb.Append('> - `' + (Format-MdCell $s) + '`'+$A) }
            $null = $sb.Append($A)
        }
    }

    # --- Findings ---
    $null = $sb.Append('## Findings'+$A+$A)
    $findings = @($Analysis.findings)
    if ($findings.Count -eq 0) {
        $null = $sb.Append('> [!success] No issues were flagged for this session.'+$A+$A)
    } else {
        $sorted = $findings | Sort-Object @{ Expression = { $so = $sevOrder[[string]$_.severity]; if ($null -eq $so) { 9 } else { $so } } }, @{ Expression = { -1 * [int]$_.count } }
        $i = 0
        foreach ($f in $sorted) {
            $i++
            $sev = [string]$f.severity
            $co  = $sevCallout[$sev]; if (-not $co) { $co = 'note' }
            $cat = if ($f.category) { " · $($f.category)" } else { '' }
            $cnt = if ([int]$f.count -gt 0) { " · ×$([int]$f.count)" } else { '' }
            $null = $sb.Append('### ' + $i + '. ' + $f.title + $A+$A)
            $null = $sb.Append('> [!' + $co + '] ' + $sev.ToUpper() + $cat + $cnt + $A)
            if ($f.evidence)   { $null = $sb.Append('> **Evidence:** ' + (Format-MdCell ([string]$f.evidence)) + $A) }
            if ($f.root_cause) { $null = $sb.Append('> **Root cause:** ' + (Format-MdCell ([string]$f.root_cause)) + $A) }
            $null = $sb.Append($A)
            if ($f.solution) {
                $null = $sb.Append('> [!tip] Proposed solution'+$A)
                foreach ($ln in ([string]$f.solution -split '\r?\n')) { $null = $sb.Append('> ' + $ln + $A) }
                $null = $sb.Append($A)
            }
        }
    }

    # --- Network & players ---
    $null = $sb.Append('## Players & Connections'+$A+$A)
    $null = $sb.Append('> [!info] ' + (Format-MdCell ([string]$Analysis.network_assessment)) + $A+$A)
    $null = $sb.Append('- Connection attempts (open / close): **' + $n.Opens + ' / ' + $n.Closes + '**  _(includes server-browser pings)_'+$A)
    $null = $sb.Append('- Player connects: **' + $n.PlayerSessions + '** across **' + $n.UniquePlayers + '** unique players over **' + $Digest.MapRounds + '** map rounds'+$A)
    $null = $sb.Append('- Peak concurrent players: **' + $n.PeakConcurrent + '**'+$A)
    $null = $sb.Append('- Unique client IPs: **' + $n.UniqueIPs + '**'+$A)
    $null = $sb.Append('- Timeout lines: **' + $n.Timeouts + '**, disconnect lines: **' + $n.Disconnects + '**'+$A+$A)
    $null = $sb.Append('> [!note] In UT99 each map change makes clients reconnect, so a **connect** counts every (re)join — a fresh connect on every map travel, plus any mid-game rejoins. A player present all evening therefore racks up many connects. "Total time" is the meaningful engagement measure; a high connect count with normal session length is healthy, not churn.'+$A+$A)

    $players = @($Digest.Players)
    if ($players.Count -gt 0) {
        $fmtDur = { param($sec) $s=[int]$sec; if ($s -ge 3600) { '{0}h{1:d2}m' -f [int]($s/3600), [int](($s%3600)/60) } elseif ($s -ge 60) { '{0}m{1:d2}s' -f [int]($s/60), ($s%60) } else { "${s}s" } }
        $null = $sb.Append('| Player | Connects | Avg session | Total time | IPs | First seen |'+$A+'|---|--:|--:|--:|--:|---|'+$A)
        foreach ($p in ($players | Select-Object -First 30)) {
            $first = if ($p.First) { ([datetime]$p.First).ToString('HH:mm') } else { '' }
            $null = $sb.Append('| ' + (Format-MdCell $p.Name) + ' | ' + $p.Joins + ' | ' + (& $fmtDur $p.AvgSec) + ' | ' + (& $fmtDur $p.TotalSec) + ' | ' + $p.IPs + ' | ' + $first + ' |'+$A)
        }
        $null = $sb.Append($A)
        # Real churn = many connects with consistently SHORT stays (rapid connect/drop),
        # not just a high connect count (that is normal map-travel over a long session).
        $churny = @($players | Where-Object { $_.Joins -ge 5 -and $_.AvgSec -lt 60 })
        if ($churny.Count -gt 0) {
            $null = $sb.Append('> [!warning] Possible connect/disconnect churn (many short sessions): ' + (($churny | ForEach-Object { '**' + (Format-MdCell $_.Name) + '** (' + $_.Joins + '× avg ' + (& $fmtDur $_.AvgSec) + ')' }) -join ', ') + ' — rapid rejoins with short stays can indicate an unstable link, a failing content download, or a client crash loop.'+$A+$A)
        }
    } else {
        $null = $sb.Append('_No named player connects were parsed (NPLoader join lines not found in this log)._'+$A+$A)
    }

    # --- Issues by map (Feature 2) ---
    $null = $sb.Append('## Issues by Map'+$A+$A)
    $mi = @($Digest.MapIssues)
    if ($mi.Count -gt 0) {
        $null = $sb.Append('| Map | Warnings | Script warnings | Errors |'+$A+'|---|--:|--:|--:|'+$A)
        foreach ($m in $mi) {
            $null = $sb.Append('| ' + (Format-MdCell $m.Map) + ' | ' + $m.Warnings + ' | ' + $m.ScriptWarnings + ' | ' + $m.Errors + ' |'+$A)
        }
        $null = $sb.Append($A + '_Attribution is by the map active when each line was logged; `(startup)` covers engine/package load before the first map._'+$A+$A)
    } else {
        $null = $sb.Append('_No map-attributable issues._'+$A+$A)
    }

    $null = $sb.Append('## Anti-Cheat / Integrity'+$A+$A)
    $null = $sb.Append('> [!info] ' + (Format-MdCell ([string]$Analysis.anticheat_assessment)) + $A+$A)
    if (@($Digest.AntiCheat).Count -gt 0) {
        $null = $sb.Append('| Count | Signature |'+$A+'|--:|---|'+$A)
        foreach ($s in $Digest.AntiCheat) { $null = $sb.Append('| ' + $s.Count + ' | ' + (Format-MdCell $s.Signature) + ' |'+$A) }
        $null = $sb.Append($A)
    } else {
        $null = $sb.Append('_No anti-cheat/integrity anomalies detected in the digest._'+$A+$A)
    }

    # --- Session & config overview ---
    $null = $sb.Append('## Session & Config Overview'+$A+$A)
    $null = $sb.Append('- **Engine:** ' + $Digest.EngineVersion + $A)
    $null = $sb.Append('- **Base directory:** `' + $Digest.BaseDir + '`'+$A)
    $null = $sb.Append('- **Maps played (' + $Digest.Maps.Count + '):** ' + (($Digest.Maps | ForEach-Object { '`' + $_ + '`' }) -join ', ') + $A)
    $null = $sb.Append('- **Mutators:** ' + (($Digest.Mutators | ForEach-Object { '`' + $_ + '`' }) -join ', ') + $A)
    $null = $sb.Append('- **Server packages:** ' + (($Digest.ServerPackages | ForEach-Object { '`' + $_ + '`' }) -join ', ') + $A+$A)

    # --- Recurring script warnings ---
    $null = $sb.Append('## Recurring Script Warnings'+$A+$A)
    if (@($Digest.ScriptWarnings).Count -gt 0) {
        $null = $sb.Append('| Count | Signature |'+$A+'|--:|---|'+$A)
        foreach ($s in $Digest.ScriptWarnings) { $null = $sb.Append('| ' + $s.Count + ' | ' + (Format-MdCell $s.Signature) + ' |'+$A) }
        $null = $sb.Append($A)
    } else { $null = $sb.Append('_None._'+$A+$A) }

    # --- Recurring warnings ---
    $null = $sb.Append('## Recurring Warnings'+$A+$A)
    if (@($Digest.Warnings).Count -gt 0) {
        $null = $sb.Append('| Count | Signature |'+$A+'|--:|---|'+$A)
        foreach ($s in $Digest.Warnings) { $null = $sb.Append('| ' + $s.Count + ' | ' + (Format-MdCell $s.Signature) + ' |'+$A) }
        $null = $sb.Append($A)
    } else { $null = $sb.Append('_None._'+$A+$A) }

    # --- Failed-to-load offenders (verbatim names, all of them) ---
    $null = $sb.Append('## Failed-to-Load Offenders'+$A+$A)
    if (@($Digest.FailedLoads).Count -gt 0) {
        $null = $sb.Append('| Count | Message |'+$A+'|--:|---|'+$A)
        foreach ($s in $Digest.FailedLoads) { $null = $sb.Append('| ' + $s.Count + ' | ' + (Format-MdCell $s.Signature) + ' |'+$A) }
        $null = $sb.Append($A)
    } else { $null = $sb.Append('_None._'+$A+$A) }

    # --- Recommendations checklist ---
    $null = $sb.Append('## Recommendations'+$A+$A)
    $recs = @($Analysis.recommendations)
    if ($recs.Count -eq 0) {
        $null = $sb.Append('- [ ] No action required.'+$A+$A)
    } else {
        foreach ($r in $recs) { $null = $sb.Append('- [ ] ' + (Format-MdCell ([string]$r)) + $A) }
        $null = $sb.Append($A)
    }

    # --- Appendix: raw tallies ---
    $null = $sb.Append('> [!note]- Appendix — raw signature tallies & tag histogram'+$A)
    $null = $sb.Append('> **Tag histogram:** ' + (($Digest.TagHistogram.GetEnumerator() | ForEach-Object { "$($_.Key)=$($_.Value)" }) -join ', ') + $A)
    $appendix = {
        param($title, $list)
        $null = $sb.Append('> '+$A+'> **' + $title + '**'+$A)
        if (@($list).Count -eq 0) { $null = $sb.Append('> - (none)'+$A); return }
        foreach ($s in $list) { $null = $sb.Append('> - `' + $s.Count + 'x` ' + (Format-MdCell $s.Signature) + $A) }
    }
    & $appendix 'Hard errors'      $Digest.Errors
    & $appendix 'Package/version'  $Digest.PackageIssues
    $null = $sb.Append($A)
    $null = $sb.Append('---'+$A)
    $null = $sb.Append('*Generated by UT99 ServerLog Analyzer on ' + (Get-Date).ToString('yyyy-MM-dd HH:mm') + '.*'+$A)

    Set-Content -LiteralPath $OutPath -Value $sb.ToString() -Encoding UTF8
}

# ========================================================================== #
#  Main                                                                       #
# ========================================================================== #

try {
    # 1. Fetch (unless -NoFetch), then decide which local log to analyze.
    $staged = Invoke-ServerFetch

    if ($LogFile) {
        if (-not (Test-Path $LogFile)) { throw "Specified -LogFile not found: $LogFile" }
        $sourceLog = $LogFile
        Write-RunLog INFO "Analyzing specified log: $sourceLog"
    }
    elseif ($staged) {
        # Name the downloaded log by its session date (matches existing convention).
        $sessionDate = if ($Date) { $Date } else { Get-LogSessionDate -Path $staged }
        if (-not $sessionDate) { $sessionDate = Get-Date }
        $finalName = $Config.LocalLogNamePattern -replace '\{date\}', $sessionDate.ToString('yyyy-MM-dd')
        $sourceLog = Join-Path $LogFolder $finalName
        Move-Item -LiteralPath $staged -Destination $sourceLog -Force
        Remove-Item -LiteralPath (Split-Path $staged -Parent) -Recurse -Force -ErrorAction SilentlyContinue
        Write-RunLog INFO "Saved downloaded log as: $sourceLog"
    }
    else {
        throw "Nothing to analyze: -NoFetch was set but no -LogFile was provided."
    }

    # 2. Deterministic digest.
    Write-RunLog INFO "Scanning log into digest..."
    $digest = Get-ServerLogDigest -Path $sourceLog -TopN ([int]$Config.MaxSignaturesPerBucket)
    Write-RunLog INFO ("Digest: {0} lines, {1} warnings, {2} script warnings, {3} hard errors, {4} unique IPs." -f `
        $digest.LineCount, [int]$digest.WarningTotal, [int]$digest.SWTotal, [int]$digest.ErrorTotal, $digest.Network.UniqueIPs)

    # Report date: -Date > log session date > today.
    $reportDate = if ($Date) { $Date }
                  elseif ($digest.LogOpen -and ($sd = Get-LogSessionDate -Path $sourceLog)) { $sd }
                  else { Get-Date }

    # 2.5 Trend vs history (Feature 1) - computed before analysis so the model sees it.
    $historyPath = Join-Path $StateFolder 'digest-history.json'
    $trend = Get-Trend -Digest $digest -HistoryPath $historyPath -ReportDate $reportDate
    if ($trend.HasHistory) {
        Write-RunLog INFO ("Trend vs {0}: warnings {1:+#;-#;0}, scriptWarnings {2:+#;-#;0}, hardErrors {3:+#;-#;0}; {4} new signature(s)." -f `
            $trend.PrevDate, $trend.Deltas.Warnings, $trend.Deltas.ScriptWarnings, $trend.Deltas.Errors, @($trend.NewSignatures).Count)
    } else {
        Write-RunLog INFO "No prior history - first analyzed session."
    }

    # 3. Analysis.
    if ($NoAnalysis) {
        Write-RunLog INFO "Skipping Claude analysis (-NoAnalysis)."
        $analysis = [pscustomobject]@{
            summary              = '(Analysis skipped — running in -NoAnalysis mode. Deterministic tallies only.)'
            overall_status       = 'Unknown'
            findings             = @()
            network_assessment   = 'Not analyzed.'
            anticheat_assessment = 'Not analyzed.'
            recommendations      = @()
        }
    } else {
        # Prefer the process env var; fall back to the User-scoped value in case
        # this is running under a scheduled S4U logon that didn't inherit it.
        $apiKey = $env:ANTHROPIC_API_KEY
        if (-not $apiKey) { $apiKey = [Environment]::GetEnvironmentVariable('ANTHROPIC_API_KEY', 'User') }
        if (-not $apiKey) { throw "ANTHROPIC_API_KEY environment variable is not set. Run Setup.ps1 to configure it." }
        $analysis = Invoke-ServerLogAnalysis -Digest $digest -ApiKey $apiKey -Trend $trend -Model $Config.ApiModel -MaxTokens $Config.ApiMaxTokens
    }

    # 4. Report.
    $reportName = $Config.ReportNamePattern -replace '\{date\}', $reportDate.ToString('yyyy-MM-dd')
    $reportPath = Join-Path $LogFolder $reportName
    New-ServerLogReport -Analysis $analysis -Digest $digest -ReportDate $reportDate -OutPath $reportPath -Trend $trend
    Write-RunLog INFO "Report written: $reportPath"

    # 4b. Persist this run into the trend history (after a successful report).
    Save-DigestHistory -Digest $digest -Trend $trend -HistoryPath $historyPath -ReportDate $reportDate
    Write-RunLog INFO "Trend history updated: $historyPath"

    # 5. State.
    $stateFile = Join-Path $StateFolder 'last-run.json'
    @{
        last_run_utc     = (Get-Date).ToUniversalTime().ToString('o')
        source_log       = $sourceLog
        report_path      = $reportPath
        line_count       = $digest.LineCount
        warnings         = [int]$digest.WarningTotal
        script_warnings  = [int]$digest.SWTotal
        hard_errors      = [int]$digest.ErrorTotal
        unique_ips       = $digest.Network.UniqueIPs
        player_sessions  = [int]$digest.Network.PlayerSessions
        unique_players   = [int]$digest.Network.UniquePlayers
        peak_concurrent  = [int]$digest.Network.PeakConcurrent
        new_signatures   = @($trend.NewSignatures).Count
    } | ConvertTo-Json | Set-Content -Path $stateFile -Encoding UTF8

    # 6. Open if interactive.
    $isInteractive = ([Environment]::UserInteractive) -and ($Host.Name -ne 'ServerRemoteHost')
    if ($isInteractive -and $Config.OpenReportOnInteractiveRun) {
        try { Start-Process $reportPath } catch {}
    }

    Write-RunLog INFO ("Done. Elapsed: {0:N1}s" -f ((Get-Date) - $RunStarted).TotalSeconds)
    Write-RunLog INFO ("Report: $reportPath")

} catch {
    Write-RunLog ERROR ("FATAL: {0}" -f $_.Exception.Message)
    Write-RunLog ERROR ($_.ScriptStackTrace)
    exit 1
}
