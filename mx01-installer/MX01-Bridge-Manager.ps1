# MX01 Bridge Manager - Windows PowerShell 5.1 compatible WinForms application.
# This UI delegates configuration and printing to the private installer runtime.

$ErrorActionPreference = 'Stop'

Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing
[System.Windows.Forms.Application]::EnableVisualStyles()

$script:Root = $PSScriptRoot
$script:Bridge = Join-Path $script:Root 'mxw01_windows_print_menu.py'
$script:Python = Join-Path $script:Root 'runtime\python.exe'
$script:PythonW = Join-Path $script:Root 'runtime\pythonw.exe'
$script:Selector = Join-Path $script:Root 'Select-MX01-Printer.bat'
$script:RegistryPath = 'HKLM:\Software\MX01Bridge'
$script:LastStatusText = 'Checking bridge status…'
$script:IsConnected = $false
$script:ProfileAccounts = @()

$script:Colors = @{
    Background = [System.Drawing.Color]::FromArgb(12, 19, 32)
    Panel      = [System.Drawing.Color]::FromArgb(21, 31, 48)
    PanelAlt   = [System.Drawing.Color]::FromArgb(27, 40, 59)
    Border     = [System.Drawing.Color]::FromArgb(43, 60, 82)
    Text       = [System.Drawing.Color]::FromArgb(239, 245, 250)
    Muted      = [System.Drawing.Color]::FromArgb(157, 174, 192)
    Teal       = [System.Drawing.Color]::FromArgb(44, 205, 183)
    TealDark   = [System.Drawing.Color]::FromArgb(22, 132, 125)
    Green      = [System.Drawing.Color]::FromArgb(69, 214, 156)
    Red        = [System.Drawing.Color]::FromArgb(255, 112, 120)
}

function Get-RegistryValueSafe {
    param([string]$Name, $Default = $null)
    foreach ($view in @([Microsoft.Win32.RegistryView]::Registry64, [Microsoft.Win32.RegistryView]::Registry32)) {
        $baseKey = $null
        $key = $null
        try {
            $baseKey = [Microsoft.Win32.RegistryKey]::OpenBaseKey([Microsoft.Win32.RegistryHive]::LocalMachine, $view)
            $key = $baseKey.OpenSubKey('Software\MX01Bridge', $false)
            if ($null -ne $key) {
                $value = $key.GetValue($Name, $null)
                if ($null -ne $value) { return $value }
            }
        } catch { }
        finally {
            if ($null -ne $key) { $key.Dispose() }
            if ($null -ne $baseKey) { $baseKey.Dispose() }
        }
    }
    return $Default
}

