# ---------------------------[ Script Start Timestamp ]---------------------------
$scriptStartTime = Get-Date

# ---------------------------[ Configuration ]---------------------------
$applicationName = "__APPLICATION_NAME__"
$wingetAppID     = "__WINGET_APP_ID__"

$logFileName = "uninstall.log"

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

# ---------------------------[ Winget Uninstall Exit Code Helper ]---------------------------
# Reference: https://kb.filewave.com/books/microsoft-windows-package-manager-winget/page/troubleshooting-errors-with-winget
function Get-WingetUninstallExitCodeInfo {
    [CmdletBinding()]
    param([int]$ExitCode)

    $codeMap = @{
        0              = @{ Category = "Success"; Description = "Success" }
        -1978335212    = @{ Category = "Success"; Description = "No packages found (already uninstalled)" }
        -1978335130    = @{ Category = "Fail";    Description = "One or more applications failed to uninstall" }
        -1978335183    = @{ Category = "Fail";    Description = "Running uninstall command failed" }
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

# ---------------------------[ Winget Uninstallation ]---------------------------
# Tries machine scope first, then retries without scope for user-scoped installations.
function Invoke-WingetUninstallation {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$WingetPath,
        [Parameter(Mandatory)][string]$AppID
    )

    try {
        Write-Log "Uninstalling with scope machine." -Tag "Run"
        Write-Log "Invoking: winget uninstall -e --id $AppID --silent --scope machine --accept-source-agreements --force" -Tag "Debug"
        & $WingetPath uninstall -e --id $AppID --silent --scope machine --accept-source-agreements --force
        $exitCode = $LASTEXITCODE
        $exitInfo = Get-WingetUninstallExitCodeInfo -ExitCode $exitCode
        Write-Log "Winget uninstall exit code: $exitCode ($($exitInfo.Description)); Category=$($exitInfo.Category)" -Tag "Info"

        if ($exitCode -eq 0 -or $exitInfo.Category -eq "Success") {
            Write-Log "Uninstallation completed successfully." -Tag "Success"
            return $true
        }

        Write-Log "Machine-scope uninstall failed; retrying without scope for user-scoped installations." -Tag "Info"
        Write-Log "Invoking: winget uninstall -e --id $AppID --silent --accept-source-agreements --force" -Tag "Debug"
        & $WingetPath uninstall -e --id $AppID --silent --accept-source-agreements --force
        $exitCode = $LASTEXITCODE
        $exitInfo = Get-WingetUninstallExitCodeInfo -ExitCode $exitCode
        Write-Log "Winget uninstall (no scope) exit code: $exitCode ($($exitInfo.Description)); Category=$($exitInfo.Category)" -Tag "Info"

        if ($exitCode -eq 0 -or $exitInfo.Category -eq "Success") {
            Write-Log "Uninstallation completed successfully after scope retry." -Tag "Success"
            return $true
        }

        Write-Log "Uninstall failed: $($exitInfo.Description)" -Tag "Error"
        return $false
    }
    catch {
        Write-Log "Exception during uninstallation: $_" -Tag "Error"
        Write-Log "Exception details: $($_.ScriptStackTrace)" -Tag "Debug"
        return $false
    }
}

# ---------------------------[ Script Start ]---------------------------
Write-Log "======== Baramundi Winget Uninstallation Started ========" -Tag "Start"
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

    # ---------------------------[ Pre-Uninstall Detection ]---------------------------
    Write-Log "--- Phase: Pre-uninstall detection ---" -Tag "Info"
    $isCurrentlyInstalled = Test-ApplicationInstalled -WingetPath $wingetPath -AppID $wingetAppID

    if (-not $isCurrentlyInstalled) {
        Write-Log "$applicationName is not installed. No action required." -Tag "Success"
        Complete-Script -ExitCode 0
    }
    Write-Log "$applicationName IS installed. Proceeding with uninstallation." -Tag "Info"

    # ---------------------------[ Uninstallation ]---------------------------
    Write-Log "--- Phase: Uninstallation ---" -Tag "Info"
    $uninstallSucceeded = Invoke-WingetUninstallation -WingetPath $wingetPath -AppID $wingetAppID

    if (-not $uninstallSucceeded) {
        Write-Log "Uninstallation of $applicationName failed." -Tag "Error"
        Complete-Script -ExitCode 1
    }

    # ---------------------------[ Post-Uninstall Verification ]---------------------------
    Write-Log "--- Phase: Post-uninstall verification ---" -Tag "Info"
    $isStillInstalled = Test-ApplicationInstalled -WingetPath $wingetPath -AppID $wingetAppID

    if (-not $isStillInstalled) {
        Write-Log "$applicationName has been successfully uninstalled and verified." -Tag "Success"
        Complete-Script -ExitCode 0
    }

    Write-Log "$applicationName is still detected after uninstallation. Verification failed." -Tag "Error"
    Complete-Script -ExitCode 1
}
catch {
    Write-Log "Unexpected error during uninstallation: $_" -Tag "Error"
    Write-Log "Exception details: $($_.ScriptStackTrace)" -Tag "Debug"
    Complete-Script -ExitCode 1
}
