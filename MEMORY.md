# UT99 ServerLog Analyzer — Project Memory

Persistent notes for this project. Read at the start of every session.
See `CLAUDE.md` for project-specific details.

## CONFIRMED ROOT CAUSES

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

## RULED-OUT THEORIES

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

## PROJECT CONVENTIONS

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
- WinSCP saved session name is `FMJ FTP Server` (shared with UT99 ChatLog Analyzer).
- **Remote log rotation changed 2026-08-09:** it is no longer the fixed `/System/server-old.log`.
  Each server start rotates the previous log to **`/Logs/server.yyyymmdd_hhmm.log`** and old ones
  **accumulate**. Config is now `RemoteLogFolder='/Logs/'` + `RemoteLogMask='server.*.log'` (the
  key `RemoteLogName` no longer exists); the fetch uses WinSCP **`get -latest`** into a `_incoming`
  staging folder because the remote name isn't known in advance. Newest is always the wanted one.
  `DeleteAfterDownload=$false` (never delete them).
- **A rotated log has no `Log file closed` line** — the server is killed/restarted, not shut down
  cleanly, so `Digest.LogClosed` is empty and that dashboard row renders blank. The log window
  comes from `FirstEntry`/`LastEntry` instead, min/max'd over every timestamp format present:
  `Log file open MM/dd/yy`, `NetComeGo MM/dd/yy HH:mm:ss`, MapVote `yyyy/MM/dd Time > HH:mm:ss.fff`,
  and ACE `[TIME] dd-MM-yyyy / HH:mm:ss` — **ACE is day-first**, confirmed by cross-checking an
  ACE line against a same-instant NetComeGo line (`09-08-2026` == `08/09/26` == 9 Aug).
- Downloaded log and report both go to `D:\Dropbox\Gaming\UTLogs\ServerLogs` (NOT `_system`).
- Report/log filename date = the log's "Log file open" session date, not the run date.
- Analysis is AI-assisted: a deterministic deduped **digest** (not raw lines) is sent to the
  Anthropic API (`claude-sonnet-4-6`); `ANTHROPIC_API_KEY` is a User env var.
- Docs (`README.md`) are finalized only after a live end-to-end test + explicit approval.
- Scheduled task runs daily at **04:25** (server boots 02:00–05:00, creating the log). Retry
  is Task Scheduler restart-on-failure: 30-min interval × 3 (04:25/04:55/05:25/05:55).
  **Do NOT use 05:00** — the separate "Daily Restart" task force-reboots (`shutdown /r /f`) at
  05:00 every 3 days and kills the run (see CONFIRMED ROOT CAUSES). The 30-min retry grid must
  also stay off 05:00, hence 04:25 (not 04:30, whose grid would hit 05:00).
  `RunOnlyIfNetworkAvailable` is
  intentionally OFF so a no-network start still runs, fails fast (exit 1), and restarts — this
  covers both "log not created yet" and "no network" with one mechanism.
- Task principal is **S4U + RunLevel Highest** ("run whether logged on or not" + "run with
  highest privileges"), matching the working `UT99 Chat Monitor - Daily` task. Registering
  S4U/Highest **requires an elevated (Run as Administrator) session** — a normal shell returns
  "Access is denied". GOTCHA: `Register-DailyTask.ps1` unregisters the old task *before*
  creating the new one, so a failed elevated step leaves NO task. Register it from an elevated
  pwsh (or via `Start-Process -Verb RunAs`, which triggers a UAC prompt).

## CHANGE LOG

Newest first. Format: `- YYYY-MM-DD — what changed`.

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
