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
    # Remote folder containing the rotated server log (relative to the saved
    # session's home directory). The UT99 engine writes server.log here and
    # rotates it to server-old.log.
    RemoteLogFolder   = '/System/'

    # Exact remote file to download.
    RemoteLogName     = 'server-old.log'

    # If $true, delete the log from the server after a verified download.
    # Leave $false - server-old.log is the server's own rotated log.
    DeleteAfterDownload = $false

    # --- Local paths ---------------------------------------------------------
    # Folder where the downloaded log AND the generated report are written.
    LocalLogFolder    = 'D:\Dropbox\Gaming\UTLogs\ServerLogs'

    # System folder for state and run logs (kept with the project, separate
    # from the log/report output folder above).
    SystemFolder      = 'D:\Dropbox\Computing1\BatchFiles_Scripts\Claude Projects\UT99\UT99 ServerLog Analyzer\_system'

    # Naming patterns. {date} is replaced with the report date (yyyy-MM-dd).
    LocalLogNamePattern = 'FMJ Server Log {date}.log'
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

    # --- Reports -------------------------------------------------------------
    # If $true, opens the report when the script finishes a non-scheduled run.
    # Has no effect when run by Task Scheduler.
    OpenReportOnInteractiveRun = $true
}

# Export the hashtable so dot-sourcing scripts can use it.
$Config
