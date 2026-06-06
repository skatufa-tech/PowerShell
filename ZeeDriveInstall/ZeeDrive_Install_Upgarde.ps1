# ==============================================================================
# ZEEDRIVE INSTALL / UPDATE SCRIPT (PRODUCTION SAFE)
# Compatible with NinjaOne RMM - runs as SYSTEM, UI via RunAsUser module
# Version: 1.6  |  Date: 2026-04-23
# ==============================================================================
#

#
# RUN AS: SYSTEM (from NinjaOne scheduled task)
#
# DETECTION:
#   ZeeDrive installs to:
#     C:\Program Files\Thinkscape Zee Drive\[version]\ZeeDrive.exe  (v65.3+)
#     C:\Program Files (x86)\Thinkscape Zee Drive\[version]\ZeeDrive.exe (older)
#   The folder name IS the version (e.g. 68.19.0.0).
#   No standard Uninstall registry key is written by ZeeDrive.

#
# SCENARIOS:
#   A - Not installed     -> Download + Install -> popup "contact support"
#   B - Installed, latest -> Log and exit, no action
#   C - Installed, old    -> Download + Install (SYSTEM) +
#                            Update (user via RunAsUser) +
#                            popup "sign out now / later"
#
# EXIT CODES:  0 = success / no action needed    1 = error
# ==============================================================================

$ScriptVersion = "1.6"
$WorkDir       = "$env:ProgramData\ZeeDriveDeploy"
$Log           = "$WorkDir\ZeeDeploy.log"
$InstallerPath = "$WorkDir\ZeeDrive_New.exe"
$UIScriptPath  = "$WorkDir\ZeeDriveUI.ps1"

# Full path required - ServiceUI's CreateProcessAsUser does not inherit PATH

$InstallBase64 = "C:\Program Files\Thinkscape Zee Drive"
$InstallBase32 = "C:\Program Files (x86)\Thinkscape Zee Drive"
$DownloadPage  = "https://docs.zeedrive.com/resources/download"
$BlobBase      = "https://thinkscapestorage.blob.core.windows.net/zeedrive"

# ==============================================================================
# LOGGING
# ==============================================================================
if (-not (Test-Path $WorkDir)) {
    New-Item -ItemType Directory -Path $WorkDir -Force | Out-Null
}

function Write-Log {
    param([string]$Message, [string]$Level = "INFO")
    $ts = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    $entry = "$ts [$Level] $Message"
    $entry | Out-File $Log -Append -Encoding utf8
    # Write-Host instead of Write-Output so log lines are NEVER captured
    # into variables when functions are called with $var = FunctionName()
    Write-Host $entry
}

Write-Log "===== ZeeDrive Deploy Script v$ScriptVersion Started ====="

# ==============================================================================
# SERVICEUI CHECK
<# ==============================================================================
$ServiceUIAvailable = Test-Path $ServiceUI
if ($ServiceUIAvailable) {
    Write-Log "ServiceUI.exe found."
} else {
    Write-Log "ServiceUI.exe NOT found at $ServiceUI - popups will be skipped." "WARN"
}#>

# ==============================================================================
# DETECT ACTIVE CONSOLE USER
# ==============================================================================
$ActiveUser = $null
$Explorer   = Get-Process explorer -IncludeUserName -ErrorAction SilentlyContinue |
              Select-Object -First 1

if ($Explorer) {
    $ActiveUser = $Explorer.UserName
    Write-Log "Active console user: $ActiveUser  (Session: $($Explorer.SessionId))"
} else {
    Write-Log "No active console user detected. Popups will be skipped." "WARN"
}


function Install-RunAsUserModule {

    try {

        if (-not (Get-Module -ListAvailable -Name RunAsUser)) {

            Write-Log "RunAsUser module not found. Installing..."

            if (-not (Get-PackageProvider -Name NuGet -ErrorAction SilentlyContinue)) {
                Install-PackageProvider -Name NuGet -MinimumVersion 2.8.5.201 -Force
            }

            Set-PSRepository PSGallery -InstallationPolicy Trusted -ErrorAction SilentlyContinue

            Install-Module RunAsUser -Force -AllowClobber -Scope AllUsers
        }

        Import-Module RunAsUser -Force
        Write-Log "RunAsUser module loaded."
        return $true
    }
    catch {
        Write-Log "Failed to install/load RunAsUser module: $_" "ERROR"
        return $false
    }
}

