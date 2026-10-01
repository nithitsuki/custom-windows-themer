# Windows native theming — internals & reverse-engineering map

Research companion to `custom-windows-themer.ps1`. Everything below was verified on the
target machine (Windows 10 21H2, build 19044) unless noted otherwise. Sources are
linked inline; the most valuable ones are the `SecureUxTheme`/`ThemeTool` project
(which reverse-engineered the *native* theme-manager COM API) and Microsoft's own
`.theme` format documentation.

---

## 1. The theming stack, era by era

| Era | Loading/rendering | Apply/save path | Notes |
|-----|-------------------|-----------------|-------|
| **Windows 7** | `uxtheme.dll` draws controls from an `.msstyles` (resource-only PE); DWM does Aero glass (`DwmIsCompositionEnabled`, `DwmExtendFrameIntoClientArea`) | Classic **Desktop Themes** (`themeui.dll`, OLE automation) + `.theme` files – see `re/ITheme_win7.h` | themeui.dll is *still present* in Win10/11 and its CLSID surface survives |
| **Windows 8/8.1** | same `uxtheme` engine, more immersive APIs (`GetImmersiveColorFromColorSetEx` etc.) | Theme manager gains `get_ScreenSaver`/`put_ScreenSaver` slots in `ITheme` | Start screen era; accent system born (`Explorer\Accent`) |
| **Windows 10** | `uxtheme` + `uDWM`; accent/taskbar/Start colours come from the **Accent registry block** + `ColorizationColor` | Custom Theme Manager COM in **`themeui.dll`**: `CLSID {9324da94-50ec-4a14-a770-e90ca03e7c8f}` ("Windows Theme Manager 2 API") | 1803→1809→1903 vtable drift documented in `re/ITheme_1809.h` / `ITheme_1903.h` (dark-mode `AppMode`/`SystemMode` slots added in 1903) |
| **Windows 11** | `uDWM` re-written (Mica/Acrylic is a DWM material, not acrylic); taskbar/Start are XAML in `ShellExperienceHost` | Same themeui Theme Manager (Settings > Personalization uses it) | `TaskbarAcrylicOpacity` is a **Windows 10 only** hack; on 11 the taskbar reads `EnableTransparency` |

Core components (all present on Win10 21H2):

- **`uxtheme.dll`** — visual style engine; parses `.msstyles`, exposes the
  documented UxTheme API + **undocumented ordinals** (see §4).
- **`themeui.dll`** — in-process COM server for `IThemeManager2`/`ITheme`
  (`InprocServer32`, `ThreadingModel=Apartment`). This is the native "save/apply
  theme" API.
