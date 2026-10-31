# UT99 ServerLog Analyzer — Open Items

## VERIFY

1. First live run under the new fetch code — scheduled task 2026-11-01 07:30. In
   `_system\Runlogs\run-2026-11-01-0730*.log` expect: a `server-old.log` WARN (or a successful
   fetch if it rotated), the live `server.log` archived, and a real report for the newest session.
   The API path has not yet executed under this code.
2. Report content for a session captured mid-flight — confirm the Oct 31 (or later) report reads
   sensibly when the session was still running at fetch time, rather than looking truncated.

## WATCH

3. **Why `/System/server-old.log` gets deleted — ongoing investigation.** Established 2026-10-31:
   a direct `get` confirms it is genuinely absent (not an FTP stat glitch), and it was absent
   despite the 03:05 restart that should have created it, so something removes it. Observed
   pattern: 10-28 present, 10-29 gone, 10-30 present, 10-31 gone. Next useful fact: whether it
   exists briefly after NFO's restart and is then deleted, or never appears at all (see item 7).
4. Supersede-archiving across consecutive days — confirm a grown live session replaces its own
   earlier capture (`Superseded ... N -> M bytes` in the run log) rather than being rejected.
5. Duplicate-run guard on a genuinely idle day — confirm it exits 0 with "No new log activity"
   when there is no restart and no new lines, and does **not** block a legitimate refresh.
6. Whether the alternating present/gone pattern for `server-old.log` tracks manual vs
   NFO-initiated restarts; if it does, that identifies which restart path is responsible.

## DECIDE

7. Post-restart `-ArchiveOnly` probe as a second scheduled task, in the window just after NFO's
   ~07:00 restart, to catch `server-old.log` before it disappears. Offered, not set up.
8. Whether to ask NFO support if their restart wrapper touches `/System/*.log`. Cheap, and a yes
   closes item 3 outright.
9. Removal of the old `ANTHROPIC_API_KEY` User env var, pending migration of all projects to
   project-specific names (open since 2026-10-15).

## BLOCKED

None.

## ACCEPTED

10. A live-log fetch reports a session before it ends; the next day's longer capture supersedes
    the archive and the report for that date is rewritten. Chosen deliberately — losing a session
    entirely is worse than reporting one early.
11. The Oct 30 2026 session (Oct 30 → Oct 31 03:05) is lost permanently — not on the server, not
    in `Raw Server Logs\`. Unrecoverable.
12. Merging several archived sessions into one report is not implemented; sketched in
    `Capture Manual Restarts.md`.

## Git Actions Outstanding

None.