# ==============================================================================
# FUNCTION: SHOW POPUP VIA RUNASUSER
#
# ServiceUI v1.3 requires the full path to the executable because
# CreateProcessAsUser does not inherit the system PATH variable.
# Syntax: ServiceUI.exe -process:explorer.exe "C:\full\path\to\app.exe" "args"
# ==============================================================================

function Show-UserPopup {

    param([string]$PopupScript)

    if (-not $ActiveUser) {
        Write-Log "No active user - skipping popup." "WARN"
        return
    }

    if (-not (Install-RunAsUserModule)) {
        Write-Log "RunAsUser unavailable - skipping popup." "WARN"
        return
    }

    try {

        $TempScript = "$WorkDir\ZeeDriveUI.ps1"

        $PopupScript | Out-File -FilePath $TempScript -Encoding UTF8 -Force

        Invoke-AsCurrentUser -ScriptBlock {

            powershell.exe `
                -ExecutionPolicy Bypass `
                -WindowStyle Hidden `
                -File "C:\ProgramData\ZeeDriveDeploy\ZeeDriveUI.ps1"

        }

        Write-Log "Popup launched using RunAsUser."
    }
    catch {

        Write-Log "RunAsUser popup failed: $_" "ERROR"

        try {
            msg.exe * "ZeeDrive installation/update completed. Please check ZeeDrive."
            Write-Log "Fallback msg.exe notification displayed."
        }
        catch {
            Write-Log "Fallback notification also failed: $_" "ERROR"
        }
    }
}


# ==============================================================================
# FUNCTION: DETECT INSTALLED ZEEDRIVE VERSION
# Scans both Program Files paths for versioned subfolders containing ZeeDrive.exe
# Returns highest version string (e.g. "68.19.0.0") or $null if not found.
# ==============================================================================
function Get-InstalledZeeDriveVersion {
    $found = @()
    foreach ($base in @($InstallBase64, $InstallBase32)) {
        if (-not (Test-Path $base)) { continue }
        foreach ($folder in (Get-ChildItem -Path $base -Directory -ErrorAction SilentlyContinue)) {
            $exe = Join-Path $folder.FullName "ZeeDrive.exe"
            if (Test-Path $exe) {
                Write-Log "Found installation: $($folder.FullName)"
                $found += $folder.Name    # folder name = version e.g. "68.19.0.0"
            }
        }
    }

    if ($found.Count -eq 0) { return $null }

    $highest = $found | Sort-Object {
        try { [System.Version]$_ } catch { [System.Version]"0.0.0.0" }
    } -Descending | Select-Object -First 1

    Write-Log "Detected installed version: $highest"
    return $highest
}

# ==============================================================================
# FUNCTION: GET LATEST VERSION FROM ZEEDRIVE DOWNLOAD PAGE
# Returns hashtable: @{ VersionFull; DownloadUrl } or $null on failure.
# ==============================================================================
function Get-LatestZeeDriveVersion {
    Write-Log "Fetching ZeeDrive download page..."
    try {
        $html    = (Invoke-WebRequest -Uri $DownloadPage -UseBasicParsing -TimeoutSec 30).Content
        $rx      = [regex]'Version-(\d+\.\d+)\.0\.0/ZeeDrive\.exe'
        $matches = $rx.Matches($html)

        if ($matches.Count -eq 0) {
            Write-Log "Could not parse version from download page." "ERROR"
            return $null
        }

        # Page is ordered newest-first; first match = latest
        $short = $matches[0].Groups[1].Value          # e.g. "68.19"
        $full  = "$short.0.0"                          # e.g. "68.19.0.0"
        $url   = "$BlobBase/Version-$full/ZeeDrive.exe"

        Write-Log "Latest available version: $full"
        Write-Log "Download URL: $url"
        return @{ VersionFull = $full; DownloadUrl = $url }
    }
    catch {
        Write-Log "Failed to fetch download page: $_" "ERROR"
        return $null
    }
}

# ==============================================================================
# FUNCTION: COMPARE VERSIONS
# Returns: negative = installed older, 0 = same, positive = installed newer
# ==============================================================================
function Compare-Versions {
    param([string]$Installed, [string]$Latest)
    try {
        return ([System.Version]$Installed).CompareTo([System.Version]$Latest)
    }
    catch {
        Write-Log "Version comparison error (installed='$Installed' latest='$Latest'): $_" "WARN"
        return 0
    }
}

# ==============================================================================
# FUNCTION: DOWNLOAD FILE
# ==============================================================================
function Download-File {
    param([string]$Url, [string]$Dest)
    Write-Log "Downloading $Url ..."
    try {
        (New-Object System.Net.WebClient).DownloadFile($Url, $Dest)
        Write-Log "Download complete. Size: $((Get-Item $Dest).Length) bytes."
        return $true
    }
    catch {
        Write-Log "Download failed: $_" "ERROR"
        return $false
    }
}

# ==============================================================================
# FUNCTION: RUN ZEEDRIVE COMMAND (always in SYSTEM context = current context)
# ==============================================================================
function Invoke-ZeeDriveCommand {
    param([string]$ExePath, [string]$Command)
    Write-Log "Running: $ExePath Command=$Command"
    try {
        $proc = Start-Process -FilePath $ExePath -ArgumentList "Command=$Command" `
                              -Wait -PassThru -NoNewWindow -ErrorAction Stop
        Write-Log "Command=$Command exit code: $($proc.ExitCode)"
        return $proc.ExitCode
    }
    catch {
        Write-Log "Exception running Command=$Command : $_" "ERROR"
        return 1
    }
}

# ==============================================================================
# POPUP: SCENARIO A - Fresh install, tell user to contact support
# ==============================================================================
$PopupInstall = @'
Add-Type -AssemblyName PresentationFramework
Add-Type -AssemblyName PresentationCore
Add-Type -AssemblyName WindowsBase

[xml]$xaml = @"
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        Title="ZeeDrive Installed" Height="210" Width="460"
        WindowStartupLocation="CenterScreen" ResizeMode="NoResize" Topmost="True">
    <Grid Margin="20">
        <Grid.RowDefinitions>
            <RowDefinition Height="Auto"/>
            <RowDefinition Height="*"/>
            <RowDefinition Height="Auto"/>
        </Grid.RowDefinitions>
        <TextBlock Grid.Row="0" FontSize="15" FontWeight="Bold" Margin="0,0,0,10"
                   Foreground="#1A73E8" Text="ZeeDrive Has Been Installed"/>
        <TextBlock Grid.Row="1" TextWrapping="Wrap" FontSize="13" LineHeight="22"
                   Text="ZeeDrive has been successfully installed on your computer. To set it up and connect your network drives, please contact IT Support."/>
        <Button Grid.Row="2" Name="OkBtn" Content="OK" Width="90"
                HorizontalAlignment="Right" Margin="0,14,0,0" FontSize="13" Padding="8,4"/>
    </Grid>
</Window>
"@
$reader = [System.Xml.XmlNodeReader]::new($xaml)
$win    = [System.Windows.Markup.XamlReader]::Load($reader)
$win.FindName("OkBtn").Add_Click({ $win.Close() })
$win.ShowDialog() | Out-Null
'@

# ==============================================================================
# POPUP BUILDER: SCENARIO C
# Runs Command=Update in user context first, then shows sign out popup.
# Injecting $InstallerPath and $Log via function parameters avoids
# escaping issues with paths inside here-strings.
# ==============================================================================
function Build-UpdateScript {
    param([string]$ExePath, [string]$LogPath)
    return @"
`$installerPath = '$ExePath'
`$logPath       = '$LogPath'

function Write-UILog(`$msg) {
    `$t = Get-Date -Format 'yyyy-MM-dd HH:mm:ss'
    "`$t [UI] `$msg" | Out-File `$logPath -Append -Encoding utf8
}

Write-UILog 'User session: Running ZeeDrive Command=Update...'
try {
    `$p = Start-Process -FilePath `$installerPath ``
                        -ArgumentList 'Command=Update' ``
                        -Wait -PassThru -NoNewWindow -ErrorAction Stop
    Write-UILog "Command=Update exit code: `$(`$p.ExitCode)"
    Write-UILog "Command=Update PID: $($p.Id)"
    Write-UILog "Command=Update ExitCode: $($p.ExitCode)"
    # Exit codes: 0 or 10 = success, anything else = error
    # We show the popup regardless - the update install step already succeeded.
    # Command=Update only updates the HKCU Run key; even if it fails the new
    # version is installed and the user needs to be told to sign out.
    `$ok = `$true
}
catch {
    Write-UILog "Command=Update exception: `$_"
    `$ok = `$true   # Still show popup - install succeeded even if Update key failed
}

Add-Type -AssemblyName PresentationFramework
Add-Type -AssemblyName PresentationCore
Add-Type -AssemblyName WindowsBase

if (`$ok) {
    [xml]`$xaml = @'
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        Title="ZeeDrive Updated" Height="235" Width="500"
        WindowStartupLocation="CenterScreen" ResizeMode="NoResize" Topmost="True">
    <Grid Margin="20">
        <Grid.RowDefinitions>
            <RowDefinition Height="Auto"/>
            <RowDefinition Height="*"/>
            <RowDefinition Height="Auto"/>
        </Grid.RowDefinitions>
        <TextBlock Grid.Row="0" FontSize="15" FontWeight="Bold" Margin="0,0,0,10"
                   Foreground="#1A73E8" Text="ZeeDrive Has Been Updated"/>
        <TextBlock Grid.Row="1" TextWrapping="Wrap" FontSize="13" LineHeight="22"
                   Text="ZeeDrive has been updated to the latest version. To activate the new version, please sign out of Windows and sign back in again."/>
        <StackPanel Grid.Row="2" Orientation="Horizontal" HorizontalAlignment="Right" Margin="0,14,0,0">
            <Button Name="LaterBtn" Content="Sign out later" Width="130"
                    Margin="0,0,10,0" FontSize="13" Padding="8,4"/>
            <Button Name="NowBtn" Content="Sign out now" Width="130"
                    FontSize="13" Padding="8,4" Background="#1A73E8" Foreground="White"/>
        </StackPanel>
    </Grid>
</Window>
'@
    `$reader = [System.Xml.XmlNodeReader]::new(`$xaml)
    `$win    = [System.Windows.Markup.XamlReader]::Load(`$reader)
    `$win.FindName('LaterBtn').Add_Click({ `$win.Close() })
    `$win.FindName('NowBtn').Add_Click({ `$win.Close(); Start-Sleep 2; logoff })
    `$win.ShowDialog() | Out-Null
    Write-UILog 'Update popup dismissed by user.'
}
else {
    Write-UILog 'Popup skipped (should not reach here).'
}
"@
}

# ==============================================================================
# MAIN
# ==============================================================================

# --- Detect installed version ---
$installedVersion = Get-InstalledZeeDriveVersion

if ($installedVersion) {
    Write-Log "ZeeDrive is installed. Clean version: [$installedVersion]"
} else {
    Write-Log "ZeeDrive is NOT installed."
}

# --- Get latest available version ---
$latest = Get-LatestZeeDriveVersion
if (-not $latest) {
    Write-Log "Cannot determine latest version. Exiting." "ERROR"
    exit 1
}

# ==========================================================================
# SCENARIO A: NOT INSTALLED -> Fresh Install
# ==========================================================================
if (-not $installedVersion) {
    Write-Log "--- SCENARIO A: Fresh Install ---"

    if (-not (Download-File -Url $latest.DownloadUrl -Dest $InstallerPath)) {
        Write-Log "Aborting - download failed." "ERROR"
        exit 1
    }

    $code = Invoke-ZeeDriveCommand -ExePath $InstallerPath -Command "Install"

    if ($code -eq 10 -or $code -eq 0 -or $code -eq 11) {
        Write-Log "Install succeeded (exit code: $code)."
        if ($code -eq 11) { Write-Log "Note: reboot may be required." "WARN" }
        Write-Log "Showing 'contact support' popup..."
        Show-UserPopup -PopupScript $PopupInstall
        Write-Log "--- Scenario A complete ---"
        exit 0
    }
    else {
        Write-Log "Install failed (exit code: $code)." "ERROR"
        exit 1
    }
}

# ==========================================================================
# SCENARIO B: INSTALLED AND UP TO DATE -> No action
# ==========================================================================
$cmp = Compare-Versions -Installed $installedVersion -Latest $latest.VersionFull

if ($cmp -ge 0) {
    Write-Log "--- SCENARIO B: Already up to date ---"
    Write-Log "Installed: [$installedVersion]  |  Latest: [$($latest.VersionFull)]"
    Write-Log "No action required."
    exit 0
}

# ==========================================================================
# SCENARIO C: UPDATE REQUIRED
# ==========================================================================
Write-Log "--- SCENARIO C: Update Required ---"
Write-Log "Installed : [$installedVersion]  ->  Available: [$($latest.VersionFull)]"

if (-not (Download-File -Url $latest.DownloadUrl -Dest $InstallerPath)) {
    Write-Log "Aborting - download failed." "ERROR"
    exit 1
}

# Step 1/2: Install new version files as SYSTEM
$installCode = Invoke-ZeeDriveCommand -ExePath $InstallerPath -Command "Install"
if ($installCode -ne 10 -and $installCode -ne 0 -and $installCode -ne 11) {
    Write-Log "Install step failed (exit code: $installCode). Aborting." "ERROR"
    exit 1
}
Write-Log "Install step (1/2) succeeded (exit code: $installCode)."

# Locate the newly installed exe from Program Files.
# Command=Update MUST run from the newly installed version's exe in Program Files,
# NOT from the downloaded ZeeDrive_New.exe in WorkDir. Running it from the wrong
# path is what causes exit code 1.
$newVersionFull  = $latest.VersionFull
$newInstalledExe = $null

foreach ($base in @($InstallBase64, $InstallBase32)) {
    $candidate = Join-Path $base "$newVersionFull\ZeeDrive.exe"
    if (Test-Path $candidate) {
        $newInstalledExe = $candidate
        break
    }
}

if (-not $newInstalledExe) {
    Write-Log "Cannot find newly installed ZeeDrive.exe at expected path under Program Files." "ERROR"
    Write-Log "Expected: $InstallBase64\$newVersionFull\ZeeDrive.exe" "ERROR"
    exit 1
}

Write-Log "New installed exe located: $newInstalledExe"

# Step 2/2: Command=Update runs in USER context via ServiceUI.
# It updates the HKCU Run registry key to point to the new version.
# Must use the newly installed exe path - running from any other path returns exit code 1.
Write-Log "Launching user-context Update + popup via RunAsUserModule (step 2/2)..."
$updateScript = Build-UpdateScript -ExePath $newInstalledExe -LogPath $Log
Show-UserPopup -PopupScript $updateScript

# Clean up old version folders now that update is complete.
# ZeeDrive's Command=Install does not remove previous version folders.
<#Write-Log "Cleaning up old ZeeDrive version folders..."
foreach ($base in @($InstallBase64, $InstallBase32)) {
    if (-not (Test-Path $base)) { continue }
    foreach ($folder in (Get-ChildItem -Path $base -Directory -ErrorAction SilentlyContinue)) {
        if ($folder.Name -ne $newVersionFull) {
            Write-Log "Removing old version folder: $($folder.FullName)"
            try {
                Remove-Item -Path $folder.FullName -Recurse -Force -ErrorAction Stop
                Write-Log "Removed: $($folder.FullName)"
            }
            catch {
                Write-Log "Could not remove $($folder.FullName): $_" "WARN"
            }
        }
    }
}
#>
Write-Log "--- Scenario C complete ---"
Write-Log "===== ZeeDrive Deploy Script v$ScriptVersion Finished ====="
exit 0
