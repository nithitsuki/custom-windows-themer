<#
.SYNOPSIS
    Preset theme switcher for Windows 10 / 11.

.DESCRIPTION
    Applies a color preset from presets/*.json to Windows and lets you flip
    between it and your own saved theme. The preset files are the only source
    of color: every accent, palette slot and terminal color comes from them.

    What it changes:
      * Desktop wallpaper  -> the preset's wallpaper, or a generated gradient (Fill)
      * Accent color       -> the preset's accent on title bars / window borders
      * Light mode         -> app/system mode from the preset (default: light)
      * Start menu         -> frosted/translucent (EnableTransparency) + preset AccentPalette
      * Taskbar            -> acrylic taskbar (TaskbarAcrylicOpacity, Windows 10)
      * Windows Terminal   -> the preset's color scheme (incl. translucent acrylic)

    It never needs Administrator: every change is per-user (HKCU / %LOCALAPPDATA%).

.EXAMPLE
    .\custom-windows-themer.ps1 toggle     # flip between the preset and your saved theme
    .\custom-windows-themer.ps1 presets    # list the available presets
    .\custom-windows-themer.ps1 apply ocean  # apply the 'ocean' preset (saves your theme first)
    .\custom-windows-themer.ps1 apply      # apply the last selected preset (falls back to rose)
    .\custom-windows-themer.ps1 restore    # turn the preset OFF (back to your saved theme)
    .\custom-windows-themer.ps1 status     # show what is currently active
    .\custom-windows-themer.ps1 install    # only resolve/generate the wallpaper (no theme change)
    .\custom-windows-themer.ps1 themes     # list installed themes via the NATIVE Windows theme API
    .\custom-windows-themer.ps1 theme-save [path]    # save the CURRENT theme as a real .theme file
    .\custom-windows-themer.ps1 theme-restore <path> # apply a .theme file natively (like double-clicking)
    .\custom-windows-themer.ps1 restart-shell        # forced explorer restart (guarded, never leaves it dead)
    .\custom-windows-themer.ps1 theme-switch <idx>   # switch to an installed theme natively (see 'themes')
#>

[CmdletBinding()]
param(
    [Parameter(Position = 0)]
    [ValidateSet('toggle', 'apply', 'presets', 'restore', 'on', 'off', 'status', 'install',
                 'themes', 'theme-save', 'theme-restore', 'theme-switch', 'theme-file',
                 'restart-shell', 'savetheme', 'taskbar-acrylic', 'start-acrylic')]
    [string]$Command = 'toggle',

    [Parameter(Position = 1)]
    [string]$ThemeArg = ''
)

$ErrorActionPreference = 'Stop'

# ----------------------------------------------------------------------------
# Paths & constants
# ----------------------------------------------------------------------------
# Script root. Embedders (tests/_load-themer.ps1) may pre-set $ScriptDir before
# this script runs; otherwise resolve it from this script's own path.
if (-not $ScriptDir) { $ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Definition }
$PresetsDir      = Join-Path $ScriptDir 'presets'
$StateDir        = Join-Path $env:LOCALAPPDATA 'custom-windows-themer'
$SavedThemePath  = Join-Path $StateDir 'saved-theme.json'
$StatePath       = Join-Path $StateDir 'state.json'
$TerminalBackup  = Join-Path $StateDir 'terminal-backup.json'

# The user themes folder - files here appear in Settings > Themes and in the
# native theme manager listing ("themes" command). The concrete .theme file
# name is built inside Write-CWTThemeFile, after the preset loads, because the
# file is named after the preset's display name.
$UserThemesDir   = Join-Path $env:LOCALAPPDATA 'Microsoft\Windows\Themes'

# Prefix for every Windows Terminal scheme this script generates. Defined once
# and used everywhere: on apply, ALL schemes carrying this prefix are removed
# before the current one is added, so rotating presets never orphans stale
# schemes in the user's settings.json.
$TerminalSchemePrefix = 'CWT - '


# ----------------------------------------------------------------------------
# Helpers
# ----------------------------------------------------------------------------
function Write-Accent($Message) { Write-Host $Message -ForegroundColor Magenta }
function Write-Info($Message) { Write-Host "  $Message" -ForegroundColor Gray }
function Write-Ok($Message)   { Write-Host "  [+] $Message" -ForegroundColor Green }
function Write-Warn($Message) { Write-Host "  [!] $Message" -ForegroundColor Yellow }

# Immediate, unbuffered progress log (survives hangs / interrupted runs)
$LogFile = Join-Path $env:TEMP 'cwt-log.txt'
function Step($Message) {
    try { [System.IO.File]::AppendAllText($LogFile, "$(Get-Date -Format 'HH:mm:ss.fff')  $Message`n") } catch { }
}

<#
  Turn arbitrary text (a preset's displayName) into a label that is safe for
  BOTH a file name and a .theme INI value: strips CR/LF (a newline would forge
  extra INI lines) and the characters \ / : * ? " < > | , trims, collapses
  whitespace runs to a single space, and caps the length at 64.
  Used for the .theme file name, its DisplayName= line and its comment line.
#>
function Format-CWTSafeLabel([string]$Text) {
    if ($null -eq $Text) { return '' }
    $s = $Text -replace '[\r\n]', ''
    $s = $s -replace '[\\/:*?"<>|]', ''
    $s = $s -replace '\s+', ' '
    $s = $s.Trim()
    if ($s.Length -gt 64) { $s = $s.Substring(0, 64).TrimEnd() }
    return $s
}

if (-not (Test-Path $StateDir)) { New-Item -ItemType Directory -Force -Path $StateDir | Out-Null }

<#
  Load presets/<name>.json and publish it as the $CWT_* script variables.
  The preset files are the ONLY source of color in this tool - no hex value
  lives in this script.

  Required keys: accent, accentLight, selectionBg, titleBar, paletteEntry5,
  paletteEntry7 (all "#RRGGBB"), taskbarAcrylic (0-255), paletteAlpha (0-255),
  and the "terminal" object with all 16 ANSI slots plus
  foreground/background/cursorColor/selectionBackground.

  Optional keys:
    * normalBg / selectionFg ("#RRGGBB"). GUI chrome only (the GUI log box reads
      normalBg); neither is ever applied to Windows, so a preset may omit them.
    * systemLight / appLight (0 = Dark, 1 = Light). When a preset omits them
      or sets them to null, Get-CWTSystemLight / Get-CWTAppLight keep their
      defaults - so a minimal preset cannot silently break the
      Windows 11 accent gate (see those functions below the import call).
    * wallpaper (string). Absolute path, or relative to the repo root. When it
      is null, Resolve-CWTWallpaper generates a gradient.

  Tunables (documented here because JSON has no comments):
    * taskbarAcrylic: Windows 10 TaskbarAcrylicOpacity. 0 = fully transparent
      (no blur) .. 80 = visible frosted blur, still translucent (user-verified)
      .. 255 = max blur / almost solid.
    * paletteAlpha: AccentPalette opacity (Start menu / action centre tint).
      0 = fully transparent .. 96 = clearly frosted (default) .. 170 = light
      frost .. 255 = solid colour. AveYo's themes ship ~0xAA. Tune it live with
      the 'start-acrylic' command.

  The name is matched against ^[a-z0-9][a-z0-9-]*$ before it is turned into a
  file path, so a crafted name (e.g. ..\..\foo) can never load a JSON file
  outside presets/.

  An unknown name: THROWS when -Explicit is set (the name came from the
  'apply' / 'on' command-line argument - a typo must fail loudly instead of
  silently applying another preset), and falls back to 'rose' when -Explicit
  is not set (state.json value, or no argument at all). It throws when no
  preset file exists at all, because every later step reads these variables.
#>
function Import-CWTPreset {
    param(
        [string]$Name,
        # $true when the name came from the 'apply' / 'on' command-line
        # argument. An unknown explicit name is an error, not a fallback.
        [switch]$Explicit
    )

    if (-not $Name) { $Name = 'rose' }
    # Preset names become file names - reject anything that is not a plain
    # slug, otherwise "$Name.json" could point outside presets/.
    if ($Name -notmatch '^[a-z0-9][a-z0-9-]*$') {
        throw "Invalid preset name '$Name' - preset names must match ^[a-z0-9][a-z0-9-]*$ (letters, digits, hyphens)."
    }
    $path = Join-Path $PresetsDir "$Name.json"
    if (-not (Test-Path $path)) {
        if ($Explicit) {
            throw "Unknown preset '$Name' - run the 'presets' command to list the available preset names."
        }
        Write-Warn "Unknown preset '$Name' - using 'rose' instead."
        $Name = 'rose'
        $path = Join-Path $PresetsDir "$Name.json"
    }
    if (-not (Test-Path $path)) {
        throw "No preset file found at $path (the presets/ folder ships with this script)."
    }

    try {
        $json = Get-Content $path -Raw -Encoding UTF8 | ConvertFrom-Json
    } catch {
        throw "Preset '$Name' is not valid JSON: $($_.Exception.Message)"
    }

    foreach ($k in @('accent', 'accentLight', 'selectionBg',
                     'titleBar', 'paletteEntry5', 'paletteEntry7')) {
        $prop = $json.PSObject.Properties[$k]
        if ($null -eq $prop -or -not $prop.Value) { throw "Preset '$Name': missing required key '$k'." }
        if ("$($prop.Value)" -notmatch '^#[0-9A-Fa-f]{6}$') { throw "Preset '$Name': '$k' must look like #RRGGBB." }
    }

    # Optional GUI-chrome colors: only the GUI log box reads these and neither
    # is ever applied to Windows, so presets may omit them. Validate the
    # format only when the key is present (all shipped presets keep them).
    $script:CWT_NormalBg    = $null
    $script:CWT_SelectionFg = $null
    foreach ($k in @('normalBg', 'selectionFg')) {
        $prop = $json.PSObject.Properties[$k]
        if ($null -eq $prop -or $null -eq $prop.Value -or "$($prop.Value)" -eq '') { continue }
        if ("$($prop.Value)" -notmatch '^#[0-9A-Fa-f]{6}$') { throw "Preset '$Name': '$k' must look like #RRGGBB." }
        if ($k -eq 'normalBg') { $script:CWT_NormalBg = [string]$prop.Value }
        else                   { $script:CWT_SelectionFg = [string]$prop.Value }
    }

    foreach ($k in @('taskbarAcrylic', 'paletteAlpha')) {
        $prop = $json.PSObject.Properties[$k]
        if ($null -eq $prop -or $null -eq $prop.Value) { throw "Preset '$Name': missing required key '$k'." }
        $n = [int]$prop.Value
        if ($n -lt 0 -or $n -gt 255) { throw "Preset '$Name': '$k' must be between 0 and 255." }
    }

    # The terminal scheme must stay complete: 16 ANSI slots + 4 meta colors.
    $tProp = $json.PSObject.Properties['terminal']
    if ($null -eq $tProp -or $null -eq $tProp.Value) { throw "Preset '$Name': missing required object 'terminal'." }
    foreach ($k in @('foreground', 'background', 'cursorColor', 'selectionBackground',
                     'black', 'red', 'green', 'yellow', 'blue', 'purple', 'cyan', 'white',
                     'brightBlack', 'brightRed', 'brightGreen', 'brightYellow',
                     'brightBlue', 'brightPurple', 'brightCyan', 'brightWhite')) {
        $slot = $json.terminal.PSObject.Properties[$k]
        if ($null -eq $slot -or -not $slot.Value) { throw "Preset '$Name': terminal.$k is missing." }
        if ("$($slot.Value)" -notmatch '^#[0-9A-Fa-f]{6}$') { throw "Preset '$Name': terminal.$k must look like #RRGGBB." }
    }

    # Nullable mode keys: null/absent keeps the default (see Get-CWTSystemLight).
    $systemLight = $null
    if ($json.PSObject.Properties['systemLight'] -and $null -ne $json.systemLight) {
        $systemLight = [int]$json.systemLight
        if ($systemLight -notin 0, 1) { throw "Preset '$Name': systemLight must be 0, 1 or null." }
    }
    $appLight = $null
    if ($json.PSObject.Properties['appLight'] -and $null -ne $json.appLight) {
        $appLight = [int]$json.appLight
        if ($appLight -notin 0, 1) { throw "Preset '$Name': appLight must be 0, 1 or null." }
    }
    $wallpaper = $null
    if ($json.PSObject.Properties['wallpaper'] -and $json.wallpaper) {
        $wallpaper = [string]$json.wallpaper
    }

    $script:CWT_PresetName     = $Name
    $script:CWT_DisplayName    = if ($json.PSObject.Properties['displayName'] -and $json.displayName) { [string]$json.displayName } else { $Name }
    $script:CWT_Description    = if ($json.PSObject.Properties['description'] -and $json.description) { [string]$json.description } else { '' }
    $script:CWT_Accent         = [string]$json.accent
    $script:CWT_AccentLight    = [string]$json.accentLight
    $script:CWT_SelectionBg    = [string]$json.selectionBg
    # $CWT_NormalBg / $CWT_SelectionFg were set by the optional-key loop above.
    $script:CWT_TitleBar       = [string]$json.titleBar
    $script:CWT_PaletteEntry5  = [string]$json.paletteEntry5
    $script:CWT_PaletteEntry7  = [string]$json.paletteEntry7
    $script:CWT_TaskbarAcrylic = [int]$json.taskbarAcrylic
    $script:CWT_PaletteAlpha   = [int]$json.paletteAlpha
    $script:CWT_SystemLight    = $systemLight
    $script:CWT_AppLight       = $appLight
    $script:CWT_Wallpaper      = $wallpaper
    $script:CWT_Terminal       = $json.terminal
    Step "Import-CWTPreset: loaded '$Name' ($($script:CWT_DisplayName)) from $path"
    return $Name
}

# ----------------------------------------------------------------------------
# Preset selection & load. This call MUST run before anything reads a $CWT_*
# variable: explicit argument > last selection persisted in state.json > rose.
# ----------------------------------------------------------------------------
$CWTRequestedPreset    = ''
$CWTRequestedExplicit  = $false
if (($Command -eq 'apply' -or $Command -eq 'on') -and $ThemeArg) {
    $CWTRequestedPreset   = $ThemeArg
    # A name typed on the command line must FAIL when it is unknown - falling
    # back would re-theme the desktop with an unintended preset.
    $CWTRequestedExplicit = $true
} elseif (Test-Path $StatePath) {
    try {
        $state = Get-Content $StatePath -Raw -Encoding UTF8 | ConvertFrom-Json
        if ($state.PSObject.Properties['preset'] -and $state.preset) {
            $CWTRequestedPreset = [string]$state.preset
        }
    } catch { }
}
$null = Import-CWTPreset -Name $CWTRequestedPreset -Explicit:$CWTRequestedExplicit

# The generated .theme file is named after the active preset's display name,
# The .theme file name is built inside Write-CWTThemeFile, e.g.
# "%LOCALAPPDATA%\Microsoft\Windows\Themes\Ocean.theme". The label is
# sanitized there by Format-CWTSafeLabel.

# ----------------------------------------------------------------------------
# Light/dark mode.
# ----------------------------------------------------------------------------
function Get-OSBuildNumber {
    try { return [Environment]::OSVersion.Version.Build } catch { return 0 }
}
function Test-IsWin11 { return (Get-OSBuildNumber) -ge 22000 }
function Get-CWTSystemLight {
    # Preset override first: systemLight may pin the value (0 = Dark, 1 = Light).
    # The fallback is Light on BOTH Windows 10 and 11. The apply path always
    # writes ColorPrevalence=0, so NO accent paints on the taskbar in either
    # mode, and the title-bar accent (Set-TitleBarAccent 1) is DWM-side and
    # independent of the system mode - there is no reason to force Dark on
    # Windows 11. Light matches the proven original behavior, all shipped
    # presets and tests/test-win11-taskbar-accent.ps1.
    if ($null -ne $CWT_SystemLight) { return [int]$CWT_SystemLight }
    return 1
}
function Get-CWTAppLight {
    # Preset override first (appLight may be null); default: Light on both OSes.
    if ($null -ne $CWT_AppLight) { return [int]$CWT_AppLight }
    return 1
}

<#
  Convert "#RRGGBB" to a registry DWORD.
  ColorizationColor is AARRGGBB (verified: default 0xC40078D7 => the Windows
  default blue 0078D7).
  AccentColorMenu is AABBGGRR (verified empirically: setting it as AABBGGRR makes
  the derived ColorizationColor renders the accent; setting it as AARRGGBB renders blue).
  Pass -AABBGGRR for AccentColorMenu / StartColorMenu.
#>
function ConvertTo-ColorDWord {
    param([string]$Hex, [byte]$Alpha = 255, [switch]$AABBGGRR)
    $Hex = $Hex.TrimStart('#')
    $r = [Convert]::ToInt32($Hex.Substring(0, 2), 16)
    $g = [Convert]::ToInt32($Hex.Substring(2, 2), 16)
    $b = [Convert]::ToInt32($Hex.Substring(4, 2), 16)
    if ($AABBGGRR) {
        # bytes (LE): R,G,B,A  -> DWORD AABBGGRR
        $bytes = [byte[]]@([byte]$r, [byte]$g, [byte]$b, [byte]$Alpha)
    } else {
        # bytes (LE): B,G,R,A  -> DWORD AARRGGBB
        $bytes = [byte[]]@([byte]$b, [byte]$g, [byte]$r, [byte]$Alpha)
    }
    return [BitConverter]::ToUInt32($bytes, 0)
}

# "#RRGGBB" -> 4 bytes [R,G,B,A] (the AccentPalette binary layout)
function ConvertTo-RGBABytes([string]$Hex, [byte]$Alpha = 255) {
    $Hex = $Hex.TrimStart('#')
    return ,[byte[]]@(
        [Convert]::ToByte($Hex.Substring(0, 2), 16),
        [Convert]::ToByte($Hex.Substring(2, 2), 16),
        [Convert]::ToByte($Hex.Substring(4, 2), 16),
        [byte]$Alpha
    )
}

# "#RRGGBB" -> System.Drawing.Color (used by the wallpaper gradient generator)
function ConvertTo-DrawColor([string]$Hex) {
    $rgb = ConvertTo-RGBABytes $Hex
    return [System.Drawing.Color]::FromArgb([int]$rgb[0], [int]$rgb[1], [int]$rgb[2])
}

<#
  32-byte AccentPalette used by the Start menu / taskbar / action center.
  8 entries x 4 bytes, each [R,G,B,A] - exactly 32 bytes. Windows ships the
  DEFAULT BLUE palette here and the shell does NOT regenerate it from
  AccentColorMenu - which is why the Start menu stays opaque blue while the
  taskbar (which reads AccentColorMenu / ColorizationColor) takes the accent.
  Writing it is what actually re-colours the Start menu (same approach as the
  well-known "Pitch Black Theme" gists). Every color comes from the preset.
#>
function New-CWTAccentPalette {
    param([int]$Alpha = $CWT_PaletteAlpha)
    # Alpha controls how much of the frosted wallpaper shows through the accent
    # tint on Start menu / action centre: 0 = fully transparent .. 255 = solid.
    # AveYo's themes ship ~0xAA; users asked for more transparency here, so the
    # default is 96 (0x60). Tunable live via 'start-acrylic' command.
    $a = [byte]$Alpha
    $entries = @(
        $CWT_SelectionBg,   # 0 Accent hover
        $CWT_Accent,        # 1 Accent (main)
        $CWT_TitleBar,      # 2 Active title bar / border
        $CWT_Accent,        # 3 Settings icons / links
        $CWT_Accent,        # 4 Start menu background (when transparency off) / active taskbar button
        $CWT_PaletteEntry5, # 5 Taskbar front / folders on Start list background (light mode)
        $CWT_Accent,        # 6 Taskbar background (when transparency on)
        $CWT_PaletteEntry7  # 7 Unused
    )
    $bytes = New-Object System.Collections.Generic.List[byte]
    foreach ($e in $entries) { $bytes.AddRange([byte[]](ConvertTo-RGBABytes $e $a)) }
    return $bytes.ToArray()
}

# ----------------------------------------------------------------------------
# Windows API bits (compiled once per process). Class name MUST match the
# type check below, otherwise Add-Type re-runs and throws "type already exists".
# ----------------------------------------------------------------------------
function Ensure-WinApi {
    if (-not ('CustomWinAPI' -as [type])) {
        Add-Type @"
using System;
using System.Runtime.InteropServices;
public class CustomWinAPI {
    // SPI_SETDESKWALLPAPER (20) with SPIF_UPDATEINIFILE | SPIF_SENDCHANGE (3)
    [DllImport("user32.dll", CharSet = CharSet.Auto)]
    public static extern int SystemParametersInfo(int uAction, int uParam, string lpvParam, int fuWinIni);
}
"@
    }
}

# ----------------------------------------------------------------------------
# Native theme manager: reverse-engineered IThemeManager2 COM API (themeui.dll)
# (CLSID {9324da94-...} "Windows Theme Manager 2 API" - the same API the
#  Settings app uses to list / apply / save Windows themes.)
# Reverse-engineered by the SecureUxTheme project (LGPL-2.1):
#   https://github.com/namazso/SecureUxTheme  (ThemeLib/theme.cpp, re/*.h)
# Verified S_OK on Windows 10 21H2: Init, GetThemeCount/Current/Custom/Default,
# SetCurrentTheme. NOTE: ExportRoamingThemeToStream returns S_OK but only emits
# an ~82-byte serialization header from a bare CoCreateInstance process, so
# 'theme-save' writes a plain .theme file instead (see Save-ThemeFile below).
# NOTE: theme objects returned by GetTheme are bare C++ vtables (not QI-able)
# whose layout shifts per build - we deliberately don't call into them.
# ----------------------------------------------------------------------------
function Ensure-ThemeApi {
    if (-not ('CustomThemeApi' -as [type])) {
        Add-Type @"
using System;
using System.Runtime.InteropServices;
using System.Runtime.InteropServices.ComTypes;
using System.Threading;

namespace CustomThemeApi {

  [ComImport]
  [Guid("c1e8c83e-845d-4d95-81db-e283fdffc000")]
  [InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
  public interface IThemeManager2 {
    [PreserveSig] int Init(int flags);
    [PreserveSig] int InitAsync(IntPtr hwnd, int unknown);
    [PreserveSig] int Refresh();
    [PreserveSig] int RefreshAsync(IntPtr hwnd, int unknown);
    [PreserveSig] int RefreshComplete();
    [PreserveSig] int GetThemeCount(out int count);
    [PreserveSig] int GetTheme(int idx, out IntPtr theme);
    [PreserveSig] int IsThemeDisabled(int idx, out int disabled);
    [PreserveSig] int GetCurrentTheme(out int idx);
    [PreserveSig] int SetCurrentTheme(IntPtr parent, int theme_idx, int applyNow, uint applyFlags, uint packFlags);
    [PreserveSig] int GetCustomTheme(out int idx);
    [PreserveSig] int GetDefaultTheme(out int idx);
    [PreserveSig] int CreateThemePack(IntPtr parent, [MarshalAs(UnmanagedType.LPWStr)] string path, uint packFlags);
    [PreserveSig] int CloneAndSetCurrentTheme(IntPtr parent, [MarshalAs(UnmanagedType.LPWStr)] string path, [MarshalAs(UnmanagedType.BStr)] out string resultPath);
    [PreserveSig] int InstallThemePack(IntPtr parent, [MarshalAs(UnmanagedType.LPWStr)] string path, int unknown, uint applyFlags, uint packFlags, [MarshalAs(UnmanagedType.BStr)] out string p1, out IntPtr theme);
    [PreserveSig] int DeleteTheme([MarshalAs(UnmanagedType.LPWStr)] string path);
    [PreserveSig] int OpenTheme(IntPtr parent, [MarshalAs(UnmanagedType.LPWStr)] string path, uint packFlags);
    [PreserveSig] int AddAndSelectTheme(IntPtr parent, [MarshalAs(UnmanagedType.LPWStr)] string path, uint applyFlags, uint packFlags);
    [PreserveSig] int SQMCurrentTheme();
    [PreserveSig] int ExportRoamingThemeToStream([MarshalAs(UnmanagedType.Interface)] IStream stream, int unknown);
    [PreserveSig] int ImportRoamingThemeFromStream([MarshalAs(UnmanagedType.Interface)] IStream stream, int unknown);
    [PreserveSig] int UpdateColorSettingsForLogonUI();
    [PreserveSig] int GetDefaultThemeId(out Guid id);
    [PreserveSig] int UpdateCustomTheme();
  }

  public static class Interop {
    [DllImport("ole32.dll")]
    public static extern int CoInitialize(IntPtr pvReserved);
    [DllImport("ole32.dll")]
    public static extern int CoCreateInstance(ref Guid clsid, IntPtr pUnk, uint dwClsContext, ref Guid riid, [MarshalAs(UnmanagedType.Interface)] out object ppv);

    public static readonly Guid CLSID_ThemeManager2 = new Guid("9324da94-50ec-4a14-a770-e90ca03e7c8f");
    public static readonly Guid IID_IThemeManager2 = new Guid("c1e8c83e-845d-4d95-81db-e283fdffc000");
  }

  public static class Native {
    // The COM class is Apartment-threaded with no registered proxy for the
    // RE'd IID; run calls on an STA thread when the caller is MTA.
    static T Sta<T>(Func<T> f) {
      if (Thread.CurrentThread.GetApartmentState() == ApartmentState.STA) return f();
      T result = default(T);
      Exception error = null;
      var th = new Thread(() => { try { result = f(); } catch (Exception e) { error = e; } });
      th.SetApartmentState(ApartmentState.STA);
      th.Start();
      th.Join();
      if (error != null) throw error;
      return result;
    }

    public static int[] GetState() {
      return Sta<int[]>(() => {
        var r = new int[4];
        using (var ctx = Open()) {
          int count = 0, cur = 0, custom = 0, def = 0;
          ctx.Mg.Init(0);
          ctx.Mg.GetThemeCount(out count);
          ctx.Mg.GetCurrentTheme(out cur);
          ctx.Mg.GetCustomTheme(out custom);
          ctx.Mg.GetDefaultTheme(out def);
          r[0] = count; r[1] = cur; r[2] = custom; r[3] = def;
        }
        return r;
      });
    }

    public static int SwitchTheme(int idx, bool applyNow) {
      return Sta<int>(() => {
        using (var ctx = Open()) {
          ctx.Mg.Init(0);
          return ctx.Mg.SetCurrentTheme(IntPtr.Zero, idx, applyNow ? 1 : 0, 0, 0);
        }
      });
    }

    // .theme DisplayName values like '@C:\Windows\...\themeui.dll,-2013' are
    // indirect resource strings - resolve them to human-readable names.
    [DllImport("shlwapi.dll", CharSet = CharSet.Unicode)]
    static extern int SHLoadIndirectString(string pszSource, System.Text.StringBuilder pszOutBuf, int cchOutBuf, IntPtr ppvReserved);

    public static string ResolveIndirect(string s) {
      if (string.IsNullOrEmpty(s) || !s.StartsWith("@")) return s;
      var sb = new System.Text.StringBuilder(512);
      int hr = SHLoadIndirectString(s, sb, sb.Capacity, IntPtr.Zero);
      return (hr == 0 && sb.Length > 0) ? sb.ToString() : s;
    }

    // --- High Contrast safety (SPI_GETHIGHCONTRAST / SPI_SETHIGHCONTRAST) ---
    [StructLayout(LayoutKind.Sequential)]
    struct HIGHCONTRAST { public int cbSize; public int dwFlags; public IntPtr lpszDefaultScheme; }
    [DllImport("user32.dll", CharSet = CharSet.Unicode)]
    static extern int SystemParametersInfo(int uAction, int uParam, ref HIGHCONTRAST lpvParam, int fuWinIni);
    const int SPI_GETHIGHCONTRAST = 0x0042;
    const int SPI_SETHIGHCONTRAST = 0x0043;
    const int SPIF_SENDCHANGE = 0x2;
    const int HCF_HIGHCONTRASTON = 0x1;

    // Some themes (the "Ease of Access" / high-contrast ones) turn High Contrast
    // mode on when applied. Detect the live state, not just the registry.
    public static bool IsHighContrastOn() {
      HIGHCONTRAST hc = new HIGHCONTRAST();
      hc.cbSize = Marshal.SizeOf(typeof(HIGHCONTRAST));
      SystemParametersInfo(SPI_GETHIGHCONTRAST, hc.cbSize, ref hc, 0);
      return (hc.dwFlags & HCF_HIGHCONTRASTON) != 0;
    }

    public static void ForceHighContrastOff() {
      HIGHCONTRAST hc = new HIGHCONTRAST();
      hc.cbSize = Marshal.SizeOf(typeof(HIGHCONTRAST));
      hc.dwFlags = 0;
      hc.lpszDefaultScheme = IntPtr.Zero;
      SystemParametersInfo(SPI_SETHIGHCONTRAST, hc.cbSize, ref hc, SPIF_SENDCHANGE);
    }

    class Ctx : IDisposable {
      public IThemeManager2 Mg;
      public void Dispose() {
        if (Mg != null) { Marshal.FinalReleaseComObject(Mg); Mg = null; }
      }
    }
    static Ctx Open() {
      Interop.CoInitialize(IntPtr.Zero);
      object obj = null;
      Guid c = Interop.CLSID_ThemeManager2, i = Interop.IID_IThemeManager2;
      int hr = Interop.CoCreateInstance(ref c, IntPtr.Zero, 0x1, ref i, out obj);
      if (hr != 0 || obj == null)
        throw new Exception("CoCreateInstance(ThemeManager2) failed 0x" + ((uint)hr).ToString("X8") +
          " - native theme API unavailable (themes service stopped?)");
      return new Ctx { Mg = (IThemeManager2)obj };
    }
  }
}
"@
    }
}

# Native theme-list helpers
function Get-ThemeFileNames {
    # Names for installed themes come from the .theme files themselves.
    $dirs = @(
        (Join-Path $env:WINDIR 'Resources\Themes'),
        (Join-Path $env:WINDIR 'Resources\Ease of Access Themes'),
        (Join-Path $env:LOCALAPPDATA 'Microsoft\Windows\Themes')
    )
    $files = @()
    foreach ($d in $dirs) {
        if (Test-Path $d) { $files += Get-ChildItem $d -Filter '*.theme' -File -ErrorAction SilentlyContinue }
    }
    $files | ForEach-Object {
        $display = $null
        $inTheme = $false
        foreach ($ln in (Get-Content $_.FullName -ErrorAction SilentlyContinue)) {
            $t = $ln.Trim()
            if ($t -match '^\[') { $inTheme = ($t -ieq '[Theme]'); continue }
            if ($inTheme -and $t -match '^DisplayName\s*=\s*(.+?)\s*$') { $display = $Matches[1]; break }
        }
        # Ease-of-Access themes enable High Contrast mode when applied - flag them.
        $isHc = ($_.FullName -like '*\Ease of Access Themes\*')
        if (-not $isHc) {
            $isHc = [bool](Select-String -Path $_.FullName -Pattern '^HighContrast\s*=' -Quiet -ErrorAction SilentlyContinue)
        }
        [pscustomobject]@{ Name = $display; File = $_.FullName; HighContrast = $isHc }
    }
}

function Show-NativeThemes {
    try {
        Ensure-ThemeApi
        $st = [CustomThemeApi.Native]::GetState()
        Write-Accent "Native theme manager (themeui.dll ThemeManager2)"
        Write-Info "Installed themes : $($st[0])   current=$($st[1])   custom=$($st[2])   default=$($st[3])"
        $names = Get-ThemeFileNames
        if ($names) {
            Write-Info "Installed theme files (name <- path):"
            $names | ForEach-Object {
                $n = $_.Name
                try {
                    if ($n -and $n.StartsWith('@')) { $n = [CustomThemeApi.Native]::ResolveIndirect($n) }
                } catch { }
                $tag = if ($_.HighContrast) { '  [Ease-of-Access theme - applies HIGH CONTRAST mode]' } else { '' }
                Write-Info ("  {0} <- {1}{2}" -f $(if ($n) { "'$n'" } else { '(no DisplayName)' }), $_.File, $tag)
            }
            if ($names | Where-Object { $_.HighContrast }) {
                Write-Warn "High Contrast themes are listed above - theme-switch on them will be auto-undone by this script."
            }
        } else {
            Write-Info "No .theme files found in the standard theme folders."
        }
        Write-Info "Switch with: custom-windows-themer.ps1 theme-switch <index>"
    } catch {
        Write-Warn "Native theme API failed: $($_.Exception.Message)"
        Write-Warn "Fallback: this script's apply/restore still works (registry layer)."
    }
}

function Save-ThemeFile {
    param([string]$Path)
    # Default: a timestamped .theme in the user themes folder so it shows up in
    # Settings > Personalization > Themes - exactly like the preset's own
    # "<PresetDisplayName>.theme".
    if (-not $Path) {
        $stamp = Get-Date -Format 'yyyy-MM-dd HHmmss'
        $Path = Join-Path $UserThemesDir "Saved theme $stamp.theme"
    }
    try {
        if (Test-Path $Path) { Write-Warn "Overwriting existing file: $Path" }

        $desk = 'HKCU:\Control Panel\Desktop'
        $dwm  = 'HKCU:\Software\Microsoft\Windows\DWM'
        $per  = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Themes\Personalize'

        $wallpaper = Get-RegString $desk 'Wallpaper'
        if (-not $wallpaper -or -not (Test-Path $wallpaper)) {
            Write-Warn "No wallpaper path in the registry - writing the theme without one."
            $wallpaper = $null
        }
        # registry WallpaperStyle -> .theme PicturePosition:
        #   10 Fill=4, 6 Fit=3, 22 Span=5, 2 Stretch=2 ; TileWallpaper=1 -> Tile=1 ; else Center=0
        $style = Get-RegString $desk 'WallpaperStyle'
        $tile  = Get-RegString $desk 'TileWallpaper'
        if ($tile -eq '1') { $picturePos = 1 }
        else {
            switch ("$style") {
                '10' { $picturePos = 4 }
                '6'  { $picturePos = 3 }
                '22' { $picturePos = 5 }
                '2'  { $picturePos = 2 }
                default { $picturePos = 0 }
            }
        }

        $colorization = Get-RegDWord $dwm 'ColorizationColor'
        if ($null -eq $colorization) { $colorization = ConvertTo-ColorDWord $CWT_Accent }
        $colorHex = '0X{0:X8}' -f $colorization
        $autoColor = Get-RegDWord $desk 'AutoColorization'
        if ($null -eq $autoColor) { $autoColor = 0 }

        $perProps = Get-ItemProperty $per -ErrorAction SilentlyContinue
        $sysLight  = if ($null -ne $perProps -and $null -ne $perProps.SystemUsesLightTheme) { [int]$perProps.SystemUsesLightTheme } else { 1 }
        $appsLight = if ($null -ne $perProps -and $null -ne $perProps.AppsUseLightTheme) { [int]$perProps.AppsUseLightTheme } else { 1 }
        $sysMode = if ($sysLight  -eq 1) { 'Light' } else { 'Dark' }
        $appMode = if ($appsLight -eq 1) { 'Light' } else { 'Dark' }

        $displayName = [System.IO.Path]::GetFileNameWithoutExtension($Path)
        $writeTime = 0
        if ($wallpaper -and (Test-Path $wallpaper)) {
            $writeTime = [System.IO.File]::GetLastWriteTimeUtc($wallpaper).ToFileTimeUtc()
        }
        $guid = [guid]::NewGuid().ToString().ToUpper()

        $content = @(
            '; Saved theme - generated by custom-windows-themer.ps1 theme-save'
            ''
            '[Theme]'
            "DisplayName=$displayName"
            "; stable id so the theme survives re-import"
            "ThemeId={$guid}"
            ''
            '[Control Panel\Desktop]'
            "Wallpaper=$wallpaper"
            'Pattern='
            'MultimonBackgrounds=0'
            "PicturePosition=$picturePos"
            "WallpaperWriteTime=$writeTime"
            ''
            '[VisualStyles]'
            'Path=%SystemRoot%\resources\Themes\Aero\Aero.msstyles'
            'ColorStyle=NormalColor'
            'Size=NormalSize'
            "AutoColorization=$autoColor"
            "ColorizationColor=$colorHex"
            "SystemMode=$sysMode"
            "AppMode=$appMode"
            'VisualStyleVersion=10'
            ''
            '[boot]'
            'SCRNSAVE.EXE='
            ''
            '[MasterThemeSelector]'
            'MTSM=RJSPBS'
        )
        $dir = Split-Path $Path -Parent
        if ($dir -and -not (Test-Path $dir)) { New-Item -ItemType Directory -Force -Path $dir | Out-Null }
        $content | Set-Content -Path $Path -Encoding Unicode
        Write-Ok "Saved current theme to: $Path"
        Write-Info "Wallpaper : $wallpaper"
        Write-Info "Accent    : $colorHex   ($sysMode / $appMode mode)"
        Write-Info "It is installed for Settings > Personalization > Themes - double-click it (or run theme-restore) to apply."
    } catch {
        Write-Warn "Could not save theme: $($_.Exception.Message)"
    }
}

<#
  If a theme woke up High Contrast mode and the user didn't have it on before,
  switch it back off (registry + SPI). Used after theme-switch / theme-restore.
#>
function Undo-HighContrastIfNeeded {
    param([bool]$WasOn, [string]$What)
    Start-Sleep -Milliseconds 1500
    $hcFl = Get-ItemProperty 'HKCU:\Control Panel\Accessibility\HighContrast' -ErrorAction SilentlyContinue
    $hcRegOn = ($null -ne $hcFl -and $hcFl.Flags -ne 126)   # 126 = baseline off; anything else = on
    if (-not $WasOn -and ([CustomThemeApi.Native]::IsHighContrastOn() -or $hcRegOn)) {
        [CustomThemeApi.Native]::ForceHighContrastOff() | Out-Null
        $hcK = 'HKCU:\Control Panel\Accessibility\HighContrast'
        if (Test-Path $hcK) {
            Set-ItemProperty -Path $hcK -Name 'Flags' -Value 126 -Type DWord -Force
            Set-ItemProperty -Path $hcK -Name 'High Contrast Scheme' -Value '' -Force
            Remove-ItemProperty -Path $hcK -Name 'Previous High Contrast Scheme MUI Value' -ErrorAction SilentlyContinue
            Remove-ItemProperty -Path $hcK -Name 'Previous High Contrast Scheme MUI Ptr' -ErrorAction SilentlyContinue
            Remove-ItemProperty -Path $hcK -Name 'LastUpdatedThemeId' -ErrorAction SilentlyContinue
        }
        Write-Warn "$What turned ON High Contrast mode - it was switched back OFF automatically."
    }
}

function Restore-ThemeFile {
    param([string]$Path)
    if (-not $Path -or -not (Test-Path $Path)) {
        Write-Warn "Usage: custom-windows-themer.ps1 theme-restore <path-to-.theme-file>"
        return
    }
    try {
        $full = (Resolve-Path $Path).Path
        $disp = $null
        try {
            $raw = Get-Content $full -Raw
            if ($raw -match '(?m)^DisplayName\s*=\s*(.+?)\s*$') { $disp = $Matches[1].Trim() }
        } catch { }
        Write-Info "Applying theme: $(if ($disp) { $disp } else { $full })"
        Write-Info "(native apply via the Windows shell - identical to double-clicking the .theme file)"
        Ensure-ThemeApi
        $hcWasOn = [CustomThemeApi.Native]::IsHighContrastOn()
        Start-Process $full | Out-Null
        Undo-HighContrastIfNeeded $hcWasOn "The applied theme"
        $cur = (Get-ItemProperty 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Themes' -ErrorAction SilentlyContinue).CurrentTheme
        if ($cur -eq $full) {
            Write-Ok "Theme applied: $full (now the active theme)"
        } else {
            Write-Ok "Theme handed to Windows to apply: $full"
            Write-Info "Current theme registry value: $cur"
        }
        Write-Warn "Note: .theme files cannot carry the Start-menu palette / transparency / taskbar acrylic."
        Write-Warn "For a full pixel-perfect restore of a saved profile, use 'restore' instead of theme-restore."
    } catch {
        Write-Warn "Could not apply theme: $($_.Exception.Message)"
    }
}

function Switch-NativeTheme {
    param([string]$IndexArg)
    if (-not $IndexArg -or $IndexArg -notmatch '^\d+$') {
        Write-Warn "Usage: custom-windows-themer.ps1 theme-switch <index>   (list them with 'themes')"
        return
    }
    try {
        Ensure-ThemeApi
        $idx = [int]$IndexArg
        # Safety: remember whether the user had High Contrast on BEFORE switching.
        # (Ease-of-Access themes switch it on - we must not silently keep that.)
        $hcWasOn = [CustomThemeApi.Native]::IsHighContrastOn()
        $hr = [CustomThemeApi.Native]::SwitchTheme($idx, $true)
        if ($hr -eq 0) {
            Write-Ok "Switched to theme index $idx (native apply)."
        } else {
            Write-Warn "Switch failed with HRESULT 0x$('{0:X8}' -f $hr) - index out of range?"
            return
        }
        # Auto-undo High Contrast if the applied theme turned it on.
        Undo-HighContrastIfNeeded $hcWasOn "Theme $idx"
        $curTheme = (Get-ItemProperty 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Themes' -ErrorAction SilentlyContinue).CurrentTheme
        if ($curTheme -and $curTheme -like '*\Ease of Access Themes\*') {
            Write-Warn "Note: the applied theme is an Ease-of-Access (High Contrast) theme."
        }
    } catch {
        Write-Warn "Could not switch theme: $($_.Exception.Message)"
    }
}

# ----------------------------------------------------------------------------
# Individual setters
# ----------------------------------------------------------------------------
function Set-Wallpaper {
    param([string]$Path)
    Ensure-WinApi
    [CustomWinAPI]::SystemParametersInfo(20, 0, $Path, 3) | Out-Null
    Set-ItemProperty -Path 'HKCU:\Control Panel\Desktop' -Name Wallpaper -Value $Path -Force
}

function Set-WallpaperStyle([string]$Style) {
    # "10" = Fill, "6" = Fit, "2" = Stretch ; TileWallpaper "0" = off
    Set-ItemProperty -Path 'HKCU:\Control Panel\Desktop' -Name WallpaperStyle -Value $Style -Force
    Set-ItemProperty -Path 'HKCU:\Control Panel\Desktop' -Name TileWallpaper  -Value '0' -Force
}

function Set-AccentColor {
    param([string]$Hex, [int]$PaletteAlpha = $CWT_PaletteAlpha)
    $dwmPath = 'HKCU:\Software\Microsoft\Windows\DWM'
    if (-not (Test-Path $dwmPath)) { New-Item -Force -Path $dwmPath | Out-Null }
    # Taskbar / title-bar colour (ColorPrevalence=1) is driven by ColorizationColor (AARRGGBB)
    Set-ItemProperty -Path $dwmPath -Name ColorizationColor -Value ([uint32](ConvertTo-ColorDWord $Hex)) -Type DWord -Force
    # The Start menu / taskbar also read AccentColorMenu, StartColorMenu (AABBGGRR)
    # and the 32-byte AccentPalette (BGRA). All three must be written or the
    # Start menu keeps the default blue palette.
    $accPath = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\Accent'
    if (-not (Test-Path $accPath)) { New-Item -Force -Path $accPath | Out-Null }
    Set-ItemProperty -Path $accPath -Name AccentColorMenu -Value ([uint32](ConvertTo-ColorDWord $Hex -AABBGGRR)) -Type DWord -Force
    Set-ItemProperty -Path $accPath -Name StartColorMenu  -Value ([uint32](ConvertTo-ColorDWord $Hex -AABBGGRR)) -Type DWord -Force
    Set-ItemProperty -Path $accPath -Name AccentPalette   -Value ([byte[]](New-CWTAccentPalette $PaletteAlpha)) -Type Binary -Force
}

function Set-Personalize {
    param([int]$AppsLight, [int]$SystemLight, [int]$ColorPrevalence)
    $p = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Themes\Personalize'
    if (-not (Test-Path $p)) { New-Item -Force -Path $p | Out-Null }
    Set-ItemProperty -Path $p -Name AppsUseLightTheme    -Value $AppsLight      -Type DWord -Force
    Set-ItemProperty -Path $p -Name SystemUsesLightTheme -Value $SystemLight    -Type DWord -Force
    # Win10: "Show color on Start, taskbar, and action center"
    # Win11: "Show accent color on Start and taskbar"
    Set-ItemProperty -Path $p -Name ColorPrevalence      -Value $ColorPrevalence -Type DWord -Force
}

function Set-TransparencyEffects([int]$Value) {
    # 1 = frosted/translucent Start menu, taskbar, action center (Win10 & Win11)
    $p = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Themes\Personalize'
    if (-not (Test-Path $p)) { New-Item -Force -Path $p | Out-Null }
    Set-ItemProperty -Path $p -Name EnableTransparency -Value $Value -Type DWord -Force
}

function Set-TitleBarAccent([int]$Value) {
    # Win10: "Show color on title bars"; Win11: "Show accent color on title bars and window borders"
    $dwm = 'HKCU:\Software\Microsoft\Windows\DWM'
    if (-not (Test-Path $dwm)) { New-Item -Force -Path $dwm | Out-Null }
    Set-ItemProperty -Path $dwm -Name ColorPrevalence -Value $Value -Type DWord -Force
}

function Set-AutoColorization([int]$Value) {
    $desk = 'HKCU:\Control Panel\Desktop'
    if (-not (Test-Path $desk)) { New-Item -Force -Path $desk | Out-Null }
    Set-ItemProperty -Path $desk -Name AutoColorization -Value $Value -Type DWord -Force
}

function Set-TaskbarAcrylic([int]$Value) {
    # Windows 10 taskbar acrylic: 0 = fully transparent (no blur) ..
    # 80 = frosted blur, still translucent .. 255 = max blur / almost solid.
    # Windows 11 only: no-op (taskbar re-written; frosted via EnableTransparency).
    $adv = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced'
    if (-not (Test-Path $adv)) { New-Item -Force -Path $adv | Out-Null }
    Set-ItemProperty -Path $adv -Name TaskbarAcrylicOpacity -Value $Value -Type DWord -Force
}

<#
  Write "<PresetDisplayName>.theme" - a real, installable Windows theme file,
  in the same modern format Windows itself writes (see Custom.theme /
  aero.theme). The file is named after the active preset (e.g. "Ocean.theme").
  Places it in the user themes folder so it shows up in:
    * Settings > Personalization > Themes
    * our native listing ("themes" command)
  and can be double-clicked (or ShellExecute'd) to apply natively, or shared
  like any other .theme file.
  Note: .theme files cannot carry AccentPalette / StartColorMenu /
  EnableTransparency / TaskbarAcrylicOpacity - those stay registry-only and are
  still applied by the script's registry layer.
#>
function Write-CWTThemeFile {
    param(
        [string]$Name = $CWT_DisplayName,
        [string]$Wallpaper = '',
        [string]$OutputDir = $UserThemesDir
    )
    try {
        if (-not (Test-Path $OutputDir)) { New-Item -ItemType Directory -Force -Path $OutputDir | Out-Null }
        if (-not $Wallpaper) { $Wallpaper = Resolve-CWTWallpaper }
        if (-not $Wallpaper -or -not (Test-Path $Wallpaper)) {
            Write-Warn "No wallpaper available for the .theme file - skipping theme file."
            return $null
        }
        # Sanitize the display name once: it drives the file name, the
        # DisplayName= INI value and a comment line (a CR/LF there would forge
        # extra INI lines; path chars would escape the themes folder).
        $label = Format-CWTSafeLabel $Name
        if (-not $label) { $label = Format-CWTSafeLabel $CWT_PresetName }
        if (-not $label) {
            Write-Warn "Preset display name is empty after sanitizing - skipping theme file."
            return $null
        }
        $output = Join-Path $OutputDir "$label.theme"
        # AARRGGBB, same style Windows writes (0xC4 alpha byte + the preset accent)
        $colorHex = '0X{0:X8}' -f (ConvertTo-ColorDWord $CWT_Accent)
        $writeTime = [System.IO.File]::GetLastWriteTimeUtc($Wallpaper).ToFileTimeUtc()
        # SystemMode/AppMode must match what the registry apply writes -
        # same source, same mapping as Save-ThemeFile (1 = Light, 0 = Dark).
        $sysLight  = Get-CWTSystemLight
        $appsLight = Get-CWTAppLight
        $systemMode = if ($sysLight  -eq 1) { 'Light' } else { 'Dark' }
        $appMode    = if ($appsLight -eq 1) { 'Light' } else { 'Dark' }
        # Stable id derived from the preset KEY (not the display name): the
        # theme survives re-generation and each preset key gets its own id.
        # NOTE: the id cannot collide, but the FILE NAME can - the name is
        # built from the display name above, so two presets sharing a
        # displayName would overwrite each other's .theme file. The four
        # shipped presets have unique display names.
        $presetKey = [string]$CWT_PresetName
        if (-not $presetKey) { $presetKey = $label }
        $md5 = [System.Security.Cryptography.MD5]::Create()
        try { $idBytes = $md5.ComputeHash([System.Text.Encoding]::UTF8.GetBytes("custom-windows-themer:$presetKey")) }
        finally { $md5.Dispose() }
        $themeId = ([guid]$idBytes).ToString().ToUpper()
        $content = @(
            "; $label theme - generated by custom-windows-themer.ps1"
            ''
            '[Theme]'
            "DisplayName=$label"
            '; stable id so the theme survives re-generation'
            "ThemeId={$themeId}"
            ''
            '[Control Panel\Desktop]'
            "Wallpaper=$Wallpaper"
            'Pattern='
            'MultimonBackgrounds=0'
            'PicturePosition=4'
            "WallpaperWriteTime=$writeTime"
            ''
            '[VisualStyles]'
            'Path=%SystemRoot%\resources\Themes\Aero\Aero.msstyles'
            'ColorStyle=NormalColor'
            'Size=NormalSize'
            'AutoColorization=0'
            "ColorizationColor=$colorHex"
            "SystemMode=$systemMode"
            "AppMode=$appMode"
            'VisualStyleVersion=10'
            ''
            '[boot]'
            'SCRNSAVE.EXE='
            ''
            '[MasterThemeSelector]'
            'MTSM=RJSPBS'
        )
        # Windows themes are UTF-16 LE
        $content | Set-Content -Path $output -Encoding Unicode
        Write-Ok "Written Windows theme file: $output"
        return $output
    } catch {
        Write-Warn "Could not write theme file: $_"
        return $null
    }
}

# ----------------------------------------------------------------------------
# Shell refresh - layered and SAFE. The old code force-killed explorer and then
# trusted Winlogon to bring it back; when the shell crashed after restart (a
# recurring explorer.exe 0xc0000005 bug on some machines) Winlogon can refuse /
# throttle the restart, leaving the desktop dead while the script prints "Done".
# New rules:
#   1. Try a live, NON-destructive refresh first (the shell and DWM pick up most
#      accent / palette / transparency changes without a restart).
#   2. Restart ONLY the Start-menu host process (it respawns by itself) to
#      repaint the Start palette.
#   3. If a real explorer restart is still needed, do it with a GUARANTEE:
#      verify stability (not mere presence), retry, and never return with the
#      shell dead.
#   4. A short background watchdog heals the desktop even if explorer crashes
#      in the minutes after we finish (the "done but dead" failure window).
# ----------------------------------------------------------------------------

<#
  Broadcast "per-user system parameters changed" so DWM and the shell re-read the
  Personalize / DWM / Accent keys live. This is the refresh Windows Settings
  performs for most colour / accent / transparency toggles and does NOT kill
  explorer.
#>
function Update-PerUserSettings {
    try {
        Step "Update-PerUserSettings: broadcasting live settings refresh"
        $r = Start-Process (Join-Path $env:SystemRoot 'System32\rundll32.exe') `
                -ArgumentList 'user32.dll,UpdatePerUserSystemParameters' `
                -WindowStyle Hidden -PassThru
        try { $r.WaitForExit(5000) | Out-Null } catch { }
    } catch {
        Step "Update-PerUserSettings skipped: $($_.Exception.Message)"
    }
}

<#
  The Start menu caches its accent palette inside StartMenuExperienceHost.exe.
  Restarting just that host (it respawns automatically on demand) repaints the
  Start menu with the new palette while explorer.exe stays up - a far narrower
  blast radius than a full shell restart.
#>
function Restart-StartMenuHost {
    try {
        $hosts = Get-Process StartMenuExperienceHost -ErrorAction SilentlyContinue
        if ($hosts) {
            Write-Info "Repainting Start menu (restarting its host process - explorer stays up)..."
            $hosts | Stop-Process -Force -ErrorAction SilentlyContinue
            Step "Restart-StartMenuHost: restarted Start menu host PID $($hosts.Id -join ',')"
        }
    } catch {
        Step "Restart-StartMenuHost skipped: $($_.Exception.Message)"
    }
}

function Test-ExplorerRunning {
    return [bool](Get-Process explorer -ErrorAction SilentlyContinue)
}

<#
  Wait for explorer to be present AND STAY alive for the stability window.
  Mere presence is not enough - the old code declared "ok" the moment an
  instance appeared, then the shell died minutes later.
#>
function Wait-ExplorerStable {
    param([int]$TimeoutSeconds = 15, [int]$StableSeconds = 3)
    $deadline = (Get-Date).AddSeconds($TimeoutSeconds)
    while ((Get-Date) -lt $deadline) {
        Start-Sleep -Milliseconds 500
        if (Test-ExplorerRunning) {
            Start-Sleep -Seconds $StableSeconds
            return (Test-ExplorerRunning)
        }
    }
    return $false
}

<#
  Bulletproof explorer restart. Returns $true only when explorer is running and
  stable afterwards; never returns having left the shell dead if the OS will
  still start it. Handles:
    * Winlogon not restarting the shell (throttled / refused after crashes)
    * explorer crashing again during the restart window (crash-loop)
    * double-instance races (we only start explorer when no instance exists)
#>
function Restart-ExplorerSafe {
    $TimeoutSeconds = 20
    $MaxAttempts     = 3
    $StableSeconds   = 3

    # Serialize restarts: stop any watchdog left over from a previous run so we
    # (and Windows) are the only ones who can spawn the shell right now.
    Stop-ExplorerWatchdog

    Write-Info "Restarting explorer so the new colours take effect..."
    $existing = Get-Process explorer -ErrorAction SilentlyContinue
    if ($existing) {
        Step "Restart-ExplorerSafe: stopping explorer PID $($existing.Id -join ',')"
        $existing | Stop-Process -Force -ErrorAction SilentlyContinue
    }

    for ($attempt = 1; $attempt -le $MaxAttempts; $attempt++) {
        Step "Restart-ExplorerSafe: attempt $attempt - waiting for a stable explorer"
        # Let Winlogon try first: it owns the correct session / user context.
        $deadline = (Get-Date).AddSeconds($TimeoutSeconds)
        while ((Get-Date) -lt $deadline -and -not (Test-ExplorerRunning)) {
            Start-Sleep -Milliseconds 500
        }
        # Stability check - the guarantee the old code never made.
        if (Wait-ExplorerStable 3 $StableSeconds) {
            Step "Restart-ExplorerSafe: explorer stable after attempt $attempt"
            Write-Ok "Explorer restarted and stable."
            return $true
        }
        # Winlogon did not (or could not) bring it back - start it directly in
        # the interactive session. Safe here: no instance exists right now.
        if ($attempt -lt $MaxAttempts) {
            Write-Warn "Explorer is not coming back by itself - starting it directly (attempt $attempt/$MaxAttempts)."
        } else {
            Write-Warn "Explorer is not coming back - final start attempt."
        }
        try {
            Start-Process explorer.exe | Out-Null
        } catch {
            Step "Restart-ExplorerSafe: start failed: $($_.Exception.Message)"
        }
    }

    if (Test-ExplorerRunning) {
        Step "Restart-ExplorerSafe: explorer is running after manual start"
        Write-Ok "Explorer started."
        return $true
    }
    Write-Warn "Could not start Explorer. Start it manually with: Start-Process explorer.exe  (or log off/on)"
    Step "Restart-ExplorerSafe: FAILED - explorer not running"
    return $false
}

$WatchdogScript = Join-Path $StateDir 'explorer-watchdog.ps1'

<#
  Detached, one-shot background safety net. If explorer dies in the minutes
  after we finish (e.g. a shell crash bug or Winlogon throttle), starting it
  again. Does nothing while explorer is up; exits after $Seconds.
#>
function Start-ExplorerWatchdog {
    param([int]$Seconds = 180)
    try {
        Remove-Item $WatchdogScript -Force -ErrorAction SilentlyContinue
        $content = @'
param([int]$Seconds)
$deadline = (Get-Date).AddSeconds($Seconds)
$missing = 0
while ((Get-Date) -lt $deadline) {
    Start-Sleep -Seconds 10
    if (Get-Process explorer -ErrorAction SilentlyContinue) { $missing = 0 }
    else { $missing++ }
    if ($missing -ge 2) {
        $missing = 0
        try { Start-Process explorer.exe -ErrorAction Stop | Out-Null } catch { }
    }
}
'@
        Set-Content -Path $WatchdogScript -Value $content -Encoding ASCII
        Start-Process powershell.exe -ArgumentList @(
            '-NoProfile', '-WindowStyle', 'Hidden',
            '-File', "`"$WatchdogScript`"", $Seconds
        ) -WindowStyle Hidden | Out-Null
        Step "Start-ExplorerWatchdog: watching for $Seconds seconds"
    } catch {
        Step "Start-ExplorerWatchdog skipped: $($_.Exception.Message)"
    }
}

<#
  Kill any watchdog still watching from a previous run. Back-to-back apply/restore
  must NEVER have two watchdogs alive: they could each start explorer and race
  Windows' own restart into a two-instance shell. One watchdog, always the newest.
#>
function Stop-ExplorerWatchdog {
    try {
        Get-CimInstance Win32_Process -Filter "Name = 'powershell.exe'" -ErrorAction SilentlyContinue |
            Where-Object { $_.CommandLine -like '*explorer-watchdog.ps1*' } |
            ForEach-Object {
                Step "Stop-ExplorerWatchdog: stopping old watchdog PID $($_.ProcessId)"
                Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue
            }
    } catch {
        Step "Stop-ExplorerWatchdog skipped: $($_.Exception.Message)"
    }
}

function Refresh-Shell {
    # Apply the theme LIVE and never touch explorer. Measured on this machine
    # (Win10 21H2): the theme values do NOT crash explorer - pid stayed stable
    # for 5 minutes. It is the kill + restart cycle that triggers a recurring
    # explorer.exe access violation (fault offset 0x458aa), leaving the desktop
    # dead. So apply/restore NO LONGER restart the shell:
    #   Layer 1: broadcast "per-user system parameters changed" - DWM and the
    #            shell re-read accent / palette / transparency / wallpaper live.
    #   Layer 2: repaint the Start menu palette via its host process only.
    #   Layer 3: short background watchdog as insurance against unrelated crashes.
    # Users who specifically want the shell restarted can run 'restart-shell'.
    Update-PerUserSettings
    Restart-StartMenuHost
    Start-ExplorerWatchdog 90
}

# ----------------------------------------------------------------------------
# Windows Terminal theming
# ----------------------------------------------------------------------------
function Get-WTSettingsPath {
    $candidates = @(
        (Join-Path $env:LOCALAPPDATA 'Packages\Microsoft.WindowsTerminal_8wekyb3d8bbwe\LocalState\settings.json')
        (Join-Path $env:LOCALAPPDATA 'Packages\Microsoft.WindowsTerminalPreview_8wekyb3d8bbwe\LocalState\settings.json')
        (Join-Path $env:LOCALAPPDATA 'Microsoft\Windows Terminal\settings.json')
    )
    foreach ($p in $candidates) { if (Test-Path $p) { return $p } }
    return $null
}

<#
  ConvertFrom-Json that also understands JSONC (// and /* */ comments), which is
  what Windows Terminal's settings.json ships with by default. A standard
  ConvertFrom-Json would throw on the comments and kill the whole apply flow.
