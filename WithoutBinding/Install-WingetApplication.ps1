# ---------------------------[ Script Start Timestamp ]---------------------------
$scriptStartTime = Get-Date

# ---------------------------[ Configuration ]---------------------------
$applicationName = "__APPLICATION_NAME__"
$wingetAppID     = "__WINGET_APP_ID__"

# Optional: pass a string directly to the installer (e.g. "/silent /configID=XXXXX"). Leave empty for none.
# See: https://learn.microsoft.com/en-us/windows/package-manager/winget/install (--override)
$installOverride = ""

$logFileName = "install.log"

# ---------------------------[ Logging Setup ]---------------------------
$log           = $true
$logDebug      = $false
$logGet        = $true
$logRun        = $true
$enableLogFile = $true

$logFileDirectory = "$env:ProgramData\BaramundiLogs\Applications\$applicationName"
$logFile          = "$logFileDirectory\$logFileName"

if ($enableLogFile -and -not (Test-Path -Path $logFileDirectory)) {
    New-Item -ItemType Directory -Path $logFileDirectory -Force | Out-Null
}

# ---------------------------[ Logging Function ]---------------------------
function Write-Log {
    [CmdletBinding()]
    param (
        [string]$Message,
        [string]$Tag = "Info"
    )

    if (-not $log) { return }

    if (($Tag -eq "Debug") -and (-not $logDebug)) { return }
    if (($Tag -eq "Get")   -and (-not $logGet))   { return }
    if (($Tag -eq "Run")   -and (-not $logRun))   { return }

    $timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    $tagList   = @("Start", "Get", "Run", "Info", "Success", "Error", "Debug", "End")
    $rawTag    = $Tag.Trim()

    if ($tagList -contains $rawTag) {
        $rawTag = $rawTag.PadRight(7)
    }
    else {
        $rawTag = "Error  "
    }

    $color = switch ($rawTag.Trim()) {
        "Start"   { "Cyan" }
        "Get"     { "Blue" }
        "Run"     { "Magenta" }
        "Info"    { "Yellow" }
        "Success" { "Green" }
        "Error"   { "Red" }
        "Debug"   { "DarkYellow" }
        "End"     { "Cyan" }
        default   { "White" }
    }

    $logMessage = "$timestamp [  $rawTag ] $Message"

    if ($enableLogFile) {
        try {
            Add-Content -Path $logFile -Value $logMessage -Encoding UTF8
        }
        catch {
            # Logging must never block script execution
        }
    }

    Write-Host "$timestamp " -NoNewline
    Write-Host "[  " -NoNewline -ForegroundColor White
    Write-Host "$rawTag" -NoNewline -ForegroundColor $color
    Write-Host " ] " -NoNewline -ForegroundColor White
    Write-Host "$Message"
}

# ---------------------------[ Exit Function ]---------------------------
function Complete-Script {
    param([int]$ExitCode)

    $scriptEndTime = Get-Date
    $duration      = $scriptEndTime - $scriptStartTime

    Write-Log "Script execution time: $($duration.ToString('hh\:mm\:ss\.ff'))" -Tag "Info"
    Write-Log "Exit Code: $ExitCode" -Tag "Info"
    Write-Log "======== Script Completed ========" -Tag "End"

    exit $ExitCode
}

# ---------------------------[ Winget Path Resolver ]---------------------------
function Get-WingetPath {
    $wingetBase = "$env:ProgramW6432\WindowsApps"
    Write-Log "Resolving Winget path from: $wingetBase" -Tag "Debug"

    try {
        $wingetFolders = Get-ChildItem -Path $wingetBase -Directory -ErrorAction Stop |
            Where-Object { $_.Name -like 'Microsoft.DesktopAppInstaller_*_x64__8wekyb3d8bbwe' }
        Write-Log "x64 DesktopAppInstaller folders found: $($wingetFolders.Count)" -Tag "Debug"

        if (-not $wingetFolders) {
            $wingetFolders = Get-ChildItem -Path $wingetBase -Directory -ErrorAction Stop |
                Where-Object { $_.Name -like 'Microsoft.DesktopAppInstaller_*_arm64__8wekyb3d8bbwe' }
            Write-Log "arm64 DesktopAppInstaller folders found: $($wingetFolders.Count)" -Tag "Debug"
        }

        if (-not $wingetFolders) {
            throw "No matching Winget installation folders found (x64 or arm64)."
        }

        $latestWingetFolder = $wingetFolders |
            Sort-Object CreationTime -Descending |
            Select-Object -First 1
        Write-Log "Selected folder: $($latestWingetFolder.FullName)" -Tag "Debug"

        $resolvedPath = Join-Path $latestWingetFolder.FullName 'winget.exe'

        if (-not (Test-Path $resolvedPath)) {
            throw "winget.exe not found at expected location."
        }
        Write-Log "Winget executable path: $resolvedPath" -Tag "Debug"

        return $resolvedPath
    }
    catch {
        Write-Log "Failed to resolve Winget path: $_" -Tag "Error"
        Write-Log "Exception type: $($_.Exception.GetType().FullName)" -Tag "Debug"
        return $null
    }
}