- **`themeservice.dll` / Themes service** — low-level style loading.
- **`uDWM.dll`** — the compositor-side renderer (Aero → Mica/Acrylic).
- **`.theme`** — an INI file describing a theme (documented by Microsoft:
  <https://learn.microsoft.com/en-us/windows/win32/controls/themesfileformat-overview>).
- **`.msstyles`** — resource-only PE with the visual style resources (bitmaps,
  text, metrics). Theme re-skinning community is huge (see §5).
- **`.themepack` / `.deskthemepack`** — CAB/ZIP containers wrapping a `.theme` +
  wallpaper; the Microsoft Store's "Windows Themes" ship as these.

---

## 2. The accent/dark-mode subsystem (what our script drives)

All HKCU, no admin:

| Value | Type | Meaning (Win10 21H2) |
|---|---|---|
| `HKCU\...\Themes\Personalize\EnableTransparency` | DWORD | 1 = frosted/acrylic Start + taskbar; 0 = opaque |
| `...\Personalize\ColorPrevalence` | DWORD | 1 = "show accent on Start, taskbar, action center" |
| `...\Personalize\AppsUseLightTheme` / `SystemUsesLightTheme` | DWORD | App / system dark-light mode |
| `HKCU\...\DWM\ColorizationColor` | DWORD | `AARRGGBB`; taskbar/titlebar colour (+intensity alpha, e.g. `0xC4……`) |
| `HKCU\...\DWM\ColorPrevalence` | DWORD | 1 = accent on **window borders/title bars** |
| `HKCU\...\Explorer\Accent\AccentColorMenu` | DWORD | `AABBGGRR`; window borders & titlebar menu accent |
| `HKCU\...\Explorer\Accent\StartColorMenu` | DWORD | `AABBGGRR`; UWP modals/Start-derived surfaces |
| `HKCU\...\Explorer\Accent\AccentPalette` | 32 bytes | **8 × `[R,G,B,A]`**; Start menu / taskbar / action-center derive their colour from here. **Windows does NOT regenerate it from `AccentColorMenu`** — this is why the Start menu stays blue while the taskbar takes the accent (the bug this project fixed). AveYo's "Pitch Black" gists use the same trick: <https://gist.github.com/AveYo/80fc6677b9f34939e44364880fbf3768> |
| `HKCU\Control Panel\Desktop\AutoColorization` | DWORD | 0/1 "pick accent from wallpaper" |
| `HKCU\...\Explorer\Advanced\TaskbarAcrylicOpacity` | DWORD | Win10 only; 0 = most transparent .. 255 = blurriest. Documented informally by <https://github.com/AndMJ/TaskbarAcrylicOpacity> |

AccentPalette generation: Windows builds the 8 shades from the accent colour with
an internal (undocumented) algorithm — reverse-engineering attempts and
working approximations: <https://learn.microsoft.com/en-us/answers/questions/2045412/change-accent-color-for-taskbar-on-windows-11-via>,
<https://www.purebasic.fr/english/viewtopic.php?t=79843>,
<https://ramensoftware.com/getting-brighter-colors-in-windows-10/>.

---

## 3. The native theme manager (the real hook)

Reverse-engineered by **namazso** in the SecureUxTheme/ThemeTool project
(<https://github.com/namazso/SecureUxTheme>, fork with the RE headers:
<https://github.com/joelvaneenwyk/windows-secure-ux-theme>, `ThemeLib/theme.cpp`,
`re/*.h`).

```text
CLSID_ThemeManager2 = {9324da94-50ec-4a14-a770-e90ca03e7c8f}   themeui.dll, in-proc, Apartment
IID_IThemeManager2  = {c1e8c83e-845d-4d95-81db-e283fdffc000}
ITheme              = per-build vtable (see re/ITheme_*.h; NOT QI-able as IUnknown on 21H2!)
```

The manager (24 vtable slots) — the interesting ones:

```text
Init(flags) / InitAsync(hwnd, unknown) / Refresh() / RefreshAsync(hwnd, unknown) / RefreshComplete()
GetThemeCount(out int)
GetTheme(idx, out ITheme)                       # per-theme object model
GetCurrentTheme(out idx) / GetCustomTheme / GetDefaultTheme
SetCurrentTheme(hwnd, idx, applyNow, applyFlags, packFlags)   # applyNow=1 == what Settings does
CreateThemePack(hwnd, path, packFlags)          # "save as pack" — E_INVALIDARG on 21H2 (unproven)
CloneAndSetCurrentTheme / InstallThemePack / DeleteTheme / OpenTheme
AddAndSelectTheme(hwnd, path, applyFlags, packFlags)
ExportRoamingThemeToStream(IStream, 0)          # native "save current theme" — see caveat below
ImportRoamingThemeFromStream(IStream, 0)        # native "install & apply saved theme" — WORKS
```

`apply_flags` (from `public/themetool.h`):
`1<<0` ignore background · `1<<1` ignore cursor · `1<<2` ignore desktop icons ·
`1<<3` ignore colour · `1<<4` ignore sound · `1<<5` ignore screensaver ·
`1<<8` no hourglass.

The `ITheme` object model (`ITheme_1903.h`) — display name, visual style
(+colour/size/version), colorization colour, app/system **light-dark mode**,
wallpaper + fit position, slideshow, cursors, sound scheme, desktop icons,
high-contrast, logon background, brand logo, theme id/magic value… i.e. the
complete serialisable theme state.

### Proven on this machine (Win10 21H2)

Done live while writing this doc — a C# COM interop probe from PowerShell (STA):

- `CoCreateInstance` + `Init(0)` → S_OK; **`GetThemeCount` = 9** (10 after an
  import), `GetDefaultTheme`=5, `GetCustomTheme`=0, `GetCurrentTheme`=0
- **`SetCurrentTheme(idx, applyNow=0|1, 0, 0)` → S_OK** — the exact call the
  Settings app makes; switch themes natively, no explorer kill needed
- **`ExportRoamingThemeToStream` → S_OK** — ~558 KB blob: custom container
  containing a **CAB** (`MSCF`) with `Unsaved T.theme` + `DesktopBackground\15.png`
  (wallpaper embedded). The native "save current theme" format.
- **`ImportRoamingThemeFromStream` → S_OK** — imports + applies it; wrote
  `Roamed.theme` into `%LOCALAPPDATA%\Microsoft\Windows\Themes` and moved the
  `CurrentTheme` registry pointer. (It consumed the previously-current
  `Custom.theme` on this machine — native apply semantics.)
- Crash/limitations observed: `CreateThemePack` → E_INVALIDARG (matrix of
  extensions/flags); `InstallThemePack`/`CloneAndSetCurrentTheme` → process
  crash (likely needs a dialog flow); `AddAndSelectTheme` → E_FAIL;
  `OpenTheme` → E_INVALIDARG; `ITheme` vtable on 21H2 is **shifted** relative
  to the RE'd 1903 header (slot 0's QI even crashes an IUnknown call — the
  object is a bare C++ vtable, ThemeTool never QIs, it just calls slots).

