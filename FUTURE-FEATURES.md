# UT99 ServerLog Analyzer — Future Feature Backlog

Ideas evaluated on 2026-08-03. Features **1 (trend/NEW diffing)**, **2 (per-map attribution)**,
and **3 (connection/player analytics)** are **implemented**. The items below are documented for
later implementation. Each note includes where it would hook into the existing pipeline
(`_system\Bin\UT99 ServerLog Analyzer.ps1`).

---

## 4. Crash / restart / uptime verdict

**Value:** Turn a silent crash into a top-line alert.

**How:** The digest already counts `Log file open` events as `Restarts`. Extend the scan to:
- Detect a session that ended in `appError` / `Critical` / no matching `Log file closed`.
- Parse open/close timestamps to compute uptime per session and total.
- Surface "server restarted N times / crashed at HH:MM" as a dedicated finding and a
  frontmatter field (`crashed: true/false`), and colour the status callout accordingly.

**Hook:** add fields to `Get-ServerLogDigest` return object; render a "Stability" block in
`New-ServerLogReport` above the dashboard; feed a `STABILITY:` line into `ConvertTo-DigestText`.

---

## 5. Config-drift alarm

**Value:** Catch a mutator/package that silently stopped loading after an update.

**How:** Save a baseline of `ServerPackages` + `Mutators` + key command-line switches to
`State\config-baseline.json` (write once, or on demand via a `-SetBaseline` switch). Each run,
diff current vs baseline and flag **removed** entries (High) and **added** entries (Info).

**Hook:** new `Compare-ConfigBaseline` function run after the digest; render a "Config Drift"
section; include the diff in the API digest so the model can comment.

---

## 6. Alerting + report upload

**Value:** Learn about problems without opening Obsidian.

**How (two parts):**
- **Discord webhook / email:** if any finding is `High`/`Critical` (or a NEW signature appears),
  POST a short summary to a configured Discord webhook URL (`Invoke-RestMethod`). Add
  `AlertWebhookUrl` + `AlertMinSeverity` to `config.ps1`.
- **Report upload:** reuse the ChatLog Analyzer's `Invoke-ReportUpload` pattern (WinSCP `put`)
  to push the `.md` (or an HTML render) back to the server. Add `UploadReport` +
  `ReportUploadFolder` to `config.ps1`.

**Hook:** after `New-ServerLogReport` in Main; gate on config flags.

---

## 7. Obsidian dashboard note (MOC)

**Value:** Proper Obsidian navigation + at-a-glance trend across days.

**How:** After each run, regenerate `_FMJ Server Health.md` in the report folder:
- A trend table (date · status · warnings · errors · restarts · peak players) built from
  `State\digest-history.json` (already maintained by Feature 1).
- `[[FMJ Server Log Analysis YYYY-MM-DD]]` wikilinks to each daily report.
- Optionally a small ASCII/mermaid sparkline of warnings/errors over time.

**Hook:** new `New-HealthDashboardNote` function reading `digest-history.json`; call in Main.

---

## 8. Missing-content manifest

**Value:** Make the missing-skin fix copy-paste.

**How:** The digest already isolates `Failed to load ... Object not found: Texture <Pkg>.<obj>`
warnings. Group by package, and emit a ready-to-paste block: the list of packages to add to a
redirect / `ServerPackages`, plus a note on which are player skins vs. genuinely missing server
content.

**Hook:** derive from `warnDict` inside `Get-ServerLogDigest` (add a `MissingContent` list);
render a "Missing Content Manifest" section with a fenced code block.

---

## 9. Tickrate / performance extraction

**Value:** Performance is critical for a DM server; ties into the existing **UT99 TickLogger**
project (`../UT99 TickLogger`).

**How:** If `server-old.log` (or a companion log written by TickLogger) contains tick/frame
data, extract avg/min tick, flag sustained drops below a threshold, and correlate low-tick
windows with specific maps (reuse the Feature 2 active-map tracking). Add a `Performance`
section and a `PerfThresholdTPS` config value.

**Hook:** new detector in the scan loop keyed on the TickLogger line format; render a
"Performance" section; feed `PERFORMANCE:` into the digest text.

---

## Considered but dropped

- **Per-player country/geo:** the log only shows `IpToCountry` package *loading*, not per-player
  country results, so this would require an external GeoIP lookup (offline dependency). Revisit
  only if a GeoIP database is added locally.
