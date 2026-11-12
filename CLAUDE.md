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
| `_system\Bin\Register-DailyTask.ps1` | Windows Task Scheduler registration — registers **both** the 01:30 daily run and the hourly `-ArchiveOnly` task (`-NoHourly` skips the latter) |
| `_system\State\last-run.json` | Timestamp, paths, counts and `session_open` from the last run; read back by the duplicate-run guard |
| `_system\State\winscp-*.xml` | Per-fetch WinSCP session logs |
| `_system\Runlogs\run-*.log` | Per-run text logs |
| `README.md` (project root) | User documentation |
| `MEMORY.md` (project root) | Root causes, ruled-out theories, conventions, change log |
| `open-items.md` (project root) | Open and deferred items plus pending git actions |
| `.gitattributes` (project root) | Line endings: `*.md` LF, `*.ps1` CRLF (stops false "modified" files) |

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
  fatal. Archiving both means a session is never lost even when it isn't the one reported.
  `Invoke-RotatedLogFetch` and the `FetchSource`/`RemoteLogFolder`/`RemoteLogMask`/
  `DeleteAfterDownload` config keys were **deleted** — `/Logs/` has produced nothing since
  2026-10-01 and the function silently re-digested the newest archive. See MEMORY CONFIRMED ROOT
  CAUSES. The raw folder is a **permanent, never-wiped archive**.
- **One report per DAY, merged from the archive (added 2026-11-08):** what gets reported is chosen
  from `RawLogFolder`, not from whatever was just downloaded — every archived session whose
  "Log file open" date matches the report date (default yesterday, or `-Date`) is merged into one
  report, and the digest sums across them. A day with several restarts therefore yields a single
  report with a **Sessions** row per session (the table is omitted when a day held one session),
  not one report per restart. This replaced "analyze whichever session is newest" and makes
  `Capture Manual Restarts.md` obsolete as a plan — it is implemented.
- **Shutdowns section (added 2026-11-08, `Get-ShutdownEvents`):** one row per server start in the
  report, giving what the server was **down by** (the next start, or its own log-close time), the
  **last log activity** before it, and the reason if one was logged. Shutdowns triggered from
  outside the game (NFO restart, control panel) log no reason, so those rows read "No reason
  logged" — that is expected, not a parsing failure.
- **Two scheduled tasks (`Register-DailyTask.ps1` registers both):** `UT99 ServerLog Analyzer -
  Daily` at **01:30** (full run) and `UT99 ServerLog Analyzer - Hourly Archive` every hour at
  **:15** (`-ArchiveOnly`: fetch + archive, no digest, no API call, so it is free). The hourly task
  is what makes a session impossible to lose, given that `server-old.log` is only sometimes created
  at a restart and the live log is buffered. Because the daily run merges whole days out of the
  archive, **it no longer has to be timed against a restart** — that is why 01:30 replaced the old
  07:30 slot, which existed only to follow NFO's ~07:00 restart. 01:30 and its 30-minute retry grid
  also clear the 05:00 `shutdown /r /f` reboot of this machine. The hourly task has no
  restart-on-failure: the next hour is the retry.
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
- **Trend baseline must be the newest EARLIER day (`Get-Trend`, fixed 2026-11-09):** the history
  filter is `$_.date -lt $curDateStr`, **not** `-ne`. With `-ne` the baseline was the newest entry
  in the whole history, so re-running an older day compared it against a *later* report (the
  2026-11-07 re-run rendered "Δ vs 2026-11-08") and, because that later day's signatures were
  already in the seen-set, nothing could ever be flagged NEW. `$prev` derives from `$prior`, so the
  one filter governs both the delta baseline and new-signature detection.
- **16 KB server-side log buffering — run the server with `-forcelogflush`.** UT99 buffers its log
  in ~16 KB blocks, so the file on the server lags actual play and the final partial block is lost
  outright when the process is killed at a restart. This is why a report's "Last log activity" sits
  45–60 minutes before the restart that ended the session (e.g. `server.20261108_0240.log` ends
  17:22 against an 18:19 restart), and why archives for short sessions come out at suspiciously
  round sizes (17,730 / 34,114 / 66,882 bytes — the same session plus N blocks). Confirmed locally
  2026-11-09: of a server's startup output, 22 lines reached disk without the flag versus 75 with
  it. Server-side corroboration: only 1 of ~80 archives (`server.20260906_2333.log`) carries a
  `Log file closed` marker and every recent archive ends **mid-line**, so the buffer is normally
  lost. A gap between last activity and the next start is **lost log, not downtime** — never read
  it as an outage. `Log: Close: Error while attempting to close socket.` is **not** a shutdown
  marker (3,893–8,611 occurrences per log, from ~line 303); `Log file closed` is.
  **The flag cannot currently be set:** NFO's panel refuses it in the "starting line" field (URL
  only — no dashes or spaces) and there is no `.ini` equivalent, since both `forceflush` and
  `forcelogflush` exist only as command-line `ParseParam` switches.
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

## Known limitations

Accepted, no action. Numbered 8–13 to match references in `open-items.md` (items 7 and 4 cite
them). Do not re-investigate these as bugs.

8. Play between the 01:30 run and the next restart is left out of that day's report.
9. A shutdown caused from outside (NFO restart or control panel) logs no reason, so those rows
   read "No reason logged".
10. NFO's `/Logs/server.*.log` rotation script has produced nothing since
    `server.20261001_1748.log` and is **not required** — every archive and report since
    2026-10-03 comes from `/System/server-old.log` plus the live `/System/server.log`, and the
    current code contains no reference to `/Logs/`. Do not re-investigate it as broken
    infrastructure; it is a dead redundancy, requested back only as item 7.3.
11. A restart storm faster than the hourly archive task loses the intermediate sessions: only the
    session live at `:15` is captured, and the rest are overwritten in `server-old.log` before any
    fetch sees them. Precedent: the 2026-09-27 crash loop produced 132 sessions in about two hours,
    which NFO's per-restart `/Logs/` script caught and an hourly fetch would not. Accepted unless
    item 7.3 is granted.
12. A server start that was never archived leaves no record, so its session and shutdown cannot be
    reported. The Oct 30 2026 session (Oct 30 → Oct 31 03:05) is lost permanently this way, and
    the pre-2026-08-23 `/Logs/` files have since been aged off the server.
13. The last ~280 lines of every session are never flushed to disk, so "Last log activity" always
    reads early — ~40 minutes on an idle server, seconds on a busy one. `-forcelogflush` is the
    only fix and NFO's panel will not accept it (the "starting line" field refuses dashes and
    spaces; there is no `.ini` equivalent). **Not a blocker:** the loss is trailing idle traffic,
    and the Shutdowns note now says so explicitly rather than blaming an outside shutdown. The one
    case it would matter is diagnosing a crash, since the explanatory lines would be exactly the
    unflushed ones — recent reports show 0 hard errors. Still requested as item 7.2; if NFO grants
    it, verify that a Shutdowns row's "Last log activity" lands within seconds of "Down by".
