' LightMenu Print Agent - Silent startup launcher
' Runs restart-loop-node.bat hidden so no console window flashes on Windows boot
' or when the user clicks the desktop shortcut.
Dim fso, scriptDir, shell
Set fso = CreateObject("Scripting.FileSystemObject")
Set shell = CreateObject("WScript.Shell")
scriptDir = fso.GetParentFolderName(WScript.ScriptFullName)
' Window style 0 = hidden, False = don't wait for it to finish
shell.Run Chr(34) & scriptDir & "\restart-loop-node.bat" & Chr(34), 0, False
