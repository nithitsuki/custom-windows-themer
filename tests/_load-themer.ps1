# Loads custom-windows-themer.ps1's functions WITHOUT running the top-level
# command dispatch (which would default to 'toggle'). Strips everything from
# the '# Main dispatch' marker onward, then evaluates the rest in this scope.
# $ScriptDir is pre-set here so the script's Import-CWTPreset call (which runs
# at load time) finds presets/ under the repo root instead of under tests\.
param(
    [string]$Root
)
$ScriptDir = $Root
$src = Get-Content (Join-Path $Root 'custom-windows-themer.ps1') -Raw
$idx = $src.IndexOf('# Main dispatch')
if ($idx -lt 0) { throw 'custom-windows-themer.ps1: Main dispatch marker not found' }
$src = $src.Substring(0, $idx)
Invoke-Expression $src
