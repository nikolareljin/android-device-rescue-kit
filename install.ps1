[CmdletBinding()]
param(
    # Install into WSL instead, for a machine that already runs everything
    # there. The native path is the default because it does not need one.
    [switch]$UseWsl,
    # Check what would happen and change nothing.
    [switch]$DryRun
)

$ErrorActionPreference = 'Stop'
$RepoUrl = 'https://github.com/nikolareljin/android-device-rescue-kit.git'
$InstallerUrl = 'https://raw.githubusercontent.com/nikolareljin/android-device-rescue-kit/main/install.sh'

# Decided in ADR-0041. WSL 2 is a virtual machine and its adb cannot see a USB
# device without usbipd-win, installed separately, plus `usbipd attach` from an
# elevated prompt once per session. That is setup performed under time pressure
# before a rescue can begin, on a machine the operator may not own.
#
# Native adb.exe talks to the Windows USB stack directly and needs none of it,
# and `winget install Git.Git` already ships bash 5.x, so the toolkit's own
# scripts run unmodified. One implementation, not two.

function Test-Command {
    param([string]$Name)
    return [bool](Get-Command $Name -ErrorAction SilentlyContinue)
}

function Install-WingetPackage {
    param([string]$Id, [string]$Label)

    if ($DryRun) {
        Write-Host ("  would install {0} ({1})" -f $Label, $Id)
        return
    }

    Write-Host ("  {0} ({1})" -f $Label, $Id)
    # --accept-*-agreements: without them winget waits for a keypress that a
    # scripted install never sends, and the run appears to hang.
    & winget install --exact --id $Id --silent `
        --accept-package-agreements --accept-source-agreements | Out-Null

    # 0 installed, -1978335189 already installed. Neither is a failure.
    if ($LASTEXITCODE -ne 0 -and $LASTEXITCODE -ne -1978335189) {
        throw ("Installing {0} ({1}) failed with exit code {2}." -f $Label, $Id, $LASTEXITCODE)
    }
}

if ($UseWsl) {
    if (-not (Test-Command 'wsl.exe')) {
        throw 'WSL 2 is required for -UseWsl. Run "wsl --install", restart when prompted, install a Linux distribution, then run this installer again.'
    }
    $distributions = @(wsl.exe --list --quiet 2>$null | Where-Object { $_.Trim() })
    if ($distributions.Count -eq 0) {
        throw 'No WSL Linux distribution is installed. Run "wsl --install -d Ubuntu", finish its first-run setup, then run this installer again.'
    }

    Write-Host 'Installing inside WSL...'
    Write-Host ''
    Write-Warning 'adb inside WSL 2 cannot see a USB device on its own. You will also need usbipd-win, and `usbipd attach --wsl` from an elevated prompt, once per session and again after every reconnect.'
    Write-Host ''
    if ($DryRun) {
        Write-Host '  would run the Linux installer inside WSL'
        exit 0
    }

    # set -o pipefail: without it the pipeline reports bash's status, not
    # curl's, so a 404 or blocked proxy fed an empty script to bash, which
    # exited 0 and the installer announced success.
    & wsl.exe -- bash -lc "set -o pipefail; curl -fsSL '$InstallerUrl' | bash"
    if ($LASTEXITCODE -ne 0) {
        throw "The WSL installer failed with exit code $LASTEXITCODE."
    }

    Write-Host ''
    Write-Host 'Installed in WSL. From PowerShell:'
    Write-Host "  wsl bash -lc '~/.local/bin/adrescue --help'"
    Write-Host "  wsl bash -lc '~/.local/bin/adrescue probe'"
    Write-Host ''
    Write-Host 'Use /mnt/c/... paths for Windows folders when running through WSL.'
    exit 0
}

if (-not (Test-Command 'winget')) {
    throw 'winget is required. It ships with App Installer from the Microsoft Store on Windows 10 1809 and later. Install that, then run this again. To use WSL instead, run this installer with -UseWsl.'
}

Write-Host 'Installing the Android Device Rescue Kit natively.'
Write-Host 'No WSL, and no USB passthrough: adb talks to the phone directly.'
Write-Host ''
Write-Host 'Dependencies:'

# Git for Windows brings the bash the toolkit runs under, and the whole MSYS2
# userland with it.
Install-WingetPackage -Id 'Git.Git' -Label 'Git for Windows, which supplies bash'
Install-WingetPackage -Id 'Google.PlatformTools' -Label 'Android platform tools (adb)'
Install-WingetPackage -Id 'BurntSushi.ripgrep.MSVC' -Label 'ripgrep'
Install-WingetPackage -Id 'GnuPG.GnuPG' -Label 'GnuPG'

if ($DryRun) {
    Write-Host ''
    Write-Host ('  would clone {0} and put adrescue on PATH' -f $RepoUrl)
    exit 0
}

# winget updates the machine and user PATH, but not this already-running
# process. Without this, every check below fails on a first install and the
# installer reports tools missing that it just installed.
$env:Path = `
    [Environment]::GetEnvironmentVariable('Path', 'Machine') + ';' + `
    [Environment]::GetEnvironmentVariable('Path', 'User')

$missing = @()
foreach ($tool in 'git', 'adb', 'rg', 'gpg', 'gzip', 'tar') {
    if (-not (Test-Command $tool)) { $missing += $tool }
}

# Google.PlatformTools is a zip-binary package, and historically did not put
# adb on PATH at all (winget-pkgs issue 103349). Say so plainly rather than
# failing later inside bash, where it reads as a broken toolkit.
if ($missing.Count -gt 0) {
    Write-Host ''
    Write-Warning ("Installed, but not yet on PATH in this window: {0}" -f ($missing -join ', '))
    Write-Warning 'Open a new PowerShell window and run this installer again. If adb is still missing after that, its winget package did not register itself; install Android platform tools manually and add them to PATH.'
    exit 1
}

# Deliberately not `Get-Command bash`. On a machine with WSL that resolves to
# C:\Windows\System32\bash.exe, the WSL launcher, and the shim would then run
# the one interpreter this whole decision exists to avoid -- silently, and only
# on the machines where WSL is present.
$candidates = @()
foreach ($base in $env:ProgramFiles, ${env:ProgramFiles(x86)}) {
    if ($base) { $candidates += (Join-Path $base 'Git\bin\bash.exe') }
}
if ($env:LOCALAPPDATA) {
    $candidates += (Join-Path $env:LOCALAPPDATA 'Programs\Git\bin\bash.exe')
}
# Wherever winget actually put it, git.exe is on PATH by now and bash sits one
# level up beside it: <root>\cmd\git.exe next to <root>\bin\bash.exe.
$gitExe = (Get-Command git -ErrorAction SilentlyContinue).Source
if ($gitExe) {
    $candidates += (Join-Path (Split-Path (Split-Path $gitExe -Parent) -Parent) 'bin\bash.exe')
}

$bash = $candidates | Where-Object { $_ -and (Test-Path $_) } | Select-Object -First 1
if (-not $bash) {
    throw 'Git for Windows is installed but its bash.exe was not found. Reinstall Git for Windows, or run this installer with -UseWsl.'
}

Write-Host ''
Write-Host 'Installing the toolkit...'

# Hand over to the same installer Linux and macOS use. It clones the latest
# release, links the launchers and fixes PATH; there is no second
# implementation of any of that here.
& $bash -lc "set -o pipefail; curl -fsSL '$InstallerUrl' | bash"
if ($LASTEXITCODE -ne 0) {
    throw "The installer failed with exit code $LASTEXITCODE."
}

# Git Bash's ~/.local/bin is inside its own home, which Windows does not have
# on PATH. A .cmd shim is what makes `adrescue` work from PowerShell and cmd.
$shimDir = Join-Path $env:LOCALAPPDATA 'Programs\adrescue'
New-Item -ItemType Directory -Force -Path $shimDir | Out-Null
$shim = Join-Path $shimDir 'adrescue.cmd'
@(
    '@echo off'
    'rem Runs the toolkit under the bash that Git for Windows provides, against'
    'rem native adb. The toolkit excludes device paths from MSYS conversion'
    'rem itself; nothing is disabled here, because a blanket setting would also'
    'rem stop the local destination being converted, which adb.exe does need.'
    'rem'
    'rem %* is what forwards the arguments. $* would not: cmd.exe leaves it'
    'rem alone, bash then expands it against its own empty argument list, and'
    'rem every `adrescue probe` arrives as a bare `adrescue`. The inner \" is'
    'rem passed through cmd untouched and reaches bash as a real quote, so'
    'rem "$@" keeps a path with spaces in one piece.'
    ('"' + $bash + '" -lc "adrescue \"$@\"" -- %*')
) | Set-Content -Path $shim -Encoding ASCII

$userPath = [Environment]::GetEnvironmentVariable('Path', 'User')
# Compared entry by entry. -like would treat [ ] in a profile path as wildcards,
# and would also match a different directory that merely contains this one.
if (($userPath -split ';' | Where-Object { $_.TrimEnd('\') -eq $shimDir.TrimEnd('\') }).Count -eq 0) {
    [Environment]::SetEnvironmentVariable('Path', "$userPath;$shimDir", 'User')
    Write-Host ("Added {0} to your PATH." -f $shimDir)
}

# What winget cannot supply, said here rather than discovered mid-rescue.
#
# dialog is in MSYS2's msys repository and needs that runtime. Git for Windows
# ships a fork of it with no package manager, and loading another build of
# msys-2.0.dll into the same process is not supported, so there is no way to
# add dialog to this shell. The toolkit uses numbered text prompts instead --
# the same questions, and the same code underneath.
#
# unzip is not shipped either, but Windows itself provides bsdtar as tar.exe,
# which reads zip. `adrescue log` uses whichever is present.
Write-Host ''
Write-Host 'Two tools have no winget package for this shell:'
Write-Host ''
Write-Host '  dialog  Full-screen menus. Not installable under Git Bash, so the prompts'
Write-Host '          are numbered questions instead. Same questions, same result.'
Write-Host '          Choose explicitly any time with: adrescue --ui dialog|text'
$bsdtar = $false
try {
    $tarVersion = (& tar --version 2>$null | Select-Object -First 1)
    if ($tarVersion -match 'bsdtar|libarchive') { $bsdtar = $true }
} catch { $bsdtar = $false }
if ($bsdtar) {
    Write-Host '  unzip   Not present; bsdtar reads the bugreport zip in its place.'
} else {
    Write-Warning '  unzip is not present and no bsdtar was found. "adrescue log" will skip'
    Write-Warning '  bugreport extraction, which is where last_kmsg and the tombstones are.'
}

Write-Host ''
Write-Host 'Installed. Open a new PowerShell window, then:'
Write-Host ''
Write-Host '  adrescue --help'
Write-Host '  adrescue probe'
Write-Host ''
Write-Host 'Plug the phone in with USB debugging on. Nothing else is needed:'
Write-Host 'adb runs natively, so there is no passthrough step.'
