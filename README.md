# Tanium Scripts

PowerShell scripts to deploy the Tanium Client and prepare it for capture in a non-persistent (VDI) golden image.

| Script | Purpose |
| --- | --- |
| [Install-Tanium.ps1](Install-Tanium.ps1) | Silently installs the Tanium Client and optionally waits for a policy tag to land |
| [Set-TaniumGoldenImage.ps1](Set-TaniumGoldenImage.ps1) | Cleans up the client identity and applies VDI settings before sealing the image |

Typical workflow on the master image:

1. Run `Install-Tanium.ps1` to install the client (and wait for your image policy tag, if used).
2. Let the client receive its policies and finish any other image configuration.
3. Run `Set-TaniumGoldenImage.ps1` as the last step before sealing.
4. Shut down and capture the image **without** restarting the Tanium services or rebooting.

## Requirements

- Windows PowerShell 5.1
- Administrator rights
- For `Install-Tanium.ps1`: the Tanium Client installer (`SetupClient.exe`), by default in the same folder as the script

## Install-Tanium.ps1

Runs `SetupClient.exe` silently with the given server(s), port and log verbosity. If `-TaniumPolicy` is set, it then polls the client's tag registry key (`HKLM:\SOFTWARE\WOW6432Node\Tanium\Tanium Client\Sensor Data\Tags`) once per second until the tag appears or the timeout passes.

### Parameters

| Parameter | Default | Description |
| --- | --- | --- |
| `Servers` | `server1.domain.local`, `server2.domain.local` | Tanium server(s). Accepts an array or a single comma-separated string. |
| `ServerPort` | `17472` | Tanium server port (1–65535). |
| `VerbosityLevel` | `1` | Client log verbosity: `1`, `41` or `91`. |
| `InstallerPath` | `.\SetupClient.exe` (script folder) | Path to the installer. |
| `TaniumPolicy` | *(empty)* | Policy tag to wait for after install. No check when empty. |
| `WaitForPolicyTimeout` | `300` | Seconds to wait for the policy tag (1–86400). |
| `LogPath` | `C:\Windows\Logs\TaniumInstall.log` | Transcript location. |

> Change the default `Servers` value in the script, or always pass `-Servers`, before using it in your environment.

### Examples

```powershell
# Install with default settings, no policy check
.\Install-Tanium.ps1

# Install against two servers and wait up to 10 minutes for the citrix_image tag
.\Install-Tanium.ps1 -Servers "tanium1.corp.local,tanium2.corp.local" -TaniumPolicy citrix_image -WaitForPolicyTimeout 600
```

### Exit codes

| Code | Meaning |
| --- | --- |
| `0` | Installed successfully |
| `3010` | Installed successfully, reboot required |
| `1` | Installation failed (installer returned another exit code, or an error occurred) |

If the policy tag does not land in time, a warning is written but the installer's exit code is still returned.

## Set-TaniumGoldenImage.ps1

Prepares an installed Tanium Client for imaging, following Tanium's guidance on [preparing the Tanium Client on a VDI instance](https://help.tanium.com/bundle/ug_client_cloud/page/client/os_imaging_virtual.html).

The script:

1. If `-TaniumPolicy` is set, checks that the policy tag has landed. If it hasn't, the script throws an error and changes nothing.
1. Locates `TaniumClient.exe` under `Program Files (x86)` or `Program Files`.
2. Stops all services matching `Tanium*`.
3. Removes the client identity settings: `ComputerId`, `LastGoodServerName`, `RegistrationCount`.
4. Applies and verifies these client settings:

   | Setting | Value |
   | --- | --- |
   | `CX.index.FirstScanDistributeOverTimeMinutes` | `1140` |
   | `RandomSensorDelayInSeconds` | `20` |
   | `MaxAgeMultiplier` | `2` |
   | `MinDistributeOverTimeInSeconds` | `60` |
   | `SaveClientStateIntervalInSeconds` | `1800` |

The services are **not** restarted. Starting the client or rebooting before capture makes it re-register and generate a new `ComputerId`.

### Running as SYSTEM (Tamper Protection)

With Tamper Protection enabled, only SYSTEM can stop the Tanium services. When the script is not already running as SYSTEM, it:

1. Registers a temporary scheduled task `TaniumConfig-TempSystemTask` that runs the script as SYSTEM.
2. Waits for it to finish (up to 15 minutes).
3. Prints the log, removes the task and returns the task's exit code.

The script must therefore be run from a `.ps1` file in a location SYSTEM can read.

### Usage

From an elevated PowerShell session:

```powershell
# Prepare the image
.\Set-TaniumGoldenImage.ps1

# Only prepare the image when the citrix_image policy tag has landed
.\Set-TaniumGoldenImage.ps1 -TaniumPolicy citrix_image
```

| Parameter | Default | Description |
| --- | --- | --- |
| `TaniumPolicy` | *(empty)* | Policy tag that must be present before anything is changed. No check when empty. |

### Exit codes

| Code | Meaning |
| --- | --- |
| `0` | All services stopped and all settings removed/applied and verified |
| `1` | Policy tag not present, or one or more steps failed (listed in the output) |

### Log

The transcript is written to `C:\Windows\Logs\TaniumConfig.log`. Remove it before sealing the image if you don't want it in the image.

## Author

Matthijs Koers
