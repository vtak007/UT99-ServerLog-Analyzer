It's feasible and moderate in size. The simplest approach is to treat a report as covering every archived session since the last report, not just one log.

**How it would work**
1. **Watermark:** `last-run.json` already records `source_log`. The 07:30 run (and `-ArchiveOnly` runs) archive new logs as planned. The report step then selects every archived `server.yyyymmdd_hhmm.log` newer than that watermark, sorted by name, which is chronological.
2. **Combine:** concatenate those logs into one temp file and feed it to the existing `Get-ServerLogDigest`. The digest already takes the min and max of all timestamps for the coverage span. Signatures are deduplicated and counted, and the API input stays bounded, so token cost stays flat.
3. **Report:** the title and frontmatter show the sessions covered, for example "3 sessions, 10/03 17:45 → 10/04 07:00", with a short per-session list. The report is named for the last session's date. Then update the watermark.

**Things I'd need to handle**
- **Restart boundaries:** a connect with no matching disconnect at the end of a session (the file just stops) could skew session times and "Total time". I'd close open sessions at each log's last timestamp.
- **Per-session fields:** engine, mutators and package list come from the first "Log file open" block. They'd be taken from the latest session instead.
- **Trend comparison:** `digest-history.json` compares against the previous report. A merged report would count as one entry, which is fine.
- **First run after the change:** the watermark is `server.20261001_1748.log`. Sessions from 10/03 17:45 onward would be merged into one report, and the 10/01 17:48 → 10/03 17:45 gap stays lost, because nothing archived it.
- **Mixed sources:** merging only makes sense for logs archived from `server-old.log`. The NFO `/Logs/` copies could duplicate the same session under a different minute, so the fallback path stays single-log.

**Cost:** about 60–100 lines of PowerShell, mostly the selection, the boundary handling and the report header. It's testable offline with `-NoFetch` against the archive, with no server access needed.

**How it fits the options:** it works with either A or B. The merge only needs the archive to contain the manual-restart sessions. The scheduled archive task (A) means you never have to remember to run it. With A and merging together, a manual restart, an NFO restart and the morning report all combine automatically.

I'd stage it as two commits on the same branch: first the fetch and archive work (with `-ArchiveOnly` and the 07:30 schedule), then the multi-session merge. That way you can test each on its own.
