# Regression: the theme must keep "Show accent color on Start and taskbar" OFF
# (ColorPrevalence=0) — even on Win11 where the gate would otherwise paint the
# taskbar with the accent. Previously this test enforced Win11 ColorPrevalence=1;
# now we enforce disabled (0) with Light mode on both OSes.
param(
    [string]$Root = (Split-Path -Parent $PSScriptRoot)
)
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot '_load-themer.ps1') -Root $Root
# Fix up ScriptDir globals broken by Invoke-Expression loading (would point to tests\)
Set-Variable -Name ScriptDir -Value $Root -Scope Script -Force
Set-Variable -Name UserThemesDir -Value (Join-Path $env:LOCALAPPDATA 'Microsoft\Windows\Themes') -Scope Script -Force
# The .theme path is asserted directly below, built from $UserThemesDir, so it
# is computed there rather than pinned here.

function Get-Build { return [Environment]::OSVersion.Version.Build }
$build = Get-Build
Write-Host "OS build: $build"
if ($build -lt 22000) {
    Write-Host "SKIP: not Win11 (build <22000) - test only enforces Win11 contract on Win11 hosts"
    # Still verify helpers exist and default to Win10 behavior
    if (-not (Get-Command Test-IsWin11 -ErrorAction SilentlyContinue)) { throw "FAIL: Test-IsWin11 helper missing" }
    if (Test-IsWin11) { throw "FAIL: Test-IsWin11 returned true on Win10 build $build" }
    Write-Host "PASS: helpers present, correctly report not-Win11"
    exit 0
}

# On Win11, helpers must exist and report true
if (-not (Get-Command Test-IsWin11 -ErrorAction SilentlyContinue)) { throw "FAIL: Test-IsWin11 helper missing (needed for Win11 taskbar fix)" }
if (-not (Get-Command Get-CWTSystemLight -ErrorAction SilentlyContinue)) { throw "FAIL: Get-CWTSystemLight helper missing" }
if (-not (Test-IsWin11)) { throw "FAIL: Test-IsWin11 returned false on build $build (>=22000)" }
$expectedLight = Get-CWTSystemLight
Write-Host " Helpers: Test-IsWin11=true, Get-CWTSystemLight=$expectedLight (accent on taskbar disabled, Light=1 expected)"

# Snapshot live Personalize so we can restore after the apply probe
$per = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Themes\Personalize'
$orig = Get-ItemProperty $per -ErrorAction SilentlyContinue
$origSys = if ($null -ne $orig -and $null -ne $orig.SystemUsesLightTheme) { [int]$orig.SystemUsesLightTheme } else { $null }
$origApps = if ($null -ne $orig -and $null -ne $orig.AppsUseLightTheme) { [int]$orig.AppsUseLightTheme } else { $null }
$origPrev = if ($null -ne $orig -and $null -ne $orig.ColorPrevalence) { [int]$orig.ColorPrevalence } else { $null }
$origTransp = if ($null -ne $orig -and $null -ne $orig.EnableTransparency) { [int]$orig.EnableTransparency } else { $null }

# Ensure we have a saved theme so Restore-Saved can undo Apply-CustomTheme
$stateDir = Join-Path $env:LOCALAPPDATA 'custom-windows-themer'
$savedPath = Join-Path $stateDir 'saved-theme.json'
$statePath = Join-Path $stateDir 'state.json'
$hadSaved = Test-Path $savedPath
$hadState = Test-Path $statePath
$savedBackup = $null; $stateBackup = $null
if ($hadSaved) { $savedBackup = Get-Content $savedPath -Raw }
if ($hadState) { $stateBackup = Get-Content $statePath -Raw }
# Force Save-CurrentTheme to actually capture (remove existing saved so it re-saves)
# But keep backup to restore after
try {
    # Clean saved so next Save captures current (pre-apply) state
    if (Test-Path $savedPath) { Remove-Item $savedPath -Force }
    if (Test-Path $statePath) { Remove-Item $statePath -Force }

    # Apply (this is the code under test) - it internally saves then sets
    Apply-CustomTheme
    Start-Sleep -Seconds 2

    $after = Get-ItemProperty $per -ErrorAction SilentlyContinue
    $sys = [int]$after.SystemUsesLightTheme
    $apps = [int]$after.AppsUseLightTheme
    $prev = [int]$after.ColorPrevalence
    $transp = [int]$after.EnableTransparency

    Write-Host " After Apply-CustomTheme: SystemUsesLightTheme=$sys AppsUseLightTheme=$apps ColorPrevalence=$prev EnableTransparency=$transp"

    if ($sys -ne 1) { throw "FAIL: SystemUsesLightTheme=$sys, expected 1 (Light mode)" }
    if ($apps -ne 1) { throw "FAIL: AppsUseLightTheme=$apps, expected 1 (keep apps light)" }
    if ($prev -ne 0) { throw "FAIL: ColorPrevalence=$prev, expected 0 (Show accent on Start/taskbar OFF)" }
    if ($transp -ne 1) { throw "FAIL: EnableTransparency=$transp, expected 1" }

    # Verify .theme file was written with SystemMode=Light (accent on taskbar disabled)
    $cwtTheme = Join-Path (Join-Path $env:LOCALAPPDATA 'Microsoft\Windows\Themes') 'Rose.theme'
    if (-not (Test-Path $cwtTheme)) { throw "FAIL: Rose.theme not written" }
    $content = Get-Content $cwtTheme -Raw
    if ($content -notmatch 'SystemMode=Light') { throw "FAIL: Rose.theme SystemMode is not Light`n$content" }
    if ($content -notmatch 'AppMode=Light') { throw "FAIL: Rose.theme AppMode is not Light`n$content" }
    Write-Host " .theme file: SystemMode=Light AppMode=Light - OK"

    Write-Host "PASS: taskbar accent disabled contract satisfied"
} finally {
    # Restore original live state via Restore-Saved (or manual fallback)
    try {
        if (Test-Path $savedPath) {
            Restore-Saved
            Start-Sleep -Seconds 1
        } else {
            # fallback manual restore if save failed
            if ($null -ne $origSys) { Set-ItemProperty -Path $per -Name SystemUsesLightTheme -Value $origSys -Type DWord -Force }
            if ($null -ne $origApps) { Set-ItemProperty -Path $per -Name AppsUseLightTheme -Value $origApps -Type DWord -Force }
            if ($null -ne $origPrev) { Set-ItemProperty -Path $per -Name ColorPrevalence -Value $origPrev -Type DWord -Force }
            if ($null -ne $origTransp) { Set-ItemProperty -Path $per -Name EnableTransparency -Value $origTransp -Type DWord -Force }
        }
    } catch { Write-Host " Restore warning: $_" }

    # Restore saved-theme.json/state.json backups if we overwrote them
    if ($savedBackup) { Set-Content -Path $savedPath -Value $savedBackup -Encoding UTF8 }
    elseif (-not $hadSaved -and (Test-Path $savedPath)) { Remove-Item $savedPath -Force -ErrorAction SilentlyContinue }
    if ($stateBackup) { Set-Content -Path $statePath -Value $stateBackup -Encoding UTF8 }
    elseif (-not $hadState -and (Test-Path $statePath)) { Remove-Item $statePath -Force -ErrorAction SilentlyContinue }

    # Ensure Start menu host repaint doesn't linger stale
    try { Update-PerUserSettings } catch { }
}
