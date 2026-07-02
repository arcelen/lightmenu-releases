@echo off
title LightMenu Print Server
setlocal

REM Paths relative to this script (.internal\scripts\)
set "NODE=%~dp0..\runtime\node.exe"
set "APP=%~dp0..\app\main.js"
set "UPDATER=%~dp0updater.js"
set "TUNNEL_DIR=%~dp0..\tunnel"
set "ROOT=%~dp0..\.."

cd /d "%ROOT%"

REM ── Start Cloudflare tunnel in its own minimized window ──────────────────────
if exist "%TUNNEL_DIR%\cloudflared.exe" (
    start "LightMenu Tunnel" /MIN "%TUNNEL_DIR%\cloudflared.exe" tunnel --config "%TUNNEL_DIR%\config.yml" run
)

:NODE_LOOP
echo [%TIME%] Checking for updates...
"%NODE%" "%UPDATER%"
echo [%TIME%] Starting print server...
"%NODE%" "%APP%"
echo [%TIME%] Print server exited, restarting in 3 seconds...
timeout /t 3 /nobreak >nul
goto NODE_LOOP
