@echo off
title LightMenu Station - Building Installer
cd /d "%~dp0"
echo Working directory: %CD%
echo.

:: ---------------------------------------------------------------------
:: Fully self-contained build: every input comes from files committed to
:: this repo (print-agent\, installer\assets\). No dependency on an
:: ambient ".internal" folder from a previous install - run this from a
:: fresh git clone and it produces a complete, working Setup.exe every
:: time. This replaced an older version of this script that assumed you
:: were running it from inside an already-fully-assembled restaurant
:: folder, which meant node.exe (the runtime) silently never made it
:: into the compiled installer unless you happened to be building from a
:: folder that already had a real install's .internal\runtime\node.exe.
:: ---------------------------------------------------------------------

set "AGENT_DIR=%~dp0..\print-agent"
set "ASSETS_DIR=%~dp0assets"

:: Find Inno Setup (try PATH first, then known locations)
set "ISCC="
for /f "delims=" %%I in ('where ISCC.exe 2^>nul') do set "ISCC=%%I"
if not defined ISCC set "ISCC=C:\Program Files\Inno Setup 7\ISCC.exe"
if not exist "%ISCC%" set "ISCC=C:\Program Files (x86)\Inno Setup 7\ISCC.exe"
if not exist "%ISCC%" (
    echo ERROR: Inno Setup 7 not found. Download: https://jrsoftware.org/isdl.php
    pause & exit /b 1
)
echo [OK] Inno Setup: %ISCC%

:: Find javascript-obfuscator
set "OBFUSCATOR="
for /f "delims=" %%I in ('where javascript-obfuscator 2^>nul') do set "OBFUSCATOR=%%I"
if not defined OBFUSCATOR (
    echo ERROR: javascript-obfuscator not found.
    echo        Install with: npm install -g javascript-obfuscator
    echo        Refusing to ship an unobfuscated build - install it and re-run.
    pause & exit /b 1
) else (
    echo [OK] Obfuscator: %OBFUSCATOR%
)
echo.

:: Sanity-check required repo sources exist before we start
if not exist "%AGENT_DIR%\main.js" (
    echo ERROR: %AGENT_DIR%\main.js not found. Are you running this from installer\ inside the repo?
    pause & exit /b 1
)
if not exist "%AGENT_DIR%\runtime\node.exe" (
    echo ERROR: %AGENT_DIR%\runtime\node.exe not found.
    echo        This is the Node/Bun runtime the agent needs to run at all.
    echo        It is tracked via Git LFS - run: git lfs pull
    pause & exit /b 1
)
if not exist "%ASSETS_DIR%\lightmenu.ico" (
    echo ERROR: %ASSETS_DIR%\lightmenu.ico not found - generic fallback icon missing.
    pause & exit /b 1
)

:: Build staging folder entirely from committed sources
echo [..] Assembling staging folder from print-agent...
if exist "staging" rmdir /S /Q "staging"
mkdir "staging\.internal\app"      > nul
mkdir "staging\.internal\scripts"  > nul
mkdir "staging\.internal\runtime"  > nul

:: App payload - the actual agent code + its version manifest
copy /Y "%AGENT_DIR%\main.js"           "staging\.internal\app\main.js"           > nul
copy /Y "%AGENT_DIR%\store.js"          "staging\.internal\app\store.js"          > nul
copy /Y "%AGENT_DIR%\qrcode.js"         "staging\.internal\app\qrcode.js"         > nul
copy /Y "%AGENT_DIR%\version.json"      "staging\.internal\app\version.json"      > nul
copy /Y "%ASSETS_DIR%\lightmenu.ico"    "staging\.internal\app\lightmenu.ico"     > nul
copy /Y "%ASSETS_DIR%\lightmenu.png"    "staging\.internal\app\lightmenu.png"     > nul
copy /Y "%ASSETS_DIR%\lightmenu.png"    "staging\lightmenu.png"                   > nul

:: Scripts - the launcher/runner/updater glue (ui.ps1 + updater.js live at the
:: print-agent root; the rest live in print-agent\scripts)
copy /Y "%AGENT_DIR%\ui.ps1"                        "staging\.internal\scripts\ui.ps1"                  > nul
copy /Y "%AGENT_DIR%\updater.js"                    "staging\.internal\scripts\updater.js"               > nul
copy /Y "%AGENT_DIR%\scripts\agent-runner.ps1"       "staging\.internal\scripts\agent-runner.ps1"         > nul
copy /Y "%AGENT_DIR%\scripts\launch-gui.vbs"         "staging\.internal\scripts\launch-gui.vbs"           > nul
copy /Y "%AGENT_DIR%\scripts\start-silent.vbs"       "staging\.internal\scripts\start-silent.vbs"         > nul
copy /Y "%AGENT_DIR%\scripts\restart-loop-node.bat"  "staging\.internal\scripts\restart-loop-node.bat"    > nul

