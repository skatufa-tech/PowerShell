# ============================================================
# HydroVal - Defender Update Remediation
#
# Purpose:
#   Automatically install available Microsoft Defender updates.
#
# This script does NOT contain a hard-coded Defender version.
#
# It uses the configured Microsoft Update source and installs
# applicable Defender Antivirus updates.
#
# Log:
#   C:\ProgramData\TechEUC\DefenderUpdate\
#       DefenderRemediation.log
# ============================================================

$LogDir  = "$env:ProgramData\TechEUC\DefenderUpdate"
$LogFile = "$LogDir\DefenderRemediation.log"

New-Item -Path $LogDir -ItemType Directory -Force | Out-Null


function Write-Log {

    param(
        [string]$Message,
        [string]$Level = "INFO"
    )

    $Time = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    $Line = "$Time [$Level] $Message"

    Write-Host $Line
    Add-Content -Path $LogFile -Value $Line
}


function Get-DefenderStatus {

    try {

        $Status = Get-MpComputerStatus -ErrorAction Stop

        return [PSCustomObject]@{

            EngineVersion      = $Status.AMEngineVersion
            PlatformVersion    = $Status.AMProductVersion
            ServiceVersion     = $Status.AMServiceVersion
            AntivirusSignature = $Status.AntivirusSignatureVersion

        }

    }
    catch {

        Write-Log "Unable to retrieve Defender status: $($_.Exception.Message)" "ERROR"

        return $null
    }
}


# ============================================================
# START
# ============================================================

Write-Log "============================================================"
Write-Log "HydroVal Defender Remediation Started"
Write-Log "Computer: $env:COMPUTERNAME"
Write-Log "============================================================"


# ============================================================
# BEFORE STATUS
# ============================================================

$Before = Get-DefenderStatus

if ($Before) {

    Write-Log "BEFORE UPDATE"
    Write-Log "Engine   : $($Before.EngineVersion)"
    Write-Log "Platform : $($Before.PlatformVersion)"
    Write-Log "Service  : $($Before.ServiceVersion)"
    Write-Log "AV Sig   : $($Before.AntivirusSignature)"
}
else {

    Write-Log "Unable to determine current Defender status." "WARNING"
}


# ============================================================
# STEP 1
# Defender Engine / Security Intelligence
# ============================================================

Write-Log "Starting Defender update through Microsoft Update."

try {

    Update-MpSignature `
        -UpdateSource MicrosoftUpdateServer `
        -ErrorAction Stop

    Write-Log "Defender engine/security intelligence update completed." "SUCCESS"

}
catch {

    Write-Log "Update-MpSignature failed: $($_.Exception.Message)" "WARNING"
}


# ============================================================
# STEP 2
# Windows Update / Defender Platform
# ============================================================

Write-Log "Checking Windows Update for Defender Platform updates."


try {

    Set-Service `
        -Name wuauserv `
        -StartupType Manual `
        -ErrorAction SilentlyContinue

    Start-Service `
        -Name wuauserv `
        -ErrorAction SilentlyContinue


    $Session = New-Object -ComObject Microsoft.Update.Session

    $Searcher = $Session.CreateUpdateSearcher()


    Write-Log "Searching Microsoft Update..."

    $SearchResult = $Searcher.Search(
        "IsInstalled=0 and IsHidden=0 and Type='Software'"
    )


    # --------------------------------------------------------
    # Defender updates only
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
            Write-Log "Installing Defender update:"
            Write-Log "$($Update.Title)"
            Write-Log "KB: $($Update.KBArticleIDs -join ', ')"
            Write-Log "Update ID: $($Update.Identity.UpdateID)"


            # ------------------------------------------------
            # Create update collection
            # ------------------------------------------------

            $Collection = New-Object `
                -ComObject Microsoft.Update.UpdateColl

            [void]$Collection.Add($Update)


            # ------------------------------------------------
            # Download
            # ------------------------------------------------

            Write-Log "Downloading update..."

            $Downloader = $Session.CreateUpdateDownloader()

            $Downloader.Updates = $Collection

            $DownloadResult = $Downloader.Download()

            Write-Log "Download Result: $($DownloadResult.ResultCode)"


            # ------------------------------------------------
            # Install
            # ------------------------------------------------

            if (
                $DownloadResult.ResultCode -eq 2 -or
                $DownloadResult.ResultCode -eq 3
            ) {

                Write-Log "Download completed. Installing update."

                $Installer = $Session.CreateUpdateInstaller()

                $Installer.Updates = $Collection

                $InstallResult = $Installer.Install()


                Write-Log "Install Result : $($InstallResult.ResultCode)"
                Write-Log "Reboot Required: $($InstallResult.RebootRequired)"


                if ($InstallResult.ResultCode -eq 2) {

                    Write-Log "Defender update installed successfully." "SUCCESS"

                }
                else {

                    Write-Log "Defender update installation returned a non-success result." "WARNING"

                }

            }
            else {

                Write-Log "Download failed. Installation skipped." "ERROR"

            }
        }
    }

}
catch {

    Write-Log "Windows Update processing failed: $($_.Exception.Message)" "ERROR"
}


# ============================================================
# STEP 3
# Allow Defender to initialize
# ============================================================

Write-Log "Waiting for Defender components to initialize."

Start-Sleep -Seconds 45


# ============================================================
# AFTER STATUS
# ============================================================

$After = Get-DefenderStatus

if ($After) {

    Write-Log "AFTER UPDATE"
    Write-Log "Engine   : $($After.EngineVersion)"
    Write-Log "Platform : $($After.PlatformVersion)"
    Write-Log "Service  : $($After.ServiceVersion)"
    Write-Log "AV Sig   : $($After.AntivirusSignature)"

}
else {

    Write-Log "Unable to verify Defender after remediation." "ERROR"

    exit 1
}


# ============================================================
# STEP 4
# Check if Defender updates are still pending
# ============================================================

Write-Log "Performing final Windows Update check."


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

        Write-Log "Defender update(s) are still pending." "WARNING"

        foreach ($Update in $RemainingUpdates) {

            Write-Log "Pending: $($Update.Title)"
        }

        Write-Log "RESULT: REMEDIATION INCOMPLETE." "WARNING"

        exit 1
    }


}
catch {

    Write-Log "Final Windows Update check failed: $($_.Exception.Message)" "ERROR"

    exit 1
}


# ============================================================
# FINAL RESULT
# ============================================================

Write-Log "============================================================"
Write-Log "SUCCESS - Defender is up to date with available updates."
Write-Log "Final Engine   : $($After.EngineVersion)"
Write-Log "Final Platform : $($After.PlatformVersion)"
Write-Log "Final Service  : $($After.ServiceVersion)"
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


exit 0