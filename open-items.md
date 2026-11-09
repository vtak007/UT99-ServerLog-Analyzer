# UT99 ServerLog Analyzer — Open Items

## Status

| # | Item | Status |
|---|---|---|
| 1 | Report for a day with 3+ restarts | Open — waiting on such a day |
| 2 | `-forcelogflush` effect on Shutdowns rows | Ready — waiting on your NFO edit |
| 3 | 01:30 scheduled run under the trend fix | Open — checks tonight |
| 4 | Why `/System/server-old.log` goes missing | Open — closes via item 9 |
| 5 | Does it track manual vs NFO restarts | Open — needs more restarts |
| 6 | Empty signature keys in Changes Since Last Run | Open — cosmetic |
| 7 | 14-day cleanup of run logs and WinSCP XMLs | Deferred 2026-11-09 |
| 8 | Doc updates after your report review | Waiting on your approval |
| 9 | NFO support question | Draft ready — waiting to send |
| 10–13 | Known limitations | Accepted, no action |
| 14–17 | Git actions | Outstanding |

## VERIFY

1. First report for a day with three or more restarts: Sessions table is correct, and the AI does
   not call short or no-player sessions crashes. Two-session days verified 2026-11-09 (Nov 3, Nov 8).
2. `-forcelogflush` effect, once you have added it to the server command line at NFO: the next
   report's Shutdowns row shows "Last log activity" at or within seconds of "Down by", instead of
   the current 44–57 minute gaps. Verified locally 2026-11-09 (22 lines survived a kill without the
   flag, 75 lines with it).
3. Tonight's 01:30 scheduled run under the trend fix: reports 2026-11-09 and compares against
   2026-11-08, not against a later date.

## WATCH

4. Why `/System/server-old.log` goes missing. Hourly data 2026-11-08/09: present 18:15, absent
   19:15 through 03:15 (restart 18:19), present from 04:15 (restart 03:55) — so some restarts both
   fail to create it and remove the copy that was there. **Ruled out 2026-11-09:** shutdown
   cleanliness does not explain it — `server.20261108_0240.log` ended with the full socket-close
   shutdown flood and got no rotation, while `server.20261108_1819.log` was killed mid-line and did.
5. Whether `server-old.log` going missing tracks manual vs NFO-initiated restarts.
6. Empty signature keys (`sw|`, `err|`, stored with count 0 in `digest-history.json`) surface in
   the report as a meaningless "1 signature(s) resolved" line reading `` `sw¦` ``. Cosmetic; fix is
   to skip zero-count/empty keys when building the signature map.

## DECIDE

7. Add a 14-day cleanup of old run logs and WinSCP XML files — **deferred 2026-11-09**. Current
   volume: 167 run logs (713 KB) and 172 XMLs (685 KB) back to 2026-08-03, growing ~48 files a day.
8. Approve updates after reviewing the regenerated Nov 7 and Nov 8 reports: `README.md`,
   `CLAUDE.md`, `MEMORY.md` (including the 16 KB log-buffering root cause, the `-forcelogflush`
   test result, and the ruled-out theory in item 4), and the 07:30 default and retry count in
   `Register-DailyTask.ps1`.
9. Send the NFO support question (draft prepared 2026-11-09) asking whether their restart wrapper
   or control-panel stop/start touches `/System/*.log`; a yes closes item 4.

## BLOCKED

None.

## ACCEPTED

10. Play between the 01:30 run and the next restart is left out of that day's report.
11. A shutdown caused from outside (NFO restart or control panel) logs no reason, so those rows
    read "No reason logged".
12. A server start that was never archived leaves no record, so its session and shutdown cannot be
    reported.
13. The Oct 30 2026 session (Oct 30 → Oct 31 03:05) is lost permanently; it is not on the server or
    in `Raw Server Logs\`.

## Git Actions Outstanding

14. Commit this `open-items.md` update.
15. Merge `fix/trend-baseline-backfill` to `main` after item 8 and your go-ahead. It was branched
    from `feature/merge-day-sessions`, so this one merge brings both.
16. Delete `fix/trend-baseline-backfill` and `feature/merge-day-sessions` after the merge.
17. Push `main` on your go-ahead.
