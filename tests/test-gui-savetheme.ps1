# Test: custom-windows-themer GUI - "Save current .theme" button must not crash the GUI.
# Simulates the real user flow: window opens -> auto 'status' runs -> user
# clicks the Save button -> output appears in the log -> GUI stays alive.
# RED first: with the cross-thread output-reading bug, the GUI process dies
# (exit 2, PSInvalidOperation in ScriptBlock.GetContextFromTLS) -> test fails.

param(
    [string]$Root = (Split-Path -Parent $PSScriptRoot)
)

$ErrorActionPreference = 'Stop'
$guiPath = Join-Path $Root 'custom-windows-themer-gui.ps1'
if (-not (Test-Path $guiPath)) { throw "GUI not found: $guiPath" }

$themesDir = Join-Path $env:LOCALAPPDATA 'Microsoft\Windows\Themes'
# clean up artifacts possibly left by a previous FAILED (crashing) run
Get-ChildItem $themesDir -Filter 'Saved theme *.theme' -File -ErrorAction SilentlyContinue |
    Where-Object { $_.LastWriteTime -gt (Get-Date).AddMinutes(-20) } |
    Remove-Item -Force -ErrorAction SilentlyContinue
$before = @(Get-ChildItem $themesDir -Filter 'Saved theme *.theme' -File -ErrorAction SilentlyContinue | ForEach-Object { $_.FullName })

$src = Get-Content $guiPath -Raw

# Invoke-Expression loses $PSScriptRoot - pin the repo dir explicitly.
$src = $src.Replace(
    '$ScriptDir    = Split-Path -Parent $MyInvocation.MyCommand.Definition',
    ("`$ScriptDir    = '" + $Root.Replace("'", "''") + "'")
)

# Driver replaces the final Application.Run line - it MUST include the Run call
# itself (a missing Run = silent instant return, test proves nothing).
$driver = @'

$script:guiEx  = $null
$script:guiLog = ''

$t1 = New-Object System.Windows.Forms.Timer
$t1.Interval = 6000   # let the auto 'status' run finish first (exact user flow)
$t1.Add_Tick({
    $t1.Stop()
    try { $btnSave.PerformClick() } catch { $script:guiEx = $_.Exception.Message }
})
$t1.Start()

$t2 = New-Object System.Windows.Forms.Timer
$t2.Interval = 13000  # after the click finishes, snapshot and close
$t2.Add_Tick({
    $t2.Stop()
    $script:guiLog = $txtLog.Text
    $form.Close()
})
$t2.Start()

try {
    [System.Windows.Forms.Application]::Run($form)
} catch {
    $script:guiEx = $_.Exception.Message
}
'@
$src = $src.Replace('[System.Windows.Forms.Application]::Run($form)', $driver)
Invoke-Expression $src

# --- Assertions ---
$after = @(Get-ChildItem $themesDir -Filter 'Saved theme *.theme' -File -ErrorAction SilentlyContinue | ForEach-Object { $_.FullName })
$created = @($after | Where-Object { $_ -notin $before })

if ($script:guiEx) {
    foreach ($f in $created) { Remove-Item $f -Force -ErrorAction SilentlyContinue }
    throw "GUI exception: $script:guiEx"
}
if ($script:guiLog -notmatch 'Saved current theme to:') {
    foreach ($f in $created) { Remove-Item $f -Force -ErrorAction SilentlyContinue }
    throw "Log does not contain the save confirmation. Log: $script:guiLog"
}
if ($created.Count -ne 1) {
    foreach ($f in $created) { Remove-Item $f -Force -ErrorAction SilentlyContinue }
    throw "Expected exactly 1 new 'Saved theme *.theme', found $($created.Count)"
}

$b = [System.IO.File]::ReadAllBytes($created[0])
if ($b.Length -lt 300) {
    Remove-Item $created[0] -Force -ErrorAction SilentlyContinue
    throw "Saved .theme is suspiciously small: $($b.Length) bytes"
}
$head = [System.IO.File]::ReadAllText($created[0], [System.Text.Encoding]::Unicode)
if ($head -notmatch '\[Theme\]' -or $head -notmatch 'DisplayName=Saved theme') {
    Remove-Item $created[0] -Force -ErrorAction SilentlyContinue
    throw "Saved .theme is missing [Theme]/DisplayName"
}

# cleanup: remove the test artifact (the real feature is exercised by the user)
Remove-Item $created[0] -Force -ErrorAction SilentlyContinue
Write-Host "GUI Save-button test: PASS ($($b.Length) byte .theme written, GUI stayed alive)"