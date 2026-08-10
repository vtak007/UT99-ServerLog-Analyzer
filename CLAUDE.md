# UT99 ServerLog Analyzer — Project Instructions

Downloads the FMJ server's newest rotated log (`/Logs/server.yyyymmdd_hhmm.log`) via WinSCP, analyzes it with the
Anthropic API, and writes a professional Obsidian markdown report. Modeled on the
sibling **UT99 ChatLog Analyzer** project (same WinSCP-session + API patterns).

## README auto-update

This project's README is `README.md` in the project root. Whenever changes are made to any
script or config file, check whether those changes affect the README and update it as part
of the same task (per global doc-update gating: after tested + approved).

## Key files

| File | Purpose |
|---|---|
| `_system\config.ps1` | All user-facing settings (WinSCP session, remote/local paths, API model) |
| `_system\Bin\UT99 ServerLog Analyzer.ps1` | Main pipeline: fetch → digest → AI analysis → Obsidian report |
| `_system\Bin\Setup.ps1` | One-time setup: folders, WinSCP/session check, API key, smoke test |
| `_system\Bin\Register-DailyTask.ps1` | Windows Task Scheduler registration |
| `_system\State\last-run.json` | Timestamp, paths, and counts from the last run |
| `_system\State\winscp-*.xml` | Per-fetch WinSCP session logs |
| `_system\Runlogs\run-*.log` | Per-run text logs |
| `README.md` (project root) | User documentation |

## Output locations (not in the project folder)

- Downloaded log: `D:\Dropbox\Gaming\UTLogs\ServerLogs\FMJ Server Log <date>.log`
- Report: `D:\Dropbox\Gaming\UTLogs\ServerLogs\FMJ Server Log Analysis <date>.md`

Report/log date = the log's own "Log file open" session date (falls back to today), so a
morning run over the previous night's rotated log is named for the session it covers.

## Design notes

- **Remote log is timestamped, not fixed-name:** each server start rotates the previous log to
  `/Logs/server.yyyymmdd_hhmm.log` and old ones accumulate. Config exposes `RemoteLogFolder` +
  `RemoteLogMask` (`server.*.log`); `Invoke-ServerFetch` uses WinSCP `get -latest` into a
  `_incoming` staging folder, then resolves the downloaded file (its remote name is unknown
  until it lands) and renames it by the log's session date.
- **Log coverage window:** the digest scans every timestamp format the log actually contains
  (`Log file open`, `NetComeGo`, MapVote `yyyy/MM/dd Time >`, ACE `[TIME] dd-MM-yyyy`, day-first)
  and min/max's them into `FirstEntry`/`LastEntry`/`SpanText`. Rotated logs have **no**
  `Log file closed` marker, so `Digest.LogClosed` is normally empty — use First/Last instead.
- **Bounded digest:** `Get-ServerLogDigest` deduplicates issue lines into signatures with
  counts (top-N per bucket via `MaxSignaturesPerBucket`). Only the digest — never the raw
  11k+ lines — is sent to the API, so token cost stays flat regardless of log size.
- **Buckets:** hard errors, `Warning:`, `ScriptWarning:`/Accessed None (grouped by
  `package.class.function` + offending variable), anti-cheat/integrity (UTPure/IGPlus/NSC),
  package/version. Plus a tag histogram and network counters (opens/closes/unique IPs/timeouts).
- `DeleteAfterDownload` is `$false` — never delete the server's own rotated logs.
- Player IPs (PII) are counted, not sent verbatim to the API.
