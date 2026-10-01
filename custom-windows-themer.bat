@echo off
rem Convenience launcher for custom-windows-themer.ps1 (no admin required)
rem Double-click  -> opens the tiny GUI wrapper (custom-windows-themer-gui.ps1)
rem With a command -> runs the console tool directly:
rem   custom-windows-themer.bat [toggle|apply ^<preset^>|presets|restore|on|off|status|install|themes|theme-save|theme-restore|theme-switch|theme-file|restart-shell|savetheme|taskbar-acrylic|start-acrylic]
if "%~1"=="" (
  powershell -NoProfile -Sta -ExecutionPolicy Bypass -File "%~dp0custom-windows-themer-gui.ps1"
) else (
  rem -Sta keeps COM calls to the native Windows theme manager on the right apartment.
  powershell -NoProfile -Sta -ExecutionPolicy Bypass -File "%~dp0custom-windows-themer.ps1" %*
)
