# ==============================================================================
#  UT99 ServerLog Analyzer - Configuration
#  Edit the values below to match your setup. Save the file when done.
# ==============================================================================

$Config = @{

    # --- WinSCP --------------------------------------------------------------
    # The exact name of your saved session in WinSCP (same session the
    # ChatLog Analyzer uses).
    WinSCPSessionName = 'FMJ FTP Server'

    # Full path to winscp.com (the scripting console, NOT WinSCP.exe).
    # Default install location for WinSCP 6.5.x on Windows 11:
    WinSCPcomPath     = 'C:\Program Files (x86)\WinSCP\WinSCP.com'

    # --- Server side ---------------------------------------------------------
    # Every run fetches BOTH of these and archives both, so a session can't be
    # lost (see "Live-log fetch" in CLAUDE.md Design notes).

    # UT99's previous-session log: server.log is rotated here at every restart.
    # Preferred source when present because the session is complete - but it is
    # NOT reliably present (confirmed absent 2026-10-31 despite a restart), so a
    # failed fetch of this path is a warning, not an error.
    RemoteLogPath     = '/System/server-old.log'

    # The live, currently-open session log. Exists whenever the server is
    # running, so this is the dependable source; a failed fetch IS an error.
    RemoteLivePath    = '/System/server.log'

    # --- Local paths ---------------------------------------------------------
    # Folder where the downloaded log AND the generated report are written.
    LocalLogFolder    = 'D:\Dropbox\Gaming\UTLogs\ServerLogs'

    # System folder for state and run logs (kept with the project, separate
    # from the log/report output folder above).
    SystemFolder      = 'D:\Dropbox\Computing1\BatchFiles_Scripts\Claude Projects\UT99\UT99 ServerLog Analyzer\_system'

    # Subfolder (under LocalLogFolder) where raw downloaded logs are archived,
    # kept separate from the generated reports. Raw logs keep their original
    # server-side name (e.g. server.20260817_0500.log) - nothing renames them.
    RawLogSubfolder = 'Raw Server Logs'

    # Naming pattern for the generated report. {date} is replaced with the
    # report date (yyyy-MM-dd).
    ReportNamePattern   = 'FMJ Server Log Analysis {date}.md'

    # --- Analysis ------------------------------------------------------------
    # Anthropic API model. claude-sonnet-4-6 gives strong analysis quality.
    # claude-haiku-4-5-20251001 is cheaper/faster if cost matters.
    ApiModel          = 'claude-sonnet-4-6'

    # Maximum tokens in the model's response. 8192 is ample for a full report.
    ApiMaxTokens      = 8192

    # Cap on how many unique signatures per bucket are forwarded to the API.
    # Keeps token usage flat regardless of how large the log is.
    MaxSignaturesPerBucket = 25

    # --- Findings filtering ---------------------------------------------------
    # Map name fragments (case-insensitive regex) whose findings are suppressed from the
    # "## Findings" section only (still shown in "## Recommendations" if the AI mentions them
    # there). These maps' issues recur every session and the admin has decided they don't need
    # a fresh finding each report.
    SuppressedFindingsMaps = @(
        'CyberSpace',
        'Temple[0O]fThe[wW]inds',
        'CodexEvolved',
        'AncientPhobos',
        'DarkFortress'
    )

    # Topic fragments (case-insensitive regex) whose findings are suppressed from the
    # "## Findings" section only - same filter as SuppressedFindingsMaps above, but matched on
    # subject matter rather than map name. 'skin' covers every skin package and texture-variant
    # message (CommandoSkins, FCommandoSkins, SGirlSkins, SoldierSkins, TSkMSkins, ...): these are
    # client-side cosmetics the server can't and shouldn't fix, so they don't warrant a finding.
    # They still appear in Failed-to-Load Offenders and, if the model raises them, Recommendations.
    SuppressedFindingsPatterns = @(
        'skin'
    )

    # --- Reports -------------------------------------------------------------
    # If $true, opens the report when the script finishes a non-scheduled run.
    # Has no effect when run by Task Scheduler.
    OpenReportOnInteractiveRun = $true
}

# Export the hashtable so dot-sourcing scripts can use it.
$Config
