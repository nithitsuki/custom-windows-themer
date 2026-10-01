# Regression runner for custom-windows-themer theme switcher tests.
# Usage:  powershell -NoProfile -ExecutionPolicy Bypass -File tests\run-tests.ps1
# Each test runs in its own STA powershell (the GUI/COM layers need STA).

$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
$tests = Get-ChildItem (Join-Path $PSScriptRoot 'test-*.ps1') -File

$failed = @()
foreach ($t in $tests) {
    Write-Host ("== {0}" -f $t.Name)
    $ps = powershell -NoProfile -Sta -ExecutionPolicy Bypass -File $t.FullName -Root $root 2>&1
    $code = $LASTEXITCODE
    if ($code -eq 0) {
        Write-Host "   PASS"
        $ps | ForEach-Object { Write-Host "   $_" }
    } else {
        Write-Host "   FAIL (exit $code):"
        $ps | ForEach-Object { Write-Host "     $_" }
        $failed += $t.Name
    }
}

Write-Host ""
if ($failed.Count) {
    Write-Host ("RESULT: $($failed.Count) FAILED - " + ($failed -join ', ')) -ForegroundColor Red
    exit 1
} else {
    Write-Host "RESULT: all tests passed" -ForegroundColor Green
    exit 0
}