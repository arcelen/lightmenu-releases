# LightMenu Print Agent - Background Runner
# ------------------------------------------
# Starts the cloudflared tunnel + node.exe main.js with all stdout/stderr
# piped into events.log. The UI window tails that log to show live activity.
#
# This script has ONE job: keep node.exe alive and writing to events.log.
# It does NOT change anything about how main.js prints — same arguments,
# same working directory, same env. Output redirection is the only diff
# vs. running node.exe in a CMD window.

$ErrorActionPreference = 'SilentlyContinue'

$scriptDir   = Split-Path -Parent $MyInvocation.MyCommand.Definition
$rootDir     = Resolve-Path "$scriptDir\..\.."
$nodeExe     = "$scriptDir\..\runtime\node.exe"
$appJs       = "$scriptDir\..\app\main.js"
$updaterJs   = "$scriptDir\updater.js"
$logPath     = "$scriptDir\..\app\events.log"
$tunnelDir   = "$scriptDir\..\tunnel"
$lockFile    = "$scriptDir\..\app\.agent.lock"

# ── Single-instance guard ────────────────────────────────────────────────────
# If another runner is already alive, bail. The GUI launcher uses this to
# avoid spawning a second copy when the user double-clicks the icon twice.
if (Test-Path $lockFile) {
    $pidInLock = Get-Content $lockFile -ErrorAction SilentlyContinue
    if ($pidInLock -and (Get-Process -Id $pidInLock -ErrorAction SilentlyContinue)) {
        exit 0
    }
}
$PID | Out-File -FilePath $lockFile -Force

# ── Header banner in events.log ───────────────────────────────────────────────
$banner = @"

================================================================
  LightMenu Print Agent — started $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')
================================================================
"@
Add-Content -Path $logPath -Value $banner -Encoding UTF8

# ── Start tunnel ──────────────────────────────────────────────────────────────
$tunnelExe    = "$tunnelDir\cloudflared.exe"
$tunnelConfig = "$tunnelDir\config.yml"
if (Test-Path $tunnelExe) {
    Start-Process -FilePath $tunnelExe `
        -ArgumentList "tunnel","--config","`"$tunnelConfig`"","run" `
        -WindowStyle Hidden `
        -RedirectStandardOutput "$scriptDir\..\app\tunnel.log" `
        -RedirectStandardError  "$scriptDir\..\app\tunnel.err.log" | Out-Null
}

# ── Loop: run updater + node, restart on exit ────────────────────────────────
while ($true) {
    # Light-touch update check (writes to events.log too)
    Add-Content -Path $logPath -Value "[$(Get-Date -Format 'HH:mm:ss')] Checking for updates..." -Encoding UTF8
    & $nodeExe $updaterJs 2>&1 | Out-File -Append -Encoding UTF8 $logPath

    Add-Content -Path $logPath -Value "[$(Get-Date -Format 'HH:mm:ss')] Starting print server..." -Encoding UTF8
    & $nodeExe $appJs 2>&1 | Out-File -Append -Encoding UTF8 $logPath

    Add-Content -Path $logPath -Value "[$(Get-Date -Format 'HH:mm:ss')] Print server exited - restarting in 3s..." -Encoding UTF8
    Start-Sleep -Seconds 3

    # Trim events.log to last ~2000 lines to keep it manageable
    if ((Get-Item $logPath -ErrorAction SilentlyContinue).Length -gt 1MB) {
        $tail = Get-Content $logPath -Tail 2000
        $tail | Set-Content $logPath -Encoding UTF8 -Force
    }
}
