# UT99 ServerLog Analyzer — Open Items

## Status

| # | Item | Status |
|---|---|---|
| 1 | Report for a day with 3+ restarts | Open — waiting on such a day |
| 2 | `-forcelogflush` effect on Shutdowns rows | Ready — waiting on your NFO edit |
| 3 | 01:30 scheduled run under the trend fix | Open — checks tonight |
| 4 | `Register-DailyTask.ps1` registering both tasks | Open — needs one elevated run |
| 5 | Why `/System/server-old.log` goes missing | Open — closes via item 10 |
| 6 | Does it track manual vs NFO restarts | Open — needs more restarts |
| 7 | Daily task ran twice on 2026-11-09 | Open — one unexplained API call |
| 8 | Empty signature keys in Changes Since Last Run | Open — cosmetic |
| 9 | 14-day cleanup of run logs and WinSCP XMLs | Deferred 2026-11-09 |
| 10 | NFO support question | Draft ready — waiting to send |
| 11–14 | Known limitations | Accepted, no action |
| 15–17 | Git actions | Outstanding |

## VERIFY

1. First report for a day with three or more restarts: Sessions table is correct, and the AI does
   not call short or no-player sessions crashes. Two-session days verified 2026-11-09 (Nov 3, Nov 8).
2. `-forcelogflush` effect, once you have added it to the server command line at NFO: the next
   report's Shutdowns row shows "Last log activity" at or within seconds of "Down by", instead of
   the current 44–57 minute gaps. Verified locally 2026-11-09 (22 lines survived a kill without the
   flag, 75 lines with it).
3. Tonight's 01:30 scheduled run under the trend fix: reports 2026-11-09 and compares against
   2026-11-08, not against a later date.
4. `Register-DailyTask.ps1` now registers the hourly archive task as well as the daily one. Run it
   once from an **elevated** shell and confirm it reproduces the live schedule (daily 01:30, hourly
   at :15 with `PT1H` repetition). The trigger it builds was verified to match the live task, but
   registration itself has not been exercised; the working tasks were deliberately left in place.

## WATCH

5. Why `/System/server-old.log` goes missing. Hourly data 2026-11-08/09: present 18:15, absent
   19:15 through 03:15 (restart 18:19), present from 04:15 (restart 03:55) — so some restarts both
   fail to create it and remove the copy that was there. **Ruled out 2026-11-09:** shutdown
   cleanliness does not explain it — `server.20261108_0240.log` ended with the full socket-close
   shutdown flood and got no rotation, while `server.20261108_1819.log` was killed mid-line and did.
   No longer a data-loss risk — the hourly task captures the session either way.
6. Whether `server-old.log` going missing tracks manual vs NFO-initiated restarts.
7. The Daily task ran twice on 2026-11-09 — 01:30 (scheduled) and again at 05:10:25, which Task
   Scheduler records as that task's last run. Both analyzed Nov 8, so the second was a second paid
   API call. Confirm whether you triggered it from Task Scheduler; if not, find what re-fired it
   (the retry grid off 01:30 would land on :00/:30, so 05:10 does not fit it).
8. Empty signature keys (`sw|`, `err|`, stored with count 0 in `digest-history.json`) surface in
   the report as a meaningless "1 signature(s) resolved" line reading `` `sw¦` ``. Cosmetic; fix is
   to skip zero-count/empty keys when building the signature map.

## DECIDE

9. Add a 14-day cleanup of old run logs and WinSCP XML files — **deferred 2026-11-09**. Current
   volume: 167 run logs (713 KB) and 172 XMLs (685 KB) back to 2026-08-03, growing ~48 files a day.
10. Send the NFO support question (draft prepared 2026-11-09) asking whether their restart wrapper
    or control-panel stop/start touches `/System/*.log`; a yes closes item 5.

## BLOCKED

None.

## ACCEPTED

11. Play between the 01:30 run and the next restart is left out of that day's report.
12. A shutdown caused from outside (NFO restart or control panel) logs no reason, so those rows
    read "No reason logged".
13. A server start that was never archived leaves no record, so its session and shutdown cannot be
    reported.
14. The Oct 30 2026 session (Oct 30 → Oct 31 03:05) is lost permanently; it is not on the server or
    in `Raw Server Logs\`.

## Git Actions Outstanding

15. Merge `fix/trend-baseline-backfill` to `main` on your go-ahead. It was branched from
    `feature/merge-day-sessions`, so this one merge brings both.
16. Delete `fix/trend-baseline-backfill` and `feature/merge-day-sessions` after the merge.
17. Push `main` on your go-ahead.
