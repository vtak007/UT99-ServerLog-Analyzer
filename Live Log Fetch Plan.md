# Plan — Live-log fetch, supersede-archiving, and duplicate-run guard

Branch: `fix/live-log-fetch-and-dedupe`
Written: 2026-10-31 · Status: awaiting approval, no code changed yet

## Problem

Three defects, found 2026-10-31 by inspecting the 07:30 run log and then the server directly.

1. **`/System/server-old.log` can be absent entirely.** It was present 10-30 07:30 and gone by
   10-31 07:30, despite a restart at 03:05 that should have produced it. A direct `get` confirms
   it is genuinely missing, not a listing glitch. The Oct 30 session (Oct 30 → Oct 31 03:05) is
   **permanently lost** — it is not on the server and not in `Raw Server Logs\`.
2. **The `/Logs/` fallback silently re-analyzes an old archive.** `Invoke-RotatedLogFetch`
   downloads the frozen `server.20261001_1748.log` (that folder has had nothing new since
   2026-10-01), then resolves "the fetched file" as the newest-by-name file in `RawLogFolder` —
   always a `server-old` archive newer than anything `/Logs/` holds. The 10-30 and 10-31 runs both
   re-digested the Oct 29 session, each spending an API call to rewrite an identical report.
3. **Nothing detects a repeat run.** Both runs produced byte-identical digests (9,403 lines,
   98 warnings, 27 script warnings, 18 unique IPs) and neither noticed.

Also established: **FTP listing metadata on this host is unreliable.** `ls` reported
`/System/server.log` as 17,730 bytes modified Oct 31 03:05; the actual download is 378,178 bytes
with activity through 12:44. Sizes and mtimes from a directory listing must never be trusted —
only a completed download is authoritative.

## Approach

Make the **live `/System/server.log`** the dependable source, since it exists whenever the server
runs, and stop treating "already archived" as "nothing to do" — a live session grows between runs.

### 1. Rewire the fetch — `Invoke-ServerFetch`

Each run fetches **both** remote logs and archives **both**, so a session can no longer be lost:

| Step | Source | Purpose |
|---|---|---|
| 1 | `/System/server-old.log` | Complete, closed session. Missing is normal — WARN, not an error. |
| 2 | `/System/server.log` | Live session. Must succeed; failure is a hard error. |
| 3 | — | Analyze whichever archived session has the **newest** `Log file open` time. |

Both downloads go to `_system\State\staging` and are archived via the shared naming/supersede
logic below. If step 1 yields a session that is new to the archive but *older* than the one chosen
for analysis, log a WARN naming the file — it is safely archived but will not get a report, and
can be reported later with `-LogFile`. Generating multiple reports in one run stays out of scope
(that is the `Capture Manual Restarts.md` idea).

`Invoke-RotatedLogFetch` is **deleted**, along with its config keys (`RemoteLogFolder`,
`RemoteLogMask`, `DeleteAfterDownload`) and the `FetchSource` dispatch — `/Logs/` has produced
nothing for a month and the function is the direct cause of defect 2. No existence check via `ls`
is added anywhere, per the stale-metadata finding; a failed `get` remains the "absent" signal.

### 2. Supersede-archiving — new `Save-SessionArchive`

Extracted from `Invoke-ServerOldFetch` so both fetches share it. Name stays
`server.<yyyyMMdd_HHmm>.log` from `Get-LogSessionDate`. On collision, the current
"never overwrite" rule is **replaced** by:

- staged file **larger** than the existing archive → replace it (a longer capture of the same
  session is a strict superset — this is the normal live-log case)
- otherwise → keep the existing archive, discard the staged copy, INFO

Byte length is the comparison, not line count: it is cheaper and sufficient for a monotonically
appended log.

### 3. Duplicate-run guard — main flow

After the digest (local and cheap), before `Invoke-ServerLogAnalysis`: if `session_open` **and**
`line_count` both match `last-run.json`, log INFO "no new log activity since last run" and exit 0
without calling the API. Keyed on content, not filename, so it permits the legitimate refresh of a
grown session while still catching the 10-30/10-31 duplicates. Requires adding `session_open` to
the `last-run.json` payload. Skipped when `-LogFile` is passed explicitly, and overridable with a
new `-Force` switch.

## Files touched

| File | Change |
|---|---|
| `_system\Bin\UT99 ServerLog Analyzer.ps1` | Rewrite `Invoke-ServerFetch`; add `Save-SessionArchive`; slim `Invoke-ServerOldFetch` + add live-fetch twin; delete `Invoke-RotatedLogFetch`; add guard and `-Force`; add `session_open` to state |
| `_system\config.ps1` | Add `RemoteLivePath = '/System/server.log'`; remove `FetchSource`, `RemoteLogFolder`, `RemoteLogMask`, `DeleteAfterDownload` |
| `README.md`, `CLAUDE.md`, `MEMORY.md` | After tested + approved only, per the doc-update gate |

## Testing

1. **Offline** — `-NoFetch -LogFile` against the already-downloaded Oct 31 live log
   (`...\scratchpad\srvcheck\server-live.log`, session opens 03:05:16, 6,667 lines): expect exit 0
   and a report dated 2026-10-31, proving the live log digests cleanly.
2. **Live run** — expect: `server-old.log` WARN (absent), live fetch succeeds, archived as
   `server.20261031_0305.log`, report `FMJ Server Log Analysis 2026-10-31.md`.
3. **Guard** — immediately re-run. Expect exit 0, no API call, "no new log activity".
4. **Supersede** — re-run after further play. Expect the archive replaced with the longer capture
   and a refreshed report for the same date.
5. **Commit before the live runs**, per the deploy-discipline rule.

## Risks

- **Torn final line.** Downloading a log mid-write can truncate the last entry. `Get-ServerLogDigest`
  is regex-per-line and skips non-matching lines, so impact is at most one dropped entry; test 1
  confirms on real data.
- **Early reporting.** A live fetch reports a session before it ends; the next day's larger capture
  supersedes it. Accepted deliberately — losing a session entirely is worse.
- **Report churn.** Same-date reports get rewritten as the session grows. Intended.
- **Trend history** keys on report date, so a superseding re-run updates that date's entry rather
  than adding one. Needs a check during implementation that `Save-DigestHistory` replaces rather
  than appends for a repeated date.
