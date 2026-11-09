# UT99 ServerLog Analyzer — Open Items

## Status

| # | Item | Status |
|---|---|---|
| 1 | Report for a day with 3+ restarts | Open — waiting on such a day |
| 2 | 01:30 scheduled run under the trend fix | Open — checks tonight |
| 3 | `Register-DailyTask.ps1` registering both tasks | Open — needs one elevated run |
| 4 | Why `/System/server-old.log` goes missing | Open — closes via item 9 |
| 5 | Does it track manual vs NFO restarts | Open — needs more restarts |
| 6 | Daily task ran twice on 2026-11-09 | Open — one unexplained API call |
| 7 | Empty signature keys in Changes Since Last Run | Open — cosmetic |
| 8 | 14-day cleanup of run logs and WinSCP XMLs | Deferred 2026-11-09 |
| 9 | NFO support message (3 questions) | Draft ready — waiting to send |
| 10–15 | Known limitations | Accepted, no action |
| 16–18 | Git actions | Outstanding |

## VERIFY

1. First report for a day with three or more restarts: Sessions table is correct, and the AI does
   not call short or no-player sessions crashes. Two-session days verified 2026-11-09 (Nov 3, Nov 8).
2. Tonight's 01:30 scheduled run under the trend fix: reports 2026-11-09 and compares against
   2026-11-08, not against a later date.
3. `Register-DailyTask.ps1` now registers the hourly archive task as well as the daily one. Run it
   once from an **elevated** shell and confirm it reproduces the live schedule (daily 01:30, hourly
   at :15 with `PT1H` repetition). The trigger it builds was verified to match the live task, but
   registration itself has not been exercised; the working tasks were deliberately left in place.

## WATCH

4. Why `/System/server-old.log` goes missing. Hourly data 2026-11-08/09: present 18:15, absent
   19:15 through 03:15 (restart 18:19), present from 04:15 (restart 03:55) — so some restarts both
   fail to create it and remove the copy that was there. Shutdown cleanliness cannot be the
   discriminator: every recent archive ends mid-line with an unflushed buffer, and only 1 of ~80
   archives carries a `Log file closed` marker, so there is no variation to correlate against.
   No longer a data-loss risk — the hourly task captures the session either way.
5. Whether `server-old.log` going missing tracks manual vs NFO-initiated restarts.
6. The Daily task ran twice on 2026-11-09 — 01:30 (scheduled) and again at 05:10:25, which Task
   Scheduler records as that task's last run. Both analyzed Nov 8, so the second was a second paid
   API call. Confirm whether you triggered it from Task Scheduler; if not, find what re-fired it
   (the retry grid off 01:30 would land on :00/:30, so 05:10 does not fit it).
7. Empty signature keys (`sw|`, `err|`, stored with count 0 in `digest-history.json`) surface in
   the report as a meaningless "1 signature(s) resolved" line reading `` `sw¦` ``. Cosmetic; fix is
   to skip zero-count/empty keys when building the signature map.

## DECIDE

8. Add a 14-day cleanup of old run logs and WinSCP XML files — **deferred 2026-11-09**. Current
   volume: 167 run logs (713 KB) and 172 XMLs (685 KB) back to 2026-08-03, growing ~48 files a day.
9. Send the NFO support message (drafted 2026-11-09), covering three things:
    1. Whether their restart wrapper or control-panel stop/start touches `/System/*.log` — a yes
       closes item 4.
    2. Whether there is any way to pass the engine switch `-forcelogflush` on the server command
       line, given that the "starting line" field rejects dashes and spaces — would retire item 15.
    3. **Low priority:** whether their `/Logs/server.yyyymmdd_hhmm.log` rotation script can be
       revived. Not required (see item 12), but it is the only thing that would close the
       restart-storm gap in item 13.

## BLOCKED

None.

## ACCEPTED

10. Play between the 01:30 run and the next restart is left out of that day's report.
11. A shutdown caused from outside (NFO restart or control panel) logs no reason, so those rows
    read "No reason logged".
12. NFO's `/Logs/server.*.log` rotation script has produced nothing since
    `server.20261001_1748.log` and is **not required** — every archive and report since
    2026-10-03 comes from `/System/server-old.log` plus the live `/System/server.log`, and the
    current code contains no reference to `/Logs/`. Do not re-investigate it as broken
    infrastructure; it is a dead redundancy, requested back only as item 9.3.
13. A restart storm faster than the hourly archive task loses the intermediate sessions: only the
    session live at `:15` is captured, and the rest are overwritten in `server-old.log` before any
    fetch sees them. Precedent: the 2026-09-27 crash loop produced 132 sessions in about two hours,
    which NFO's per-restart `/Logs/` script caught and an hourly fetch would not. Accepted unless
    item 9.3 is granted.
14. A server start that was never archived leaves no record, so its session and shutdown cannot be
    reported. The Oct 30 2026 session (Oct 30 → Oct 31 03:05) is lost permanently this way, and
    the pre-2026-08-23 `/Logs/` files have since been aged off the server.
15. The last ~280 lines of every session are never flushed to disk, so "Last log activity" always
    reads early — ~40 minutes on an idle server, seconds on a busy one. `-forcelogflush` is the
    only fix and NFO's panel will not accept it (the "starting line" field refuses dashes and
    spaces; there is no `.ini` equivalent). **Not a blocker:** the loss is trailing idle traffic,
    and the Shutdowns note now says so explicitly rather than blaming an outside shutdown. The one
    case it would matter is diagnosing a crash, since the explanatory lines would be exactly the
    unflushed ones — recent reports show 0 hard errors. Still requested as item 9.2; if NFO grants
    it, verify that a Shutdowns row's "Last log activity" lands within seconds of "Down by".

## Git Actions Outstanding

16. Merge `fix/trend-baseline-backfill` to `main` on your go-ahead. It was branched from
    `feature/merge-day-sessions`, so this one merge brings both.
17. Delete `fix/trend-baseline-backfill` and `feature/merge-day-sessions` after the merge.
18. Push `main` on your go-ahead.
