# UT99 ServerLog Analyzer — Project Instructions

Downloads the FMJ server's session logs (`/System/server-old.log` and the live `/System/server.log`)
via WinSCP, analyzes the newest with the
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
| `_system\State\last-run.json` | Timestamp, paths, counts and `session_open` from the last run; read back by the duplicate-run guard |
| `_system\State\winscp-*.xml` | Per-fetch WinSCP session logs |
| `_system\Runlogs\run-*.log` | Per-run text logs |
| `README.md` (project root) | User documentation |

## Output locations (not in the project folder)

- Archived raw log: `D:\Dropbox\Gaming\UTLogs\ServerLogs\Raw Server Logs\server.yyyymmdd_hhmm.log`
  (named from the log's own "Log file open" time — see Design notes below).
- Report: `D:\Dropbox\Gaming\UTLogs\ServerLogs\FMJ Server Log Analysis <date>.md`

Report/log date = the log's own "Log file open" session date (falls back to today), so a
morning run over the previous night's rotated log is named for the session it covers.

## Design notes

- **Both session logs are fetched every run (changed 2026-10-31):** `Invoke-ServerFetch` calls
  `Get-RemoteSessionLog` twice — for `Config.RemoteLogPath` (`/System/server-old.log`, the previous
  closed session) and `Config.RemoteLivePath` (`/System/server.log`, the live one) — archives both
  via `Save-SessionArchive`, and analyzes whichever has the newest "Log file open" time. A failed
  `server-old` fetch is a **WARN, not an error**: it is frequently absent, and on 2026-10-31 it was
  missing despite a 03:05 restart that should have created it, losing that session for good. The
  live log exists whenever the server runs, so it is the dependable source and its failure is
  fatal. Archiving both means a session is never lost even when it isn't the one reported; an
  archived-but-unreported session is named in a WARN for later `-LogFile` use. Multi-session
  reports in one run remain unimplemented (sketched in `Capture Manual Restarts.md`).
  `Invoke-RotatedLogFetch` and the `FetchSource`/`RemoteLogFolder`/`RemoteLogMask`/
  `DeleteAfterDownload` config keys were **deleted** — `/Logs/` has produced nothing since
  2026-10-01 and the function silently re-digested the newest archive. See MEMORY CONFIRMED ROOT
  CAUSES. The raw folder is a **permanent, never-wiped archive**. The schedule is **07:30** because
  NFO's restart currently lands ~07:00; with the live log now fetched too, an early run no longer
  loses the session, it just reports it before it ends.
- **GOTCHA — never trust an FTP listing on this host.** On 2026-10-31 `ls /System/*.log` reported
  `server.log` as 17,730 bytes modified 03:05 while the real file was 378,178 bytes with activity
  through 12:44; sizes and mtimes are stale/cached and only a completed download is authoritative.
  `Get-RemoteSessionLog` therefore probes existence **only by attempting the `get`** — a failed
  transfer is the "absent" signal. Do not add an `ls`-based pre-check, and never let a decision
  depend on a listed size or mtime.
- **Supersede-archiving (`Save-SessionArchive`):** names the archive `server.yyyymmdd_hhmm.log`
  from the log's own "Log file open" time. The former never-overwrite rule is **replaced** by a
  supersede rule — a staged file **larger** than an existing archive of the same session replaces
  it, since a longer capture of a monotonically appended log is a strict superset. This is the
  normal case when the live `server.log` is fetched again while the same session still runs; under
  the old rule every refreshed capture was rejected as "already archived".
- **Duplicate-run guard (main flow, before `Invoke-ServerLogAnalysis`):** keyed on **content**
  (session open time + line count vs `last-run.json`), not on the filename, so a grown session
  still refreshes while an unchanged one exits 0 without an API call. Bypassed by `-LogFile`,
  overridden by `-Force`. **GOTCHA:** `ConvertFrom-Json` revives the stored ISO `session_open`
  string as a `[datetime]`, so a `[string]` cast of it yields the culture format
  (`10/31/2026 03:05:16`) and never matches the round-trip value — both sides must be normalized
  through one zone-insensitive format (`yyyy-MM-ddTHH:mm:ss`). The guard silently never fired
  until this was fixed.
- **Log coverage window:** the digest scans every timestamp format the log actually contains
  (`Log file open`, `NetComeGo`, MapVote `yyyy/MM/dd Time >`, ACE `[TIME] dd-MM-yyyy`, day-first)
  and min/max's them into `FirstEntry`/`LastEntry`/`SpanText`. Rotated logs have **no**
  `Log file closed` marker, so `Digest.LogClosed` is normally empty — it is still collected but
  no longer rendered (the dashboard row was dropped); use First/Last as the coverage window.
  The **endpoints are rendered once**, in the `log_first_entry`/`log_last_entry` frontmatter; the
  dashboard shows only the `Log covers` span. The old `**Log covers:**` line under the H1 and the
  `Log session opened`/`First log entry`/`Last log entry` dashboard rows were removed (2026-08-20)
  — `Log session opened` was always the same instant as the first entry, just formatted
  differently. `LogOpen`/`FirstEntryText`/`LastEntryText` are still collected and feed frontmatter.
- **Bounded digest:** `Get-ServerLogDigest` deduplicates issue lines into signatures with
  counts (top-N per bucket via `MaxSignaturesPerBucket`). Only the digest — never the raw
  11k+ lines — is sent to the API, so token cost stays flat regardless of log size.
- **Buckets:** hard errors, `Warning:`, `ScriptWarning:`/Accessed None (grouped by
  `package.class.function` + offending variable), anti-cheat/integrity (UTPure/IGPlus/NSC),
  package/version. Plus a tag histogram and network counters (opens/closes/unique IPs/timeouts).
- The server's own logs are **never deleted** — every fetch is a plain `get`, download-only.
- Player IPs (PII) are counted, not sent verbatim to the API.
- **Findings suppression (`Config.SuppressedFindingsMaps` + `Config.SuppressedFindingsPatterns`):**
  in `New-ServerLogReport`, before rendering `## Findings`, the two lists are unioned into one
  regex and any finding whose title/evidence/root_cause/solution text matches is dropped from that
  section only — `## Recommendations` is untouched, since the AI is still free to mention those
  maps there. Matching is done against the raw text (there's no structured per-finding map
  field), so fragments must tolerate the exact spelling variants seen in logs, e.g.
  `Temple[0O]fThe[wW]inds` for `DM-Temple0fTheWinds` (note the digit `0`, not letter `O`).
  `SuppressedFindingsPatterns` is the same mechanism matched on subject rather than map name;
  it currently holds `skin`, which covers every skin package and texture-variant message
  (CommandoSkins, SGirlSkins, SoldierSkins, TSkMSkins, …) — client-side cosmetics the server
  can't fix. They remain visible in Failed-to-Load Offenders and may still appear in
  Recommendations.
- **Sections deliberately removed from the report (2026-08-20 duplication pass):**
  `## Session & Config Overview` (engine/base dir/maps/mutators/~80-entry ServerPackages list) is
  gone — static config that barely changes between sessions, and the packages line alone ran
  longer than most of the report. Those fields are **still collected and still sent to the API**
  via `ConvertTo-DigestText`, so the model keeps its config context. Likewise `Failed to load`
  signatures are filtered out of `## Recurring Warnings` at render time (a pointer line replaces
  them) because Failed-to-Load Offenders lists the same events with real names — `Digest.Warnings`
  is untouched, so the API digest and NEW/resolved-signature diffing still see them.
  **Kept on purpose:** the Players & Connections bullets that restate Health Dashboard rows, the
  findings evidence that restates the recurring tables, and the Recommendations that condense each
  finding's proposed solution — all reviewed 2026-08-20 and deliberately left as-is.
- **Markdown table rendering (`Format-MdCell` + `Format-MdTable`):** every table in the report
  goes through `Format-MdTable` (headers, per-column `L`/`R` aligns, rows); cells — including the
  separator row — are padded to a per-column max width, floored at 3, so the raw `.md` source is
  visually column-aligned even without a markdown previewer (VS Code raw view, etc.), not just
  when rendered. **GOTCHA:** a row-building `foreach` that emits exactly ONE `,@(...)` row arrives
  at the function already unrolled, as a flat array of that row's *cells*; `Format-MdTable` detects
  this (`$Rows[0] -isnot [System.Array]`) and re-wraps it. Without that guard a single-row table
  renders one row per cell, split character by character. A literal
  `|` in a player name is replaced with the look-alike `¦` (not backslash-escaped `\|`) because
  some renderers (Obsidian) don't reliably honor `\|` escaping inside table cells and will still
  split the column on it — `¦` can never be mistaken for a column separator, in source or render.
