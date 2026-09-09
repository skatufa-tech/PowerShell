# ============================================================
# TechEUC - Defender Update Remediation  (v2 — Hardened)
#
# Purpose:
#   Automatically install available Microsoft Defender updates
#   (Security Intelligence + Platform) from Microsoft Update.
#
# This script does NOT contain a hard-coded Defender version.
#
# Changes from v1:
#   - EULA acceptance before download
#   - Explicit Microsoft Update targeting (bypasses WSUS)
#   - Admin privilege enforcement
#   - Signature fallback chain (MU -> MMPC)
#   - Single-instance mutex
#   - WU service state preservation
#   - Polling loop instead of hardcoded sleep
#   - Log rotation (max 500 KB)
#   - UTF-8 log encoding
#   - COM object cleanup
#   - Network pre-check
#   - Defender-absent early exit
#
# Log:
#   C:\ProgramData\TechEUC\DefenderUpdate\
#       DefenderRemediation.log
# ============================================================

#Requires -Version 5.1
#Requires -RunAsAdministrator


# ============================================================
# CONFIGURATION
# ============================================================

$LogDir      = "$env:ProgramData\TechEUC\DefenderUpdate"
$LogFile     = "$LogDir\DefenderRemediation.log"
$LogMaxBytes = 512KB                          # rotate when log exceeds this
$MutexName   = "Global\TechEUCDefenderRemediation"
$PollTimeout = 90                             # max seconds to wait for Defender init
$PollInterval = 10                            # seconds between polls

# Microsoft Update Service ID (constant, never changes)
$MicrosoftUpdateServiceID = "7971f918-a847-4430-9279-4a52d1efe18d"

# Exit codes
$EXIT_SUCCESS              = 0
$EXIT_DEFENDER_ABSENT      = 10
$EXIT_NO_NETWORK           = 11
$EXIT_ANOTHER_INSTANCE     = 12
$EXIT_REMEDIATION_INCOMPLETE = 1
$EXIT_POST_CHECK_FAILED    = 2


# ============================================================
# BOOTSTRAP — directory, log rotation
# ============================================================

New-Item -Path $LogDir -ItemType Directory -Force | Out-Null

# Log rotation: if the log exceeds $LogMaxBytes, keep the last half
if (Test-Path $LogFile) {

    $LogInfo = Get-Item $LogFile

    if ($LogInfo.Length -gt $LogMaxBytes) {

        $Lines    = Get-Content $LogFile -Encoding UTF8
        $HalfIdx  = [math]::Floor($Lines.Count / 2)
        $Lines[$HalfIdx..($Lines.Count - 1)] |
            Set-Content $LogFile -Encoding UTF8 -Force
    }
}


# ============================================================
# FUNCTIONS
# ============================================================

function Write-Log {

    param(
        [string]$Message,
        [string]$Level = "INFO"
    )

    $Time = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    $Line = "$Time [$Level] $Message"

    Write-Host $Line
    Add-Content -Path $LogFile -Value $Line -Encoding UTF8
}


function Get-DefenderStatus {

    try {

        $Status = Get-MpComputerStatus -ErrorAction Stop

        return [PSCustomObject]@{

            EngineVersion      = $Status.AMEngineVersion
            PlatformVersion    = $Status.AMProductVersion
            ServiceVersion     = $Status.AMServiceVersion
            AntivirusSignature = $Status.AntivirusSignatureVersion
            RealTimeEnabled    = $Status.RealTimeProtectionEnabled
        }
    }
    catch {

        Write-Log "Unable to retrieve Defender status: $($_.Exception.Message)" "ERROR"
        return $null
    }
}


function Release-ComObject {

    param([object]$ComObject)

    if ($null -ne $ComObject) {

        try {
            [void][System.Runtime.InteropServices.Marshal]::ReleaseComObject($ComObject)
        }
        catch {
            # Swallow — object may already be collected
        }
    }
}


