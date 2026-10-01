<#
.SYNOPSIS
    Tiny graphical wrapper for custom-windows-themer.ps1 (no console needed).

.DESCRIPTION
    A small window with buttons that drive the main script:
      * Apply theme      (custom-windows-themer.ps1 apply)
      * Restore mine     (custom-windows-themer.ps1 restore)
      * Toggle           (custom-windows-themer.ps1 toggle)
      * Save .theme      (custom-windows-themer.ps1 savetheme) - saves the current theme
      * Refresh status   (custom-windows-themer.ps1 status)

    The window loads the active preset (state.json -> presets/*.json) and paints
    its own widgets with the preset colors, so the GUI matches the applied theme.

    Launch it by double-clicking custom-windows-themer.bat, or directly:
        powershell -NoProfile -Sta -ExecutionPolicy Bypass -File custom-windows-themer-gui.ps1
#>

Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing

$ScriptDir    = Split-Path -Parent $MyInvocation.MyCommand.Definition
$MainScript   = Join-Path $ScriptDir 'custom-windows-themer.ps1'
$StatePath    = Join-Path $env:LOCALAPPDATA 'custom-windows-themer\state.json'
$PresetsDir   = Join-Path $ScriptDir 'presets'
$Busy         = $false

# ----------------------------------------------------------------------------
# Active preset: every widget color comes from presets/<name>.json. System
# colors are only the fallback when the preset file is missing or unreadable.
# ----------------------------------------------------------------------------
function Get-ActivePreset {
    $name = 'rose'
    if (Test-Path $StatePath) {
        try {
            $state = Get-Content $StatePath -Raw -Encoding UTF8 | ConvertFrom-Json
            if ($state.PSObject.Properties['preset'] -and $state.preset) { $name = [string]$state.preset }
        } catch { }
    }
    $path = Join-Path $PresetsDir "$name.json"
    if (-not (Test-Path $path)) { $path = Join-Path $PresetsDir 'rose.json' }
    if (-not (Test-Path $path)) { return $null }
    try { return Get-Content $path -Raw -Encoding UTF8 | ConvertFrom-Json } catch { return $null }
}
$preset = Get-ActivePreset

function ConvertTo-GUIColor([string]$Hex, [System.Drawing.Color]$Fallback) {
    if (-not $Hex) { return $Fallback }
    try {
        $h = $Hex.TrimStart('#')
        return [System.Drawing.Color]::FromArgb(
            [Convert]::ToByte($h.Substring(0, 2), 16),
            [Convert]::ToByte($h.Substring(2, 2), 16),
            [Convert]::ToByte($h.Substring(4, 2), 16))
    } catch { return $Fallback }
}

$AccentColor = ConvertTo-GUIColor $preset.accent     ([System.Drawing.SystemColors]::Highlight)
$NormalBg    = ConvertTo-GUIColor $preset.normalBg   ([System.Drawing.SystemColors]::Window)
$PresetTitle = if ($preset -and $preset.displayName)  { [string]$preset.displayName } else { 'Custom Windows Themer' }
$PresetDesc  = if ($preset -and $preset.description)  { [string]$preset.description } else { 'no preset file found - check the presets/ folder' }

# ----------------------------------------------------------------------------
# Widgets
# ----------------------------------------------------------------------------
$form = New-Object System.Windows.Forms.Form
$form.Text = 'Custom Windows Themer'
$form.ClientSize = New-Object System.Drawing.Size(430, 500)
$form.FormBorderStyle = 'FixedSingle'
$form.MaximizeBox = $false
$form.StartPosition = 'CenterScreen'
$form.BackColor = [System.Drawing.Color]::White
$form.Font = New-Object System.Drawing.Font('Segoe UI', 9)

$lblTitle = New-Object System.Windows.Forms.Label
$lblTitle.Text = $PresetTitle
$lblTitle.Font = New-Object System.Drawing.Font('Segoe UI', 22, [System.Drawing.FontStyle]::Bold)
$lblTitle.ForeColor = $AccentColor
$lblTitle.AutoSize = $true
$lblTitle.Location = New-Object System.Drawing.Point(20, 16)

$lblSub = New-Object System.Windows.Forms.Label
$lblSub.Text = $PresetDesc
$lblSub.Font = New-Object System.Drawing.Font('Segoe UI', 9)
$lblSub.ForeColor = [System.Drawing.SystemColors]::GrayText
$lblSub.AutoSize = $true
$lblSub.Location = New-Object System.Drawing.Point(22, 58)

$lblMode = New-Object System.Windows.Forms.Label
$lblMode.Text = 'Mode: ...'
$lblMode.Font = New-Object System.Drawing.Font('Segoe UI', 9, [System.Drawing.FontStyle]::Bold)
$lblMode.ForeColor = [System.Drawing.Color]::FromArgb(60, 60, 60)
$lblMode.AutoSize = $true
$lblMode.Location = New-Object System.Drawing.Point(22, 84)

function New-AccentButton([string]$Text, [int]$X, [int]$Y, [int]$W) {
    $b = New-Object System.Windows.Forms.Button
    $b.Text = $Text
    $b.Size = New-Object System.Drawing.Size($W, 34)
    $b.Location = New-Object System.Drawing.Point($X, $Y)
    $b.BackColor = $AccentColor
    $b.ForeColor = [System.Drawing.Color]::White
    $b.FlatStyle = 'Flat'
    $b.FlatAppearance.BorderSize = 0
    $b.Cursor = 'Hand'
    $b.UseVisualStyleBackColor = $false
    return $b
}

$btnApply   = New-AccentButton 'Apply theme'     20 118 124
$btnRestore = New-AccentButton 'Restore mine'    152 118 110
$btnToggle  = New-AccentButton 'Toggle'          270 118 140

$btnSave    = New-AccentButton 'Save current .theme' 20 158 220
$btnRefresh = New-AccentButton 'Refresh status'      252 158 158

$txtLog = New-Object System.Windows.Forms.TextBox
$txtLog.Multiline = $true
$txtLog.ReadOnly = $true
$txtLog.ScrollBars = 'Vertical'
$txtLog.WordWrap = $false
$txtLog.BackColor = $NormalBg
$txtLog.ForeColor = [System.Drawing.SystemColors]::WindowText
$txtLog.BorderStyle = 'FixedSingle'
$txtLog.Location = New-Object System.Drawing.Point(20, 202)
$txtLog.Size = New-Object System.Drawing.Size(390, 276)

$form.Controls.AddRange(@($lblTitle, $lblSub, $lblMode, $btnApply, $btnRestore, $btnToggle,
                           $btnSave, $btnRefresh, $txtLog))

# ----------------------------------------------------------------------------
# Helpers
# ----------------------------------------------------------------------------
function Append-Log([string]$Line) {
    if ([string]::IsNullOrEmpty($Line)) { return }
    $txtLog.AppendText($Line + [Environment]::NewLine)
}

function Set-Busy([bool]$Value) {
    $script:Busy = $Value
    foreach ($c in @($btnApply, $btnRestore, $btnToggle, $btnSave, $btnRefresh)) {
        $c.Enabled = -not $Value
    }
}

function Invoke-CWTCommand([string]$Command) {
    if ($script:Busy) { return }
    Set-Busy $true
    $lblMode.Text = "Working on: $Command ..."
    $lblMode.ForeColor = $AccentColor
    Append-Log ''
    Append-Log "> custom-windows-themer.ps1 $Command"

    $combined = ''
    try {
        $psi = New-Object System.Diagnostics.ProcessStartInfo
        $psi.FileName = 'powershell.exe'
        $psi.UseShellExecute = $false
        $psi.CreateNoWindow = $true
        $psi.RedirectStandardOutput = $true
        $psi.RedirectStandardError = $true
        # -Sta is required by the native theme-API COM calls in custom-windows-themer.ps1
        $psi.Arguments = "-NoProfile -Sta -ExecutionPolicy Bypass -File `"$MainScript`" $Command"

        $p = New-Object System.Diagnostics.Process
        $p.StartInfo = $psi
        $null = $p.Start()
        # IMPORTANT: read the child output with pure .NET tasks ONLY. Attaching
        # scriptblock handlers to OutputDataReceived / ErrorDataReceived makes
        # PowerShell execute them on the background reader thread, which has no
        # runspace context - the process dies with PSInvalidOperation
        # (ScriptBlock.GetContextFromTLS), WER "PowerShell" event, exit code 2.
        $outTask = $p.StandardOutput.ReadToEndAsync()
        $errTask = $p.StandardError.ReadToEndAsync()
        # keep the UI pumping messages while the child runs
        while (-not $p.HasExited -or -not $outTask.IsCompleted -or -not $errTask.IsCompleted) {
            [System.Windows.Forms.Application]::DoEvents()
            Start-Sleep -Milliseconds 60
        }
        $p.WaitForExit()
        try { $combined = $outTask.Result + $errTask.Result } catch { $combined = $_.Exception.Message }
    } catch {
        $combined = "ERR: $($_.Exception.Message)"
    }
    foreach ($line in ($combined -split "`r?`n")) { Append-Log $line }

    $mode = 'unknown'
    if (Test-Path $StatePath) {
        try { $mode = (Get-Content $StatePath -Raw | ConvertFrom-Json).mode } catch { }
    }
    if ($Command -eq 'status') {
        $cur = (Get-ItemProperty 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Themes' -ErrorAction SilentlyContinue).CurrentTheme
        if ($cur) { $lblMode.Text = "Mode: live theme -> $(Split-Path $cur -Leaf)" }
        else { $lblMode.Text = 'Mode: see log below' }
    } else {
        $lblMode.Text = "Mode: $mode"
    }
    $lblMode.ForeColor = [System.Drawing.Color]::FromArgb(60, 60, 60)
    Set-Busy $false
}

$btnApply.Add_Click({ Invoke-CWTCommand 'apply' })
$btnRestore.Add_Click({ Invoke-CWTCommand 'restore' })
$btnToggle.Add_Click({ Invoke-CWTCommand 'toggle' })
$btnSave.Add_Click({ Invoke-CWTCommand 'savetheme' })
$btnRefresh.Add_Click({ Invoke-CWTCommand 'status' })

$form.Add_Shown({
    $form.Activate()
    # kick off an initial status read in the background so the window shows instantly
    $form.BeginInvoke([Action]{ Invoke-CWTCommand 'status' }) | Out-Null
})

[System.Windows.Forms.Application]::Run($form)
