#Requires -Version 5.1
<#
    Builds GitHub Issues Tray into .\dist (a plain folder with the .exe and the
    Windows App SDK next to it). Stops a running copy first: Windows locks the
    files of a running .exe and the publish would fail half-way.

    powershell -ExecutionPolicy Bypass -File .\build.ps1
#>
param(
    [ValidateSet('x64', 'ARM64')]
    [string]$Platform = 'x64'
)

$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $MyInvocation.MyCommand.Path
$project = Join-Path $root 'src\GitHubIssuesTray\GitHubIssuesTray.csproj'
$dist = Join-Path $root 'dist'
$exe = Join-Path $dist 'GitHubIssuesTray.exe'

# Only the copy in dist: a test copy running from elsewhere locks nothing here.
$running = Get-Process -Name GitHubIssuesTray -ErrorAction SilentlyContinue |
    Where-Object { $_.Path -eq $exe }
if ($running) {
    Write-Host 'Stopping the running copy...' -ForegroundColor Yellow
    $running | Stop-Process -Force
    Start-Sleep -Milliseconds 800
}

try {
    dotnet publish $project -c Release -p:Platform=$Platform -o $dist -nologo
    if ($LASTEXITCODE -ne 0) { throw "dotnet publish failed ($LASTEXITCODE)" }
    Write-Host "Built: $exe" -ForegroundColor Green
}
finally {
    # A failed build must not leave the tray without the copy it stopped.
    if ($running -and (Test-Path -LiteralPath $exe)) {
        Start-Process $exe
        Write-Host 'Started again.' -ForegroundColor Green
    }
}