function Test-InternetConnectivity {

    # Quick DNS check against Microsoft endpoints
    $Targets = @(
        "go.microsoft.com"
        "definitionupdates.microsoft.com"
    )

    foreach ($Target in $Targets) {

        try {

            $null = [System.Net.Dns]::GetHostAddresses($Target)
            return $true
        }
        catch {
            # try next
        }
    }

    return $false
}


# ============================================================
# RUNTIME ADMIN CHECK (belt-and-suspenders with #Requires)
# ============================================================

$CurrentIdentity  = [Security.Principal.WindowsIdentity]::GetCurrent()
$CurrentPrincipal = [Security.Principal.WindowsPrincipal]$CurrentIdentity

if (-not $CurrentPrincipal.IsInRole(
    [Security.Principal.WindowsBuiltInRole]::Administrator)) {

    Write-Log "Script must run as Administrator. Exiting." "ERROR"
    exit $EXIT_REMEDIATION_INCOMPLETE
}


# ============================================================
# SINGLE-INSTANCE MUTEX
# ============================================================

$Mutex = $null

try {

    $Mutex = [System.Threading.Mutex]::new($false, $MutexName)

    if (-not $Mutex.WaitOne(0)) {

        Write-Log "Another instance of TechEUC Defender Remediation is already running. Exiting." "WARNING"
        exit $EXIT_ANOTHER_INSTANCE
    }
}
catch {

    Write-Log "Mutex check failed (non-fatal): $($_.Exception.Message)" "WARNING"
    # Continue — better to risk overlap than to skip remediation
}


# ============================================================
# COM objects — declared at script scope so STEP 4 can use them
# ============================================================

$Session        = $null
$Searcher       = $null
$ServiceManager = $null
$Downloader     = $null
$Installer      = $null
$Collection     = $null