function ConvertTo-NativeArgument {
    param([AllowEmptyString()][string]$Value)
    # Quote according to the Windows CommandLineToArgvW/backslash rules.
    if ($null -eq $Value) { $Value = '' }
    if ($Value.Length -gt 0 -and $Value -notmatch '[\s"]') { return $Value }
    $builder = New-Object System.Text.StringBuilder
    [void]$builder.Append('"')
    $slashes = 0
    foreach ($char in $Value.ToCharArray()) {
        if ($char -eq '\') { $slashes++; continue }
        if ($char -eq '"') {
            if ($slashes -gt 0) { [void]$builder.Append(('\' * (2 * $slashes))) }
            [void]$builder.Append('\"')
            $slashes = 0
            continue
        }
        if ($slashes -gt 0) { [void]$builder.Append(('\' * $slashes)); $slashes = 0 }
        [void]$builder.Append($char)
    }
    if ($slashes -gt 0) { [void]$builder.Append(('\' * (2 * $slashes))) }
    [void]$builder.Append('"')
    return $builder.ToString()
}

function Invoke-HiddenPython {
    param(
        [Parameter(Mandatory=$true)][string]$Executable,
        [Parameter(Mandatory=$true)][string[]]$Arguments,
        [int]$TimeoutMilliseconds = 120000
    )
    if (-not (Test-Path -LiteralPath $Executable)) { throw "The private Python runtime was not found: $Executable" }
    if (-not (Test-Path -LiteralPath $script:Bridge)) { throw "The MX01 bridge script was not found: $($script:Bridge)" }
    $allArgs = @($script:Bridge) + $Arguments
    $quoted = @($allArgs | ForEach-Object { ConvertTo-NativeArgument ([string]$_) })
    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName = $Executable
    $psi.Arguments = $quoted -join ' '
    $psi.UseShellExecute = $false
    $psi.CreateNoWindow = $true
    $psi.WindowStyle = [System.Diagnostics.ProcessWindowStyle]::Hidden
    $process = New-Object System.Diagnostics.Process
    $process.StartInfo = $psi
    try {
        if (-not $process.Start()) { throw 'The bridge helper could not be started.' }
        if (-not $process.WaitForExit($TimeoutMilliseconds)) {
            try { $process.Kill() } catch { }
            throw 'The bridge helper took too long and was stopped.'
        }
        $process.WaitForExit()
        return [int]$process.ExitCode
    } finally { $process.Dispose() }
}

function Invoke-ElevatedPython {
    param([Parameter(Mandatory=$true)][string[]]$Arguments)
    if (-not (Test-Path -LiteralPath $script:Python)) { throw "The private Python runtime was not found: $($script:Python)" }
    if (-not (Test-Path -LiteralPath $script:Bridge)) { throw "The MX01 bridge script was not found: $($script:Bridge)" }
    $allArgs = @($script:Bridge) + $Arguments
    $quoted = @($allArgs | ForEach-Object { ConvertTo-NativeArgument ([string]$_) })
    $argumentLine = $quoted -join ' '
    $proc = Start-Process -FilePath $script:Python -ArgumentList $argumentLine -Verb RunAs -WindowStyle Hidden -Wait -PassThru
    return [int]$proc.ExitCode
}

function Get-StatusResult {
    $tempFile = Join-Path ([System.IO.Path]::GetTempPath()) ('mx01-status-' + [guid]::NewGuid().ToString('N') + '.json')
    try {
        $exitCode = Invoke-HiddenPython -Executable $script:PythonW -Arguments @('status', '--output', $tempFile) -TimeoutMilliseconds 20000
        if (-not (Test-Path -LiteralPath $tempFile)) {
            if ($exitCode -ne 0) { throw "Status check returned exit code $exitCode without status output." }
            throw 'The bridge did not return status information.'
        }
        $raw = [System.IO.File]::ReadAllText($tempFile).Trim()
        if ([string]::IsNullOrWhiteSpace($raw)) { throw 'The bridge returned an empty status response.' }
        $connected = $false
        $detail = $raw
        try {
            $data = ConvertFrom-Json -InputObject $raw -ErrorAction Stop
            $candidates = New-Object System.Collections.Generic.List[string]
            foreach ($name in @('status','state','connection','connection_status')) {
                $p = $data.PSObject.Properties[$name]
                if ($null -ne $p -and $null -ne $p.Value) { $candidates.Add([string]$p.Value) }
            }
            foreach ($name in @('connected','is_connected')) {
                $p = $data.PSObject.Properties[$name]
                if ($null -ne $p) {
                    if ($p.Value -eq $true -or [string]$p.Value -match '^(?i:true|yes|1)$') { $connected = $true }
                    if ($p.Value -eq $false -or [string]$p.Value -match '^(?i:false|no|0)$') { }
                }
            }
            if (-not $connected) {
                foreach ($candidate in $candidates) {
                    if ($candidate -match '(?i)connected' -and $candidate -notmatch '(?i)disconnected|not\s+connected') { $connected = $true; break }
                }
            }
            if ($candidates.Count -gt 0) { $detail = $candidates[0] }
        } catch {
            if ($raw -match '(?i)\bconnected\b' -and $raw -notmatch '(?i)\bdisconnected\b|\bnot\s+connected\b') { $connected = $true }
            if ($raw -match '(?i)\b(disconnected|not\s+connected|offline|stopped)\b') { $connected = $false }
        }
        return [pscustomobject]@{ Connected = $connected; Detail = $detail; Raw = $raw; ExitCode = $exitCode }
    } finally {
        if (Test-Path -LiteralPath $tempFile) { Remove-Item -LiteralPath $tempFile -Force -ErrorAction SilentlyContinue }
    }
}

function Set-StatusVisual {
    param([bool]$Connected, [string]$Text)
    $script:IsConnected = $Connected
    if ($Connected) {
        $statusValue.Text = 'CONNECTED'
        $statusValue.ForeColor = $script:Colors.Green
        $statusDot.BackColor = $script:Colors.Green
        $statusMessage.Text = 'Your MX01 bridge is ready to receive print jobs.'
    } else {
        $statusValue.Text = 'NOT CONNECTED'
        $statusValue.ForeColor = $script:Colors.Muted
        $statusDot.BackColor = $script:Colors.Red
        if ($Text -and $Text -notmatch '(?i)disconnected|not connected|offline|stopped') {
            $statusMessage.Text = $Text
        } else {
            $statusMessage.Text = 'Choose Connect to select a printer and start the bridge.'
        }
    }
    $connectButton.Visible = -not $Connected
    $refreshButton.Visible = -not $Connected
}

function Refresh-BridgeStatus {
    $refreshButton.Enabled = $false
    $statusMessage.Text = 'Checking bridge status…'
    [System.Windows.Forms.Application]::DoEvents()
    try {
        $result = Get-StatusResult
        Set-StatusVisual -Connected $result.Connected -Text $result.Detail
    } catch {
        Set-StatusVisual -Connected $false -Text ''
        $statusMessage.Text = 'Status is unavailable. Connect to select a printer, or try Refresh.'
        $script:LastStatusText = $_.Exception.Message
    } finally { $refreshButton.Enabled = $true }
}

function Get-ProfileAccounts {
    $results = New-Object System.Collections.Generic.List[string]
    $seen = @{}
    try {
        $profiles = Get-CimInstance -ClassName Win32_UserProfile -ErrorAction Stop
        foreach ($profile in $profiles) {
            if ($profile.Special -or [string]::IsNullOrWhiteSpace([string]$profile.SID)) { continue }
            $account = $null
            try {
                $sid = New-Object System.Security.Principal.SecurityIdentifier([string]$profile.SID)
                $account = $sid.Translate([System.Security.Principal.NTAccount]).Value
            } catch { }
            if ([string]::IsNullOrWhiteSpace($account)) {
                if (-not [string]::IsNullOrWhiteSpace([string]$profile.LocalPath)) { $account = Split-Path -Leaf ([string]$profile.LocalPath) }
                else { continue }
            }
            if (-not $seen.ContainsKey($account.ToLowerInvariant())) { $seen[$account.ToLowerInvariant()] = $true; $results.Add($account) }
        }
    } catch { }
    $current = [System.Security.Principal.WindowsIdentity]::GetCurrent().Name
    if (-not [string]::IsNullOrWhiteSpace($current) -and -not $seen.ContainsKey($current.ToLowerInvariant())) {
        $seen[$current.ToLowerInvariant()] = $true
        $results.Add($current)
    }
    $sorted = @($results.ToArray() | Sort-Object { $_.ToLowerInvariant() })
    return ,$sorted
}

function Load-Accounts {
    $preferred = [string](Get-RegistryValueSafe -Name 'SelectedUser' -Default '')
    if ([string]::IsNullOrWhiteSpace($preferred)) { $preferred = [string](Get-RegistryValueSafe -Name 'LibkiUser' -Default '') }
    $current = [System.Security.Principal.WindowsIdentity]::GetCurrent().Name
    $script:ProfileAccounts = @(Get-ProfileAccounts)
    $accountCombo.BeginUpdate()
    try {
        $accountCombo.Items.Clear()
        foreach ($account in $script:ProfileAccounts) { [void]$accountCombo.Items.Add([string]$account) }
        $index = -1
        if (-not [string]::IsNullOrWhiteSpace($preferred)) { $index = $accountCombo.Items.IndexOf($preferred) }
        if ($index -lt 0 -and -not [string]::IsNullOrWhiteSpace($current)) { $index = $accountCombo.Items.IndexOf($current) }
        if ($index -ge 0) { $accountCombo.SelectedIndex = $index }
        elseif ($accountCombo.Items.Count -gt 0) { $accountCombo.SelectedIndex = 0 }
    } finally { $accountCombo.EndUpdate() }
}

function Update-AccountState {
    $accountCombo.Enabled = -not $scopeAll.Checked
    $accountHint.Enabled = -not $scopeAll.Checked
}

function Start-BridgeNow {
    if (-not (Test-Path -LiteralPath $script:PythonW)) { throw "The private Python windowless runtime was not found: $($script:PythonW)" }
    $arguments = @($script:Bridge, 'run') | ForEach-Object { ConvertTo-NativeArgument ([string]$_) }
    Start-Process -FilePath $script:PythonW -ArgumentList ($arguments -join ' ') -WindowStyle Hidden | Out-Null
    Start-Sleep -Milliseconds 1200
    Refresh-BridgeStatus
}

function Test-CurrentAccountAllowed {
    param([string]$Scope, [string]$Account)
    if ($Scope -eq 'all') { return $true }
    $sameAccount = $false
    try {
        $currentSid = [System.Security.Principal.WindowsIdentity]::GetCurrent().User.Value
        $selectedSid = (New-Object System.Security.Principal.NTAccount($Account)).Translate([System.Security.Principal.SecurityIdentifier]).Value
        $sameAccount = ($currentSid -eq $selectedSid)
    } catch {
        $currentName = [System.Security.Principal.WindowsIdentity]::GetCurrent().Name
        $sameAccount = $currentName.Equals($Account, [System.StringComparison]::OrdinalIgnoreCase)
    }
    if ($Scope -eq 'only') { return $sameAccount }
    return -not $sameAccount
}

function Save-StartupConfiguration {
    $applyButton.Enabled = $false
    try {
        if ($autoStartCheck.Checked) {
            $scope = if ($scopeOnly.Checked) { 'only' } elseif ($scopeExcept.Checked) { 'except' } else { 'all' }
            $arguments = @('install-startup', '--scope', $scope)
            if ($scope -ne 'all') {
                $account = [string]$accountCombo.SelectedItem
                if ([string]::IsNullOrWhiteSpace($account)) { throw 'Choose a Windows account before saving this startup scope.' }
                $arguments += @('--user', $account)
            }
            $exitCode = Invoke-ElevatedPython -Arguments $arguments
            if ($exitCode -ne 0) { throw "Startup configuration returned exit code $exitCode." }
            $footerMessage.Text = 'Startup settings saved successfully.'
            if (Test-CurrentAccountAllowed -Scope $scope -Account ([string]$accountCombo.SelectedItem)) {
                Start-BridgeNow
            } elseif ($scope -eq 'only') {
                $footerMessage.Text = "Startup is enabled; the bridge will start when $($accountCombo.SelectedItem) signs in."
            } else {
                $footerMessage.Text = 'Startup is enabled for other Windows accounts; this selected account is excluded.'
            }
        } else {
            $exitCode = Invoke-ElevatedPython -Arguments @('disable-startup')
            if ($exitCode -ne 0) { throw "Disabling startup returned exit code $exitCode." }
            $footerMessage.Text = 'Automatic startup has been disabled.'
            Refresh-BridgeStatus
        }
    } catch {
        $footerMessage.Text = 'Could not save startup settings.'
        [System.Windows.Forms.MessageBox]::Show($_.Exception.Message, 'MX01 Bridge Manager', [System.Windows.Forms.MessageBoxButtons]::OK, [System.Windows.Forms.MessageBoxIcon]::Warning) | Out-Null
    } finally {
        $applyButton.Enabled = $true
        Load-SettingsFromRegistry
    }
}

function Load-SettingsFromRegistry {
    $enabledValue = Get-RegistryValueSafe -Name 'StartupEnabled' -Default 0
    $autoStartCheck.Checked = ([string]$enabledValue -match '^(?i:1|true|yes)$')
    $scope = [string](Get-RegistryValueSafe -Name 'StartupScope' -Default 'only')
    switch ($scope.ToLowerInvariant()) {
        'except' { $scopeExcept.Checked = $true }
        'all' { $scopeAll.Checked = $true }
        default { $scopeOnly.Checked = $true }
    }
    Load-Accounts
    Update-AccountState
}

function Start-ConnectFlow {
    $connectButton.Enabled = $false
    $footerMessage.Text = 'Opening printer selection…'
    [System.Windows.Forms.Application]::DoEvents()
    try {
        if (-not (Test-Path -LiteralPath $script:Selector)) { throw "Printer selector was not found: $($script:Selector)" }
        $selectorArg = ConvertTo-NativeArgument $script:Selector
        Start-Process -FilePath $env:ComSpec -ArgumentList "/d /c call $selectorArg" -WindowStyle Normal -Wait
        Refresh-BridgeStatus
        if ($autoStartCheck.Checked) {
            $scope = if ($scopeOnly.Checked) { 'only' } elseif ($scopeExcept.Checked) { 'except' } else { 'all' }
            $arguments = @('install-startup', '--scope', $scope)
            if ($scope -ne 'all' -and $accountCombo.SelectedItem) { $arguments += @('--user', [string]$accountCombo.SelectedItem) }
            $footerMessage.Text = 'Applying startup settings…'
            [System.Windows.Forms.Application]::DoEvents()
            $exitCode = Invoke-ElevatedPython -Arguments $arguments
            if ($exitCode -ne 0) { throw "Bridge start/configuration returned exit code $exitCode." }
            if (Test-CurrentAccountAllowed -Scope $scope -Account ([string]$accountCombo.SelectedItem)) { Start-BridgeNow }
            $footerMessage.Text = 'Printer selection complete.'
        } else { $footerMessage.Text = 'Printer selection complete.' }
    } catch {
        $footerMessage.Text = 'Printer selection did not complete.'
        [System.Windows.Forms.MessageBox]::Show($_.Exception.Message, 'MX01 Bridge Manager', [System.Windows.Forms.MessageBoxButtons]::OK, [System.Windows.Forms.MessageBoxIcon]::Warning) | Out-Null
    } finally { $connectButton.Enabled = $true }
}

function New-Label {
    param([string]$Text, [int]$X, [int]$Y, [int]$Width, [int]$Height, [float]$Size = 9, [bool]$Bold = $false, [System.Drawing.Color]$Color = $script:Colors.Text)
    $label = New-Object System.Windows.Forms.Label
    $label.Text = $Text; $label.Location = New-Object System.Drawing.Point($X,$Y); $label.Size = New-Object System.Drawing.Size($Width,$Height)
    $style = if ($Bold) { [System.Drawing.FontStyle]::Bold } else { [System.Drawing.FontStyle]::Regular }
    $label.Font = New-Object System.Drawing.Font('Segoe UI',$Size,$style)
    $label.ForeColor = $Color; $label.BackColor = [System.Drawing.Color]::Transparent
    return $label
}

function New-Button {
    param([string]$Text, [int]$X, [int]$Y, [int]$Width, [int]$Height, [bool]$Primary = $false)
    $button = New-Object System.Windows.Forms.Button
    $button.Text = $Text; $button.Location = New-Object System.Drawing.Point($X,$Y); $button.Size = New-Object System.Drawing.Size($Width,$Height)
    $button.FlatStyle = [System.Windows.Forms.FlatStyle]::Flat
    $button.FlatAppearance.BorderSize = if ($Primary) { 0 } else { 1 }
    $button.FlatAppearance.BorderColor = $script:Colors.Border
    $button.BackColor = if ($Primary) { $script:Colors.TealDark } else { $script:Colors.PanelAlt }
    $button.ForeColor = $script:Colors.Text
    $button.Font = New-Object System.Drawing.Font('Segoe UI',9,[System.Drawing.FontStyle]::Bold)
    $button.Cursor = [System.Windows.Forms.Cursors]::Hand
    return $button
}

$form = New-Object System.Windows.Forms.Form
$form.Text = 'MX01 Bridge Manager'
$form.ClientSize = New-Object System.Drawing.Size(850,560)
$form.MinimumSize = New-Object System.Drawing.Size(866,599)
$form.MaximumSize = New-Object System.Drawing.Size(866,599)
$form.StartPosition = [System.Windows.Forms.FormStartPosition]::CenterScreen
$form.FormBorderStyle = [System.Windows.Forms.FormBorderStyle]::FixedSingle
$form.MaximizeBox = $false
$form.MinimizeBox = $true
$form.BackColor = $script:Colors.Background
$form.ForeColor = $script:Colors.Text
$form.Font = New-Object System.Drawing.Font('Segoe UI',9)
$iconPath = Join-Path $script:Root 'assets\mx01-bridge.ico'
if (Test-Path -LiteralPath $iconPath) { $form.Icon = [System.Drawing.Icon]::ExtractAssociatedIcon($iconPath) }

# Header
$headerAccent = New-Object System.Windows.Forms.Panel
$headerAccent.Location = New-Object System.Drawing.Point(0,0); $headerAccent.Size = New-Object System.Drawing.Size(850,5); $headerAccent.BackColor = $script:Colors.Teal
$form.Controls.Add($headerAccent)
$form.Controls.Add((New-Label 'MX01' 30 20 88 32 19 $true $script:Colors.Teal))
$form.Controls.Add((New-Label 'BRIDGE MANAGER' 108 27 225 23 10 $true $script:Colors.Text))
$form.Controls.Add((New-Label 'Printer connection and Windows startup settings' 30 57 540 22 9 $false $script:Colors.Muted))

# Status card
$statusCard = New-Object System.Windows.Forms.Panel
$statusCard.Location = New-Object System.Drawing.Point(30,91); $statusCard.Size = New-Object System.Drawing.Size(790,96)
$statusCard.BackColor = $script:Colors.Panel
$statusCard.BorderStyle = [System.Windows.Forms.BorderStyle]::FixedSingle
$form.Controls.Add($statusCard)
$statusCard.Controls.Add((New-Label 'BRIDGE STATUS' 20 13 170 20 8 $true $script:Colors.Muted))
$statusDot = New-Object System.Windows.Forms.Panel
$statusDot.Location = New-Object System.Drawing.Point(20,45); $statusDot.Size = New-Object System.Drawing.Size(10,10); $statusDot.BackColor = $script:Colors.Red
$statusCard.Controls.Add($statusDot)
$statusValue = New-Label 'CHECKING' 39 37 190 25 13 $true $script:Colors.Muted
$statusCard.Controls.Add($statusValue)
$statusMessage = New-Label 'Checking bridge status…' 238 41 420 22 9 $false $script:Colors.Muted
$statusCard.Controls.Add($statusMessage)
$connectButton = New-Button 'Connect' 679 28 92 38 $true
$statusCard.Controls.Add($connectButton)

# Startup configuration card
$settingsCard = New-Object System.Windows.Forms.Panel
$settingsCard.Location = New-Object System.Drawing.Point(30,202); $settingsCard.Size = New-Object System.Drawing.Size(790,254)
$settingsCard.BackColor = $script:Colors.Panel
$settingsCard.BorderStyle = [System.Windows.Forms.BorderStyle]::FixedSingle
$form.Controls.Add($settingsCard)
$settingsCard.Controls.Add((New-Label 'AUTOMATIC STARTUP' 20 16 250 22 9 $true $script:Colors.Muted))

$autoStartCheck = New-Object System.Windows.Forms.CheckBox
$autoStartCheck.Text = 'Start the MX01 bridge automatically with Windows'
$autoStartCheck.Location = New-Object System.Drawing.Point(20,46); $autoStartCheck.Size = New-Object System.Drawing.Size(500,28)
$autoStartCheck.Font = New-Object System.Drawing.Font('Segoe UI',10,[System.Drawing.FontStyle]::Bold)
$autoStartCheck.ForeColor = $script:Colors.Text; $autoStartCheck.BackColor = [System.Drawing.Color]::Transparent
$autoStartCheck.FlatStyle = [System.Windows.Forms.FlatStyle]::Flat
$settingsCard.Controls.Add($autoStartCheck)

$settingsCard.Controls.Add((New-Label 'Choose which Windows accounts should use the bridge:' 20 85 500 20 9 $false $script:Colors.Muted))
$scopeOnly = New-Object System.Windows.Forms.RadioButton
$scopeOnly.Text = 'Selected user only'; $scopeOnly.Location = New-Object System.Drawing.Point(23,113); $scopeOnly.Size = New-Object System.Drawing.Size(235,24)
$scopeExcept = New-Object System.Windows.Forms.RadioButton
$scopeExcept.Text = 'All except selected user'; $scopeExcept.Location = New-Object System.Drawing.Point(23,145); $scopeExcept.Size = New-Object System.Drawing.Size(235,24)
$scopeAll = New-Object System.Windows.Forms.RadioButton
$scopeAll.Text = 'All Windows users'; $scopeAll.Location = New-Object System.Drawing.Point(23,177); $scopeAll.Size = New-Object System.Drawing.Size(235,24)
foreach ($radio in @($scopeOnly,$scopeExcept,$scopeAll)) {
    $radio.Font = New-Object System.Drawing.Font('Segoe UI',9)
    $radio.ForeColor = $script:Colors.Text; $radio.BackColor = [System.Drawing.Color]::Transparent
    $settingsCard.Controls.Add($radio)
}

$accountCaption = New-Label 'WINDOWS ACCOUNT' 328 112 220 20 8 $true $script:Colors.Muted
$settingsCard.Controls.Add($accountCaption)
$accountCombo = New-Object System.Windows.Forms.ComboBox
$accountCombo.Location = New-Object System.Drawing.Point(326,137); $accountCombo.Size = New-Object System.Drawing.Size(420,31)
$accountCombo.DropDownStyle = [System.Windows.Forms.ComboBoxStyle]::DropDownList
$accountCombo.FlatStyle = [System.Windows.Forms.FlatStyle]::Flat
$accountCombo.BackColor = $script:Colors.PanelAlt; $accountCombo.ForeColor = $script:Colors.Text
$accountCombo.Font = New-Object System.Drawing.Font('Segoe UI',9)
$settingsCard.Controls.Add($accountCombo)
$accountHint = New-Label 'Accounts are discovered from local Windows profiles.' 327 176 420 22 8 $false $script:Colors.Muted
$settingsCard.Controls.Add($accountHint)
$settingsCard.Controls.Add((New-Label 'Changes may require administrator approval.' 20 218 450 18 8 $false $script:Colors.Muted))

# Actions and explanatory footer
$refreshButton = New-Button 'Refresh' 30 474 105 40 $false
$applyButton = New-Button 'Apply / Save' 674 474 146 40 $true
$footerMessage = New-Label 'Manage bridge connection and Windows startup settings.' 30 524 770 20 8 $false $script:Colors.Muted
$form.Controls.Add($refreshButton); $form.Controls.Add($applyButton); $form.Controls.Add($footerMessage)

$refreshButton.Add_Click({ Refresh-BridgeStatus })
$connectButton.Add_Click({ Start-ConnectFlow })
$applyButton.Add_Click({ Save-StartupConfiguration })
$scopeOnly.Add_CheckedChanged({ if ($scopeOnly.Checked) { Update-AccountState } })
$scopeExcept.Add_CheckedChanged({ if ($scopeExcept.Checked) { Update-AccountState } })
$scopeAll.Add_CheckedChanged({ if ($scopeAll.Checked) { Update-AccountState } })

try { Load-SettingsFromRegistry } catch { $footerMessage.Text = 'Settings could not be loaded; defaults are shown.' }
$form.Add_Shown({ Refresh-BridgeStatus })
[void]$form.ShowDialog()
$form.Dispose()
