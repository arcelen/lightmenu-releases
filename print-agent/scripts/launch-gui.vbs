' LightMenu Print Agent - GUI Launcher
' Wraps PowerShell so no console window flashes.
' 1) Ensures the background agent-runner is alive
' 2) Opens the UI window

Dim fso, shell, scriptDir
Set fso = CreateObject("Scripting.FileSystemObject")
Set shell = CreateObject("WScript.Shell")
scriptDir = fso.GetParentFolderName(WScript.ScriptFullName)

' Window-style codes: 0 = hidden, 1 = normal
' Last arg: True = wait, False = fire and forget

' Start the background runner if it's not already up. The runner has its own
' single-instance guard via .agent.lock, so calling it twice is harmless.
shell.Run "powershell.exe -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File """ & scriptDir & "\agent-runner.ps1""", 0, False

' Give the background process a moment to bind port 3000
WScript.Sleep 800

' Open the UI window (also hidden PowerShell host — the window comes from XAML)
shell.Run "powershell.exe -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File """ & scriptDir & "\ui.ps1""", 0, False
