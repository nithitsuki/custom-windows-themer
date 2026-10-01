# custom-windows-themer

A PowerShell tool that applies a color preset to Windows 10 and Windows 11.
It needs no dependencies and no Administrator rights. Every change is per-user
(`HKCU` / `%LOCALAPPDATA%`).

The preset files in `presets/` are the only source of color. The script reads
them at start and applies the colors they define. No color value lives in the
script itself.

## Presets

| Preset     | Accent   | Description                            |
|------------|----------|----------------------------------------|
| `rose`     | `#FF2E6D`| Soft rose accent on a light palette. Default preset. |
| `ocean`    | `#2196F3`| Blue accent on a light palette.        |
| `forest`   | `#2F9E44`| Green accent on a light palette.       |
| `graphite` | `#7C8AA0`| Neutral gray accent on a light palette.|

```powershell
.\custom-windows-themer.ps1 presets          # list the presets
.\custom-windows-themer.ps1 apply ocean      # select and apply a preset
.\custom-windows-themer.ps1 apply            # apply the last selected preset
```

`apply <name>` selects a preset. Without a name, `apply` uses the preset saved
in `state.json`. When no preset was ever selected, it uses `rose`. The script
saves your current theme before the first apply.

A preset file defines the accent, the light/dark modes, the Start menu palette,
the taskbar frosting, the wallpaper and the Windows Terminal scheme. Set
`systemLight` or `appLight` to `null` in a preset to use the default. The
default is light for the system and light for the apps. The script always writes
`ColorPrevalence=0`, so no accent paints on the taskbar. The system mode is
therefore free to stay light on Windows 10 and on Windows 11.

The script writes a generated wallpaper when the preset names no wallpaper file.
It draws a 3840x2160 PNG gradient from the light accent to the accent and stores
it in `%LOCALAPPDATA%\custom-windows-themer\wallpaper.png`. When
`System.Drawing` is unavailable, the script warns and applies the theme without
a wallpaper.

## Why the Start menu stayed blue

The Start menu and the taskbar read different registry values.

- The taskbar and the title bars read `ColorizationColor` (`HKCU\...\DWM`) and
  `AccentColorMenu` (`HKCU\...\Explorer\Accent`, AABBGGRR).
- The Start menu reads the 32-byte `AccentPalette` (8 entries of R,G,B,A) in
  `HKCU\...\Explorer\Accent`. When you change `AccentColorMenu`, Windows does
  not regenerate this value. An earlier version of this script wrote only
  `AccentColorMenu`. The Start menu kept the default blue palette, but the
  taskbar took the accent color.
- If "Transparency effects" is off, the Start menu shows that palette color as
  a solid color, not as frosted glass.

The script writes `AccentPalette` and `StartColorMenu` from the preset and sets
`EnableTransparency=1`. The Start menu and the taskbar then render frosted
acrylic. "Show accent color on Start and taskbar" stays off
(`ColorPrevalence=0`), so the accent color hits the title bars and window
borders while the shell surfaces stay neutral. The script saves and restores
all of these values with your old theme.

## Usage

The GUI is the quickest route. Double-click `custom-windows-themer.bat`.

The window shows five buttons: **Apply theme**, **Restore mine**, **Toggle**,
**Save current .theme**, and **Refresh status**. Each button runs the PowerShell
script from below and streams its output into the log box. The GUI paints its
own widgets with the colors of the active preset. The GUI never needs
Administrator rights.

You can also run the same commands from a PowerShell prompt in this folder:

```powershell
.\custom-windows-themer.ps1 toggle     # flip between the preset and your saved theme
.\custom-windows-themer.ps1 apply      # turn the preset ON  (saves your theme first)
.\custom-windows-themer.ps1 restore    # turn the preset OFF (back to your saved theme)
.\custom-windows-themer.ps1 status     # show what is currently active
.\custom-windows-themer.ps1 install    # resolve or generate the wallpaper (no theme change)
```

`toggle` is the main command. It reads the mode from
`%LOCALAPPDATA%\custom-windows-themer\state.json`, then it switches to the other
side each time. The state file also stores the active preset, so `toggle`
reapplies the preset you selected.

`status` prints the current mode, the active preset, its accent color and the
live Personalize values.

### The native Windows theme API

The script talks directly to the theme manager of Windows. That is the
reverse-engineered `IThemeManager2` COM API in `themeui.dll`. The Settings app
uses the same API. Read [RESEARCH.md](RESEARCH.md) for the full map of the
theming system.

```powershell
.\custom-windows-themer.ps1 themes              # list installed Windows themes (native)
.\custom-windows-themer.ps1 theme-switch 3      # switch to theme #3 (native apply, like Settings)
.\custom-windows-themer.ps1 theme-save [path]   # save the CURRENT theme as a real .theme file
.\custom-windows-themer.ps1 savetheme [path]    # alias of theme-save
.\custom-windows-themer.ps1 theme-restore path  # apply a .theme file natively (like double-clicking)
.\custom-windows-themer.ps1 theme-file          # (re)generate the installable "<Preset>.theme"
.\custom-windows-themer.ps1 theme-file apply    # ... and apply it natively (same as double-clicking)
.\custom-windows-themer.ps1 restart-shell       # forced shell restart (guarded: apply/restore never restart it)
.\custom-windows-themer.ps1 taskbar-acrylic 120 # live-tune taskbar frosting (0 = transparent .. 255 = max blur)
.\custom-windows-themer.ps1 start-acrylic 96    # live-tune Start menu opacity (0 = transparent .. 255 = solid)
```

