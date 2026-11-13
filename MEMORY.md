# UT99 ServerLog Analyzer — Project Memory

Persistent notes for this project. Read at the start of every session.
See `CLAUDE.md` for project-specific details.

## CONFIRMED ROOT CAUSES

- **Files showing as falsely "modified" after a branch switch (confirmed 2026-11-12).** The index
  stores LF but `core.autocrlf=true` checks files out as CRLF, so any LF edit left the file out of
  step (`open-items.md` blocked merges with "local changes would be overwritten"; diff against the
  branch commit was 0 lines). Fixed by `.gitattributes` (`*.md` LF, `*.ps1` CRLF). Do not
  re-investigate; if it recurs, check `git ls-files --eol` first.
- **16 KB server-side log buffering explains the gap between "last log activity" and the restart
  (confirmed locally 2026-11-09).** UT99 buffers its log in ~16 KB blocks. The consequences are
  (a) the copy on the server — and therefore every fetch, however timely — stops short of what has
  actually happened, and (b) the final partial block is **lost outright** when the process is
  killed at a restart. This is why Shutdowns rows show a 45–60 minute gap before the restart that
  ended the session (`server.20261108_0240.log` ends 17:22 against an 18:19 restart;
  `server.20261108_1819.log` ends 03:11 against an 03:55 restart) and why short sessions archive at
  recurring round sizes (17,730 / 34,114 / 66,882 bytes = the session header plus N blocks — the
  same figure appearing for two different sessions is this, not a duplicate archive). **Measured:**
  a local dedicated server was started, left 20s and killed; without `-forcelogflush` only 22 lines
  / 996 bytes had reached disk (frozen at `Bound to Engine.dll`), with the flag 75 lines / 3,605
  bytes through `Game engine initialized`. Corroborated server-side: of ~80 archives only
  `server.20260906_2333.log` contains a `Log file closed` marker, and every recent archive ends
  **mid-line** (last byte is not a newline), so the buffer was never flushed. A gap between "last
  log activity" and the next start is therefore **lost log, not downtime** — never read it as an
  outage. **Fix:** `-forcelogflush` on the server command line — but NFO's panel **rejects it**
  (2026-11-09): the "starting line" field takes a URL only and refuses any token containing a dash
  or a space, and there is **no `.ini` equivalent** — both `forceflush` and `forcelogflush` exist
  only as command-line `ParseParam` switches in the 469 binaries. Needs another panel field or NFO
  support.