# ---------------------------[ Winget Version Check ]---------------------------
function Test-WingetVersion {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$WingetPath)

    $versionOutput = & $WingetPath --version 2>&1
    $exitCode      = $LASTEXITCODE
    $versionString = ($versionOutput | Out-String).Trim()
    $isHealthy     = ($exitCode -eq 0)
    Write-Log "Winget --version exit code: $exitCode; output length: $($versionString.Length)" -Tag "Debug"
    return @{ IsHealthy = $isHealthy; Version = $versionString; ExitCode = $exitCode }
}

# ---------------------------[ Winget Exit Code Helper ]---------------------------
# Reference: https://kb.filewave.com/books/microsoft-windows-package-manager-winget/page/troubleshooting-errors-with-winget
#
# Categories:
#   Success    - Desired state (installed or already installed).
#   RetryScope - No applicable installer for scope; retry without --scope.
#   RetrySource - Pinned certificate mismatch; retry with --source winget.
#   Transient  - Temporary condition (app in use, disk full, reboot needed, etc.).
#   Fail       - Unrecoverable (policy, unsupported, invalid param).
#   Unknown    - Unmapped code; treat as Fail.
function Get-WingetExitCodeInfo {
    [CmdletBinding()]
    param([int]$ExitCode)

    $codeMap = @{
        0              = @{ Category = "Success";     Description = "Success" }
        -1978335135    = @{ Category = "Success";     Description = "Package already installed (general)" }
        -1978334963    = @{ Category = "Success";     Description = "Another version already installed" }
        -1978334962    = @{ Category = "Success";     Description = "Higher version already installed" }
        -1978334965    = @{ Category = "Success";     Description = "Reboot initiated to finish installation" }

        -1978335216    = @{ Category = "RetryScope";  Description = "No applicable installer for scope" }

        -1978335138    = @{ Category = "RetrySource"; Description = "Pinned certificate mismatch" }

        -1978334975    = @{ Category = "Transient";   Description = "Application is currently running" }
        -1978334974    = @{ Category = "Transient";   Description = "Another installation in progress" }
        -1978334973    = @{ Category = "Transient";   Description = "One or more file is in use" }
        -1978334971    = @{ Category = "Transient";   Description = "Disk full" }
        -1978334970    = @{ Category = "Transient";   Description = "Insufficient memory" }
        -1978334969    = @{ Category = "Transient";   Description = "No network connectivity" }
        -1978334967    = @{ Category = "Transient";   Description = "Reboot required to finish installation" }
        -1978334966    = @{ Category = "Transient";   Description = "Reboot required then try again" }
        -1978334959    = @{ Category = "Transient";   Description = "Package in use by another application" }
        -1978335125    = @{ Category = "Transient";   Description = "Service busy or unavailable" }

        -1978335212    = @{ Category = "Fail";        Description = "No packages found" }
        -1978335217    = @{ Category = "Fail";        Description = "No applicable installer" }
        -1978334972    = @{ Category = "Fail";        Description = "Missing dependency" }
        -1978334968    = @{ Category = "Fail";        Description = "Installation error; contact support" }
        -1978334964    = @{ Category = "Fail";        Description = "Installation cancelled by user" }
        -1978334961    = @{ Category = "Fail";        Description = "Blocked by organization policy" }
        -1978334960    = @{ Category = "Fail";        Description = "Failed to install dependencies" }
        -1978334958    = @{ Category = "Fail";        Description = "Invalid parameter" }
        -1978334957    = @{ Category = "Fail";        Description = "Package not supported on this system" }
        -1978334956    = @{ Category = "Fail";        Description = "Installer does not support upgrade" }
    }

    if ($codeMap.ContainsKey($ExitCode)) {
        return $codeMap[$ExitCode]
    }
    return @{ Category = "Unknown"; Description = "Unmapped exit code $ExitCode" }
}

