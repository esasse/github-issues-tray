#Requires -Version 5.1
<#
    Creates (or removes) the GitHub Issues Tray shortcut in the user's Startup
    folder, so it comes up with Windows, and starts it. No UAC: it is a shortcut
    in the user's own folder, no scheduled task, no service.

    It also asks Windows 11 to keep the icon on the taskbar instead of in the
    overflow menu (^), where every new tray icon lands by default. That is the same
    switch as Settings > Personalization > Taskbar > Other system tray icons.

    Coming from the PowerShell version, it replaces that shortcut (same name) and
    stops the old script if it is running, so the two do not sit side by side.

    Install:  powershell -ExecutionPolicy Bypass -File .\Install-Autostart.ps1
    Remove:   powershell -ExecutionPolicy Bypass -File .\Install-Autostart.ps1 -Remove
#>
param(
    [switch]$Remove
)

$ErrorActionPreference = 'Stop'

$root = Split-Path -Parent $MyInvocation.MyCommand.Path
$exe = Join-Path $root 'dist\GitHubIssuesTray.exe'
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

if (-not (Test-Path -LiteralPath $exe)) {
    throw "dist\GitHubIssuesTray.exe not found. Run .\build.ps1 first."
}

$shell = New-Object -ComObject WScript.Shell
$sc = $shell.CreateShortcut($link)
$sc.TargetPath = $exe
$sc.Arguments = ''
$sc.WorkingDirectory = Split-Path -Parent $exe
$sc.IconLocation = "$exe,0"
$sc.Description = 'GitHub issues and pull requests assigned to you, in the tray'
$sc.Save()
Write-Host "Shortcut created: $link" -ForegroundColor Green

$legacy = Get-CimInstance Win32_Process -Filter "Name='powershell.exe'" -ErrorAction SilentlyContinue |
    Where-Object { $_.CommandLine -like '*GitHubIssues-Tray.ps1*' }
foreach ($p in $legacy) {
    Stop-Process -Id $p.ProcessId -Force -ErrorAction SilentlyContinue
    Write-Host 'Stopped the PowerShell version.' -ForegroundColor Yellow
}

if (-not (Get-Process -Name GitHubIssuesTray -ErrorAction SilentlyContinue | Where-Object { $_.Path -eq $exe })) {
    Start-Process $exe
    Write-Host 'Started.' -ForegroundColor Green
}

# Windows creates the entry the first time the icon appears, keyed by the .exe path.
$settings = 'HKCU:\Control Panel\NotifyIconSettings'
$entry = $null
for ($i = 0; $i -lt 20 -and -not $entry; $i++) {
    if (Test-Path $settings) {
        $entry = Get-ChildItem $settings | Where-Object {
            (Get-ItemProperty $_.PSPath).ExecutablePath -eq $exe
        } | Select-Object -First 1
    }
    if (-not $entry) { Start-Sleep -Milliseconds 500 }
}
if ($entry) {
    Set-ItemProperty $entry.PSPath -Name IsPromoted -Value 1 -Type DWord
    Write-Host 'Tray icon pinned to the taskbar.' -ForegroundColor Green
} else {
    Write-Host 'Could not find the tray icon entry; pin it from the ^ menu by dragging it to the taskbar.' -ForegroundColor Yellow
}
