# UT99 ServerLog Analyzer

Automatically downloads the FMJ UT99 server's session logs (`/System/server-old.log` and the live
`/System/server.log`) via WinSCP,
analyzes the newest for issues, anomalies, and problems using the Anthropic API, and writes a clean,
professional **Obsidian-flavored markdown report** — with severity-ranked findings, root
causes, and proposed solutions.

Built to run unattended on a daily schedule, or on demand from a PowerShell prompt. Modeled on
the sibling **UT99 ChatLog Analyzer** (same WinSCP saved-session + Anthropic API patterns).

---

## What it produces

Each run writes to `D:\Dropbox\Gaming\UTLogs\ServerLogs`:

- `Raw Server Logs\server.yyyymmdd_hhmm.log` — one archive per server session, named from the
  log's own "Log file open" time (kept separate from the reports below). Both the previous and
  the live session log are fetched every run, so a run can archive more than one. A longer
  capture of a session that is still running supersedes the shorter one already archived. This
  folder is a **permanent archive** — nothing deletes from it.
- `FMJ Server Log Analysis <date>.md` — the report. One report per **day**: every archived
  session that opened on that date is merged into it, so a day with several restarts still
  produces a single report.

The report contains:

- **YAML frontmatter** (status, engine, date, first/last log entry, tags) for Obsidian. The
  coverage window's endpoints live here — `log_first_entry` / `log_last_entry` — and only the
  elapsed span is repeated in the dashboard.
- **Executive summary** and an overall status callout (Healthy / Minor Issues / Needs Attention / Critical).
- **Sessions** — one row per server session merged into the report (opened, last entry, length,
  players, maps, hard errors, warnings, script warnings). Omitted when the day held one session.
- **Shutdowns** — what ended before each server start in the report: when the server was down by,
  its last log activity, and the reason if one was logged. A shutdown caused from outside (NFO
  restart or control panel) logs no reason, so those rows read "No reason logged".
- **Health Dashboard** with day-over-day deltas, opening with a `Log covers` span row. Deltas are
  against the most recent **earlier** report, so re-running an old day still compares backwards.
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

1. **Fetch** — WinSCP (`WinSCP.com`) opens the saved session and downloads **both** session logs:
   `/System/server-old.log` (the previous, closed session — UT99 rotates `server.log` here at every
   restart, but it is **not reliably present**, so a failed fetch is only a warning) and
   `/System/server.log` (the live session, which exists whenever the server is running and is
   therefore the dependable source). Each copy is archived in `Raw Server Logs\` as
   `server.yyyymmdd_hhmm.log`, named from the log's own "Log file open" time. Archiving both means
   a session is never lost even when it isn't the one reported.

   **What gets reported** is then chosen from the archive, not from the download: every session
   that opened on the report date (default: yesterday, or `-Date`) is merged into one report, so a
   day with several restarts produces a single report with a **Sessions** row per session rather
   than one report per restart.

   If an archive for that session already exists, a **longer** fetched copy supersedes it (a
   growing capture of the same appended log is a strict superset); otherwise the existing archive
   is kept. `Raw Server Logs\` remains a permanent, never-wiped archive.

   Before the API call, a **duplicate-run guard** compares the session's "Log file open" time and
   line count against `last-run.json`; if both are unchanged the run exits 0 without analyzing or
   rewriting the report. `-Force` overrides it.
   > **Why both logs (2026-10-31):** `/System/server-old.log` was absent despite a 03:05 restart
   > that should have created it, and that session was lost for good. The old `/Logs/` fallback
   > then resolved the "fetched" file as the newest file already in `Raw Server Logs\`, so roughly
   > half the daily runs re-analyzed the previous session and rewrote an identical report at full
   > API cost. The `/Logs/` source has produced nothing since 2026-10-01 and has been removed.
   > Note also that FTP directory listings on this host return **stale sizes and mtimes**, so
   > existence is probed only by attempting the download — never by a listing.
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
- **`UT99_ANALYZER_API_KEY`** as a User environment variable (set by `Setup.ps1`). Deliberately not `ANTHROPIC_API_KEY`, which Claude Code would use in preference to a Pro subscription login.

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
# Full run: download both session logs, archive them, analyze the newest, write report.
.\"UT99 ServerLog Analyzer.ps1"

# Archive only: save the fetched logs to the raw archive and exit (no analysis, no report).
# This is what the hourly scheduled task runs; costs nothing but bandwidth.
.\"UT99 ServerLog Analyzer.ps1" -ArchiveOnly

# Report a specific day: every archived session that opened on it is merged into one report.
.\"UT99 ServerLog Analyzer.ps1" -NoFetch -Date 2026-11-08

# Re-analyze even when nothing has changed since the last run (bypasses the duplicate-run guard).
.\"UT99 ServerLog Analyzer.ps1" -Force

# Offline parse test (no download, no API cost).
.\"UT99 ServerLog Analyzer.ps1" -NoFetch -NoAnalysis -LogFile "D:\Dropbox\Gaming\UTLogs\ServerLogs\Raw Server Logs\server.20260802_0330.log"

# Re-analyze a specific local log without touching the server.
.\"UT99 ServerLog Analyzer.ps1" -NoFetch -LogFile "<path to a .log>"
```