# ---------------------------[ Application Detection ]---------------------------
function Test-ApplicationInstalled {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$WingetPath,
        [Parameter(Mandatory)][string]$AppID
    )

    Write-Log "Checking installed packages for: $AppID" -Tag "Run"
    Write-Log "Invoking: winget list -e --id $AppID --accept-source-agreements" -Tag "Debug"

    try {
        $previousOutputEncoding = [Console]::OutputEncoding
        [Console]::OutputEncoding = [System.Text.UTF8Encoding]::new()
        try {
            $installedOutput = & $WingetPath list -e --id $AppID --accept-source-agreements
            $wingetExitCode  = $LASTEXITCODE
        }
        finally {
            [Console]::OutputEncoding = $previousOutputEncoding
        }

        Write-Log "winget list exit code: $wingetExitCode" -Tag "Debug"
        $outputString = $installedOutput | Out-String
        Write-Log "Output (first 500 chars): $($outputString.Substring(0, [Math]::Min(500, $outputString.Length)))" -Tag "Debug"

        if ($wingetExitCode -eq -1978335212 -and $installedOutput -match 'No installed package found matching input criteria.') {
            Write-Log "NO_APPLICATIONS_FOUND; package not installed." -Tag "Debug"
            return $false
        }

        if ($wingetExitCode -ne 0) {
            Write-Log "Winget list returned unexpected exit code: $wingetExitCode" -Tag "Error"
            Write-Log "Raw output: $installedOutput" -Tag "Debug"
            return $false
        }

        Write-Log "Package found in winget list; application is installed." -Tag "Debug"
        return $true
    }
    catch {
        Write-Log "Exception during detection: $_" -Tag "Error"
        Write-Log "Exception details: $($_.ScriptStackTrace)" -Tag "Debug"
        return $false
    }
}

# ---------------------------[ Winget Installation ]---------------------------
# Retry engine: loops applying workarounds based on exit code category.
# Each workaround (RetryScope, RetrySource) is tried at most once.
# Every winget call is also wrapped in an in-progress wait loop for -1978334974.
function Invoke-WingetInstallation {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$WingetPath,
        [Parameter(Mandatory)][string]$AppID,
        [string]$OverrideArguments = ""
    )

    $useScope               = $true
    $useSource              = $false
    $triedNoScope           = $false
    $triedSource            = $false
    $maxInProgressRetries   = 15
    $inProgressDelaySeconds = 120

    if ($OverrideArguments) {
        Write-Log "Using install override: $OverrideArguments" -Tag "Info"
    }

    try {
        while ($true) {
            $currentArgs = @('install', '-e', '--id', $AppID, '--silent', '--skip-dependencies',
                             '--accept-package-agreements', '--accept-source-agreements', '--force')
            if ($useScope)  { $currentArgs += '--scope',  'machine' }
            if ($useSource) { $currentArgs += '--source', 'winget'  }
            if ($OverrideArguments) {
                $currentArgs += '--override'
                $currentArgs += $OverrideArguments
            }

            $scopeLabel   = if ($useScope)  { "scope machine" } else { "no scope" }
            $sourceLabel  = if ($useSource) { ", source winget" } else { "" }
            $attemptLabel = "$scopeLabel$sourceLabel"

            $inProgressCount = 0
            do {
                if ($inProgressCount -gt 0) {
                    Write-Log "Another installation is in progress. Waiting $inProgressDelaySeconds seconds before retry $inProgressCount of $maxInProgressRetries..." -Tag "Info"
                    Start-Sleep -Seconds $inProgressDelaySeconds
                }

                $runLabel = "Installing ($attemptLabel)"
                if ($inProgressCount -gt 0) { $runLabel += " [in-progress retry $inProgressCount/$maxInProgressRetries]" }
                Write-Log "$runLabel" -Tag "Run"
                Write-Log "Invoking: winget $($currentArgs -join ' ')" -Tag "Debug"

                & $WingetPath @currentArgs
                $exitCode = $LASTEXITCODE
                $exitInfo = Get-WingetExitCodeInfo -ExitCode $exitCode
                Write-Log "Winget exit code: $exitCode ($($exitInfo.Description)); Category=$($exitInfo.Category)" -Tag "Info"

                if ($exitCode -ne -1978334974) { break }

                $inProgressCount++
            } while ($inProgressCount -le $maxInProgressRetries)

            if ($exitCode -eq -1978334974) {
                Write-Log "Installation still blocked after $maxInProgressRetries retries (another installation in progress)." -Tag "Error"
                return $false
            }

            if ($exitCode -eq 0 -or $exitInfo.Category -eq "Success") {
                if ($triedNoScope -or $triedSource) {
                    Write-Log "Installation completed successfully after workaround ($attemptLabel)." -Tag "Success"
                }
                else {
                    Write-Log "Installation completed successfully." -Tag "Success"
                }
                return $true
            }

            if ($exitInfo.Category -eq "Transient") {
                Write-Log "Install blocked by transient condition: $($exitInfo.Description)" -Tag "Error"
                return $false
            }

            $workaroundApplied = $false

            if ($exitInfo.Category -eq "RetryScope" -and -not $triedNoScope) {
                Write-Log "No applicable installer for machine scope; retrying without --scope." -Tag "Info"
                $useScope          = $false
                $triedNoScope      = $true
                $workaroundApplied = $true
            }

            if ($exitInfo.Category -eq "RetrySource" -and -not $triedSource) {
                Write-Log "Pinned certificate mismatch detected; retrying with --source winget." -Tag "Info"
                $useSource         = $true
                $triedSource       = $true
                $workaroundApplied = $true
            }

            if (-not $workaroundApplied) {
                Write-Log "No further workarounds available for: $($exitInfo.Description) (Category=$($exitInfo.Category))" -Tag "Debug"
                Write-Log "Install failed: $($exitInfo.Description)" -Tag "Error"
                return $false
            }

            Write-Log "Workaround applied; retrying..." -Tag "Debug"
        }
    }
    catch {
        Write-Log "Exception during installation: $_" -Tag "Error"
        Write-Log "Exception details: $($_.ScriptStackTrace)" -Tag "Debug"
        return $false
    }
}

