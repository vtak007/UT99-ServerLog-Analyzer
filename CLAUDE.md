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

- Downloaded raw log: `D:\Dropbox\Gaming\UTLogs\ServerLogs\Raw Server Logs\server.yyyymmdd_hhmm.log`
  (original server-side name, kept as-is — see Design notes below).
- Report: `D:\Dropbox\Gaming\UTLogs\ServerLogs\FMJ Server Log Analysis <date>.md`

Report/log date = the log's own "Log file open" session date (falls back to today), so a
morning run over the previous night's rotated log is named for the session it covers.

## Design notes

- **Remote log is timestamped, not fixed-name:** each server start rotates the previous log to
  `/Logs/server.yyyymmdd_hhmm.log` and old ones accumulate. Config exposes `RemoteLogFolder` +
  `RemoteLogMask` (`server.*.log`); `Invoke-ServerFetch` uses WinSCP `get -latest` to download
  straight into `RawLogFolder` (`ServerLogs\Raw Server Logs\`, config key `RawLogSubfolder`),
  keeping the file's original server-side name — no rename, no staging folder. That folder is a
  **permanent, never-wiped archive**: the newest-by-name match after each fetch is always the
  file just downloaded, because the `yyyymmdd_hhmm` naming sorts lexicographically = chronologically
  and WinSCP's `-latest` guarantees the newest remote file is always >= anything already archived.
- **Log coverage window:** the digest scans every timestamp format the log actually contains
  (`Log file open`, `NetComeGo`, MapVote `yyyy/MM/dd Time >`, ACE `[TIME] dd-MM-yyyy`, day-first)
  and min/max's them into `FirstEntry`/`LastEntry`/`SpanText`. Rotated logs have **no**
  `Log file closed` marker, so `Digest.LogClosed` is normally empty — it is still collected but
  no longer rendered (the dashboard row was dropped); use First/Last as the coverage window.
- **Bounded digest:** `Get-ServerLogDigest` deduplicates issue lines into signatures with
  counts (top-N per bucket via `MaxSignaturesPerBucket`). Only the digest — never the raw
  11k+ lines — is sent to the API, so token cost stays flat regardless of log size.
- **Buckets:** hard errors, `Warning:`, `ScriptWarning:`/Accessed None (grouped by
  `package.class.function` + offending variable), anti-cheat/integrity (UTPure/IGPlus/NSC),
  package/version. Plus a tag histogram and network counters (opens/closes/unique IPs/timeouts).
- `DeleteAfterDownload` is `$false` — never delete the server's own rotated logs.
- Player IPs (PII) are counted, not sent verbatim to the API.
- **Markdown table rendering (`Format-MdCell` + the Players & Connections table builder):**
  cells are padded to a per-column max width so the raw `.md` source is visually column-aligned
  even without a markdown previewer (VS Code raw view, etc.), not just when rendered. A literal
  `|` in a player name is replaced with the look-alike `¦` (not backslash-escaped `\|`) because
  some renderers (Obsidian) don't reliably honor `\|` escaping inside table cells and will still
  split the column on it — `¦` can never be mistaken for a column separator, in source or render.
