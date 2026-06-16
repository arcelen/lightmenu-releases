# LightMenu Print Agent — startup registration
# ------------------------------------------------------------
# Registers a Windows Scheduled Task that launches the agent automatically
# at user logon, so a PC reboot or crash mid-shift no longer requires someone
# to remember to relaunch it manually.
#
# Run this once, from this folder, in a normal (non-admin) PowerShell window:
#   powershell -ExecutionPolicy Bypass -File install-startup.ps1
#
# Safe to re-run — it replaces any existing "LightMenuPrintAgent" task.

$ErrorActionPreference = 'Stop'

$agentDir = $PSScriptRoot
$mainJs   = Join-Path $agentDir 'main.js'

if (-not (Test-Path $mainJs)) {
    Write-Host "Could not find main.js next to this script ($agentDir). Run this from the print agent folder." -ForegroundColor Red
    exit 1
}

$nodeCmd = Get-Command node -ErrorAction SilentlyContinue
if (-not $nodeCmd) {
    Write-Host "Node.js was not found on PATH. Install Node.js, then re-run this script." -ForegroundColor Red
    exit 1
}

$taskName = "LightMenuPrintAgent"

$action  = New-ScheduledTaskAction -Execute $nodeCmd.Source -Argument "`"$mainJs`"" -WorkingDirectory $agentDir
$trigger = New-ScheduledTaskTrigger -AtLogOn
$settings = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -StartWhenAvailable -RestartCount 5 -RestartInterval (New-TimeSpan -Minutes 1)
$principal = New-ScheduledTaskPrincipal -UserId $env:USERNAME -LogonType Interactive -RunLevel Limited

Unregister-ScheduledTask -TaskName $taskName -Confirm:$false -ErrorAction SilentlyContinue

Register-ScheduledTask -TaskName $taskName -Action $action -Trigger $trigger -Settings $settings -Principal $principal -Description "Starts the LightMenu print agent automatically at logon and restarts it if it crashes." | Out-Null

Write-Host "Done. The print agent will now start automatically next time you log in." -ForegroundColor Green
Write-Host "Starting it now..." -ForegroundColor Green
Start-ScheduledTask -TaskName $taskName
