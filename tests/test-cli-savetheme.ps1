# Test: CLI savetheme via the bat launcher (no args -> default themes folder).
# The bat must exit 0 and produce a valid plain .theme file.

param(
    [string]$Root = (Split-Path -Parent $PSScriptRoot)
)

$ErrorActionPreference = 'Stop'
$themesDir = Join-Path $env:LOCALAPPDATA 'Microsoft\Windows\Themes'
$before = @(Get-ChildItem $themesDir -Filter 'Saved theme *.theme' -File -ErrorAction SilentlyContinue | ForEach-Object { $_.FullName })

$bat = Join-Path $Root 'custom-windows-themer.bat'
$out = cmd /c "`"$bat`" savetheme 2>&1"
$code = $LASTEXITCODE
# $out is one string per output line; join before regex checks (array -notmatch
# returns non-matching elements, which is not the same as "nothing matched").
$outText = $out -join "`n"

$after = @(Get-ChildItem $themesDir -Filter 'Saved theme *.theme' -File -ErrorAction SilentlyContinue | ForEach-Object { $_.FullName })
$created = @($after | Where-Object { $_ -notin $before })

if ($code -ne 0) {
    foreach ($f in $created) { Remove-Item $f -Force -ErrorAction SilentlyContinue }
    throw "bat exited $code`n$out"
}
if ($created.Count -ne 1) {
    foreach ($f in $created) { Remove-Item $f -Force -ErrorAction SilentlyContinue }
    throw "Expected exactly 1 new 'Saved theme *.theme', found $($created.Count)`n$out"
}
if ($outText -notmatch 'Saved current theme to:') {
    foreach ($f in $created) { Remove-Item $f -Force -ErrorAction SilentlyContinue }
    throw "Output missing save confirmation`n$out"
}
$b = [System.IO.File]::ReadAllBytes($created[0])
if ($b.Length -lt 300) {
    Remove-Item $created[0] -Force -ErrorAction SilentlyContinue
    throw "Saved .theme suspiciously small: $($b.Length) bytes`n$out"
}
$head = [System.IO.File]::ReadAllText($created[0], [System.Text.Encoding]::Unicode)
if ($head -notmatch '\[Theme\]' -or $head -notmatch 'DisplayName=Saved theme') {
    Remove-Item $created[0] -Force -ErrorAction SilentlyContinue
    throw "Saved .theme missing [Theme]/DisplayName`n$out"
}

Remove-Item $created[0] -Force -ErrorAction SilentlyContinue
Write-Host "CLI savetheme via bat: PASS (exit $code, $($b.Length) byte .theme)"