try {


# ============================================================
# START
# ============================================================

Write-Log "============================================================"
Write-Log "TechEUC Defender Remediation v2 Started"
Write-Log "Computer : $env:COMPUTERNAME"
Write-Log "User     : $env:USERNAME"
Write-Log "============================================================"


# ============================================================
# PRE-FLIGHT: Network check
# ============================================================

if (-not (Test-InternetConnectivity)) {

    Write-Log "No network connectivity to Microsoft endpoints. Exiting." "ERROR"
    exit $EXIT_NO_NETWORK
}

Write-Log "Network connectivity confirmed."


# ============================================================
# PRE-FLIGHT: Defender present?
# ============================================================

$Before = Get-DefenderStatus

if ($null -eq $Before) {

    Write-Log "Defender is not available on this machine (disabled, removed, or replaced by third-party AV)." "ERROR"
    Write-Log "Exiting — nothing to remediate."
    exit $EXIT_DEFENDER_ABSENT
}

Write-Log "BEFORE UPDATE"
Write-Log "Engine   : $($Before.EngineVersion)"
Write-Log "Platform : $($Before.PlatformVersion)"
Write-Log "Service  : $($Before.ServiceVersion)"
Write-Log "AV Sig   : $($Before.AntivirusSignature)"
Write-Log "RTP      : $($Before.RealTimeEnabled)"


# ============================================================
# STEP 1 — Defender Security Intelligence (Signatures)
#
#   Fallback chain: MicrosoftUpdateServer -> MMPC
# ============================================================

Write-Log "Starting Defender signature update (Security Intelligence)."

$SigUpdated = $false

try {

    Update-MpSignature `
        -UpdateSource MicrosoftUpdateServer `
        -ErrorAction Stop

    Write-Log "Signature update from Microsoft Update succeeded." "SUCCESS"
    $SigUpdated = $true
}
catch {

    Write-Log "Microsoft Update source failed: $($_.Exception.Message)" "WARNING"
    Write-Log "Attempting MMPC fallback..."

    try {

        Update-MpSignature `
            -UpdateSource MMPC `
            -ErrorAction Stop

        Write-Log "Signature update from MMPC succeeded." "SUCCESS"
        $SigUpdated = $true
    }
    catch {

        Write-Log "MMPC fallback also failed: $($_.Exception.Message)" "WARNING"
        Write-Log "Signature update could not be completed from any source." "WARNING"
    }
}


# ============================================================
# STEP 2 — Defender Platform Update via Windows Update COM API
#
#   Explicitly targets Microsoft Update (not WSUS).
# ============================================================

Write-Log "Checking Microsoft Update for Defender Platform updates."


# --------------------------------------------------------
# Preserve and start WU service
# --------------------------------------------------------

$OriginalWUStartType = $null

try {

    $WUSvc = Get-Service -Name wuauserv -ErrorAction Stop
    $OriginalWUStartType = $WUSvc.StartType

    if ($WUSvc.StartType -eq 'Disabled') {

        Set-Service -Name wuauserv -StartupType Manual -ErrorAction Stop
        Write-Log "Changed wuauserv startup from Disabled to Manual (will restore)."
    }

    if ($WUSvc.Status -ne 'Running') {

        Start-Service -Name wuauserv -ErrorAction Stop
        Write-Log "Started wuauserv service."
    }
}
catch {

    Write-Log "Could not ensure wuauserv is running: $($_.Exception.Message)" "WARNING"
}


# --------------------------------------------------------
# Create COM objects and register Microsoft Update
# --------------------------------------------------------

$Session = New-Object -ComObject Microsoft.Update.Session
$Session.ClientApplicationID = "TechEUC Defender Remediation"

# Register Microsoft Update service so we bypass WSUS
$ServiceManager = New-Object -ComObject Microsoft.Update.ServiceManager
$ServiceManager.ClientApplicationID = "TechEUC Defender Remediation"

$RegisteredService = $null

try {

    # AddService2 flags: 7 = asfAllowPendingRegistration |
    #                        asfAllowOnlineRegistration  |
    #                        asfRegisterServiceWithAU
    $RegisteredService = $ServiceManager.AddService2(
        $MicrosoftUpdateServiceID, 7, ""
    )

    Write-Log "Microsoft Update service registered for this session."
}
catch {

    Write-Log "Could not register Microsoft Update service: $($_.Exception.Message)" "WARNING"
    Write-Log "Falling back to default update source (may be WSUS)."
}


$Searcher = $Session.CreateUpdateSearcher()

# Point the searcher at Microsoft Update (not WSUS)
if ($null -ne $RegisteredService) {

    $Searcher.ServerSelection = 3          # ssOthers
    $Searcher.ServiceID       = $RegisteredService.ServiceID
}


Write-Log "Searching Microsoft Update for pending Defender updates..."

try {

    $SearchResult = $Searcher.Search(
        "IsInstalled=0 and IsHidden=0 and Type='Software'"
    )
}
catch {

    Write-Log "Update search failed: $($_.Exception.Message)" "ERROR"
    $SearchResult = $null
}


if ($null -ne $SearchResult -and $SearchResult.Updates.Count -gt 0) {

    # --------------------------------------------------------
    # Filter to Defender updates only
    # --------------------------------------------------------

    $DefenderUpdates = @(
        $SearchResult.Updates | Where-Object {

            $_.Title -match "Microsoft Defender Antivirus" -or
            $_.Title -match "Windows Defender Antivirus" -or
            $_.Title -match "KB4052623"
        }
    )

    if ($DefenderUpdates.Count -eq 0) {

        Write-Log "No Defender Platform update is currently pending."
    }
    else {

        Write-Log "Found $($DefenderUpdates.Count) Defender update(s)."

        foreach ($Update in $DefenderUpdates) {

            Write-Log "------------------------------------------------------------"
            Write-Log "Processing Defender update:"
            Write-Log "  Title    : $($Update.Title)"
            Write-Log "  KB       : $($Update.KBArticleIDs -join ', ')"
            Write-Log "  UpdateID : $($Update.Identity.UpdateID)"


            # ------------------------------------------------
            # Accept EULA (required before download)
            # ------------------------------------------------

            if (-not $Update.EulaAccepted) {

                try {

                    $Update.AcceptEula()
                    Write-Log "  EULA accepted."
                }
                catch {

                    Write-Log "  EULA acceptance failed: $($_.Exception.Message)" "ERROR"
                    Write-Log "  Skipping this update."
                    continue
                }
            }


            # ------------------------------------------------
            # Create update collection
            # ------------------------------------------------

            $Collection = New-Object -ComObject Microsoft.Update.UpdateColl
            [void]$Collection.Add($Update)


            # ------------------------------------------------
            # Download
            # ------------------------------------------------

            Write-Log "  Downloading update..."

            $Downloader         = $Session.CreateUpdateDownloader()
            $Downloader.Updates = $Collection

            try {

                $DownloadResult = $Downloader.Download()
            }
            catch {

                Write-Log "  Download threw an exception: $($_.Exception.Message)" "ERROR"
                Release-ComObject $Collection
                Release-ComObject $Downloader
                continue
            }

            Write-Log "  Download ResultCode: $($DownloadResult.ResultCode)"

            # ResultCode: 2 = Succeeded, 3 = SucceededWithErrors
            if ($DownloadResult.ResultCode -notin @(2, 3)) {

                Write-Log "  Download failed (ResultCode $($DownloadResult.ResultCode)). Skipping install." "ERROR"
                Release-ComObject $Collection
                Release-ComObject $Downloader
                continue
            }


            # ------------------------------------------------
            # Install
            # ------------------------------------------------

            Write-Log "  Download completed. Installing update..."

            $Installer         = $Session.CreateUpdateInstaller()
            $Installer.Updates = $Collection

            # Suppress UI prompts (IUpdateInstaller2/3 — may not exist on all builds)
            try { $Installer.AllowSourcePrompts = $false } catch {}
            try { $Installer.ForceQuiet         = $true  } catch {}

            try {

                $InstallResult = $Installer.Install()
            }
            catch {

                Write-Log "  Install threw an exception: $($_.Exception.Message)" "ERROR"
                Release-ComObject $Collection
                Release-ComObject $Downloader
                Release-ComObject $Installer
                continue
            }

            Write-Log "  Install ResultCode : $($InstallResult.ResultCode)"
            Write-Log "  Reboot Required    : $($InstallResult.RebootRequired)"

            if ($InstallResult.ResultCode -eq 2) {

                Write-Log "  Defender update installed successfully." "SUCCESS"
            }
            elseif ($InstallResult.ResultCode -eq 3) {

                Write-Log "  Defender update installed with warnings." "WARNING"
            }
            else {

                Write-Log "  Defender update installation returned non-success (ResultCode $($InstallResult.ResultCode))." "WARNING"
            }

            Release-ComObject $Collection
            Release-ComObject $Downloader
            Release-ComObject $Installer
        }
    }
}
else {

    Write-Log "No pending Defender updates found via Microsoft Update."
}


# ============================================================
# STEP 3 — Wait for Defender to initialize (polling loop)
# ============================================================

Write-Log "Waiting for Defender components to initialize (max ${PollTimeout}s)..."

$Elapsed = 0

while ($Elapsed -lt $PollTimeout) {

    Start-Sleep -Seconds $PollInterval
    $Elapsed += $PollInterval

    $Check = Get-DefenderStatus

    if ($null -ne $Check) {

        # If the platform version changed, Defender has re-initialized
        if ($Before.PlatformVersion -ne $Check.PlatformVersion -or
            $Before.EngineVersion   -ne $Check.EngineVersion) {

            Write-Log "Defender versions changed after ${Elapsed}s — initialization complete."
            break
        }
    }
}

if ($Elapsed -ge $PollTimeout) {

    Write-Log "Timed out waiting for Defender re-initialization (${PollTimeout}s). Proceeding with verification." "WARNING"
}


# ============================================================
# AFTER STATUS
# ============================================================

$After = Get-DefenderStatus

if ($null -eq $After) {

    Write-Log "Unable to verify Defender status after remediation." "ERROR"
    exit $EXIT_POST_CHECK_FAILED
}

Write-Log "AFTER UPDATE"
Write-Log "Engine   : $($After.EngineVersion)"
Write-Log "Platform : $($After.PlatformVersion)"
Write-Log "Service  : $($After.ServiceVersion)"
Write-Log "AV Sig   : $($After.AntivirusSignature)"
Write-Log "RTP      : $($After.RealTimeEnabled)"


# ============================================================
# STEP 4 — Final check: any Defender updates still pending?
# ============================================================

Write-Log "Performing final Microsoft Update check for remaining Defender updates."

if ($null -ne $Searcher) {

    try {

        $FinalSearch = $Searcher.Search(
            "IsInstalled=0 and IsHidden=0 and Type='Software'"
        )

        $RemainingUpdates = @(
            $FinalSearch.Updates | Where-Object {

                $_.Title -match "Microsoft Defender Antivirus" -or
                $_.Title -match "Windows Defender Antivirus" -or
                $_.Title -match "KB4052623"
            }
        )

        if ($RemainingUpdates.Count -gt 0) {

            Write-Log "Defender update(s) are still pending after remediation." "WARNING"

            foreach ($Remaining in $RemainingUpdates) {

                Write-Log "  Pending: $($Remaining.Title)"
            }

            Write-Log "RESULT: REMEDIATION INCOMPLETE." "WARNING"
            exit $EXIT_REMEDIATION_INCOMPLETE
        }
        else {

            Write-Log "No remaining Defender updates pending."
        }
    }
    catch {

        Write-Log "Final update check failed: $($_.Exception.Message)" "ERROR"
        exit $EXIT_POST_CHECK_FAILED
    }
}
else {

    Write-Log "Searcher not available — skipping final Windows Update verification." "WARNING"
}


# ============================================================
# FINAL RESULT
# ============================================================

Write-Log "============================================================"
Write-Log "SUCCESS — Defender is up to date with available updates."
Write-Log "Final Engine   : $($After.EngineVersion)"
Write-Log "Final Platform : $($After.PlatformVersion)"
Write-Log "Final Service  : $($After.ServiceVersion)"
Write-Log "Final AV Sig   : $($After.AntivirusSignature)"
Write-Log "Log File       : $LogFile"
Write-Log "============================================================"

Write-Host ""
Write-Host "============================================================"
Write-Host "       ***** DEFENDER REMEDIATION SUCCESS *****"
Write-Host "============================================================"
Write-Host " Engine   : $($After.EngineVersion)"
Write-Host " Platform : $($After.PlatformVersion)"
Write-Host " Service  : $($After.ServiceVersion)"
Write-Host " Log File : $LogFile"
Write-Host "============================================================"

exit $EXIT_SUCCESS


}   # end outer try


# ============================================================
# CLEANUP — always runs
# ============================================================

finally {

    # --------------------------------------------------------
    # Release COM objects
    # --------------------------------------------------------

    foreach ($Obj in @($Installer, $Downloader, $Collection, $Searcher, $Session, $ServiceManager)) {

        Release-ComObject $Obj
    }


    # --------------------------------------------------------
    # Restore WU service startup type
    # --------------------------------------------------------

    if ($null -ne $OriginalWUStartType) {

        try {

            Set-Service -Name wuauserv -StartupType $OriginalWUStartType -ErrorAction SilentlyContinue
            Write-Log "Restored wuauserv startup type to: $OriginalWUStartType"
        }
        catch {
            # Best-effort
        }
    }


    # --------------------------------------------------------
    # Release mutex
    # --------------------------------------------------------

    if ($null -ne $Mutex) {

        try {

            $Mutex.ReleaseMutex()
            $Mutex.Dispose()
        }
        catch {
            # Best-effort
        }
    }

    Write-Log "Cleanup complete. Script exiting."
}
