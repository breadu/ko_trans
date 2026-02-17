Set fso = CreateObject("Scripting.FileSystemObject")
' Corrected: Use ScriptFullName instead of ScriptPosition
currentDir = fso.GetParentFolderName(WScript.ScriptFullName)
Set WshShell = CreateObject("WScript.Shell")
' Execute the batch file in the current directory in hidden mode (0)
WshShell.Run "cmd /c " & Chr(34) & currentDir & "\start_ocr_server.bat" & Chr(34), 0, False