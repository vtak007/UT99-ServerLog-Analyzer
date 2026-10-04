# UT99 ServerLog Analyzer

Automatically downloads the FMJ UT99 server's previous-session log (`/System/server-old.log`) via WinSCP,
analyzes it for issues, anomalies, and problems using the Anthropic API, and writes a clean,
professional **Obsidian-flavored markdown report** — with severity-ranked findings, root
causes, and proposed solutions.

Built to run unattended on a daily schedule, or on demand from a PowerShell prompt. Modeled on
the sibling **UT99 ChatLog Analyzer** (same WinSCP saved-session + Anthropic API patterns).

---

## What it produces

Each run writes two files to `D:\Dropbox\Gaming\UTLogs\ServerLogs`:

- `Raw Server Logs\server.yyyymmdd_hhmm.log` — the downloaded log, archived under its
  original server-side name (kept separate from the reports below).
- `FMJ Server Log Analysis <date>.md` — the report.

The report contains:

- **YAML frontmatter** (status, engine, date, first/last log entry, tags) for Obsidian. The
  coverage window's endpoints live here — `log_first_entry` / `log_last_entry` — and only the
  elapsed span is repeated in the dashboard.
- **Executive summary** and an overall status callout (Healthy / Minor Issues / Needs Attention / Critical).
- **Health Dashboard** with day-over-day deltas, opening with a `Log covers` span row.
- **Changes Since Last Run** — brand-new and resolved issue signatures.
- **Findings** — severity-ranked (`Critical`/`High`/`Medium`/`Low`), each with evidence,
  root cause, and a proposed solution, using Obsidian callouts. Two config lists drop findings
  from this section (and this section only — they can still surface in Recommendations):
  `SuppressedFindingsMaps` for chronic, already-known map-authoring issues, and
  `SuppressedFindingsPatterns` for whole topics, currently client-side skins.
- **Players & Connections** — per-player connects, session times, peak concurrent players, churn detection.
- **Issues by Map** — warnings/script-warnings/errors attributed to the map that caused them.
- **Anti-Cheat / Integrity** and the recurring-signature tables. `Failed to load` signatures are
  deliberately absent from Recurring Warnings — they belong to Failed-to-Load Offenders below,
  which shows the same events with real names instead of `<x>` placeholders; a pointer line says
  how many were moved.
- **Failed-to-Load Offenders** — every distinct `Failed to load "…"` message with its real
  package/object name kept verbatim (not bucketed to `<x>`) and an occurrence count, all
  offenders listed (uncapped). Surfaces exactly which packages/files the server is missing.
- **Recommendations** checklist and a collapsible raw-tally appendix.

Every table is written column-aligned in the raw markdown — cells padded to a per-column width —
so the `.md` reads as a table in a plain-text view, not only through a renderer.

---

## How it works

1. **Fetch** — WinSCP (`WinSCP.com`) opens the saved session and downloads `/System/server-old.log`
   (UT99 rotates `server.log` to `server-old.log` at **every** server restart, manual or NFO's, and
   overwrites the previous `server-old.log`). The copy is archived in `Raw Server Logs\` as
   `server.yyyymmdd_hhmm.log`, named from the log's own "Log file open" time, and an existing
   archive file is never overwritten. If that fetch fails, a normal run falls back to the legacy
   source (newest `/Logs/server.*.log`, NFO's timestamped copies). `FetchSource = 'RotatedLogs'`
   in `config.ps1` selects the legacy source only.
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
# Full run: download /System/server-old.log, archive it, analyze, write report.
.\"UT99 ServerLog Analyzer.ps1"

# Archive only: save server-old.log to the raw archive and exit (no analysis, no report).
# Run this after a MANUAL server restart, before NFO's next restart overwrites server-old.log.
.\"UT99 ServerLog Analyzer.ps1" -ArchiveOnly

# Offline parse test (no download, no API cost).
.\"UT99 ServerLog Analyzer.ps1" -NoFetch -NoAnalysis -LogFile "D:\Dropbox\Gaming\UTLogs\ServerLogs\Raw Server Logs\server.20260802_0330.log"

# Re-analyze a specific local log without touching the server.
.\"UT99 ServerLog Analyzer.ps1" -NoFetch -LogFile "<path to a .log>"
```