- `theme-save` (alias `savetheme`) writes the current theme to a real,
  plain-text `.theme` file. That is the same format Windows and `theme-file`
  write. With no path it creates `Saved theme <timestamp>.theme` in
  `%LOCALAPPDATA%\Microsoft\Windows\Themes`. The file then appears in
  Settings > Personalization > Themes, like the preset's own theme file. The
  file carries your current wallpaper and its position, the accent color,
  auto-colorization and the light/dark mode.
- `theme-restore <path>` applies any `.theme` file natively. It hands the file
  to the Windows shell, the same as double-clicking it in Explorer.
- `theme-file` writes `<PresetDisplayName>.theme` into the user themes folder.
  The file name comes from the active preset. The file appears in Settings and
  in the `themes` listing. Double-click it, or run `theme-file apply`, to apply
  it natively. A `.theme` file carries the wallpaper, its position, the accent,
  auto-colorization and the light/dark mode. The registry layer (`apply`) adds
  what a `.theme` file cannot carry: the Start menu accent palette, the
  transparency and the taskbar acrylic.
- `restart-shell` restarts explorer on purpose. It verifies that the shell is
  back and stable, it retries, and it never leaves the desktop dead. `apply`
  and `restore` do not restart explorer. See below.

> **Why not the COM blob export?** Earlier versions used the reverse-engineered
> `ExportRoamingThemeToStream` COM call. It returns success, but from a
> standalone process it only serializes an ~82-byte header with no wallpaper
> and no theme content. The saved file was useless. `theme-save` writes a real
> `.theme` INI instead. That file always works and shows up in Settings like
> any other theme.

> CAUTION: Do not switch to a "High Contrast" theme except for a deliberate
> test. A switch to one of these themes turns on High Contrast mode. Normal
> theme applications do not turn it off. The script marks these themes in the
> `themes` output. If High Contrast was off before, the script turns it off
> after `theme-switch` or `theme-restore`. If you are stuck in High Contrast,
> run `custom-windows-themer.ps1 apply`, or use Settings > Ease of Access >
> High contrast.

- These commands do not need Administrator rights. They were verified on
  Windows 10 21H2 (build 19044).

> Tip: You can also use `custom-windows-themer.bat`. Double-click it to open
> the GUI. Pass a command to run the console tool instead, for example
> `custom-windows-themer.bat toggle`.

## How save and restore work

- On the first `apply` or `toggle`, the script saves your current theme. It
  saves the wallpaper, the accent color, the light/dark mode, the taskbar
  settings and the Windows Terminal settings. The files are
  `%LOCALAPPDATA%\custom-windows-themer\saved-theme.json` and
  `terminal-backup.json`.
- `restore` or `toggle` writes those values back exactly. The change is visible
  at once through the live settings refresh.
- Separately, `theme-save` / `savetheme` writes the current theme to a real
  `.theme` file for sharing or for Settings > Themes. See above.

## Notes

- **`apply` and `restore` never restart explorer.** The script applies the
  theme with a live "per-user settings changed" broadcast, then restarts only
  the Start menu host process. The desktop keeps running. Force-killing
  explorer and waiting for Winlogon to bring it back was the source of the
  "explorer is dead" bug. On machines where explorer crashes shortly after a
  restart (a recurring `explorer.exe` access violation at fault offset
  `0x458aa`), Winlogon can stop restarting the shell. The desktop then stays
  dead while the script prints "Done". The script now verifies that the shell
  is alive instead of assuming it. It also starts a short background watchdog
  after each run. Run `restart-shell` when you want a full shell restart.
- The script changes the Windows Terminal `settings.json`. It adds a color
  scheme named `CWT - <preset name>` and points every profile at it, plus
  `useAcrylic` / `opacity`. On every apply it first removes all schemes with
  that `CWT - ` prefix, so rotating presets never leaves stale schemes behind.
  The script backs up your original file and restores it fully on `restore`.
- The terminal acrylic uses the current profile settings: `opacity` (0-100) and
  `useAcrylic`. Acrylic renders only while "Transparency effects" is on. The
  theme turns it on. Acrylic does not render during Battery Saver.
- `TaskbarAcrylicOpacity` is a Windows 10 value. The range is 0 to 255. 0 is
  fully transparent. 255 is maximum blur. The default preset value is 80, which
  gives a visible frosted blur.
- You can tune the taskbar blur live with `custom-windows-themer.ps1
  taskbar-acrylic <0-255>`. On Windows 11, the taskbar ignores this value. The
  Windows 11 taskbar becomes frosted through `EnableTransparency` instead.
- On some Windows 10 builds, a sign out and a sign in are necessary before the
  Start menu color changes appear. The script refreshes the Start menu through
  its host process first. If the color still does not appear, `restart-shell`
  forces a full shell refresh.
- Windows 11 gates "Show accent color on Start and taskbar" behind dark system
  mode. The script keeps `ColorPrevalence=0`, so the taskbar stays neutral and
  the accent gate cannot fight the preset.

## Files

- `custom-windows-themer.ps1` contains the full tool (one file, no modules).
- `custom-windows-themer-gui.ps1` is the graphical wrapper (WinForms, part of
  the Windows install, no extra dependencies).
- `custom-windows-themer.bat` is the double-click launcher. No arguments opens
  the GUI. Arguments run the console tool (`custom-windows-themer.bat toggle`).
- `presets/` holds the preset JSON files. Add a file there to add a preset.
- `tests/` holds the regression tests for the CLI and the GUI
  (`powershell -ExecutionPolicy Bypass -File tests\run-tests.ps1`).
  `tests/test-presets-valid.ps1` validates the preset files and runs on any OS.
- `RESEARCH.md` is the reverse-engineering map of the native Windows theming
  system.

The repository ships no image files. The wallpaper comes from the preset or is
generated into the state directory.