# ---------------------------[ Script Start ]---------------------------
Write-Log "======== Baramundi Winget Deployment Started ========" -Tag "Start"
Write-Log "ComputerName: $env:COMPUTERNAME | User: $env:USERNAME | Application: $applicationName" -Tag "Info"
Write-Log "Winget App ID: $wingetAppID" -Tag "Info"

try {
    # ---------------------------[ Resolve Winget ]---------------------------
    $wingetPath = Get-WingetPath
    if (-not $wingetPath) {
        Complete-Script -ExitCode 1
    }
    Write-Log "Resolved Winget path." -Tag "Get"

    $wingetCheck = Test-WingetVersion -WingetPath $wingetPath
    Write-Log "Winget version: $($wingetCheck.Version)" -Tag "Info"
    if (-not $wingetCheck.IsHealthy) {
        Write-Log "Winget health check failed (exit code: $($wingetCheck.ExitCode)). Repair Winget or restart the machine." -Tag "Error"
        Complete-Script -ExitCode 1
    }
    Write-Log "Winget health check passed." -Tag "Debug"

    # ---------------------------[ Pre-Install Detection ]---------------------------
    Write-Log "--- Phase: Pre-install detection ---" -Tag "Info"
    $isAlreadyInstalled = Test-ApplicationInstalled -WingetPath $wingetPath -AppID $wingetAppID

    if ($isAlreadyInstalled) {
        Write-Log "$applicationName is already installed. No action required." -Tag "Success"
        Complete-Script -ExitCode 0
    }
    Write-Log "$applicationName is NOT installed. Proceeding with installation." -Tag "Info"

    # ---------------------------[ Installation ]---------------------------
    Write-Log "--- Phase: Installation ---" -Tag "Info"
    $installSucceeded = Invoke-WingetInstallation -WingetPath $wingetPath -AppID $wingetAppID -OverrideArguments $installOverride

    if (-not $installSucceeded) {
        Write-Log "Installation of $applicationName failed." -Tag "Error"
        Complete-Script -ExitCode 1
    }

    # ---------------------------[ Post-Install Verification ]---------------------------
    Write-Log "--- Phase: Post-install verification ---" -Tag "Info"
    $isNowInstalled = Test-ApplicationInstalled -WingetPath $wingetPath -AppID $wingetAppID

    if ($isNowInstalled) {
        Write-Log "$applicationName has been successfully installed and verified." -Tag "Success"
        Complete-Script -ExitCode 0
    }

    Write-Log "$applicationName was not detected after installation. Verification failed." -Tag "Error"
    Complete-Script -ExitCode 1
}
catch {
    Write-Log "Unexpected error during deployment: $_" -Tag "Error"
    Write-Log "Exception details: $($_.ScriptStackTrace)" -Tag "Debug"
    Complete-Script -ExitCode 1
}