| Switch | Effect |
|---|---|
| `-ArchiveOnly` | Download and archive `server-old.log`, then exit (no digest, API call or report). |
| `-NoFetch` | Skip the server download (use with `-LogFile`). |
| `-NoAnalysis` | Skip the Claude API call (deterministic tallies only, no cost). |
| `-LogFile <path>` | Analyze a specific local log. |
| `-Date <yyyy-MM-dd>` | Force the report date (default: the log's own session date). |

> **Caution:** `-NoAnalysis` writes a real report file (just without the AI narrative) — if a
> log's session date already has a real analyzed report, running `-NoAnalysis` against it
> **overwrites that report with a no-analysis stub**. For smoke-testing changes, point
> `-LogFile` at a log whose date you don't mind clobbering, or re-run without `-NoAnalysis`
> afterward to restore it.

---

## Scheduling

```powershell
# Register the daily task (requires an ELEVATED / Run-as-Administrator PowerShell).
.\Register-DailyTask.ps1

# Remove it.
.\Register-DailyTask.ps1 -Unregister
```

The task runs **daily at 07:30** (NFO's nightly restart currently lands at ~07:00, rotating the
finished session into `server-old.log`). Run earlier and `server-old.log` is still the session
*before* the one that just ended, so reports lag a session behind.
It is registered to **run whether you are logged on or not**, with **highest privileges**
(S4U + RunLevel Highest) — which is why registration needs an elevated shell.

> **Keep the run and its retries off 05:00.** A separate "Daily Restart" task force-reboots the
> machine (`shutdown /r /f`) at 05:00 every 3 days and will kill the run mid-fetch. 07:30 and its
> 30-minute retry grid clear that.
>
> **Manual restarts:** a restart you do yourself also overwrites `server-old.log`, so a second
> restart (NFO's) before the analyzer runs destroys the first session's log. Run
> `-ArchiveOnly` between the two restarts to keep it. See `Capture Manual Restarts.md` for the
> idea of merging archived sessions into one report (not implemented).

If a run fails (server unreachable, no network, WinSCP login failure), Windows Task Scheduler
**retries every 30 minutes** (count set by `-RetryCount`) until it succeeds. If `server-old.log`
hasn't changed since the last run (no restart), the run log notes it and the report repeats that
session. This is implemented via restart-on-failure: the script exits non-zero on any
fetch failure.

Adjust with `-Time`, `-RetryIntervalMinutes`, and `-RetryCount`.

---

## Configuration

All settings live in `_system\config.ps1`. Key values:

| Setting | Default | Purpose |
|---|---|---|
| `WinSCPSessionName` | `FMJ FTP Server` | Saved WinSCP session name |
| `FetchSource` | `ServerOld` | `ServerOld` = fetch `RemoteLogPath`, fall back to the legacy source on failure; `RotatedLogs` = legacy only |
| `RemoteLogPath` | `/System/server-old.log` | UT99's previous-session log (overwritten at every restart) |
| `RemoteLogFolder` / `RemoteLogMask` | `/Logs/` / `server.*.log` | Legacy source: remote folder and mask; the **newest** match is downloaded |
| `DeleteAfterDownload` | `$false` | Never deletes the server's rotated logs |
| `LocalLogFolder` | `…\UTLogs\ServerLogs` | Where the report is written (and the parent of `RawLogSubfolder`) |
| `RawLogSubfolder` | `Raw Server Logs` | Subfolder (under `LocalLogFolder`) where raw logs are archived, kept separate from reports |
| `ApiModel` | `claude-sonnet-4-6` | Anthropic model |
| `MaxSignaturesPerBucket` | `25` | Caps digest size (token control) |
| `SuppressedFindingsMaps` | `CyberSpace`, `Temple[0O]fThe[wW]inds`, `CodexEvolved`, `AncientPhobos`, `DarkFortress` | Case-insensitive regex fragments; findings mentioning these maps are dropped from **Findings** (still shown in **Recommendations**) |

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
- Markdown tables (e.g. the Players & Connections table) are rendered with padded, column-aligned
  cells so the raw `.md` source lines up visually even without a markdown previewer. A literal
  `|` in a player name would otherwise break a table column; it's rendered as the look-alike
  character `¦` instead.
