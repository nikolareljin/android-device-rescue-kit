[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
$InstallerUrl = 'https://raw.githubusercontent.com/nikolareljin/android-device-rescue-kit/main/install.sh'

if (-not (Get-Command wsl.exe -ErrorAction SilentlyContinue)) {
    throw 'WSL 2 is required on Windows. Run "wsl --install", restart when prompted, install a Linux distribution, then run this installer again.'
}

$distributions = @(wsl.exe --list --quiet 2>$null | Where-Object { $_.Trim() })
if ($distributions.Count -eq 0) {
    throw 'No WSL Linux distribution is installed. Run "wsl --install -d Ubuntu", finish its first-run setup, then run this installer again.'
}

Write-Host 'Installing Android Device Rescue Kit inside WSL...'
# set -o pipefail: without it the pipeline reports bash's status, not curl's,
# so a 404 or blocked proxy fed an empty script to bash, which exited 0 and
# the installer announced success.
& wsl.exe -- bash -lc "set -o pipefail; curl -fsSL '$InstallerUrl' | bash"
if ($LASTEXITCODE -ne 0) {
    throw "The WSL installer failed with exit code $LASTEXITCODE."
}

Write-Host ''
Write-Host 'Installed in WSL. Run these commands from PowerShell or Windows Terminal:'
Write-Host "  wsl bash -lc '~/.local/bin/android-rescue-dump --help'"

Write-Host "  wsl bash -lc '~/.local/bin/android-rescue-dump data /mnt/c/AndroidBackups'"

Write-Host "  wsl bash -lc '~/.local/bin/android-rescue-prompt /mnt/c/AndroidCaptures/example'"
Write-Host ''
Write-Host 'Use /mnt/c/... paths for Windows folders when running the toolkit through WSL.'