#>
function ConvertFrom-JsonC {
    param([string]$JsonText)
    $sb = New-Object System.Text.StringBuilder
    $len = $JsonText.Length
    $i = 0
    $inString = $false
    $q = [char]0
    $escape = $false
    while ($i -lt $len) {
        $c = $JsonText[$i]
        if ($inString) {
            $sb.Append($c) | Out-Null
            if ($escape) { $escape = $false }
            elseif ($c -eq '\') { $escape = $true }
            elseif ($c -eq $q) { $inString = $false }
            $i++
        } else {
            if ($c -eq '"' -or $c -eq "'") {
                $inString = $true; $q = $c
                $sb.Append($c) | Out-Null; $i++
            }
            elseif ($c -eq '/' -and ($i + 1) -lt $len -and $JsonText[$i + 1] -eq '/') {
                while ($i -lt $len -and $JsonText[$i] -ne "`n") { $i++ }
                $sb.Append("`n") | Out-Null; $i++
            }
            elseif ($c -eq '/' -and ($i + 1) -lt $len -and $JsonText[$i + 1] -eq '*') {
                $i += 2
                while ($i -lt $len -and -not ($JsonText[$i] -eq '*' -and ($i + 1) -lt $len -and $JsonText[$i + 1] -eq '/')) { $i++ }
                if ($i -lt $len) { $i += 2 }
            }
            else {
                $sb.Append($c) | Out-Null; $i++
            }
        }
    }
    return ($sb.ToString() | ConvertFrom-Json)
}

function Get-CWTScheme {
    # The terminal color scheme comes from the loaded preset's "terminal"
    # object: all 16 ANSI slots (color0..15 -> black..brightWhite) plus
    # foreground/background/cursorColor/selectionBackground. The scheme's name
    # is the preset's display name, prefixed with $TerminalSchemePrefix so
    # Apply-TerminalTheme can find and remove every scheme it ever created.
    # NOTE: transparency (useAcrylic/opacity) is a PROFILE setting, not a scheme
    # setting - it is applied in Set-ProfileScheme below.
    $t = $CWT_Terminal
    return [ordered]@{
        name                = "$($TerminalSchemePrefix)$($CWT_DisplayName)"
        foreground          = [string]$t.foreground
        background          = [string]$t.background
        cursorColor         = [string]$t.cursorColor
        selectionBackground = [string]$t.selectionBackground
        black               = [string]$t.black          # color0
        red                 = [string]$t.red            # color1
        green               = [string]$t.green          # color2
        yellow              = [string]$t.yellow         # color3
        blue                = [string]$t.blue           # color4
        purple              = [string]$t.purple         # color5
        cyan                = [string]$t.cyan           # color6
        white               = [string]$t.white          # color7
        brightBlack         = [string]$t.brightBlack    # color8
        brightRed           = [string]$t.brightRed      # color9
        brightGreen         = [string]$t.brightGreen    # color10
        brightYellow        = [string]$t.brightYellow   # color11
        brightBlue          = [string]$t.brightBlue     # color12
        brightPurple        = [string]$t.brightPurple   # color13
        brightCyan          = [string]$t.brightCyan     # color14
        brightWhite         = [string]$t.brightWhite    # color15
    }
}

function Apply-TerminalTheme {
    $wt = Get-WTSettingsPath
    if (-not $wt) {
        Write-Warn "Windows Terminal not found - skipping terminal scheme (install it from the Store to use the '$($TerminalSchemePrefix)$($CWT_DisplayName)' scheme)."
        return
    }
    try {
        $raw  = Get-Content $wt -Raw -Encoding UTF8
        $json = ConvertFrom-JsonC $raw
    } catch {
        Write-Warn "Could not parse Windows Terminal settings ($_). Skipping terminal theme."
        return
    }

    $scheme = Get-CWTScheme
    if (-not $json.PSObject.Properties['schemes']) { $json | Add-Member -MemberType NoteProperty -Name schemes -Value @() }
    # Remove EVERY scheme this script ever generated (all of them carry
    # $TerminalSchemePrefix) before adding the current one - otherwise
    # rotating presets orphans stale schemes in settings.json forever.
    $json.schemes = @($json.schemes | Where-Object {
        $n = "$($_.name)"
        -not $n.StartsWith($TerminalSchemePrefix)
    })
    $json.schemes += [pscustomobject]$scheme

    # point EVERY profile at the new scheme + acrylic transparency
    $profiles = $json.profiles
    if ($null -eq $profiles) {
        # settings.json without a "profiles" section at all
        $json | Add-Member -MemberType NoteProperty -Name profiles -Value ([pscustomobject]([ordered]@{
            defaults = [pscustomobject]([ordered]@{})
            list     = @()
        })) -Force
        $profiles = $json.profiles
    }

    # useAcrylic + opacity (0-100) is the current API (1.12+). acrylicOpacity is
    # deprecated. The acrylic blur also needs Windows "Transparency effects" on,
    # which the theme enables via EnableTransparency.
    function Set-ProfileScheme($p) {
        $p | Add-Member -MemberType NoteProperty -Name colorScheme -Value $scheme.name -Force
        $p | Add-Member -MemberType NoteProperty -Name useAcrylic -Value $true -Force
        $p | Add-Member -MemberType NoteProperty -Name opacity -Value 65 -Force
    }

    if ($profiles -is [System.Array]) {
        # legacy format: profiles is a flat array
        foreach ($p in $profiles) { Set-ProfileScheme $p }
    } else {
        # modern format: profiles.{list,defaults}
        if ($profiles.PSObject.Properties['defaults']) { Set-ProfileScheme $profiles.defaults }
        else {
            $profiles | Add-Member -MemberType NoteProperty -Name defaults -Value ([pscustomobject]([ordered]@{})) -Force
            Set-ProfileScheme $profiles.defaults
        }
        if ($profiles.PSObject.Properties['list']) {
            foreach ($p in $profiles.list) { Set-ProfileScheme $p }
        }
    }

    $json | ConvertTo-Json -Depth 100 | Set-Content $wt -Encoding UTF8
    Write-Ok "Windows Terminal: applied '$($scheme.name)' scheme to all profiles (acrylic 65%)."
}

function Restore-TerminalBackup($SettingsPath, $BackupPath) {
    if (-not $SettingsPath -or -not $BackupPath) { return }
    if (-not (Test-Path $BackupPath)) { Write-Warn "Terminal backup missing - leaving current settings as-is."; return }
    Copy-Item $BackupPath $SettingsPath -Force
    Write-Ok "Windows Terminal: restored your previous settings."
}

# ----------------------------------------------------------------------------
# Save / Apply / Restore
# ----------------------------------------------------------------------------
function Get-RegDWord($Path, $Name) {
    $v = Get-ItemProperty $Path -Name $Name -ErrorAction SilentlyContinue
    if ($null -ne $v) { return [uint32]$v.$Name } else { return $null }
}
function Get-RegString($Path, $Name) {
    $v = Get-ItemProperty $Path -Name $Name -ErrorAction SilentlyContinue
    if ($null -ne $v) { return $v.$Name } else { return $null }
}

function Save-CurrentTheme {
    if (Test-Path $SavedThemePath) { Step "Save-CurrentTheme: already saved, skip"; return }

    $desk = 'HKCU:\Control Panel\Desktop'
    $dwm  = 'HKCU:\Software\Microsoft\Windows\DWM'
    $acc  = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\Accent'
    $per  = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Themes\Personalize'
    $adv  = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced'

    $wt = Get-WTSettingsPath
    if ($wt) { Copy-Item $wt $TerminalBackup -Force }

    $perProps  = Get-ItemProperty $per -ErrorAction SilentlyContinue
    $appsLight = $perProps.AppsUseLightTheme
    $sysLight  = $perProps.SystemUsesLightTheme
    $colorPrev = $perProps.ColorPrevalence
    $transp    = $perProps.EnableTransparency

    # Start menu accent lives in the 32-byte AccentPalette (BGRA) - save it verbatim.
    $palette = (Get-ItemProperty $acc -Name AccentPalette -ErrorAction SilentlyContinue).AccentPalette

    $saved = [ordered]@{
        wallpaper              = Get-RegString  $desk 'Wallpaper'
        wallpaperStyle        = Get-RegString  $desk 'WallpaperStyle'
        tileWallpaper         = Get-RegString  $desk 'TileWallpaper'
        autoColorization      = Get-RegDWord   $desk 'AutoColorization'
        colorizationColor     = Get-RegDWord   $dwm  'ColorizationColor'
        accentColorMenu       = Get-RegDWord   $acc  'AccentColorMenu'
        startColorMenu        = Get-RegDWord   $acc  'StartColorMenu'
        accentPaletteB64      = if ($palette) { [Convert]::ToBase64String([byte[]]$palette) } else { $null }
        appsUseLightTheme     = if ($null -ne $appsLight) { [int]$appsLight } else { 1 }
        systemUsesLightTheme  = if ($null -ne $sysLight)  { [int]$sysLight }  else { 1 }
        colorPrevalence       = if ($null -ne $colorPrev) { [int]$colorPrev } else { 0 }
        enableTransparency    = if ($null -ne $transp)    { [int]$transp }    else { $null }
        dwmColorPrevalence    = Get-RegDWord   $dwm  'ColorPrevalence'
        taskbarAcrylicOpacity = Get-RegDWord   $adv  'TaskbarAcrylicOpacity'
        hasTerminalBackup     = if ($wt) { $true } else { $false }
        terminalSettingsPath  = $wt
    }
    $saved | ConvertTo-Json -Depth 10 | Set-Content $SavedThemePath -Encoding UTF8
    Step "Save-CurrentTheme: wrote $SavedThemePath"
    Write-Ok "Saved your current theme to: $SavedThemePath"
}

function Apply-CustomTheme {
    Step "Apply-CustomTheme: start"
    Write-Accent "Applying the '$($CWT_DisplayName)' preset..."
    # 1. Wallpaper (Fill style): the preset's wallpaper file when it exists,
    #    otherwise the generated gradient. Resolve-CWTWallpaper returns $null
    #    when neither is available - skip, never throw.
    $wallpaper = Resolve-CWTWallpaper
    if ($wallpaper) {
        Set-WallpaperStyle '10'
        Set-Wallpaper $wallpaper
        Step "Apply-CustomTheme: wallpaper set"
        Write-Ok "Wallpaper set to $wallpaper (Fill)."
    } else {
        Write-Warn "No wallpaper available - skipping wallpaper."
    }
    # 2. Accent everywhere: taskbar, Start menu (incl. its AccentPalette),
    #    title bars + light mode + frosted/translucent surfaces
    Set-AccentColor $CWT_Accent
    Step "Apply-CustomTheme: accent set"
    Write-Ok "Accent color set to $CWT_Accent (taskbar + Start menu + palette)."
    Set-AutoColorization 0
    Step "Apply-CustomTheme: auto-colorization off"
    Write-Ok "Disabled 'auto accent from background' so the accent sticks."
    # App/system mode comes from the preset, with Light as the fallback on both
    # OSes (ColorPrevalence stays 0, so no accent paints on the taskbar either way).
    $appsLight = Get-CWTAppLight
    $systemLight = Get-CWTSystemLight
    Set-Personalize -AppsLight $appsLight -SystemLight $systemLight -ColorPrevalence 0
    Step "Apply-CustomTheme: personalize set"
    Write-Ok "Mode set: apps Light=$appsLight, system Light=$systemLight. Accent on Start/taskbar disabled (ColorPrevalence=0)."
    Set-TitleBarAccent 1
    Write-Ok "Accent on title bars / window borders enabled."
    Set-TransparencyEffects 1
    Step "Apply-CustomTheme: transparency set"
    Write-Ok "Transparency effects ON - Start menu is frosted, not opaque."
    Set-TaskbarAcrylic $CWT_TaskbarAcrylic
    Step "Apply-CustomTheme: taskbar acrylic set"
    Write-Ok "Taskbar set to frosted acrylic ($CWT_TaskbarAcrylic/255 blur)."
    # 3. Windows Terminal (colors + acrylic)
    Apply-TerminalTheme
    # 4. Windows-visible theme file (Settings > Themes / native listing)
    $themeFile = Write-CWTThemeFile
    if ($themeFile) {
        Write-Info "  (apply it natively anytime with: custom-windows-themer.ps1 theme-file)`n" 
    }
    # 5. Refresh shell
    Refresh-Shell
    Step "Apply-CustomTheme: shell refreshed"
    # Persist mode + preset so 'toggle' reapplies the same preset later.
    Set-Content -Path $StatePath -Value ([ordered]@{ mode = 'custom'; preset = $CWT_PresetName } | ConvertTo-Json -Depth 5)
    Write-Accent "Done! Your desktop now uses the '$($CWT_DisplayName)' preset. (run 'restore' or 'toggle' to go back)"
}

function Set-RegValue($Path, $Name, $Value, [switch]$DWord) {
    if (-not (Test-Path $Path)) { New-Item -Force -Path $Path | Out-Null }
    if ($null -ne $Value) {
        if ($DWord) { Set-ItemProperty -Path $Path -Name $Name -Value ([uint32]$Value) -Type DWord -Force }
        else        { Set-ItemProperty -Path $Path -Name $Name -Value $Value -Force }
    } else {
        Remove-ItemProperty -Path $Path -Name $Name -ErrorAction SilentlyContinue
    }
}

function Restore-Saved {
    if (-not (Test-Path $SavedThemePath)) {
        Write-Warn "No saved theme found. Run 'apply' first so we can remember your settings."
        return
    }
    Step "Restore-Saved: start"
    Write-Accent "Restoring your saved theme..."
    $s = Get-Content $SavedThemePath -Raw -Encoding UTF8 | ConvertFrom-Json

    $desk = 'HKCU:\Control Panel\Desktop'
    $dwm  = 'HKCU:\Software\Microsoft\Windows\DWM'
    $acc  = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\Accent'
    $per  = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Themes\Personalize'
    $adv  = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced'

    if ($s.wallpaper) { Set-WallpaperStyle '10'; Set-Wallpaper $s.wallpaper; Write-Ok "Wallpaper restored." }
    Set-RegValue $desk 'WallpaperStyle'   $s.wallpaperStyle   # string
    Set-RegValue $desk 'TileWallpaper'    $s.tileWallpaper    # string
    Set-RegValue $desk 'AutoColorization' $s.autoColorization -DWord
    Set-RegValue $dwm  'ColorizationColor' $s.colorizationColor -DWord
    Set-RegValue $acc  'AccentColorMenu'   $s.accentColorMenu   -DWord
    Set-RegValue $acc  'StartColorMenu'    $s.startColorMenu    -DWord
    if ($s.accentPaletteB64) {
        Set-ItemProperty -Path $acc -Name AccentPalette -Value ([byte[]][Convert]::FromBase64String($s.accentPaletteB64)) -Type Binary -Force
    }
    Write-Ok "Accent color restored (incl. Start menu palette)."
    Set-Personalize -AppsLight ([int]$s.appsUseLightTheme) -SystemLight ([int]$s.systemUsesLightTheme) -ColorPrevalence ([int]$s.colorPrevalence)
    if ($null -ne $s.enableTransparency) { Set-TransparencyEffects ([int]$s.enableTransparency) }
    if ($null -ne $s.dwmColorPrevalence) { Set-TitleBarAccent ([int]$s.dwmColorPrevalence) }
    Write-Ok "Light/dark mode + transparency restored."
    Set-RegValue $adv 'TaskbarAcrylicOpacity' $s.taskbarAcrylicOpacity -DWord
    Write-Ok "Taskbar acrylic restored."
    Restore-TerminalBackup $s.terminalSettingsPath $TerminalBackup
    Refresh-Shell
    Step "Restore-Saved: shell refreshed"
    # Keep the preset selection so the next 'apply'/'toggle' uses the same one.
    Set-Content -Path $StatePath -Value ([ordered]@{ mode = 'saved'; preset = $CWT_PresetName } | ConvertTo-Json -Depth 5)
    Write-Accent "Done! Your original theme is back."
}

<#
  Resolve the wallpaper that 'apply' should use:
    1. The preset's "wallpaper" entry - an absolute path, or a path relative
       to the repo root. Used when the file exists.
    2. Otherwise generate a 3840x2160 PNG: a linear gradient from a light tint
       of the accent to the accent color, written to the state dir.
  Returns $null when no wallpaper is available (for example when
  System.Drawing cannot be loaded) - callers skip the wallpaper then, they
  never throw. No image ships with this repo and nothing is downloaded.
#>
function Resolve-CWTWallpaper {
    # 1. Preset-provided wallpaper file.
    if ($CWT_Wallpaper) {
        $w = [string]$CWT_Wallpaper
        try {
            if (-not [System.IO.Path]::IsPathRooted($w)) { $w = Join-Path $ScriptDir $w }
            if (Test-Path -LiteralPath $w) { return (Resolve-Path -LiteralPath $w).Path }
            Write-Warn "Preset wallpaper not found: $CWT_Wallpaper - generating a gradient instead."
        } catch {
            Write-Warn "Could not resolve preset wallpaper '$CWT_Wallpaper': $($_.Exception.Message)"
        }
    }

    # 2. Generated gradient (light tint of the accent -> the accent).
    $out = Join-Path $StateDir 'wallpaper.png'
    $bmp = $null
    try {
        Add-Type -AssemblyName System.Drawing -ErrorAction Stop
        $width = 3840
        $height = 2160
        $from = ConvertTo-DrawColor $CWT_AccentLight
        $to = ConvertTo-DrawColor $CWT_Accent
        $bmp = New-Object System.Drawing.Bitmap -ArgumentList $width, $height
        $g = [System.Drawing.Graphics]::FromImage($bmp)
        try {
            $rect = New-Object System.Drawing.Rectangle -ArgumentList 0, 0, $width, $height
            $brush = New-Object System.Drawing.Drawing2D.LinearGradientBrush -ArgumentList $rect, $from, $to, ([System.Drawing.Drawing2D.LinearGradientMode]::ForwardDiagonal)
            try {
                $g.FillRectangle($brush, 0, 0, $width, $height)
            } finally {
                $brush.Dispose()
            }
        } finally {
            $g.Dispose()
        }
    } catch {
        # Loading / drawing failed: System.Drawing is not available here.
        if ($bmp) { try { $bmp.Dispose() } catch { } }
        $bmp = $null
        Write-Warn "System.Drawing unavailable - wallpaper skipped ($($_.Exception.Message))."
        return $null
    }
    # Save ATOMICALLY: write to a temp file in the SAME directory, then move it
    # over the target, so an interrupted run cannot leave a truncated PNG.
    $tmp = "$out.$([guid]::NewGuid().ToString('N')).tmp"
    try {
        $bmp.Save($tmp, [System.Drawing.Imaging.ImageFormat]::Png)
        Move-Item -LiteralPath $tmp -Destination $out -Force
    } catch {
        # A different failure than the load/draw step above: the image exists
        # but could not be written (unwritable state dir, disk full, ...).
        Remove-Item -LiteralPath $tmp -ErrorAction SilentlyContinue
        Write-Warn "Could not save generated wallpaper to '$out' ($($_.Exception.Message))."
        return $null
    } finally {
        if ($bmp) { try { $bmp.Dispose() } catch { } }
    }
    Step "Resolve-CWTWallpaper: generated $out"
    return $out
}

function Show-Presets {
    Write-Accent "Available presets ($PresetsDir)"
    $files = @(Get-ChildItem -Path $PresetsDir -Filter '*.json' -File -ErrorAction SilentlyContinue | Sort-Object Name)
    if (-not $files.Count) {
        Write-Warn "No preset files found in $PresetsDir."
        return
    }
    foreach ($f in $files) {
        $p = $null
        try { $p = Get-Content $f.FullName -Raw -Encoding UTF8 | ConvertFrom-Json } catch {
            Write-Warn "$($f.Name): invalid JSON ($($_.Exception.Message))"
            continue
        }
        $name = if ($p.PSObject.Properties['displayName'] -and $p.displayName) { [string]$p.displayName } else { $f.BaseName }
        $desc = if ($p.PSObject.Properties['description'] -and $p.description) { [string]$p.description } else { '' }
        $accent = if ($p.PSObject.Properties['accent'] -and $p.accent) { [string]$p.accent } else { '?' }
        $marker = if ($f.BaseName -eq $CWT_PresetName) { '  <- active' } else { '' }
        Write-Info ("{0,-10} {1,-10} accent {2}  {3}{4}" -f $f.BaseName, $name, $accent, $desc, $marker)
    }
    Write-Info "Apply one with: custom-windows-themer.ps1 apply <name>"
}

function Show-Status {
    $mode = if (Test-Path $StatePath) { (Get-Content $StatePath -Raw | ConvertFrom-Json).mode } else { 'unknown' }
    Write-Accent "Custom Windows Themer"
    Write-Info "Current mode : $mode"
    Write-Info "Active preset: $($CWT_DisplayName) ($($CWT_PresetName)) - accent $($CWT_Accent)"
    Write-Info "Saved theme  : $(if (Test-Path $SavedThemePath) { 'yes' } else { 'none (will be saved on first apply)' })"
    $wt = Get-WTSettingsPath
    Write-Info "Terminal     : $(if ($wt) { 'found' } else { 'not installed' })"
    $per = Get-ItemProperty 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Themes\Personalize' -ErrorAction SilentlyContinue
    if ($per) {
        Write-Info "Light apps   : $($per.AppsUseLightTheme)   Light system: $($per.SystemUsesLightTheme)   AccentOnBar: $($per.ColorPrevalence)   Transparency: $($per.EnableTransparency)"
    } else {
        Write-Info "Personalize  : (registry key missing - nothing applied yet)"
    }
    $accent = Get-RegDWord 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\Accent' 'AccentColorMenu'
    if ($null -ne $accent) {
        $expected = ConvertTo-ColorDWord $CWT_Accent -AABBGGRR
        Write-Info "Accent menu  : 0x$('{0:X8}' -f $accent) (preset expects 0x$('{0:X8}' -f $expected))"
    }
}

# ----------------------------------------------------------------------------
# Main dispatch
# ----------------------------------------------------------------------------
try {
    switch ($Command) {
        'presets' { Show-Presets }
        'install' {
            # No downloads: resolve the preset wallpaper or generate the gradient.
            $wp = Resolve-CWTWallpaper
            if ($wp) { Write-Ok "Wallpaper ready: $wp" }
            else { Write-Warn "No wallpaper could be generated." }
        }
        'apply'  { Save-CurrentTheme; Apply-CustomTheme }
        'on'     { Save-CurrentTheme; Apply-CustomTheme }
        'restore'{ Restore-Saved }
        'off'    { Restore-Saved }
        'status' { Show-Status }
        'themes' { Show-NativeThemes }
        'theme-save' { Save-ThemeFile $ThemeArg }
        'savetheme'  { Save-ThemeFile $ThemeArg }
        'theme-restore' { Restore-ThemeFile $ThemeArg }
        'theme-switch'  { Switch-NativeTheme $ThemeArg }
        'restart-shell' {
            # Explicitly opted-in full shell restart with the guaranteed recovery
            # path. apply/restore do NOT restart explorer anymore (see Refresh-Shell).
            Restart-ExplorerSafe
            Start-ExplorerWatchdog 180
        }
        'theme-file' {
            # (Re)generate the installable "<PresetDisplayName>.theme" and
            # optionally apply it through Windows' own shell handling (same as
            # double-clicking).
            $themeFile = Write-CWTThemeFile
            if ($themeFile) {
                Write-Info "This theme file is now installed in Settings > Personalization > Themes"
                Write-Info "and listed by the 'themes' command."
                if ($ThemeArg -eq 'apply') {
                    Write-Info "Applying it via the shell (same as double-clicking a .theme)..."
                    Start-Process $themeFile | Out-Null
                    Write-Ok "Applied: $themeFile (accent palette etc. are normalized by the next 'apply' run)"
                } else {
                    Write-Info "To apply it natively, double-click it or run: custom-windows-themer.ps1 theme-file apply"
                }
            } else {
                Write-Warn "FAILED: no .theme file was written (see the warnings above for the reason)."
            }
        }
        'taskbar-acrylic' {
            # Live-tune the taskbar frosting (Windows 10).
            if ($ThemeArg -notmatch '^\d+$' -or [int]$ThemeArg -gt 255) {
                Write-Warn "Usage: custom-windows-themer.ps1 taskbar-acrylic <0-255>  (0 = fully transparent .. 255 = max blur)"
                return
            }
            Set-TaskbarAcrylic ([int]$ThemeArg)
            Write-Ok "Taskbar acrylic set to $ThemeArg (0 = transparent .. 255 = max blur)."
            Refresh-Shell
        }
        'start-acrylic' {
            # Live-tune Start menu / action centre transparency (accent palette alpha).
            if ($ThemeArg -notmatch '^\d+$' -or [int]$ThemeArg -gt 255) {
                Write-Warn "Usage: custom-windows-themer.ps1 start-acrylic <0-255>  (0 = fully transparent .. 255 = solid color)"
                return
            }
            Set-AccentColor $CWT_Accent -PaletteAlpha ([int]$ThemeArg)
            Write-Ok "Start menu / accent palette opacity set to $ThemeArg (0 = transparent .. 255 = solid)."
            Refresh-Shell
        }
        'toggle' {
            # The preset was selected at startup (state.json's "preset", or the
            # argument of a previous 'apply <name>'), so both sides use it.
            $mode = if (Test-Path $StatePath) { (Get-Content $StatePath -Raw | ConvertFrom-Json).mode } else { 'saved' }
            if ($mode -eq 'custom') { Restore-Saved } else { Save-CurrentTheme; Apply-CustomTheme }
        }
    }
} catch {
    Write-Host ""
    Write-Host "Something went wrong:" -ForegroundColor Red
    Write-Host "  $_" -ForegroundColor Red
    Write-Host "  (full trace in: $LogFile)" -ForegroundColor Gray
    exit 1
}
