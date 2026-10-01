# Schema check for presets/*.json. Pure JSON validation: no registry, no
# Windows API, runs on any OS. Exits 0 when every preset file is valid,
# 1 otherwise.
param(
    [string]$Root = (Split-Path -Parent $PSScriptRoot)
)

$ErrorActionPreference = 'Stop'
$hexPattern = '^#[0-9A-Fa-f]{6}$'
# Required color keys (all applied to Windows by the themer)
$colorKeys = @('accent', 'accentLight', 'selectionBg', 'titleBar',
               'paletteEntry5', 'paletteEntry7')
# Optional GUI-chrome colors: only the GUI log box uses them, they are never
# applied to Windows - presets may omit them (all shipped presets keep them).
$optionalColorKeys = @('normalBg', 'selectionFg')
$terminalKeys = @('foreground', 'background', 'cursorColor', 'selectionBackground',
                  'black', 'red', 'green', 'yellow', 'blue', 'purple', 'cyan', 'white',
                  'brightBlack', 'brightRed', 'brightGreen', 'brightYellow',
                  'brightBlue', 'brightPurple', 'brightCyan', 'brightWhite')

$failures = @()
function Fail([string]$Message) {
    $script:failures += $Message
    Write-Host "  [FAIL] $Message" -ForegroundColor Red
}

$presetsDir = Join-Path $Root 'presets'
$files = @(Get-ChildItem -Path $presetsDir -Filter '*.json' -File -ErrorAction SilentlyContinue | Sort-Object Name)
if (-not $files.Count) {
    Fail "no preset files found in $presetsDir"
}

foreach ($f in $files) {
    Write-Host "== $($f.Name)"
    try {
        $json = Get-Content $f.FullName -Raw -Encoding UTF8 | ConvertFrom-Json
    } catch {
        Fail "$($f.Name): invalid JSON ($($_.Exception.Message))"
        continue
    }

    # Identity keys
    foreach ($k in @('name', 'displayName', 'description')) {
        $prop = $json.PSObject.Properties[$k]
        if ($null -eq $prop -or -not $prop.Value) { Fail "$($f.Name): missing key '$k'" }
    }
    if ($json.name -and $json.name -ne $f.BaseName) {
        Fail "$($f.Name): 'name' must equal the file base name"
    }

    # Color keys: #RRGGBB only
    foreach ($k in $colorKeys) {
        $prop = $json.PSObject.Properties[$k]
        if ($null -eq $prop -or -not $prop.Value) { Fail "$($f.Name): missing key '$k'"; continue }
        if ("$($prop.Value)" -notmatch $hexPattern) { Fail "$($f.Name): '$k' must match $hexPattern" }
    }

    # Optional GUI-chrome colors: only validated when present (see above)
    foreach ($k in $optionalColorKeys) {
        $prop = $json.PSObject.Properties[$k]
        if ($null -eq $prop -or $null -eq $prop.Value) { continue }
        if ("$($prop.Value)" -notmatch $hexPattern) { Fail "$($f.Name): '$k' must match $hexPattern" }
    }

    # 0-255 tunables
    foreach ($k in @('taskbarAcrylic', 'paletteAlpha')) {
        $prop = $json.PSObject.Properties[$k]
        if ($null -eq $prop -or $null -eq $prop.Value) { Fail "$($f.Name): missing key '$k'"; continue }
        if ($prop.Value -isnot [int] -and $prop.Value -isnot [long]) { Fail "$($f.Name): '$k' must be a number"; continue }
        if ([int]$prop.Value -lt 0 -or [int]$prop.Value -gt 255) { Fail "$($f.Name): '$k' must be 0-255" }
    }

    # Nullable mode keys: null, 0 or 1
    foreach ($k in @('systemLight', 'appLight')) {
        $prop = $json.PSObject.Properties[$k]
        if ($null -eq $prop) { continue }        # absent = allowed
        if ($null -eq $prop.Value) { continue }  # null = allowed
        if ([int]$prop.Value -notin 0, 1) { Fail "$($f.Name): '$k' must be 0, 1 or null" }
    }

    # Nullable wallpaper: null or a string
    $wp = $json.PSObject.Properties['wallpaper']
    if ($null -ne $wp -and $null -ne $wp.Value -and $wp.Value -isnot [string]) {
        Fail "$($f.Name): 'wallpaper' must be a string or null"
    }

    # Terminal scheme: 16 ANSI slots + 4 meta colors, all #RRGGBB
    $t = $json.PSObject.Properties['terminal']
    if ($null -eq $t -or $null -eq $t.Value) {
        Fail "$($f.Name): missing object 'terminal'"
    } else {
        foreach ($k in $terminalKeys) {
            $slot = $json.terminal.PSObject.Properties[$k]
            if ($null -eq $slot -or -not $slot.Value) { Fail "$($f.Name): terminal.$k missing"; continue }
            if ("$($slot.Value)" -notmatch $hexPattern) { Fail "$($f.Name): terminal.$k must match $hexPattern" }
        }
    }
}

if ($failures.Count) {
    Write-Host "test-presets-valid: $($failures.Count) failure(s)" -ForegroundColor Red
    exit 1
}
Write-Host "test-presets-valid: PASS ($($files.Count) presets valid)" -ForegroundColor Green
exit 0