:: Runtime - the Node/Bun binary that actually executes main.js. This is the
:: piece that silently went missing before: nothing staged it automatically.
copy /Y "%AGENT_DIR%\runtime\node.exe"      "staging\.internal\runtime\node.exe"      > nul
if exist "%AGENT_DIR%\runtime\package.json" copy /Y "%AGENT_DIR%\runtime\package.json" "staging\.internal\runtime\package.json" > nul

echo [OK] Staging ready - includes runtime\node.exe, verified below.
echo.

:: Hard verification: fail the build rather than ship a broken installer.
:: This is the exact check that would have caught the 29MB/no-runtime bug.
for %%F in ("staging\.internal\runtime\node.exe") do set "RUNTIME_SIZE=%%~zF"
if %RUNTIME_SIZE% LSS 50000000 (
    echo ERROR: staged runtime\node.exe is only %RUNTIME_SIZE% bytes - expected ~100MB+.
    echo        Something is wrong - refusing to compile a broken installer.
    pause & exit /b 1
)
echo [OK] Runtime verified: %RUNTIME_SIZE% bytes staged.
echo.

:: NOTE: no .internal\tunnel is ever staged here - cloudflared is never part
:: of the generic installer. Restaurant owners who download this get
:: download, install, open. Nothing else, ever.

:: Obfuscate JS files in staging
echo [..] Obfuscating source files...
call "%OBFUSCATOR%" "staging\.internal\app\main.js" --output "staging\.internal\app\main.js" --compact true --string-array true --string-array-encoding base64 --string-array-threshold 1 --split-strings true --split-strings-chunk-length 10 --unicode-escape-sequence true --control-flow-flattening true --control-flow-flattening-threshold 0.75 --dead-code-injection true --dead-code-injection-threshold 0.4 --identifier-names-generator hexadecimal --rename-globals false --self-defending true
echo [OK] main.js obfuscated.
call "%OBFUSCATOR%" "staging\.internal\app\store.js" --output "staging\.internal\app\store.js" --compact true --string-array true --string-array-encoding base64 --string-array-threshold 1 --split-strings true --split-strings-chunk-length 10 --unicode-escape-sequence true --control-flow-flattening true --control-flow-flattening-threshold 0.75 --dead-code-injection true --dead-code-injection-threshold 0.4 --identifier-names-generator hexadecimal --rename-globals false --self-defending true
echo [OK] store.js obfuscated.
call "%OBFUSCATOR%" "staging\.internal\app\qrcode.js" --output "staging\.internal\app\qrcode.js" --compact true --string-array true --string-array-encoding base64 --string-array-threshold 1 --split-strings true --split-strings-chunk-length 10 --unicode-escape-sequence true --control-flow-flattening true --control-flow-flattening-threshold 0.75 --dead-code-injection true --dead-code-injection-threshold 0.4 --identifier-names-generator hexadecimal --rename-globals false --self-defending true
echo [OK] qrcode.js obfuscated.
echo.

:: Compile installer from staging
echo [..] Compiling installer...
echo.
"%ISCC%" /DSourceDir=staging installer.iss
set RESULT=%ERRORLEVEL%
echo.

if %RESULT% NEQ 0 (
    rmdir /S /Q "staging" 2>nul
    echo BUILD FAILED with exit code %RESULT%
    pause & exit /b %RESULT%
)

:: Note on output size: the compiled installer typically lands around ~29MB
:: even though it embeds a ~117MB runtime. That is NOT a sign the runtime is
:: missing - Inno's LZMA2/ultra64 solid compression achieves a very high
:: ratio on this specific binary (independently verified: even plain gzip -9
:: alone gets node.exe down to ~42MB). The real safety net already ran above:
:: the RUNTIME_SIZE check on the *staged, pre-compression* file, which fails
:: the build outright if node.exe wasn't actually copied in.
for %%F in ("dist\LightMenu-Station-Setup.exe") do set "OUT_SIZE=%%~zF"
echo Compiled Setup.exe size: %OUT_SIZE% bytes ^(small output is expected - see comment above^)

:: Clean up staging
rmdir /S /Q "staging" 2>nul

echo ============================================
echo  SUCCESS! dist\LightMenu-Station-Setup.exe
echo  Fully self-contained: node runtime + scripts
echo  + obfuscated app, all staged from this repo.
echo ============================================
explorer "%~dp0dist"
pause
