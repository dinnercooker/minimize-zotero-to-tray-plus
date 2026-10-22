' Zotero Minimize-to-Tray Plus - silent launcher for the tray helper.
' Runs tray-helper.ps1 without flashing a console window (wscript is a GUI
' subsystem host, so the child PowerShell process is created hidden).
' Config file is read by the helper from its own folder (tray-config.json).
Option Explicit

Dim fso, sh, baseDir, ps1, cmd

Set fso = CreateObject("Scripting.FileSystemObject")
Set sh = CreateObject("WScript.Shell")

baseDir = fso.GetParentFolderName(WScript.ScriptFullName)
ps1 = baseDir & "\tray-helper.ps1"

If Not fso.FileExists(ps1) Then
    WScript.Quit 1
End If

cmd = "powershell.exe -NoProfile -NonInteractive -ExecutionPolicy Bypass -WindowStyle Hidden -File """ & ps1 & """"
sh.Run cmd, 0, False
