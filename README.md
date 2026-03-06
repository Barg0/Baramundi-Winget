# 📦 Baramundi Winget Deployment Scripts

PowerShell scripts for deploying and removing applications via **winget** in **Baramundi Management Suite**. Designed to run in system context as a single-script deployment job.

## 📜 Scripts

| Script | Purpose |
|---|---|
| `Install-WingetApplication.ps1` | ⬇️ Detect, install, and verify a winget package |
| `Uninstall-WingetApplication.ps1` | 🗑️ Detect, uninstall, and verify removal of a winget package |

## ⚙️ How It Works

Both scripts follow a three-phase flow:

### ⬇️ Install

1. 🔍 **Pre-install detection** -- Checks if the application is already installed. If yes, exits `0` (nothing to do).
2. 📥 **Installation** -- Runs `winget install` with a retry engine (scope fallback, source fallback, in-progress wait loop). If the install fails, exits `1`.
3. ✅ **Post-install verification** -- Re-runs detection to confirm the application is now present. Exits `0` on success, `1` on failure.

### 🗑️ Uninstall

1. 🔍 **Pre-uninstall detection** -- Checks if the application is installed. If not, exits `0` (nothing to do).
2. 📤 **Uninstallation** -- Runs `winget uninstall` with machine scope first, then retries without scope for user-scoped installations. If the uninstall fails, exits `1`.
3. ✅ **Post-uninstall verification** -- Re-runs detection to confirm the application is gone. Exits `0` on success, `1` on failure.

## 🔧 Parameters

### Install-WingetApplication.ps1

| Parameter | Required | Description |
|---|---|---|
| `-ApplicationName` | ✅ Yes | Display name used for logging and log directory |
| `-WingetAppID` | ✅ Yes | Exact winget package ID (e.g. `7zip.7zip`) |
| `-InstallOverride` | ❌ No | Custom arguments passed to the installer via `--override` |

### Uninstall-WingetApplication.ps1

| Parameter | Required | Description |
|---|---|---|
| `-ApplicationName` | ✅ Yes | Display name used for logging and log directory |
| `-WingetAppID` | ✅ Yes | Exact winget package ID (e.g. `7zip.7zip`) |

## 🚀 Usage

### ⬇️ Install

```powershell
.\Install-WingetApplication.ps1 -ApplicationName "7-Zip" -WingetAppID "7zip.7zip"
```

With installer override:

```powershell
.\Install-WingetApplication.ps1 -ApplicationName "7-Zip" -WingetAppID "7zip.7zip" -InstallOverride "/silent /configID=XXXXX"
```

### 🗑️ Uninstall

```powershell
.\Uninstall-WingetApplication.ps1 -ApplicationName "7-Zip" -WingetAppID "7zip.7zip"
```

## 🏢 Baramundi Configuration

In the Baramundi Management Console, configure the job step to execute the script with the required parameters. The scripts are designed for system context execution.

**Exit codes:**
- ✅ `0` -- Success (installed/uninstalled, or already in desired state)
- ❌ `1` -- Failure (winget error, verification failed, or unrecoverable condition)

## 🔄 Install Retry Engine

The install script includes a retry engine that handles common winget failure scenarios automatically:

| Scenario | Behavior |
|---|---|
| 🖥️ No applicable installer for machine scope | Retries without `--scope machine` |
| 🔒 Pinned certificate mismatch | Retries with `--source winget` |
| ⏳ Another installation in progress | Waits 120 seconds, retries up to 15 times |
| ⚠️ Transient conditions (disk full, no network, reboot needed) | Reports failure immediately |
| ✅ Package already installed / higher version present | Treats as success |

Each workaround is applied at most once. Workarounds can chain (e.g. scope fallback + source fallback in the same run).

## 📝 Logging

Logs are written to:

```
%ProgramData%\BaramundiLogs\Applications\<ApplicationName>\install.log
%ProgramData%\BaramundiLogs\Applications\<ApplicationName>\uninstall.log
```

Set `$logDebug = $true` inside the script to enable verbose debug logging for troubleshooting. 🐛

## 🔎 Finding Winget App IDs

Search for the correct winget package ID:

```powershell
winget search "application name"
```

Use the **Id** column value as the `-WingetAppID` parameter.
