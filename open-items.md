# UT99 ServerLog Analyzer — Open Items

## Status

| #    | Item                                               | Status                                           |
| ---- | -------------------------------------------------- | ------------------------------------------------ |
| 1    | Report for a day with 3+ restarts                  | Open — waiting on such a day                     |
| 3    | Why `/System/server-old.log` goes missing          | Open — closes via item 7                         |
| 4    | Does it track manual vs NFO restarts               | Open — needs your manual-restart times           |
| 6    | 14-day cleanup of run logs and WinSCP XMLs         | Deferred 2026-11-09                              |
| 7    | NFO support message (3 questions)                  | Deferred 2026-11-12 — draft ready                |
| 8–13 | Known limitations                                  | Accepted, no action                              |

## VERIFY

1. First report for a day with three or more restarts: Sessions table is correct, and the AI does
   not call short or no-player sessions crashes. Two-session days verified 2026-11-09 (Nov 3, Nov 8).

## WATCH

3. Why `/System/server-old.log` goes missing. Hourly data 2026-11-08/09: present 18:15, absent
   19:15 through 03:15 (restart 18:19), present from 04:15 (restart 03:55) — so some restarts both
   fail to create it and remove the copy that was there. Shutdown cleanliness cannot be the
   discriminator: every recent archive ends mid-line with an unflushed buffer, and only 1 of ~80
   archives carries a `Log file closed` marker, so there is no variation to correlate against.
   No longer a data-loss risk — the hourly task captures the session either way.
4. Whether `server-old.log` going missing tracks manual vs NFO-initiated restarts. **Needs from you:**
   a running list of the times you restart the server manually (the logs cannot tell manual from
   NFO-initiated — both log "No reason logged", item 9). After a few weeks, cross-check that list
   against the hourly WinSCP XMLs (present/absent at the :15 fetch after each restart) in one pass.
   Needs several restarts of each kind; "no pattern" is a valid result, and a yes on item 7.1
   would answer this together with item 3.

## DECIDE

6. Add a 14-day cleanup of old run logs and WinSCP XML files — **deferred 2026-11-09**. Current
   volume: 167 run logs (713 KB) and 172 XMLs (685 KB) back to 2026-08-03, growing ~48 files a day.
7. Send the NFO support message (drafted 2026-11-09; **deferred 2026-11-12**), covering three things:
    1. Whether their restart wrapper or control-panel stop/start touches `/System/*.log` — a yes
       closes item 3.
    2. Whether there is any way to pass the engine switch `-forcelogflush` on the server command
       line, given that the "starting line" field rejects dashes and spaces — would retire item 13.
    3. **Low priority:** whether their `/Logs/server.yyyymmdd_hhmm.log` rotation script can be
       revived. Not required (see item 10), but it is the only thing that would close the
       restart-storm gap in item 11.

## BLOCKED

None.

## ACCEPTED

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

## Git Actions Outstanding

None.