So the robust, ship-worthy native surface for our Windows 10/21H2 target:
**enumerate (count/current/custom/default), switch by index.** Theme *names*
come from parsing `.theme` files in `%windir%\Resources\Themes` and
`%LOCALAPPDATA%\Microsoft\Windows\Themes` (`[Theme] DisplayName=`).

> **Follow-up (2026-08-28): `ExportRoamingThemeToStream` is NOT a reliable save
> path from a standalone process.** Re-tested on this machine: with
> `current=custom=0` (active theme = `aero.theme`) the call returns S_OK but
> serializes only an **82-byte container stub** (no `[Theme]`, no wallpaper) —
> verified via `IStream.Stat` *and* `GlobalSize` (not a reading bug), even after
> `Refresh()` + `GetTheme(cur)`. The full ~558 KB blob observed earlier was
> produced by a probe that had first **imported** a roaming theme in-process
> (`ImportRoamingThemeFromStream` → `Roamed.theme`), which materializes the
> internal `XTheme` state the exporter reads. Without that in-process state the
> exporter emits an empty header while still returning success — i.e. the old
> "worked, trust us" signal was a silent data loss. Consequence: `theme-save`
> in `custom-windows-themer.ps1` now writes a **plain `.theme` INI** (same format as
> Windows' own `Custom.theme` / the generated `<PresetDisplayName>.theme`) from the live registry
> state — deterministic, installable via Settings, shareable, and it never
> pretends to succeed on an empty export.

---

## 4. Undocumented uxtheme APIs (dark mode etc.)

`uxtheme.dll` exports several **ordinal-only** functions that reverse engineers
mapped (names/metadata are on Microsoft's symbol server):

- `ShouldAppsUseDarkMode` (ordinal 132), `AllowDarkModeForApp`,
  `SetPreferredAppMode` — the dark-mode switch apps call directly;
  `GetImmersiveColor*` (colour set access).
- Best walking-through of one: valinet's "Get dark command windows all the
  time" gist (conhost dark-mode RE with Ghidra):
  <https://gist.github.com/valinet/6afb524426635df9dbe2a9035701fcf4>
- On this machine only `GetUserColorPreference` is exported **by name**; the
  accent getters (`GetSystemAccentColor` etc.) are exported per-build — either
  ordinal-only or renamed, so registry reads (our script) are the robust path.

---

## 5. The reverse-engineering ecosystem (learn & leverage)

- **SecureUxTheme / ThemeTool** — in-memory UxTheme patcher + the
  `IThemeManager2` RE (LGPL): <https://github.com/namazso/SecureUxTheme>
- **UxThemeEx** — RE of the UxTheme drawing engine, load `.msstyles` in
  app context: <https://github.com/AllieTheFox/UxThemeEx>
- **kawapure/DWM-Documentation** — RE notes on DWM (MIL/DWMCore):
  <https://github.com/kawapure/DWM-Documentation>
- **msstyleEditor** — edit `.msstyles` (themes1 resource UI):
  <https://github.com/nptr/msstyleEditor>
- **Windhawk** — mod platform; the `UXTheme hook` / `DWM fix` mods make custom
  styles work safely in RAM: <https://windhawk.net/mods/uxtheme-hook>
- **w11-theming-suite** — native Win11 theming toolkit (registry writes +
  `WM_SETTINGCHANGE`, XAML diagnostics injection):
  <https://github.com/decarvalhoe/w11-theming-suite>
- **AveYo gists** — `AccentPalette` / themed `.reg` presets (what we used for
  the Start-menu fix): <https://gist.github.com/AveYo/80fc6677b9f34939e44364880fbf3768>
- **Winaero Tweaker / ThemeSwitcher** — registry-apply approaches and GUI tools.

---

## 6. How we hook it today & honest limitations

`custom-windows-themer.ps1` now ships two layers:

1. **Registry layer** (default, no admin, always works): direct HKCU writes for
   wallpaper/accent/palette/transparency/light-mode + Explorer restart. Save =
   snapshot of those values (+ full Windows Terminal backup).
2. **Native ThemeManager layer** (new commands, no admin):
   - `themes` — native list (count, indices, current/custom/default) + names
     parsed from `.theme` files
   - `theme-switch <index>` — `SetCurrentTheme(idx, applyNow=1)` (S_OK proven)
   - `theme-save [path]` (alias `savetheme`) — writes a **plain `.theme` INI**
     of the current live state (wallpaper/position, accent, auto-colorization,
     light/dark mode) — deterministic; appears in Settings > Themes like any
     other theme. (Replaced the COM stream export — see the caveat in §3.)
   - `theme-restore <path>` — applies any `.theme` file via the Windows shell
     (Start-Process = double-click semantics; native, no COM blob needed)

Limitations (measured, not guessed): `CreateThemePack` is broken on 21H2;
`ITheme` property reads need per-build vtable mapping (a small C++ RE task —
recommended next step, details below); `AddAndSelectTheme` needs the right
context/flags; on Windows 11 the same COM API exists (tested by ThemeTool
users) but `TaskbarAcrylicOpacity` is ignored.

### The High Contrast trap (learned the hard way on this machine)

Applying an Ease-of-Access theme (`hcwhite.theme` etc.) via `SetCurrentTheme`
**turns on Windows High Contrast mode** — and once on, applying a normal theme
does *not* turn it back off (only an explicit toggle does). Live observations
on 21H2:

- `theme-switch 5` (HC White) set `HKCU\Control Panel\Accessibility\HighContrast`
  → `Flags=127`, `High Contrast Scheme=High Contrast White` and the live
  `SPI_GETHIGHCONTRAST` flag; the taskbar also vanished (explorer had died —
  `explorer.exe` needed a manual restart).
- Manual recovery that worked: `SPI_SETHIGHCONTRAST` with flags cleared +
  `Flags=126` + clearing the scheme strings (or removing the whole key) +
  restarting `explorer.exe`. `SPI_GETHIGHCONTRAST` is the authoritative live
  check (the registry alone can lag/mismatch).
- After the accessibility key was wiped to baseline, re-applying the HC themes
  no longer re-latches the flag — but a subsequent normal-theme apply *did*
  re-latch once more during testing, so the latch is flaky: the script now
  snapshots HC state before any native switch/import and **auto-forces it off**
  afterwards if it changed (defense in depth: SPI + registry checks).

### Next steps to go deeper

- **Map the 21H2 `ITheme` vtable properly**: dump the functions with a
  disassembler (Ghidra is free) loading `themeui.dll`'s public symbols from the
  Microsoft symbol server — symbol names on the vtable pointers will resolve
  instantly. Then the native layer can read names/wallpapers per theme.
- **Build a tiny C++ helper** (`applytheme.exe`) calling the manager directly —
  removes PowerShell COM interop friction and lets `AddAndSelectTheme`/packs
  get proper HWND flows.
- **Write real `.themepack`/`.deskthemepack`** files (CAB containing `.theme` +
  wallpaper) — both directions scheduled for future work (the roaming stream
  blob turned out unreliable from standalone processes — see §3 caveat; a CAB
  pack is a straightforward, deterministic alternative).
- **Windhawk mod** if you want visual-style (`.msstyles`) switching without
  touching system files — pairs cleanly with the native manager.