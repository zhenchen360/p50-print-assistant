Option Explicit

Dim fso, shell, scriptDir, ps1, command
Set fso = CreateObject("Scripting.FileSystemObject")
Set shell = CreateObject("WScript.Shell")

scriptDir = fso.GetParentFolderName(WScript.ScriptFullName)
ps1 = fso.BuildPath(scriptDir, "P50_Print_Assistant.ps1")

If Not fso.FileExists(ps1) Then
    MsgBox "P50_Print_Assistant.ps1 was not found next to this launcher.", vbCritical, "P50 Print Assistant"
    WScript.Quit 1
End If

command = "powershell.exe -NoProfile -ExecutionPolicy Bypass -STA -WindowStyle Hidden -File " & Chr(34) & ps1 & Chr(34)
shell.Run command, 0, False
