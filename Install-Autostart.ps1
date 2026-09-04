#Requires -Version 5.1
<#
    Creates (or removes) the GitHub Issues Tray shortcut in the user's Startup
    folder, so it comes up with Windows. No UAC needed: it is just a shortcut in
    the user's own folder, no scheduled task involved.

    Install:  powershell -ExecutionPolicy Bypass -File .\Install-Autostart.ps1
    Remove:   powershell -ExecutionPolicy Bypass -File .\Install-Autostart.ps1 -Remove
#>
param(
    [switch]$Remove
)

$ErrorActionPreference = 'Stop'

$root = Split-Path -Parent $MyInvocation.MyCommand.Path
$vbs = Join-Path $root 'start.vbs'
$startup = [Environment]::GetFolderPath('Startup')
$link = Join-Path $startup 'GitHub Issues Tray.lnk'

if ($Remove) {
    if (Test-Path -LiteralPath $link) {
        Remove-Item -LiteralPath $link -Force
        Write-Host "Shortcut removed: $link" -ForegroundColor Yellow
    } else {
        Write-Host 'There was no startup shortcut to remove.' -ForegroundColor Yellow
    }
    return
}

if (-not (Test-Path -LiteralPath $vbs)) {
    throw "start.vbs not found in $root"
}

$shell = New-Object -ComObject WScript.Shell
$sc = $shell.CreateShortcut($link)
$sc.TargetPath = Join-Path $env:WINDIR 'System32\wscript.exe'
$sc.Arguments = '"' + $vbs + '"'
$sc.WorkingDirectory = $root
$sc.IconLocation = "$env:WINDIR\System32\shell32.dll,13"
$sc.Description = 'GitHub issues assigned to you, in the tray'
$sc.Save()

Write-Host "Shortcut created: $link" -ForegroundColor Green
Write-Host 'The app will start on its own at the next logon.' -ForegroundColor Green
