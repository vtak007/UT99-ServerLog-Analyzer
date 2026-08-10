# UT99 ServerLog Analyzer

Automatically downloads the FMJ UT99 server's newest rotated log (`/Logs/server.<timestamp>.log`) via WinSCP,
analyzes it for issues, anomalies, and problems using the Anthropic API, and writes a clean,
professional **Obsidian-flavored markdown report** — with severity-ranked findings, root
causes, and proposed solutions.

Built to run unattended on a daily schedule, or on demand from a PowerShell prompt. Modeled on
the sibling **UT99 ChatLog Analyzer** (same WinSCP saved-session + Anthropic API patterns).

---

## What it produces

Each run writes two files to `D:\Dropbox\Gaming\UTLogs\ServerLogs`:

- `FMJ Server Log <date>.log` — the downloaded log (named by its own session date).
- `FMJ Server Log Analysis <date>.md` — the report.

The report contains:

- **YAML frontmatter** (status, engine, date, first/last log entry, tags) for Obsidian.
- **Log coverage line** at the top — the first and last timestamped entry in the log and the
  elapsed span (e.g. `Sat 08 Aug 2026 04:35:19 → Sun 09 Aug 2026 01:19:55 (21h 44m)`).
- **Executive summary** and an overall status callout (Healthy / Minor Issues / Needs Attention / Critical).
- **Health Dashboard** with day-over-day deltas.
- **Changes Since Last Run** — brand-new and resolved issue signatures.
- **Findings** — severity-ranked (`Critical`/`High`/`Medium`/`Low`), each with evidence,
  root cause, and a proposed solution, using Obsidian callouts.
- **Players & Connections** — per-player connects, session times, peak concurrent players, churn detection.
- **Issues by Map** — warnings/script-warnings/errors attributed to the map that caused them.
- **Anti-Cheat / Integrity**, **Session & Config Overview**, recurring-signature tables.
- **Failed-to-Load Offenders** — every distinct `Failed to load "…"` message with its real
  package/object name kept verbatim (not bucketed to `<x>`) and an occurrence count, all
  offenders listed (uncapped). Surfaces exactly which packages/files the server is missing.
- **Recommendations** checklist and a collapsible raw-tally appendix.

---

## How it works

1. **Fetch** — WinSCP (`WinSCP.com`) opens the saved session and downloads the **newest** file
   matching `/Logs/server.*.log` (`get -latest`). Each server start rotates the previous log to
   `/Logs/server.yyyymmdd_hhmm.log`, and these accumulate, so the name isn't known in advance —
   the download is staged to a temp folder and then renamed by the log's own session date.
2. **Digest** — a deterministic regex pre-scan deduplicates issue lines into *signatures with
   counts* (top-N per bucket), plus a tag histogram, per-map attribution, and connection/player
   analytics. Only this bounded digest — never the raw log — is sent to the API, so token cost
   stays flat regardless of log size.
3. **Analyze** — the digest goes to Claude (`claude-sonnet-4-6`) for interpretation, severity
   rating, root causes, and solutions.
4. **Report** — results render to Obsidian markdown; trend history is saved for next time.

---

## Requirements

- **Windows** with **PowerShell 7** (`pwsh.exe`).
- **WinSCP 6.5+** with a saved session named `FMJ FTP Server` (shared with the ChatLog Analyzer).
- **`ANTHROPIC_API_KEY`** as a User environment variable.

---

## First-time setup

```powershell
cd "D:\Dropbox\Computing1\BatchFiles_Scripts\Claude Projects\UT99\UT99 ServerLog Analyzer\_system\Bin"
.\Setup.ps1
```

`Setup.ps1` creates folders, verifies WinSCP and the saved session, stores the API key, and
smoke-tests the API. (Optional if you already run the ChatLog Analyzer — the key and session
are shared.)

---

## Usage

```powershell
# Full run: download the newest /Logs/server.*.log, analyze, write report.
.\"UT99 ServerLog Analyzer.ps1"

# Offline parse test (no download, no API cost).
.\"UT99 ServerLog Analyzer.ps1" -NoFetch -NoAnalysis -LogFile "D:\Dropbox\Gaming\UTLogs\ServerLogs\FMJ Server Log 2026-08-02.log"

# Re-analyze a specific local log without touching the server.
.\"UT99 ServerLog Analyzer.ps1" -NoFetch -LogFile "<path to a .log>"
```

| Switch | Effect |
|---|---|
| `-NoFetch` | Skip the server download (use with `-LogFile`). |
| `-NoAnalysis` | Skip the Claude API call (deterministic tallies only, no cost). |
| `-LogFile <path>` | Analyze a specific local log. |
| `-Date <yyyy-MM-dd>` | Force the report date (default: the log's own session date). |

---

## Scheduling

```powershell
# Register the daily task (requires an ELEVATED / Run-as-Administrator PowerShell).
.\Register-DailyTask.ps1

# Remove it.
.\Register-DailyTask.ps1 -Unregister
```

The task runs **daily at 04:25** (the server boots between 02:00 and 05:00, creating the log).
It is registered to **run whether you are logged on or not**, with **highest privileges**
(S4U + RunLevel Highest) — which is why registration needs an elevated shell.

> **Do not move it to 05:00.** A separate "Daily Restart" task force-reboots the machine
> (`shutdown /r /f`) at 05:00 every 3 days and will kill the run mid-fetch. The retry grid must
> also miss 05:00, which is why the start time is 04:25 rather than 04:30.

If a run fails because no new log exists yet (server not booted) or there is no network,
Windows Task Scheduler **retries every 30 minutes, up to 3 times** (04:55 / 05:25 / 05:55),
until it succeeds. This is implemented via restart-on-failure: the script exits non-zero on any
fetch failure.

Adjust with `-Time`, `-RetryIntervalMinutes`, and `-RetryCount`.

---

## Configuration

All settings live in `_system\config.ps1`. Key values:

| Setting | Default | Purpose |
|---|---|---|
| `WinSCPSessionName` | `FMJ FTP Server` | Saved WinSCP session name |
| `RemoteLogFolder` / `RemoteLogMask` | `/Logs/` / `server.*.log` | Remote log folder and wildcard mask; the **newest** match is downloaded |
| `DeleteAfterDownload` | `$false` | Never deletes the server's rotated logs |
| `LocalLogFolder` | `…\UTLogs\ServerLogs` | Where the log **and** report are written |
| `ApiModel` | `claude-sonnet-4-6` | Anthropic model |
| `MaxSignaturesPerBucket` | `25` | Caps digest size (token control) |

---

## Key files

| File | Purpose |
|---|---|
| `_system\config.ps1` | All user-facing settings |
| `_system\Bin\UT99 ServerLog Analyzer.ps1` | Main pipeline: fetch → digest → analysis → report |
| `_system\Bin\Setup.ps1` | One-time setup / validation |
| `_system\Bin\Register-DailyTask.ps1` | Scheduled-task registration |
| `_system\State\digest-history.json` | Trend history (day-over-day diffing) |
| `_system\State\last-run.json` | Last-run metrics |
| `FUTURE-FEATURES.md` | Backlog of deferred enhancements (4–9) |

---

## Notes

- Player IP addresses (PII) appear in the downloaded log and the report, which stay local in
  Dropbox. The digest sent to the API includes IP *counts*, not raw IP lists.
- Token usage is bounded by the deduplicated digest, so even very large logs cost roughly the
  same to analyze.
