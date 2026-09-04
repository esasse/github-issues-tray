' Starts GitHub Issues Tray without flashing a console window.
' -ExecutionPolicy Bypass in case the repo was cloned or downloaded with MOTW.
Dim shell, here
Set shell = CreateObject("WScript.Shell")
here = Left(WScript.ScriptFullName, InStrRev(WScript.ScriptFullName, "\"))
shell.Run "powershell.exe -NoProfile -NonInteractive -STA -ExecutionPolicy Bypass -WindowStyle Hidden -File """ & here & "GitHubIssues-Tray.ps1""", 0, False