| Switch | Effect |
|---|---|
| `-ArchiveOnly` | Download and archive the session logs, then exit (no digest, API call or report). |
| `-NoFetch` | Skip the server download (use with `-LogFile`). |
| `-NoAnalysis` | Skip the Claude API call (deterministic tallies only, no cost). |
| `-LogFile <path>` | Analyze a specific local log. Also bypasses the duplicate-run guard. |
| `-Force` | Analyze even when the session and line count are unchanged since the last run. |
| `-Date <yyyy-MM-dd>` | The day to report: every archived session that opened on it is merged into one report (default: yesterday). With `-LogFile` it only labels the report. |

> **Caution:** `-NoAnalysis` writes a real report file (just without the AI narrative) — if a
> log's session date already has a real analyzed report, running `-NoAnalysis` against it
> **overwrites that report with a no-analysis stub**. For smoke-testing changes, point
> `-LogFile` at a log whose date you don't mind clobbering, or re-run without `-NoAnalysis`
> afterward to restore it.

---

## Scheduling

```powershell
# Register BOTH tasks (requires an ELEVATED / Run-as-Administrator PowerShell).
.\Register-DailyTask.ps1

# Remove them.
.\Register-DailyTask.ps1 -Unregister
```

Two tasks do the work:

| Task | When | What |
|---|---|---|
| `UT99 ServerLog Analyzer - Daily` | daily at **01:30** | Full run: fetch, merge the previous day's sessions, analyze, write the report. |
| `UT99 ServerLog Analyzer - Hourly Archive` | every hour at **:15** | `-ArchiveOnly`: fetch and archive both session logs. No digest, no API call, no report. |

The hourly task is what makes a session impossible to lose. The live `server.log` is buffered
server-side and `/System/server-old.log` is only *sometimes* created at a restart, so an hourly
capture is the only thing that guarantees a session which never rotates is still archived. Because
the daily run then merges whole days out of that archive, **it no longer has to be timed against a
restart** — which is why 01:30 replaced the old 07:30 slot chosen to follow NFO's ~07:00 restart.

Both are registered to **run whether you are logged on or not**, with **highest privileges**
(S4U + RunLevel Highest) — which is why registration needs an elevated shell.

> **Keep the daily run and its retries off 05:00.** A separate "Daily Restart" task force-reboots
> the machine (`shutdown /r /f`) at 05:00 every 3 days and will kill a run mid-fetch. 01:30 and its
> 30-minute retry grid clear that.

If the daily run fails (server unreachable, no network, WinSCP login failure), Windows Task
Scheduler **retries every 30 minutes** (count set by `-RetryCount`) until it succeeds, implemented
via restart-on-failure: the script exits non-zero on any fatal fetch failure. The hourly task has
no retry — the next hour is the retry. A daily run whose session and line count are both unchanged
since the last run exits 0 before the API call (see the duplicate-run guard), so a quiet day costs
nothing.

Adjust with `-Time`, `-HourlyMinute`, `-RetryIntervalMinutes`, `-RetryCount`, or register only the
daily task with `-NoHourly`.

---

## Configuration

All settings live in `_system\config.ps1`. Key values:

| Setting | Default | Purpose |
|---|---|---|
| `WinSCPSessionName` | `FMJ FTP Server` | Saved WinSCP session name |
| `RemoteLogPath` | `/System/server-old.log` | UT99's previous-session log (overwritten at every restart, and often absent — a failed fetch is only a warning) |
| `RemoteLivePath` | `/System/server.log` | The live session log; exists whenever the server runs, so this is the dependable source |
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
| `_system\Bin\Register-DailyTask.ps1` | Scheduled-task registration (both the daily and the hourly archive task) |
| `_system\State\digest-history.json` | Trend history (day-over-day diffing) |
| `_system\State\last-run.json` | Last-run metrics |
| `FUTURE-FEATURES.md` | Backlog of deferred enhancements (4–9) |

---

## Notes

- **Run the server with `-forcelogflush`.** Without it UT99 buffers its log in ~16 KB blocks, so
  the copy on the server — and therefore every fetch — stops short of what has actually happened,
  and the final partial block is lost outright when the process is killed at a restart. That is
  why a report's "Last log activity" can sit 45–60 minutes before the restart that ended the
  session. Measured locally on 2026-11-09: of a server's startup output, **22 lines** reached disk
  without the flag versus **75 lines** with it, the rest lost on kill. Cost is one disk write per
  log line, which is nothing at UT99's few-lines-per-second rate.
- Player IP addresses (PII) appear in the downloaded log and the report, which stay local in
  Dropbox. The digest sent to the API includes IP *counts*, not raw IP lists.
- Token usage is bounded by the deduplicated digest, so even very large logs cost roughly the
  same to analyze.
- Markdown tables (e.g. the Players & Connections table) are rendered with padded, column-aligned
  cells so the raw `.md` source lines up visually even without a markdown previewer. A literal
  `|` in a player name would otherwise break a table column; it's rendered as the look-alike
  character `¦` instead.
