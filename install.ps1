# Heatwatch installer: adds Start menu + desktop shortcuts (and optionally start at sign-in), then launches it.
# Usage:  powershell -ExecutionPolicy Bypass -File install.ps1 [-StartAtSignIn] [-NoDesktopShortcut]
param([switch]$StartAtSignIn, [switch]$NoDesktopShortcut)

$app = Join-Path $PSScriptRoot 'Heatwatch.ps1'
if (-not (Test-Path $app)) { Write-Error "Heatwatch.ps1 not found next to install.ps1"; exit 1 }

$ps = "$env:SystemRoot\System32\WindowsPowerShell\v1.0\powershell.exe"
$psArgs = "-NoProfile -STA -WindowStyle Hidden -ExecutionPolicy Bypass -File `"$app`""
$shell = New-Object -ComObject WScript.Shell

function New-Shortcut([string]$path) {
    $l = $shell.CreateShortcut($path)
    $l.TargetPath = $ps; $l.Arguments = $psArgs; $l.WorkingDirectory = $PSScriptRoot
    $l.IconLocation = "$env:SystemRoot\System32\imageres.dll,104"; $l.WindowStyle = 7
    $l.Description = 'Heatwatch desktop widgets'
    $l.Save()
    Write-Host "Created $path"
}

New-Shortcut (Join-Path ([Environment]::GetFolderPath('Programs')) 'Heatwatch.lnk')
if (-not $NoDesktopShortcut) { New-Shortcut (Join-Path ([Environment]::GetFolderPath('Desktop')) 'Heatwatch.lnk') }
if ($StartAtSignIn) { New-Shortcut (Join-Path ([Environment]::GetFolderPath('Startup')) 'Heatwatch.lnk') }

Start-Process $ps -ArgumentList $psArgs -WindowStyle Hidden
Write-Host 'Heatwatch is running - look for the thermometer in the system tray.'
