; ─────────────────────────────────────────────────────────────
;  LightMenu Station – Windows Installer
;
;  HOW TO USE:
;   1. From a clean clone of this repo, just double-click
;      installer\build-installer.bat — it assembles everything (app code,
;      scripts, the node runtime) from print-agent\ and installer\assets\,
;      no manual folder prep needed.
;   2. Send dist\LightMenu-Station-Setup.exe to the restaurant.
;
;  SourceDir is set by build-installer.bat (points to staging\)
;  so the installer packages obfuscated files, not the originals.
;  There is deliberately no .internal\tunnel\ (cloudflared) staged anywhere
;  in this pipeline — the generic installer never bundles it. Restaurant
;  owners get download -> install -> open, nothing else.
; ─────────────────────────────────────────────────────────────

#ifndef SourceDir
#define SourceDir "."
#endif

#define AppName      "LightMenu Station"
#define AppVersion   "6.0.80"
#define AppPublisher "LightMenu"
#define AppURL       "https://lightmenu.com"

[Setup]
AppId={{F7A8B9C0-D1E2-3F40-A5B6-C7D8E9F01234}
AppName={#AppName}
AppVersion={#AppVersion}
AppVerName={#AppName} {#AppVersion}
AppPublisher={#AppPublisher}
AppPublisherURL={#AppURL}
DefaultDirName={localappdata}\LightMenu Station
DisableDirPage=yes
DisableProgramGroupPage=yes
OutputDir=dist
OutputBaseFilename=LightMenu-Station-Setup
SetupIconFile={#SourceDir}\.internal\app\lightmenu.ico
Compression=lzma2/ultra64
SolidCompression=yes
WizardStyle=modern
PrivilegesRequired=lowest
UninstallDisplayIcon={app}\.internal\app\lightmenu.ico
UninstallDisplayName={#AppName}
MinVersion=10.0.17763

[Languages]
Name: "english"; MessagesFile: "compiler:Default.isl"
Name: "french";  MessagesFile: "compiler:Languages\French.isl"
Name: "spanish"; MessagesFile: "compiler:Languages\Spanish.isl"

[Files]
Source: "{#SourceDir}\.internal\*"; DestDir: "{app}\.internal"; \
    Excludes: "*.log,*.lock,*.local.json,*.queue.json,*.cache.json,*.daily.json,*.bak*,ui-error.log,tunnel.log,tunnel.err.log,config.json"; \
    Flags: recursesubdirs createallsubdirs ignoreversion
; Generic logo baked at compile time (fallback for restaurants that don't
; ship their own). Copied to both {app} (legacy location) and .internal\app
; (where ui.ps1 loads it for the header logo — see ui.ps1's $logoPath).
Source: "{#SourceDir}\lightmenu.png"; DestDir: "{app}"; Flags: ignoreversion skipifsourcedoesntexist
Source: "{#SourceDir}\lightmenu.png"; DestDir: "{app}\.internal\app"; Flags: ignoreversion skipifsourcedoesntexist
; Setup.exe itself is generic and carries no restaurant secrets. The real
; config.json (restaurant_id/name/api_token, written by the web app's download
; flow) is dropped next to Setup.exe before the user runs it; if present, it's
; installed here instead of the blank placeholder baked into the compiled
; installer. "external" means it's read from disk at install time, not
; compiled into the .exe payload.
Source: "{srcexe}\config.json"; DestDir: "{app}\.internal\app"; Flags: external skipifsourcedoesntexist
; Same mechanism for a restaurant's own logo, if the download flow bundled
; one: overwrites the generic fallback above in both locations, and feeds
; the icon-regeneration step below so shortcuts get a custom icon too.
Source: "{srcexe}\lightmenu.png"; DestDir: "{app}"; Flags: external ignoreversion skipifsourcedoesntexist
Source: "{srcexe}\lightmenu.png"; DestDir: "{app}\.internal\app"; Flags: external ignoreversion skipifsourcedoesntexist

[Icons]
Name: "{userdesktop}\LightMenu Station";   Filename: "{app}\.internal\scripts\launch-gui.vbs"; WorkingDir: "{app}"; IconFilename: "{app}\.internal\app\lightmenu.ico"; Comment: "LightMenu Station"
Name: "{userstartmenu}\LightMenu Station"; Filename: "{app}\.internal\scripts\launch-gui.vbs"; WorkingDir: "{app}"; IconFilename: "{app}\.internal\app\lightmenu.ico"; Comment: "LightMenu Station"

[Run]
; Remove Mark-of-the-Web so scripts aren't blocked by Windows
Filename: "powershell.exe"; Parameters: "-NoProfile -ExecutionPolicy Bypass -Command ""Get-ChildItem -Path '{app}' -Recurse -Force | Unblock-File"""; Flags: runhidden waituntilterminated

; Add Windows Defender exclusion (prevents false-positive on node.exe)
Filename: "powershell.exe"; Parameters: "-NoProfile -Command ""Add-MpPreference -ExclusionPath '{app}'"""; Flags: runhidden waituntilterminated

; Regenerate the shortcut icon from whichever lightmenu.png just got
; installed (restaurant's own logo if the download bundled one, otherwise
; the generic fallback) — same conversion install.bat used to do per-install.
; Shortcuts already point at this .ico path, so overwriting it here still
; updates what Windows displays (icons resolve by path, not baked pixels).
Filename: "powershell.exe"; Parameters: "-NoProfile -Command ""Add-Type -AssemblyName System.Drawing; $bmp = New-Object System.Drawing.Bitmap('{app}\lightmenu.png'); $sizes = 256,128,64,48,32,16; $ms = New-Object System.IO.MemoryStream; $bw = New-Object System.IO.BinaryWriter($ms); $bw.Write([UInt16]0); $bw.Write([UInt16]1); $bw.Write([UInt16]$sizes.Count); $imgs = @(); foreach($s in $sizes){{ $resized = New-Object System.Drawing.Bitmap($s,$s); $g = [System.Drawing.Graphics]::FromImage($resized); $g.InterpolationMode = 'HighQualityBicubic'; $g.DrawImage($bmp,0,0,$s,$s); $g.Dispose(); $pms = New-Object System.IO.MemoryStream; $resized.Save($pms,[System.Drawing.Imaging.ImageFormat]::Png); $imgs += ,$pms.ToArray(); $resized.Dispose() }}; $offset = 6 + (16 * $sizes.Count); for($i=0; $i -lt $sizes.Count; $i++){{ $s = $sizes[$i]; $sz = if($s -ge 256){{0}} else {{$s}}; $bw.Write([byte]$sz); $bw.Write([byte]$sz); $bw.Write([byte]0); $bw.Write([byte]0); $bw.Write([UInt16]1); $bw.Write([UInt16]32); $bw.Write([UInt32]$imgs[$i].Length); $bw.Write([UInt32]$offset); $offset += $imgs[$i].Length }}; foreach($img in $imgs){{ $bw.Write($img) }}; [System.IO.File]::WriteAllBytes('{app}\.internal\app\lightmenu.ico', $ms.ToArray()); $bmp.Dispose()"""; Flags: runhidden waituntilterminated

; Check for latest version on first run
Filename: "{app}\.internal\runtime\node.exe"; Parameters: """{app}\.internal\scripts\updater.js"""; WorkingDir: "{app}\.internal\app"; Flags: runhidden waituntilterminated

; Launch the app when setup finishes
Filename: "wscript.exe"; Parameters: """{app}\.internal\scripts\launch-gui.vbs"""; WorkingDir: "{app}"; Flags: nowait postinstall skipifsilent; Description: "Launch LightMenu Station now"

[UninstallRun]
; Stop running processes before uninstalling
Filename: "powershell.exe"; Parameters: "-NoProfile -Command ""Get-Process node -ErrorAction SilentlyContinue | Stop-Process -Force; Get-Process powershell | Where-Object {{ $_.MainWindowTitle -like '*LightMenu*' }} | Stop-Process -Force"""; Flags: runhidden waituntilterminated

[Code]
// Windows API to set file/folder attributes (used to hide .internal)
function SetFileAttributesW(lpFileName: WideString; dwFileAttributes: DWORD): BOOL;
  external 'SetFileAttributesW@kernel32.dll stdcall';

var
  AutoStartCheckbox: TNewCheckBox;

procedure InitializeWizard;
begin
  // Add "Start with Windows" checkbox on the Finish page — checked by default
  AutoStartCheckbox := TNewCheckBox.Create(WizardForm);
  AutoStartCheckbox.Parent  := WizardForm.FinishedPage;
  AutoStartCheckbox.Left    := WizardForm.FinishedLabel.Left;
  AutoStartCheckbox.Top     := WizardForm.FinishedLabel.Top + WizardForm.FinishedLabel.Height + 20;
  AutoStartCheckbox.Width   := WizardForm.FinishedPage.ClientWidth - (WizardForm.FinishedLabel.Left * 2);
  AutoStartCheckbox.Caption := 'Start LightMenu Station automatically when Windows boots (recommended)';
  AutoStartCheckbox.Checked := True;
end;

procedure CurStepChanged(CurStep: TSetupStep);
var
  StartupLnk: String;
begin
  if CurStep = ssDone then
  begin
    // Hide .internal so it doesn't clutter the install folder
    SetFileAttributesW(ExpandConstant('{app}\.internal'), 2);

    // Clean up a v5.x-era startup entry that used a different filename —
    // it was never removed by upgrades before this, so it can linger forever.
    DeleteFile(ExpandConstant('{userstartup}\LightMenu-PrintAgent.vbs'));

    StartupLnk := ExpandConstant('{userstartup}\LightMenu Station.lnk');

    if AutoStartCheckbox.Checked then
    begin
      // Create Windows Startup folder shortcut
      CreateShellLink(
        StartupLnk,
        'LightMenu Station',
        ExpandConstant('{app}\.internal\scripts\launch-gui.vbs'),
        '',
        ExpandConstant('{app}'),
        ExpandConstant('{app}\.internal\app\lightmenu.ico'),
        0,
        SW_SHOWNORMAL
      );
    end else
    begin
      // Remove any existing startup shortcut (e.g. from prior install)
      DeleteFile(StartupLnk);
    end;
  end;
end;

procedure CurUninstallStepChanged(CurUninstallStep: TUninstallStep);
begin
  if CurUninstallStep = usPostUninstall then
    DeleteFile(ExpandConstant('{userstartup}\LightMenu Station.lnk'));
end;
