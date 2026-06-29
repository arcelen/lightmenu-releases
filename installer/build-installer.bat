@echo off
title LightMenu Station - Building Installer
cd /d "%~dp0"
echo Working directory: %CD%
echo.

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
    echo [!!] javascript-obfuscator not found - building WITHOUT obfuscation.
    echo      Install with: npm install -g javascript-obfuscator
) else (
    echo [OK] Obfuscator: %OBFUSCATOR%
)
echo.

:: Check restaurant folder
if not exist ".internal" (
    echo ERROR: .internal folder not found. Run this from the restaurant folder.
    pause & exit /b 1
)

:: Build staging folder
echo [..] Preparing staging folder...
if exist "staging" rmdir /S /Q "staging"
xcopy /E /I /Q /Y ".internal" "staging\.internal" > nul
if exist "lightmenu.png" copy /Y "lightmenu.png" "staging\lightmenu.png" > nul
echo [OK] Staging ready.
echo.

:: Obfuscate JS files in staging
if defined OBFUSCATOR (
    echo [..] Obfuscating source files...
    if exist "staging\.internal\app\main.js" (
        "%OBFUSCATOR%" "staging\.internal\app\main.js" --output "staging\.internal\app\main.js" --compact true --string-array true --string-array-encoding base64 --identifier-names-generator hexadecimal --rename-globals false --self-defending false
        echo [OK] main.js obfuscated.
    )
    if exist "staging\.internal\app\store.js" (
        "%OBFUSCATOR%" "staging\.internal\app\store.js" --output "staging\.internal\app\store.js" --compact true --string-array true --string-array-encoding base64 --identifier-names-generator hexadecimal --rename-globals false --self-defending false
        echo [OK] store.js obfuscated.
    )
    if exist "staging\.internal\app\qrcode.js" (
        "%OBFUSCATOR%" "staging\.internal\app\qrcode.js" --output "staging\.internal\app\qrcode.js" --compact true --string-array true --string-array-encoding base64 --identifier-names-generator hexadecimal --rename-globals false --self-defending false
        echo [OK] qrcode.js obfuscated.
    )
    echo.
)

:: Compile installer from staging
echo [..] Compiling installer...
echo.
"%ISCC%" /DSourceDir=staging installer.iss
set RESULT=%ERRORLEVEL%
echo.

:: Clean up staging
rmdir /S /Q "staging" 2>nul

if %RESULT% NEQ 0 (
    echo BUILD FAILED with exit code %RESULT%
    pause & exit /b %RESULT%
)

echo ============================================
echo  SUCCESS! dist\LightMenu-Station-Setup.exe
echo  Source files are protected and obfuscated.
echo ============================================
explorer "%~dp0dist"
pause
