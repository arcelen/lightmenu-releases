; ─────────────────────────────────────────────────────────────
;  LightMenu Station – Windows Installer
;
;  HOW TO USE:
;   1. Copy installer.iss and build-installer.bat into the restaurant folder
;      (the folder that contains .internal\ and lightmenu.png)
;   2. Double-click build-installer.bat
;   3. Send dist\LightMenu-Station-Setup.exe to the restaurant
;
;  SourceDir is set by build-installer.bat (points to staging\)
;  so the installer packages obfuscated files, not the originals.
; ─────────────────────────────────────────────────────────────

#ifndef SourceDir
#define SourceDir "."
#endif

#define AppName      "LightMenu Station"
#define AppVersion   "6.0.70"
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
SetupIconFile=.internal\app\lightmenu.ico
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
    Excludes: "*.log,*.lock,*.local.json,*.queue.json,*.cache.json,*.daily.json,*.bak*,ui-error.log,tunnel.log,tunnel.err.log"; \
    Flags: recursesubdirs createallsubdirs ignoreversion
Source: "{#SourceDir}\lightmenu.png"; DestDir: "{app}"; Flags: ignoreversion skipifsourcedoesntexist

[Icons]
Name: "{userdesktop}\LightMenu Station";   Filename: "{app}\.internal\scripts\launch-gui.vbs"; WorkingDir: "{app}"; IconFilename: "{app}\.internal\app\lightmenu.ico"; Comment: "LightMenu Station"
Name: "{userstartmenu}\LightMenu Station"; Filename: "{app}\.internal\scripts\launch-gui.vbs"; WorkingDir: "{app}"; IconFilename: "{app}\.internal\app\lightmenu.ico"; Comment: "LightMenu Station"

[Run]
; Remove Mark-of-the-Web so scripts aren't blocked by Windows
Filename: "powershell.exe"; Parameters: "-NoProfile -ExecutionPolicy Bypass -Command ""Get-ChildItem -Path '{app}' -Recurse -Force | Unblock-File"""; Flags: runhidden waituntilterminated

; Add Windows Defender exclusion (prevents false-positive on node.exe)
Filename: "powershell.exe"; Parameters: "-NoProfile -Command ""Add-MpPreference -ExclusionPath '{app}'"""; Flags: runhidden waituntilterminated

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