- **Fallback fetch silently re-analyzes the newest archived log (found 2026-10-31).** On days when
  `/System/server-old.log` is absent on the server, WinSCP fails with "Can't get attributes of
  file", `Invoke-ServerFetch` falls back to `Invoke-RotatedLogFetch`, which downloads the frozen
  `/Logs/server.20261001_1748.log` and then resolves the "fetched" file as the **newest-by-name
  file in `RawLogFolder`** — now always a `server-old`-era archive. The run therefore re-digests a
  log it already analyzed, spends a full paid API call and rewrites the identical dated report.
  The code comment at `Invoke-RotatedLogFetch` states the assumption that WinSCP's `-latest` is
  always >= anything archived locally; that stopped being true on 2026-10-04 when the archive
  began receiving `server-old` sessions newer than anything in `/Logs/`. Evidence: of the last 14
  runs, report dates repeat (10-29 x2, 10-27 x2, 10-24 x3, 10-22 x2, 10-18 x2) — roughly half the
  daily API calls are duplicates. `Invoke-ServerOldFetch` has the correct "already archived" skip
  guard; the fallback bypasses it. **FIXED 2026-10-31** (branch `fix/live-log-fetch-and-dedupe`):
  `Invoke-RotatedLogFetch` and its config keys were deleted outright, the live `/System/server.log`
  is now fetched every run alongside `server-old.log`, and a content-keyed duplicate-run guard
  blocks the API call when the session and line count are unchanged.
  **Still open (WATCH):** why `/System/server-old.log` goes missing is still unexplained (10-28
  present, 10-29 gone, 10-30 present, 10-31 gone). 2026-10-31 narrowed it: a direct `get` confirms
  the file is **genuinely absent**, not an FTP stat glitch, and it was absent despite a 03:05
  restart that should have created it — so something deletes it rather than rotation merely not
  happening. Consequence: **the Oct 30 session (Oct 30 → Oct 31 03:05) was lost permanently** —
  not on the server, not in `Raw Server Logs\`. Fetching the live log limits future loss to
  whatever a single missing rotation costs, but does not explain the deletion. Possibly NFO's
  restart wrapper removes it. This also supersedes the "only one clean rotation seen, so
  unconfirmed" note in the 2026-10-04 entry below: rotation is now known to be intermittent.
  **2026-11-09 update:** the hourly task gives per-hour resolution and confirms the deletion
  directly (present 11-08 18:15, absent 19:15 → 03:15 across the 18:19 restart, present from
  04:15 after the 03:55 one). Shutdown cleanliness cannot be the discriminator — see RULED-OUT
  THEORIES; essentially every session ends killed with an unflushed buffer, so there is no
  variation to correlate against. The data loss is now closed off regardless: the hourly `-ArchiveOnly` run
  captures the session whether or not it ever rotates, so this is a curiosity for NFO support to
  answer, not a risk to the archive.

- **Reports lagging the current date (found 2026-10-04).** The analyzer read only
  `/Logs/server.*.log` (rotated files), and NFO's script stopped producing them after
  `server.20261001_1748.log`, so every run re-analyzed the 10-01 log (the 10-03 run rewrote the
  `2026-10-01` report). Separately, the 10-04 04:25 run failed outright: the saved WinSCP session
  `FMJ FTP Server` had lost its stored password ("Access denied. Credentials were not specified.");
  re-saving it in WinSCP fixed that. UT99's own `/System/server-old.log` / `server.log` pair is
  now complete again (server-old: 10/03 17:45 -> 10/04 07:00; live: from 07:00), which fits the
  469e -> 469f update, but only one clean rotation has been seen so that is **unconfirmed**.
  **Fix:** fetch `/System/server-old.log`, archive by session-open time (see PROJECT CONVENTIONS).

- **05:00 scheduled-run collision with a system reboot (2026-08-05).** The daily download
  failed to produce a log: the run stopped right after logging "Fetching…", no `winscp-*.xml`
  was written, task result `0x41306` (SCHED_S_TASK_TERMINATED), action return code `0x800705AB`
  (ERROR_SHUTDOWN_IN_PROGRESS). Event logs showed a separate **"Daily Restart"** task running
  `shutdown /r /f /t 0` at **05:00** (every 3 days) — the exact minute the analyzer fires — so
  the `/f` force-reboot killed pwsh ~5s into the run, before WinSCP connected. Not a script,
  WinSCP, or server-log problem. No retries fired because the reboot wiped the restart-on-failure
  chain and the daily trigger had already fired (not "missed"), so StartWhenAvailable didn't help.
  **Fix:** moved analyzer to **04:25** (35-min head start; retry grid 04:25/04:55/05:25/05:55
  skips 05:00). Verified: manual run succeeded (LastResult 0), full report written.
- **Player "connects" ≠ churn.** In UT99 every map travel forces a client reconnect, so a
  `NetComeGo Open` (and a matching NPLoader `Player Join`) fires per map round plus any mid-game
  rejoin. A high per-player connect count is normal for someone who played all evening. Real
  churn = many connects with consistently SHORT sessions (heuristic: Joins≥5 AND AvgSec<60).
  Use **Total time** / **peak concurrent** / **unique players** as the true population measures,
  not raw connect counts.

- **Single-row markdown tables rendered character-by-character (`Format-MdTable`, found
  2026-08-20).** A row-building `foreach` that emits exactly ONE `,@(...)` row arrives at the
  table function already unrolled — as a flat array of that row's *cells*, not an array containing
  one row array — so each cell was treated as a row and split per character (`| 1 | 4 |` /
  `| U | L |` instead of `| 14 | ULevel::MultiLineCheck ... |`). Guard added:
  `if ($Rows.Count -gt 0 -and $Rows[0] -isnot [System.Array]) { $Rows = @(,$Rows) }`. This was
  latent in EVERY table since the padding work of 2026-08-18, including Players & Connections —
  any session with a single player, a single map, or a single signature would have hit it. None
  of the 11 archived reports happened to contain a one-row table, which is why it stayed hidden
  until `Failed to load` rows were filtered out of Recurring Warnings and left exactly one row.
- 2026-11-12 — Scheduled tasks drifted an hour at DST changes. Cause: on this machine
  `New-ScheduledTaskTrigger -At` serializes `StartBoundary` as UTC (`...Z`), pinning the task to a
  fixed UTC offset instead of local time. Fixed in `Register-DailyTask.ps1` (daily and hourly
  triggers) by overwriting `StartBoundary` with an offset-free local `yyyy-MM-ddTHH:mm:ss` string.

## RULED-OUT THEORIES

- **"`/System/server-old.log` appears only after a clean shutdown" (2026-11-09) — untestable, and
  the first attempt to test it used a bogus marker.** `Log: Close: Error while attempting to close
  socket.` is **not** a shutdown sequence: it is routine per-connection noise appearing 3,893–8,611
  times per log and starting around line 303, so a log that happens to end in a run of it says
  nothing about how the server went down. (A first pass on 2026-11-09 read those tails as clean
  exits and briefly recorded a counter-example built on them — wrong.) The real marker is
  `Log file closed`, present in exactly **one** of ~80 archives (`server.20260906_2333.log`).
  Every recent archive instead ends **mid-line** (last byte is not a newline:
  `server.20261107_0245.log`, `...1108_0240`, `...1108_1819`, `...1109_0355` all do), i.e. the
  process was killed with an unflushed buffer. So there is no variation in shutdown cleanliness to
  correlate against rotation — effectively every session is killed — and the theory cannot explain
  why some restarts rotate and some delete. Hourly presence data for the window: present 18:15,
  absent 19:15 → 03:15 (restart 18:19), present from 04:15 (restart 03:55). Something removes the
  file on some restarts; nothing visible from the FTP side distinguishes them. Next step is asking
  NFO whether their restart wrapper or control-panel stop/start touches `/System/*.log`.
  **Corollary:** a gap between "last log activity" and the next start is **lost log, not
  downtime** — do not read it as an outage.
- **"The hourly archive task might still miss a session that never rotates" (2026-11-09) —
  disproved in practice.** The Nov 8 18:19 session was fully archived (1,377,602 bytes) by the
  hourly `-ArchiveOnly` runs *before* `server-old.log` appeared at 04:15 holding exactly the same
  size. The hourly capture, not rotation, is what guarantees the session.
- **"The live `/Logs/server.log` is already being fetched" (2026-10-04) — false.** The mask
  `server.*.log` only matches rotated files; the live/previous logs are in `/System/`. The WinSCP
  password loss explained only the 10-04 failure, not the multi-day lag.
- **Finding #1 `DM-FortressOfNalitude` NaN vectors in `MultiLineCheck` (28×) — dismissed/monitor.**
  Rated HIGH by the AI, but `try trace for NaN vector` is the engine's **guard firing** (it detects
  and rejects the degenerate trace), so real-world impact is ~one skipped collision trace per hit, not
  a crash/corruption. No players have reported collision problems on that map. The log doesn't name the
  offending actor, there's no clean local repro to test a fix, and redeploying an edited `.unr` forces a
  client-side version/GUID re-download on a pub server — poor cost/benefit for silent log noise. If it
  ever draws real complaints: first look for an updated community release of the map (swap the `.unr`),
  then as a last resort Rebuild+resave a COPY in UnrealEd 2 469e before any manual actor-hunt (actors at
  origin (0,0,0), degenerate movers/decoration collision). Disposition: **monitor, no action.** (2026-08-05)
- **Finding #5 `NexgenPlayerLookup112N.NexgenPlayerLookup.notifyEvent Accessed None 'Receiver'`
  — cosmetic, no fix exists, KEEP the plugin.** User actively uses NexgenPlayerLookup's player-
  history/lookup DB, so disabling the `ServerActors=NexgenPlayerLookup112N.NexgenPlayerLookup`
  line (which would remove the warning at source) is OFF the table. No build fixes it: the plugin
  is abandoned (official `NexgenPlayerLookup202` = v2.02, June 2014, a different/older lineage than
  the `112N` rebuild; no changelog anywhere addresses the Receiver None). Core Nexgen 113 was in
  dev through Aug 2022 but stalled and concerns the main controller, not this plugin. The None just
  means a lookup result is dropped when a player disconnects mid-query (frequent on high-churn maps
  like DM-Peak) — no DB loss, no gameplay effect. Disposition: **leave it.** No source locally to
  self-patch. (Researched 2026-08-05; sources: ut99.org t=5179, t=3839, t=13841.)
- **Client-brought cosmetic `Failed to load` packages are NOT server problems — do not deploy
  them.** `ELD_TauntPack002` (a `Voice=`/VoicePack taunt pack, `ELD_DNF1` = DNF taunts) and the
  custom skins (`CommandoSkins.goth*Blake`, `SGirlSkins.goth*Aryss`, `tskmskins.MekS`, etc.) come
  from individual players' login URLs. The server logs "Can't find file for package" because it
  tries to replicate the client's cosmetic content, doesn't have it, and falls back to a default.
  Purely cosmetic, zero gameplay impact. Deploying to `ServerPackages` would force ALL clients to
  download one player's taunt/skin pack and adds ACE-validation surface — not worth it. Disposition
  for these signatures in a report: **confirm benign, no action.** (Decided 2026-08-05 for the
  08-04 report; ELD was NEW that run, tied to player CHUPAMELA.)
- **The Daily task's second run on 2026-11-09 at 05:10 was a ONE-OFF, not a scheduling fault — do
  not re-engineer the trigger over it.** That day the task ran at 01:30 (scheduled) and again at
  05:10:25, both analyzing Nov 8, so the second was a wasted paid API call. Ruled out at the time:
  restart-on-failure (the 01:30 run exited 0, and its retry grid lands on :00/:30 with no run logs
  there) and missed-trigger catch-up (the 01:30 trigger did fire). **Closed 2026-11-10:** with
  `Microsoft-Windows-TaskScheduler/Operational` enabled, that night's history shows exactly one
  launch of the Daily task — 107 (time trigger) / 129 (`pwsh.exe` PID 16872) / 100 (started as
  `Strix007\Perdi`) / 200 / 201 (return code 0) / 102, all inside 01:30:01–01:30:54 — and there is
  no 05:xx run log. `LastRunTime` read 01:30. A manual start remains the likeliest explanation for
  Nov 9 and is unprovable (no history was kept then). The operational log is now the standing
  instrument: if it recurs, events 110/100 name the launching account.

## PROJECT CONVENTIONS

- **An archive's filename does NOT tell you which side produced it.** `Save-SessionArchive` names
  every local archive `server.yyyymmdd_hhmm.log` from the log's own "Log file open" time — the same
  pattern NFO's `/Logs/` rotation script used, so the two are indistinguishable by name. Provenance
  of `Raw Server Logs\` as of 2026-11-09: **2026-08-07 → 08-22** (17 files) no longer on the server
  at all; **08-23 → 10-01** (39) from NFO's `/Logs/` script; **10-03 → 11-09** (24+) from
  `/System/server-old.log` plus the live `/System/server.log` under the current code. Determine
  provenance by comparing against a `/Logs/` listing, never by the name.
- **We have never deleted anything from the server.** Every fetch is a plain `get`; the old
  `DeleteAfterDownload` key was `$false` in every version that had it, and the code only passed
  WinSCP's `-delete` when it was true. Confirmed 2026-11-09 when the `/Logs/` files stopping was
  suspected to be our doing: all 196 sessions from Aug 23 to Oct 1 are still on the server,
  including 116 we never downloaded, and `/Logs/` went quiet on 2026-10-01, three days *before* the
  2026-10-04 source switch. The gap is explained by the old `get -latest`, which fetched only the
  single newest match per run — anything that rotated between two runs was never fetched.
- **A trend/history baseline is the newest EARLIER dated entry — filter with `-lt`, never `-ne`.**
  2026-11-09: `Get-Trend` selected `$_.date -ne $curDateStr`, then sorted by date and took the
  last, i.e. the newest entry in the whole history. Forward-dated runs were right by luck, but
  re-running an older day compared it against a *later* report ("Δ vs 2026-11-08" on a Nov 7
  report) and treated that later day's signatures as already seen, so nothing could be flagged
  NEW. `$prev` derives from `$prior`, so the one filter governs both the deltas and NEW detection.
  Applies to any back-fill over a dated history file: exclude the current date **and** everything
  after it.
- **A re-run over an old day is cheap and safe, so prefer it to editing a report.** `-Date` plus
  `-NoFetch` re-reports a day from the archive; `Save-DigestHistory` replaces the same-date entry
  and re-sorts, so no duplicate history row appears, and the digest is deterministic (identical
  line/warning counts on re-run). `-Force` is needed only when the content is unchanged *and* it
  is the most recent run.
- **FTP directory listings on titan7 return stale metadata — never trust them.** 2026-10-31:
  `ls /System/*.log` reported `server.log` as 17,730 bytes modified Oct 31 03:05 while the actual
  download was 378,178 bytes with log activity through 12:44. Sizes and mtimes from a listing are
  stale/cached; only a completed download is authoritative. `Get-RemoteSessionLog` therefore probes
  existence **only by attempting the `get`** (a failed transfer is the "absent" signal). Never add
  an `ls`-based pre-check, and never let a decision depend on a listed size or mtime.
- **`ConvertFrom-Json` revives ISO date strings as `[datetime]`, so never `[string]`-cast one for
  comparison.** 2026-10-31: the duplicate-run guard compared `last-run.json`'s `session_open`
  (written with `ToString('o')`) against a fresh value, but `[string]$prev.session_open` yielded the
  culture format `10/31/2026 03:05:16`, which never matched — the guard silently never fired and
  the happy-path test still passed. Normalize **both** sides through one zone-insensitive format
  (`yyyy-MM-ddTHH:mm:ss`) before comparing. Applies to any state field read back from JSON.
- **A test run redirected with `-ConfigPath` must override `SystemFolder`, not just
  `LocalLogFolder`.** `StateFolder`/`RunLogFolder` derive from `Config.SystemFolder`, so overriding
  only `LocalLogFolder` still writes the **real** `last-run.json` and `digest-history.json`
  (happened 2026-10-31; both had to be restored by hand). Override both for an isolated test.

- **Five chronic maps are suppressed from `## Findings` (still allowed in `## Recommendations`).**
  `Config.SuppressedFindingsMaps` (regex fragments, case-insensitive): CyberSpace,
  Temple0fTheWinds (digit `0`, matched as `Temple[0O]fThe[wW]inds`), CodexEvolved,
  AncientPhobos, DarkFortress. User decision 2026-08-18: these maps' issues recur every session
  and don't need a fresh finding each report. Effective starting the 2026-08-18 run; historical
  reports were NOT regenerated to retrofit this (only 2026-08-17 was regenerated, as a
  verification test — confirmed all 8 of its findings that session happened to reference these
  maps, so Findings correctly showed "No issues were flagged" while Recommendations still named
  DM-CyberSpace/DM-Temple0fTheWinds/DM-FastPaced).
- **Player Connections table columns must be padded, and `|` in cell text becomes `¦`, not `\|`.**
  `Format-MdCell` replaces a literal `|` with the look-alike `¦` character (a real pipe would
  split a table column even when backslash-escaped — Obsidian doesn't reliably honor `\|` inside
  table cells). The Player Connections table builder in `New-ServerLogReport` computes a max
  width per column (header + all rows) and pads every cell to it, so the raw `.md` source is
  visually aligned even in a plain-text/VS-Code view, not just when rendered. Discovered
  2026-08-18 from three reports (08-10, 08-14) where names like `||sT||Madara.//`, `Arepa|kHr`
  broke the table.
- **IG+ build is bleeding-edge, NOT stale — do not "update to the stable release."** The server
  runs `InstaGibPlus_next-netcode-ef237853` (commit `ef237853`, 2026-07-28) from rxut's fork's
  `next-netcode` branch (`github.com/rxut/InstaGibPlus`). This dev line is **~238 commits AHEAD**
  of the last stable release (IG+ 11, Feb 2025 on `utspect/InstaGibPlus` master) — "updating" to
  stable would be an ~18-month netcode downgrade. As of the 08-04 log the only newer dev commit
  was `1ae891fc` (same day, a jitter-bounding config flag) — irrelevant to the report's warnings.
  So the IG+ `Accessed None` findings (#3 `bbPlayer.Died` Weapon, #6 `ST_UT_Eightball.FireRockets`
  G, #7 `ST_enforcer.PlaySelect` Owner) are **not fixable by changing build** — they're live in the
  dev tip. Also can't self-patch: no local source (only `.u`) + ACE `MD5Enable=True` validates the
  package hash, so a modified `.u` would break client validation. Correct path = upstream bug report
  to rxut (draft saved 2026-08-05). [[failed-load-offenders]] skins are the same "leave it" class.
- **Server `[Engine.GameEngine]` facts (from live `UnrealTournament.ini`, 2026-08-05):**
  `FixUpMoversBoundingBox` is NOT in the ini but the 469e default is ON (log shows it running &
  auto-patching movers) — so finding #4 (CyberSpace movers) is already auto-mitigated; setting the
  flag is a no-op. Skin packages `CommandoSkins`/`FCommandoSkins`/`SGirlSkins`/`SoldierSkins` ARE in
  `ServerPackages` (so finding #9 = missing texture *variants* within shipped packages, a version
  mismatch, not a missing package). `tskmskins` and `ELD_TauntPack002` are NOT in ServerPackages.
- **Report duplication pass (2026-08-20) — what was removed vs deliberately KEPT.** A full
  audit of the 08-19 report found ~22% of its lines restating information carried elsewhere.
  Removed: the `**Log covers:**` line under the H1; the `Log session opened` / `First log entry` /
  `Last log entry` dashboard rows (endpoints now live only in frontmatter, dashboard keeps the
  `Log covers` span); the whole `## Session & Config Overview` section; `Failed to load`
  signatures in `## Recurring Warnings` (Failed-to-Load Offenders shows the same events with real
  names). **Explicitly kept by user decision — do NOT re-propose these:** (a) the Players &
  Connections bullets that restate Health Dashboard rows, (b) findings evidence that restates the
  recurring-signature tables, (c) Recommendations that condense each finding's proposed solution.
  The Anti-Cheat section's doubled "nothing was logged" (AI callout + static line) was offered and
  not taken up.
- **Skin findings are suppressed from `## Findings` (`Config.SuppressedFindingsPatterns`).** Added
  2026-08-20: a topic-based sibling of `SuppressedFindingsMaps`, matched the same way (both lists
  unioned into one case-insensitive regex over title/evidence/root_cause/solution) and applied to
  the Findings section only. Currently just `skin`, which reaches every skin package and
  texture-variant message. Rationale is the long-standing one in RULED-OUT THEORIES: client-brought
  cosmetic packages are not server problems. They still show in Failed-to-Load Offenders (with real
  names) and may still appear in Recommendations. Fragment is deliberately broad — a finding that
  merely mentions skins in its evidence is also dropped; user accepted that trade-off.
- WinSCP saved session name is `FMJ FTP Server` (shared with UT99 ChatLog Analyzer).
- **SUPERSEDED 2026-10-04 (source is now `/System/server-old.log`, see CLAUDE.md Design notes) — kept for history. Remote log rotation changed 2026-08-09:** it is no longer the fixed `/System/server-old.log`.
  Each server start rotates the previous log to **`/Logs/server.yyyymmdd_hhmm.log`** and old ones
  **accumulate**. Config is now `RemoteLogFolder='/Logs/'` + `RemoteLogMask='server.*.log'` (the
  key `RemoteLogName` no longer exists); the fetch uses WinSCP **`get -latest`**. Newest is always
  the wanted one. `DeleteAfterDownload=$false` (never delete them).
- **Raw logs archived directly, original naming kept (2026-08-17):** `Invoke-ServerFetch`
  downloads straight into `RawLogFolder` (`ServerLogs\Raw Server Logs\`, config key
  `RawLogSubfolder`) — no `_incoming` staging folder, no rename. That folder is a **permanent,
  never-wiped archive**, not a scratch dir; after each fetch, the newest-by-name match
  (`Get-ChildItem -Filter $Config.RemoteLogMask | Sort-Object Name -Descending`) is always the
  file just downloaded, because `yyyymmdd_hhmm` naming sorts lexicographically = chronologically
  and WinSCP's `-latest` guarantees the newest remote file is always >= anything already
  archived. `LocalLogNamePattern` config key removed (nothing renames raw logs anymore); reports
  still use `ReportNamePattern` in `LocalLogFolder`, unaffected.
- **A rotated log has no `Log file closed` line** — the server is killed/restarted, not shut down
  cleanly, so `Digest.LogClosed` is empty — the "Log session closed" dashboard row was therefore
  dropped on 2026-08-09 (the field is still collected, just not rendered). The log window
  comes from `FirstEntry`/`LastEntry` instead, min/max'd over every timestamp format present:
  `Log file open MM/dd/yy`, `NetComeGo MM/dd/yy HH:mm:ss`, MapVote `yyyy/MM/dd Time > HH:mm:ss.fff`,
  and ACE `[TIME] dd-MM-yyyy / HH:mm:ss` — **ACE is day-first**, confirmed by cross-checking an
  ACE line against a same-instant NetComeGo line (`09-08-2026` == `08/09/26` == 9 Aug).
- Downloaded raw log goes to `D:\Dropbox\Gaming\UTLogs\ServerLogs\Raw Server Logs\` (original
  server-side name); the report goes to `D:\Dropbox\Gaming\UTLogs\ServerLogs\` directly (NOT
  `_system`) — kept separate on purpose so raw logs don't clutter the report/Obsidian view.
- **GOTCHA:** `-NoAnalysis` still writes a real report file, just without the AI narrative. If
  you smoke-test against a log whose session date already has a real analyzed report, it
  **overwrites that report with a stub** (`overall_status: "Unknown"`). Hit this on 2026-08-17
  testing the raw-log-archive change — clobbered the 08-13 and 08-16 reports, both recovered by
  re-running without `-NoAnalysis`. Point smoke tests at a log/date you don't mind clobbering.
- Report/log filename date = the log's "Log file open" session date, not the run date.
- Analysis is AI-assisted: a deterministic deduped **digest** (not raw lines) is sent to the
  Anthropic API (`claude-sonnet-4-6`); the key is the User env var `UT99_ANALYZER_API_KEY` (never
  `ANTHROPIC_API_KEY`: Claude Code prefers that over the Pro login and would bill the API).
- Docs (`README.md`) are finalized only after a live end-to-end test + explicit approval.
- Scheduled task runs daily at **07:30** (changed from 04:25 on 2026-10-04: NFO's restart now
  lands ~07:00, and an earlier run gets the previous-previous session). Retry
  is Task Scheduler restart-on-failure at a 30-min interval. The 04:25 grid existed to dodge 05:00.
  **Do NOT use 05:00** — the separate "Daily Restart" task force-reboots (`shutdown /r /f`) at
  05:00 every 3 days and kills the run (see CONFIRMED ROOT CAUSES). The 30-min retry grid must
  also stay off 05:00 (07:30 and its retries clear it).
  `RunOnlyIfNetworkAvailable` is
  intentionally OFF so a no-network start still runs, fails fast (exit 1), and restarts — this
  covers both "log not created yet" and "no network" with one mechanism.
- Task principal is **S4U + RunLevel Highest** ("run whether logged on or not" + "run with
  highest privileges"), matching the working `UT99 Chat Monitor - Daily` task. Registering
  S4U/Highest **requires an elevated (Run as Administrator) session** — a normal shell returns
  "Access is denied". GOTCHA: `Register-DailyTask.ps1` unregisters the old task *before*
  creating the new one, so a failed elevated step leaves NO task. Register it from an elevated
  pwsh (or via `Start-Process -Verb RunAs`, which triggers a UAC prompt).
- **Git inside Dropbox:** the project (including `.git`) syncs through Dropbox, which occasionally
  holds the index briefly, so a commit/merge can fail once with `unable to write .git/index` /
  `new index file`. Transient — there is no stale `index.lock`; retry the same command. Excluding
  `.git` from Dropbox sync would remove it.
- **Branching:** every change, including docs-only, goes on its own branch and is merged to `main`
  with `--no-ff` on explicit go-ahead; `main` is then pushed to `origin` (GitHub
  `vtak007/UT99-ServerLog-Analyzer`). Decided 2026-11-12 (user chose branches over direct-to-main).

## CHANGE LOG

Newest first. Format: `- YYYY-MM-DD — what changed`.

- 2026-11-12 — `Register-DailyTask.ps1` registers local-time triggers (daily and hourly; no UTC pin),
  so the tasks no longer shift an hour at DST changes (`fix/trigger-local-time`). Live tasks patched
  to match.

- 2026-11-12 — Docs/chore: `.gitattributes` added (`*.md` LF, `*.ps1` CRLF, see CONFIRMED ROOT
  CAUSES); accepted limitations 8–13 moved from `open-items.md` to `CLAUDE.md` **Known
  limitations** (numbers kept); `CLAUDE.md` Key files table extended.
- 2026-11-12 — Docs only (`docs/close-item-2`): **`Register-DailyTask.ps1` verified.** Run from an
  elevated shell, it registered both tasks; live state matched (daily 01:30, retry 30 min x12;
  hourly start moved to :15 with `PT1H`; both `S4U/Highest`; `LastRunTime` reset to never). The
  Downloads/`%TEMP%` XML backups are no longer needed once the first hourly run succeeds.
- 2026-11-12 — `fix/empty-signature-keys`: `Get-DigestSignatureMap` no longer stores empty-signature
  keys (`sw|`, `err|` -> 0) — `@($null)` is a one-element array, so an empty bucket produced one
  entry. `Get-Trend` also skips keys ending in `|` when listing resolved signatures, covering
  entries already in `digest-history.json`. Tested with `-NoFetch -NoAnalysis -Date 2026-11-10`
  (no empty keys stored; resolved list real). Open items 6 and 7 stay deferred.
- 2026-11-10 — Docs only (`docs/close-trend-and-double-run`): two open items closed against the
  01:30 scheduled run. **Trend fix verified in production** — the unattended run reported
  2026-11-09 and logged `Trend vs 2026-11-08` (warnings -251, scriptWarnings -49, 0 new
  signatures), rendering `Value (Δ vs 2026-11-08)` and "21 signature(s) resolved since
  2026-11-08", i.e. the newest *earlier* day, not a later one; 52s, exit 0, one API call.
  **Double-run closed** as a Nov 9 one-off (see RULED-OUT THEORIES) now that the task-history
  log is enabled and recorded a single clean launch. The empty-signature-key cosmetic bug did
  not surface in that report (all 21 resolved keys real) — latent, not fixed.
  `Register-DailyTask.ps1`'s first elevated registration run was prepped (live tasks exported
  to `%TEMP%`, elevation confirmed) but **deferred** to a later session; note in `open-items.md`
  why non-elevated is destructive there.

- 2026-11-09 — Verification pass over `open-items.md` items 1–13 plus a trend fix and the doc
  update (`fix/trend-baseline-backfill`). **Code:** `Get-Trend`'s baseline filter `-ne` -> `-lt`
  so a back-filled report compares against the newest *earlier* day (it had rendered
  "Δ vs 2026-11-08" on a Nov 7 report); `Register-DailyTask.ps1` now registers the hourly
  `-ArchiveOnly` task as well as the 01:30 daily one (`-HourlyTaskName`, `-HourlyMinute`,
  `-NoHourly`; `-Unregister` removes both), default `-Time` 07:30 -> 01:30. **Verified closed:**
  the merged Nov 8 report (2 sessions, 2 shutdown rows, correct spans); the hourly archive task
  (every `:15` exit 0, supersede fired 34,114 -> 66,882); the hourly fetch catching a session that
  never rotated; the duplicate-run guard in BOTH directions (unchanged digest -> exit 0 with no API
  call; lowered line count -> passes through to render), tested against real state in a redirected
  scratchpad so a failure could not spend a call; the old `ANTHROPIC_API_KEY` User env var, which
  no longer exists in any scope (User/Machine/Process) with both analyzers on
  `UT99_ANALYZER_API_KEY`. **Reports regenerated:** Nov 7 (was built from a 66,882-byte partial
  capture — 1,201 lines / 1 player; now the full 2,344,258-byte session, 39,447 lines / 22h46m /
  43 players / peak 18) and Nov 8 (true deltas vs Nov 7: -5 warnings, -27 script warnings, instead
  of the inflated +332/+74 measured against the partial Nov 7). **Deferred:** the 14-day cleanup of
  run logs and WinSCP XMLs (167 + 172 files, ~48/day). **Outstanding user actions:**
  `-forcelogflush` on the server command line, and the NFO support question about `/System/*.log`.
- 2026-11-08 — Shutdowns section added to the report (`Get-ShutdownEvents`): one row per server
  start giving what the server was down by, its last log activity, and the reason if logged.
- 2026-11-08 — One report per day, merged from the archive: every archived session whose
  "Log file open" date matches the report date is merged into a single report with a Sessions row
  per session, replacing "analyze whichever session is newest" and implementing what
  `Capture Manual Restarts.md` only sketched. Hourly `-ArchiveOnly` scheduled task added (first run
  18:15) so a session that never rotates is still captured.
- 2026-10-31 — Live-log fetch + supersede-archiving + duplicate-run guard (`fix/live-log-fetch-and-dedupe`). `Invoke-ServerFetch` now fetches BOTH `/System/server-old.log` (WARN if absent) and `/System/server.log` via the new `Get-RemoteSessionLog`, archives both through the new `Save-SessionArchive`, and analyzes the newest session; `Invoke-RotatedLogFetch` and the `FetchSource`/`RemoteLogFolder`/`RemoteLogMask`/`DeleteAfterDownload` keys deleted; never-overwrite replaced by a supersede rule (longer capture of the same session wins); content-keyed guard added before the API call plus a new `-Force`; `session_open` added to `last-run.json`. Verified against the live server with state+output redirected to a scratchpad and no API calls: offline digest of the Oct 31 live log (6,668 lines, report dated 2026-10-31), real fetch (server-old WARN, archived `server.20261031_0305.log`), guard fires on unchanged re-run, supersede replaced a shortened archive (28,006 -> 378,178), `-Force` bypasses. The guard was broken on first write (see the `ConvertFrom-Json` convention) and fixed before commit. API path not yet exercised under the new code — first live run is the 07:30 scheduled task on 2026-11-01.
- 2026-10-31 — Docs/memory audit only (no code change): recorded the fallback-fetch re-analysis root cause and the intermittent missing `/System/server-old.log` as a WATCH item; corrected two stale notes (scheduled runs on `UT99_ANALYZER_API_KEY` now confirmed; fallback path no longer "not live-tested").
- 2026-10-15 — API key env var renamed `ANTHROPIC_API_KEY` -> `UT99_ANALYZER_API_KEY` in `Setup.ps1`, the main script and `Register-DailyTask.ps1` comments (same fix as the ChatLog Analyzer). Re-ran `Setup.ps1` to store the new var; verified offline with `-NoFetch -LogFile` on `server.20261013_0445.log` (exit 0, report `2026-10-13` written). Scheduled 07:30 runs on the new var confirmed working daily from 2026-10-16 through 2026-10-31 (live API calls completing). Old `ANTHROPIC_API_KEY` User var still to be removed once all projects are migrated (open decision).
- 2026-10-06 — `Setup.ps1`: default `$ConfigPath` now resolved in the script body (falls back to
  `$MyInvocation.MyCommand.Path`) because `$PSScriptRoot` was empty in the `param()` default
  (`Split-Path` empty-string error, reproduced in a plain PowerShell window). The main analyzer
  script has the same param default but works under the scheduled task, so it was left as-is.
  API key is a User env var (renamed to `UT99_ANALYZER_API_KEY` on 2026-10-15); rotated by re-running Setup.ps1.
- 2026-10-04 — Source switched to `/System/server-old.log`: archived as `server.yyyymmdd_hhmm.log`
  by "Log file open" time (never overwrites), legacy `/Logs/` fetch kept as fallback
  (`Config.FetchSource`/`RemoteLogPath`), new `-ArchiveOnly` switch, default schedule 07:30
  (user changed the registered task manually). Added `Capture Manual Restarts.md` (merge-sessions
  idea, not implemented). Tested live: archive, idempotent re-run, full report `2026-10-03`.
  The 10-01 17:48 -> 10-03 17:45 sessions were never archived. Fallback path was not live-tested
  at the time; it has since been exercised repeatedly (2026-10-29/31) and is **broken** — see
  CONFIRMED ROOT CAUSES.
- 2026-08-20 — Report duplication pass. Removed the `**Log covers:**` H1 line, the three coverage
  rows from the Health Dashboard, the entire `## Session & Config Overview` section, and the
  `Failed to load` rows from `## Recurring Warnings` (replaced by a pointer line to Failed-to-Load
  Offenders). All four applied to the generator AND retro-applied to the 2026-08-19 report only
  (200 → 167 lines); earlier reports left untouched. Groups 2/4/5 of the audit (dashboard↔bullets,
  findings↔tables, recommendations↔solutions) were reviewed and deliberately kept. Audit was done
  against a published annotated artifact of the 08-19 report.
- 2026-08-20 — Added `Config.SuppressedFindingsPatterns` (`'skin'`): skin-related findings are now
  dropped from `## Findings`, using the same filter as `SuppressedFindingsMaps` (the two lists are
  unioned). Verified by a synthetic-findings unit test plus a live API run over
  `server.20260820_0325.log` — 3 findings, none skin-related, where the shipped 08-19 report had
  two. Also removed the two existing skin findings (#4, #5) from the 08-19 report.
- 2026-08-20 — Fixed `Format-MdTable` rendering a single-row table character-by-character (see
  CONFIRMED ROOT CAUSES). Latent in all tables since 2026-08-18.
- 2026-08-20 — All report tables now render column-aligned in the raw markdown. Extracted the
  padding logic that was inline in the Players & Connections builder into a shared
  `Format-MdTable` (headers / `L`-`R` aligns / rows) and routed all seven tables through it:
  Health Dashboard, Players & Connections, Issues by Map, Anti-Cheat, Recurring Script Warnings,
  Recurring Warnings, Failed-to-Load Offenders. Separator rows are now padded to full width too
  (previously 2 chars short per column). Re-padded all 11 existing reports in place with a
  throwaway script rather than regenerating (only 08-17+ still have raw logs, and a regen would
  re-run the AI); verified normalized-diff-identical apart from padding, and idempotent on re-run.
- 2026-08-18 — Added `Config.SuppressedFindingsMaps`: findings mentioning CyberSpace,
  Temple0fTheWinds, CodexEvolved, AncientPhobos, or DarkFortress are now filtered out of
  `## Findings` in `New-ServerLogReport` (Recommendations unaffected). Verified by regenerating
  2026-08-17 with and without the filter (via `git stash`) — confirmed all 8 unfiltered findings
  referenced these maps and were correctly suppressed, while Recommendations kept its mentions.
- 2026-08-18 — Fixed Player Connections table misalignment: `Format-MdCell` now replaces a
  literal `|` in player names with `¦` (was backslash-escaped `\|`, which Obsidian's table
  renderer doesn't reliably honor), and the table builder now pads every cell to a per-column
  max width so the raw markdown source is column-aligned too. Regenerated 7 of the 8 affected
  reports (08-08, 08-09, 08-10, 08-12, 08-13, 08-15, 08-16, 08-17) through the real pipeline
  against their original archived raw logs (matched by internal "Log file open" timestamp, since
  raw filename date and session date can differ by a day). 08-14's raw log no longer exists (it
  predates the 2026-08-17 permanent-archive change), so its table was patched in place with a
  one-off Python script mirroring the same padding/substitution logic instead of being
  regenerated. No raw log exists for 2026-08-11 either — no report was ever produced for that date.
- 2026-08-17 — Raw logs now download directly into `ServerLogs\Raw Server Logs\` and keep their
  original server-side name (`server.yyyymmdd_hhmm.log`) instead of being staged in `_incoming`
  and renamed to `FMJ Server Log {date}.log`. Removed the now-unused `LocalLogNamePattern`
  config key and the rename/move step; added `RawLogSubfolder` config key. Raw Server Logs is
  now a permanent archive (never wiped) instead of a scratch staging folder. Verified: regression
  test against an archived log, live end-to-end fetch (confirmed no `_incoming` created, all 10
  prior archived logs untouched, correct newest-file resolution). Also found and fixed a
  concurrent-connection parsing bug in ad-hoc analysis (player names containing `\|` broke a
  naive markdown table parser) — not a code change, just a one-off scan gotcha worth remembering.
- 2026-08-09 — Dropped the permanently-blank "Log session closed" Health Dashboard row
  (superseded by First/Last log entry). `Digest.LogClosed` is still collected, just not rendered.
- 2026-08-09 — Added **log coverage window** to the report: digest now tracks `FirstEntry`/
  `LastEntry`/`SpanText` by min/max over all four timestamp formats in the log. Surfaced as a
  bold `**Log covers:**` line under the H1, `log_first_entry`/`log_last_entry` frontmatter, three
  Health Dashboard rows, and one `LOG COVERS:` line in the API digest (so the model states the
  real uptime instead of guessing). Verified: 2026-08-08 04:35:19 → 2026-08-09 01:19:55 (21h 44m).
- 2026-08-09 — **Remote log path/name changed** to `/Logs/server.yyyymmdd_hhmm.log`. Config
  `RemoteLogName` → `RemoteLogMask`; fetch rewritten to `get -latest` into a `_incoming` staging
  folder, resolve the landed file, then move+cleanup. Verified live: pulled
  `server.20260809_0330.log` (1.63 MB) in 4s → `FMJ Server Log 2026-08-08.log`, full report written.
  Also corrected stale README scheduling text (said 05:00 ×12; actual is 04:25 ×3).
- 2026-08-05 — Triaged all 08-04 report findings to disposition (see RULED-OUT/CONVENTIONS): ELD/skins/
  voice = client cosmetic, leave; #4 movers = engine auto-mitigated; #3/#6/#7 IG+ None-derefs = cosmetic,
  can't self-patch (no source + ACE MD5), drafted upstream GitHub issue (`IGPlus-Issue-AccessedNone-draft.md`);
  #5 Nexgen Receiver = cosmetic, plugin abandoned, keep feature; #1 FortressOfNalitude NaN = engine-guarded,
  no complaints, monitor. Net: no locally-fixable code issues in this batch. Pulled live UnrealTournament.ini
  to verify (kept untracked per *.ini rule).
- 2026-08-05 — Added **Failed-to-Load Offenders** report section: new `$failLoadDict` collector
  in `Get-ServerLogDigest` captures every `^Failed to load "…"` body verbatim (real names kept,
  identical messages counted), exposed as `Digest.FailedLoads` (uncapped, sorted desc), rendered
  as a `| Count | Message |` table before Recommendations in `New-ServerLogReport`. Local-only —
  NOT added to `ConvertTo-DigestText`, so API token cost is unchanged. Surfaced `ELD_TauntPack002`
  as an entirely-missing package (30 hits) that the `<x>` bucketing had hidden. Verified via
  `-NoFetch -LogFile` against `FMJ Server Log 2026-08-04.log`.
- 2026-08-05 — Diagnosed 05:00 download failure as a collision with the "Daily Restart" task
  (`shutdown /r /f` at 05:00, every 3 days). Re-registered analyzer task at **04:25** with
  restart-on-failure 30-min × **3** (was ×12). Verified via manual run (LastResult 0, report
  written). Requires elevated shell to re-register (S4U/Highest).
- 2026-08-03 — User signed off. Wrote README.md, added .gitignore (ignores State/Runlogs/*.xml/
  *.ini), created private local + remote GitHub repo, initial commit + push.
- 2026-08-03 — Task registered S4U + RunLevel Highest (run whether logged on or not + highest
  privileges) via elevated shell, matching the ChatLog task.
- 2026-08-03 — Added features 1–3: trend/NEW-signature diffing (`State\digest-history.json`,
  Get-Trend/Save-DigestHistory), per-map issue attribution (active-map tracking + Issues-by-Map
  table + `{on <map>}` in the API digest), and connection/player analytics (NPLoader name↔ip:port
  pairing, connection-index session pairing, per-player connects/avg/total time, peak concurrent,
  churn heuristic). Documented deferred features 4–9 in `FUTURE-FEATURES.md`. Scheduled task set
  to 05:00 with 30-min restart-on-failure ×12; S4U re-registration pending user go-ahead.
- 2026-08-03 — Initial build: config.ps1, main pipeline (fetch/digest/analysis/report),
  Setup.ps1, Register-DailyTask.ps1, CLAUDE.md, MEMORY.md. Verified offline parse + full
  Claude analysis against `FMJ Server Log 2026-08-02.log`. Live WinSCP fetch not yet tested.
